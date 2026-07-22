import DiskArbitration
import Foundation
import FSKit
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.mtpd", category: "Mounter")

enum MTPMounter {

    static func mount(volumeName: String, deviceKey: String) async throws -> URL {
//        if #available(macOS 27.0, *) {
//            let url = try MTPPathMarker.create(volumeName: volumeName, deviceKey: deviceKey)
//            let resource = FSPathURLResource(url: url, writable: true)
//            let mountPath = try await FSClient.shared.mountSingleVolume(resource: resource, bundleID: MTPModuleBundleID, options: [])
//            return mountPath
//        } else {
        let mountpoint = try await MountHelperClient.prepareMountpoint(name: volumeName)
        let markerURL = try MTPPathMarker.create(volumeName: volumeName, deviceKey: deviceKey)
        do {
            try await runMount(special: markerURL.path, mountpoint: mountpoint)
        } catch {
            await MountHelperClient.removeMountpoint(path: mountpoint)
            throw error
        }
        return URL(fileURLWithPath: mountpoint)
//        }
    }

    static func cleanupMountpoint(path: String) async {
//        if #available(macOS 27.0, *) {
//            return
//        }
        await MountHelperClient.removeMountpoint(path: path)
    }

    static func unmountBestEffort(path: String) throws {
        if (try? unmount(path: path)) != nil {
            return
        }
        if (try? unmount(path: path, force: true)) != nil {
            return
        }
        try unmountViaDiskArbitration(path: path, force: true)
    }

    static func unmountPolitely(path: String) throws {
        do {
            try unmount(path: path, force: false)
        } catch {
            try unmountViaDiskArbitration(path: path)
        }
    }

    static func unmount(path: String, force: Bool = false) throws {
        if Darwin.unmount(path, force ? MNT_FORCE : 0) != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            log.error("""
                unmount(\(path, privacy: .public), force=\(force)) failed: \
                \(String(cString: strerror(errno)), privacy: .public)
                """)
            throw POSIXError(code)
        }
    }

    static func unmountViaDiskArbitration(path: String, force: Bool = false, timeout: TimeInterval = 10) throws {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw POSIXError(.EIO)
        }
        guard let disk = DADiskCreateFromVolumePath(
            kCFAllocatorDefault, session,
            URL(fileURLWithPath: path) as CFURL
        ) else {
            throw POSIXError(.ENODEV)
        }

        let callbackQueue = DispatchQueue(label: "dev.xinto.mtpfs.mtpd.diskarb")
        DASessionSetDispatchQueue(session, callbackQueue)
        defer { DASessionSetDispatchQueue(session, nil) }

        final class Outcome {
            let semaphore = DispatchSemaphore(value: 0)
            var dissentStatus: DAReturn?
        }
        let outcome = Outcome()
        let context = Unmanaged.passRetained(outcome).toOpaque()

        let options = DADiskUnmountOptions(force ? kDADiskUnmountOptionForce : kDADiskUnmountOptionDefault)
        DADiskUnmount(disk, options, { _, dissenter, context in
            guard let context else {
                return
            }
            let outcome = Unmanaged<Outcome>.fromOpaque(context).takeRetainedValue()
            if let dissenter {
                outcome.dissentStatus = DADissenterGetStatus(dissenter)
            }
            outcome.semaphore.signal()
        }, context)

        guard outcome.semaphore.wait(timeout: .now() + timeout) == .success else {
            log.error("unmount via DiskArbitration of \(path, privacy: .public) timed out")
            throw POSIXError(.ETIMEDOUT)
        }
        if let status = outcome.dissentStatus {
            log.error("DiskArbitration refused to unmount \(path, privacy: .public): 0x\(String(UInt32(bitPattern: status), radix: 16), privacy: .public)")
            // DA dissent status embeds an errno in its low bits for POSIX-derived refusals.
            throw POSIXError(POSIXErrorCode(rawValue: Int32(status & 0x3FFF)) ?? .EBUSY)
        }
    }

    private static func runMount(special: String, mountpoint: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/mount")
            process.arguments = ["-F", "-t", "mtpfs", special, mountpoint]
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errData = stderrPipe.fileHandleForReading.availableData
                    let errMsg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(p.terminationStatus)"
                    log.error("mount -F failed: \(errMsg, privacy: .public)")
                    continuation.resume(throwing: POSIXError(.EPERM))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
