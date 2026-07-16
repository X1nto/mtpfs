import Foundation
import IOKit
import IOKit.usb
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.mtpd", category: "DeviceWatcher")

/// A USB interface that *might* be MTP.
struct MTPCandidate {
    let entryID: UInt64
    let vendorID: Int
    let productID: Int
    let serial: String?
    let productName: String?

    var deviceKey: String {
        if let serial, !serial.isEmpty {
            return serial
        }

        // In rare cases where the serial isn't provided, we fall back to the USB address.
        return String(format: "%04x:%04x@%llu", vendorID, productID, entryID)
    }

    var displayName: String {
        productName ?? "MTP Device"
    }
}

protocol MTPDeviceWatcherDelegate: AnyObject {
    
    /// A candidate appeared. The delegate MUST attempt an MTP session and only attach a carrier
    /// if that session opens.
    func watcher(_ watcher: MTPDeviceWatcher, didFindCandidate candidate: MTPCandidate)
    
    /// The candidate's interface went away.
    func watcher(_ watcher: MTPDeviceWatcher, didLoseCandidate candidate: MTPCandidate)
}

final class MTPDeviceWatcher {
    weak var delegate: MTPDeviceWatcherDelegate?

    private let queue = DispatchQueue(label: "dev.xinto.mtpfs.mtpd.watcher")

    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var candidates: [UInt64: MTPCandidate] = [:]

    func start() {
        queue.sync {
            guard port == nil else {
                return
            }
            port = IONotificationPortCreate(kIOMainPortDefault)
            guard let port else {
                return
            }
            IONotificationPortSetDispatchQueue(port, queue)

            addNotifications(for: self.stillImageMatch)
            addNotifications(for: self.vendorSpecificMatch)
        }
    }

    func stop() {
        queue.sync {
            for iter in iterators where iter != 0 {
                IOObjectRelease(iter)
            }
            iterators.removeAll()
            if let p = port {
                IONotificationPortDestroy(p)
                port = nil
            }
            candidates.removeAll()
        }
    }

    func forget(_ candidate: MTPCandidate) {
        queue.async {
            self.candidates.removeValue(forKey: candidate.entryID)
        }
    }

    func rescan() {
        queue.async {
            for makeMatch in [self.stillImageMatch, self.vendorSpecificMatch] {
                var iterator: io_iterator_t = 0
                guard IOServiceGetMatchingServices(kIOMainPortDefault, makeMatch() as CFDictionary, &iterator) == KERN_SUCCESS else {
                    continue
                }
                defer { IOObjectRelease(iterator) }
                self.handleAdded(iterator)
            }
        }
    }

    private func stillImageMatch() -> NSMutableDictionary {
        let dict = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
        dict["bInterfaceClass"] = 6
        dict["bInterfaceSubClass"] = 1
        dict["bInterfaceProtocol"] = 1
        return dict
    }

    private func vendorSpecificMatch() -> NSMutableDictionary {
        let dict = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
        dict["bInterfaceClass"] = 255
        return dict
    }


    private func addNotifications(for makeMatch: () -> NSMutableDictionary) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let port else {
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()

        var addedIter: io_iterator_t = 0
        let addedResult = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification,
            makeMatch() as CFDictionary,
            { context, iter in
                guard let context else {
                    return
                }
                Unmanaged<MTPDeviceWatcher>.fromOpaque(context).takeUnretainedValue().handleAdded(iter)
            },
            context, &addedIter
        )
        
        if addedResult != KERN_SUCCESS {
            log.error("IOServiceAddMatchingNotification(first match) failed: 0x\(String(addedResult, radix: 16), privacy: .public)")
        }
        
        handleAdded(addedIter)
        iterators.append(addedIter)

        var removedIter: io_iterator_t = 0
        let removedResult = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification,
            makeMatch() as CFDictionary,
            { context, iter in
                guard let context else {
                    return
                }
                Unmanaged<MTPDeviceWatcher>.fromOpaque(context).takeUnretainedValue().handleRemoved(iter)
            },
            context, &removedIter
        )
        if removedResult != KERN_SUCCESS {
            log.error("IOServiceAddMatchingNotification(terminated) failed: 0x\(String(removedResult, radix: 16), privacy: .public)")
        }
        handleRemoved(removedIter)
        iterators.append(removedIter)
    }

    private func handleAdded(_ iter: io_iterator_t) {
        var service = IOIteratorNext(iter)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iter)
            }
            if !isPlausible(service) {
                continue
            }
            guard let candidate = makeCandidate(service) else {
                continue
            }
            if candidates[candidate.entryID] != nil {
                continue
            }
            candidates[candidate.entryID] = candidate
            delegate?.watcher(self, didFindCandidate: candidate)
        }
    }

    private func handleRemoved(_ iter: io_iterator_t) {
        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) != KERN_SUCCESS {
                continue
            }
            guard let candidate = candidates.removeValue(forKey: entryID) else {
                continue
            }
            delegate?.watcher(self, didLoseCandidate: candidate)
        }
    }
    
    private func isPlausible(_ service: io_service_t) -> Bool {
        let cls = intProperty(service, "bInterfaceClass") ?? -1
        let subclass = intProperty(service, "bInterfaceSubClass") ?? -1
        let proto = intProperty(service, "bInterfaceProtocol") ?? -1

        // subclass 66 and protocol ID 1 correspond to ADB
        if subclass == 66 && proto == 1 {
            return false
        }

        if cls == 6 {
            return subclass == 1 && proto == 1
        }

        if cls == 255 {
            // AOSP sets iInterface = "MTP" on the MTP interface.
            // Requiring it keeps us away from every other vendor-specific interface on the bus.
            guard let name = interfaceName(service) else {
                return false
            }
            return name.caseInsensitiveCompare("MTP") == .orderedSame
        }

        return false
    }

    private func makeCandidate(_ service: io_service_t) -> MTPCandidate? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else {
            return nil
        }

        var device: io_service_t = 0
        IORegistryEntryGetParentEntry(service, kIOServicePlane, &device)
        defer {
            if device != 0 {
                IOObjectRelease(device)
            }
        }

        return MTPCandidate(
            entryID: entryID,
            vendorID: device != 0 ? (intProperty(device, "idVendor") ?? 0) : 0,
            productID: device != 0 ? (intProperty(device, "idProduct") ?? 0) : 0,
            serial: device != 0 ? stringProperty(device, "kUSBSerialNumberString") : nil,
            productName: device != 0 ? stringProperty(device, "kUSBProductString") : nil
        )
    }

    private func interfaceName(_ service: io_service_t) -> String? {
        stringProperty(service, "kUSBString") ?? stringProperty(service, "USB Interface Name")
    }

    private func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        guard let v = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return (v.takeRetainedValue() as? NSNumber)?.intValue
    }

    private func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        guard let v = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return v.takeRetainedValue() as? String
    }
}
