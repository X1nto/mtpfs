import Foundation
import MTPKit
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.mtpd", category: "Engine")

final class MTPService: NSObject, MTPServiceProtocol {

    private var device: MTPDevice?
    private var openVendorID: Int?
    private var openProductID: Int?

    private var cachedStorage: MTPStorageInfo?

    private let stage = MTPObjectStage()

    private let queue = DispatchQueue(label: "dev.xinto.mtpfs.session", qos: .userInitiated)

    private var sessionOwners: Set<Int32> = []
    static let localOwnerPID: Int32 = 0

    var onDeviceLost: (() -> Void)?

    private var callerPID: Int32 {
        NSXPCConnection.current()?.processIdentifier ?? Self.localOwnerPID
    }

    func openSession(reply: @escaping (Data?, Error?) -> Void) {
        openSession(vendorID: nil, productID: nil, owner: callerPID, reply: reply)
    }

    func openSessionForDevice(vendorID: Int, productID: Int, reply: @escaping (Data?, Error?) -> Void) {
        openSession(vendorID: vendorID, productID: productID, owner: Self.localOwnerPID, reply: reply)
    }

    private func openSession(
        vendorID: Int?,
        productID: Int?,
        owner: Int32,
        reply: @escaping (Data?, Error?) -> Void
    ) {
        queue.async {
            if self.device != nil {
                guard let cached = self.cachedStorage else {
                    reply(nil, POSIXError(.EALREADY))
                    return
                }

                if (vendorID != nil && vendorID != self.openVendorID) || (productID != nil && productID != self.openProductID) {
                    let requested = String(format: "%04x:%04x", vendorID ?? 0, productID ?? 0)
                    let open = String(format: "%04x:%04x", self.openVendorID ?? 0, self.openProductID ?? 0)
                    log.error(
                        """
                        openSession: requested \(requested, privacy: .public) but \(open, privacy: .public) is open
                        """
                    )
                    reply(nil, POSIXError(.EBUSY))
                    return
                }

                self.sessionOwners.insert(owner)
                self.encode(cached, reply: reply)
                return
            }

            do {
                let device = try MTPDevice.open(
                    matching: MTPDeviceMatch(vendorID: vendorID, productID: productID)
                )
                self.device = device
                self.openVendorID = vendorID
                self.openProductID = productID
                self.awaitReady(owner: owner, attempt: 0, reply: reply)
            } catch {
                reply(nil, Self.posixError(error))
            }
        }
    }

    private static let readyPollInterval: TimeInterval = 2.0
    private static let readyMaxAttempts = 23

    private func awaitReady(owner: Int32, attempt: Int, reply: @escaping (Data?, Error?) -> Void) {
        guard let device = self.device else {
            reply(nil, POSIXError(.ENODEV))
            return
        }

        if attempt == 0, let storage = device.storage {
            finishOpen(storage, owner: owner, reply: reply)
            return
        }

        switch device.probeStorage() {
        case .ready(let storage):
            finishOpen(storage, owner: owner, reply: reply)

        case .gone(let error):
            releaseDevice()
            reply(nil, Self.posixError(error))

        case .notReady:
            let next = attempt + 1
            guard next < Self.readyMaxAttempts else {
                #if DEBUG
                log.info("device did not become ready within the authorization window")
                #endif

                releaseDevice()
                reply(nil, POSIXError(.ETIMEDOUT))
                return
            }

            #if DEBUG
            if attempt == 0 {
                log.info("device open but storage not ready (authorization pending?)")
            }
            #endif

            queue.asyncAfter(deadline: .now() + Self.readyPollInterval) {
                if self.device !== device {
                    reply(nil, POSIXError(.ENODEV))
                    return
                }
                self.awaitReady(owner: owner, attempt: next, reply: reply)
            }
        }
    }

    private func finishOpen(_ storage: MTPStorage, owner: Int32, reply: (Data?, Error?) -> Void) {
        let info = MTPStorageInfo(
            freeBytes: storage.freeBytes,
            totalBytes: storage.totalBytes,
            label: storage.label
        )
        cachedStorage = info
        sessionOwners = [owner]
        encode(info, reply: reply)
    }

    func refreshStorage(reply: @escaping (Data?, Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(nil, POSIXError(.ENODEV))
                return
            }
            do {
                let storage = try device.refreshStorage()
                let info = MTPStorageInfo(
                    freeBytes: storage.freeBytes,
                    totalBytes: storage.totalBytes,
                    label: storage.label
                )
                self.cachedStorage = info
                self.encode(info, reply: reply)
            } catch {
                reply(nil, self.fail(error, "refreshStorage"))
            }
        }
    }

    func closeSession(reply: @escaping (Error?) -> Void) {
        let owner = callerPID
        queue.async {
            self.retire(owner: owner)
            reply(nil)
        }
    }

    func releaseSessionsForDeadClient(pid: Int32) {
        queue.async {
            self.retire(owner: pid)
        }
    }

    func forceCloseSession() {
        queue.async {
            if self.device == nil {
                return
            }

            #if DEBUG
            log.info("forceCloseSession: releasing device, discarding \(self.sessionOwners.count) holder(s)")
            #endif

            self.sessionOwners.removeAll()
            self.releaseDevice()
        }
    }

    private func retire(owner: Int32) {
        if sessionOwners.remove(owner) == nil {
            return
        }

        if sessionOwners.isEmpty {
            releaseDevice()
        }
    }

    private func releaseDevice() {
        device?.release()
        device = nil
        stage.removeAll()
        cachedStorage = nil
        openVendorID = nil
        openProductID = nil
    }

    private func handleDeviceLost() {
        device = nil
        stage.removeAll()
        cachedStorage = nil
        openVendorID = nil
        openProductID = nil
        onDeviceLost?()
    }

    func listObjects(parentID: UInt32, reply: @escaping (Data?, Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(nil, POSIXError(.ENODEV))
                return
            }

            do {
                let objects = try device.listChildren(parentID: parentID)
                self.encode(objects.map(Self.dto), reply: reply)
            } catch {
                reply(nil, self.fail(error, "listObjects(parent=\(parentID))"))
            }
        }
    }

    func getObjectInfo(objectID: UInt32, reply: @escaping (Data?, Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(nil, POSIXError(.ENODEV))
                return
            }
            do {
                let object = try device.metadata(objectID: objectID)
                let mtpObjectInfo = MTPObjectInfo(
                    objectID: object.objectID,
                    parentID: object.parentID,
                    name: object.name,
                    isDirectory: object.isDirectory,
                    fileSize: object.size,
                    modificationDate: object.modificationDate,
                    creationDate: object.creationDate
                )
                self.encode(mtpObjectInfo, reply: reply)
            } catch {
                reply(nil, self.fail(error, "getObjectInfo(\(objectID))"))
            }
        }
    }

    func readFile(objectID: UInt32, offset: UInt64, length: UInt64, reply: @escaping (Data?, Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(nil, POSIXError(.ENODEV))
                return
            }

            if device.capabilities.rangedRead {
                do {
                    reply(try device.readRange(objectID: objectID, offset: offset, length: length), nil)
                    return
                } catch let error as MTPError where error.isFatal {
                    self.handleDeviceLost()
                    reply(nil, Self.posixError(error))
                    return
                } catch {
                    // fall through to a whole-object read.
                }
            }

            let totalSize: UInt64
            do {
                totalSize = try device.metadata(objectID: objectID).size
            } catch {
                reply(nil, self.fail(error, "readFile.metadata(\(objectID))"))
                return
            }

            do {
                let data = try self.stage.read(
                    objectID: objectID,
                    offset: offset,
                    length: length,
                    totalSize: totalSize
                ) { sink in
                    try device.readWholeObject(objectID: objectID, into: sink)
                }
                reply(data, nil)
            } catch let error as POSIXError where error.code == .ENOSPC {
                log.error("readFile(obj=\(objectID)): no space to stage object of \(totalSize) bytes")
                reply(nil, error)
            } catch {
                reply(nil, self.fail(error, "readWholeObject(\(objectID))"))
            }
        }
    }

    func writeFile(objectID: UInt32, offset: UInt64, data: Data, reply: @escaping (Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(POSIXError(.ENODEV))
                return
            }

            do {
                try device.write(objectID: objectID, offset: offset, data: data)
                self.stage.invalidate(objectID)
                reply(nil)
            } catch {
                reply(self.fail(error, "writeFile(\(objectID))"))
            }
        }
    }

    func truncateFile(objectID: UInt32, size: UInt64, reply: @escaping (Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(POSIXError(.ENODEV))
                return
            }

            do {
                try device.truncate(objectID: objectID, to: size)
                self.stage.invalidate(objectID)
                reply(nil)
            } catch {
                reply(self.fail(error, "truncateFile(\(objectID))"))
            }
        }
    }

    func createFile(parentID: UInt32, name: String, size: UInt64, reply: @escaping (UInt32, Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(0, POSIXError(.ENODEV))
                return
            }

            do {
                reply(try device.createFile(parentID: parentID, name: name), nil)
            } catch {
                reply(0, self.fail(error, "createFile(parent=\(parentID))"))
            }
        }
    }

    func createDirectory(parentID: UInt32, name: String, reply: @escaping (UInt32, Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(0, POSIXError(.ENODEV))
                return
            }

            do {
                reply(try device.createFolder(parentID: parentID, name: name), nil)
            } catch {
                reply(0, self.fail(error, "createDirectory(parent=\(parentID))"))
            }
        }
    }

    func deleteObject(objectID: UInt32, reply: @escaping (Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(POSIXError(.ENODEV))
                return
            }

            self.stage.invalidate(objectID)

            do {
                if try device.metadata(objectID: objectID).isDirectory,
                   try !device.listChildren(parentID: objectID).isEmpty
                {
                    reply(POSIXError(.ENOTEMPTY))
                    return
                }
                try device.delete(objectID: objectID)
                reply(nil)
            } catch {
                reply(self.fail(error, "deleteObject(\(objectID))"))
            }
        }
    }

    func renameObject(objectID: UInt32, newName: String, reply: @escaping (Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(POSIXError(.ENODEV))
                return
            }

            do {
                try device.rename(objectID: objectID, to: newName)
                reply(nil)
            } catch {
                reply(self.fail(error, "renameObject(\(objectID))"))
            }
        }
    }

    func moveObject(objectID: UInt32, toParentID: UInt32, reply: @escaping (Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(POSIXError(.ENODEV))
                return
            }

            do {
                try device.move(objectID: objectID, toParent: toParentID)
                reply(nil)
            } catch {
                reply(self.fail(error, "moveObject(\(objectID) -> \(toParentID))"))
            }
        }
    }

    private func fail(_ error: Error, _ operation: String) -> Error {
        guard let mtp = error as? MTPError else {
            return error
        }

        if mtp.isFatal {
            log.error("\(operation, privacy: .public): device lost")
            handleDeviceLost()
        }
        return Self.posixError(mtp)
    }

    private static func posixError(_ error: Error) -> POSIXError {
        guard let mtpError = error as? MTPError else {
            return POSIXError(.EIO)
        }
        return mtpError.posixError()
    }

    private static func dto(_ object: MTPObject) -> MTPObjectInfo {
        MTPObjectInfo(
            objectID: object.objectID,
            parentID: object.parentID,
            name: object.name,
            isDirectory: object.isDirectory,
            fileSize: object.size,
            modificationDate: object.modificationDate,
            creationDate: object.creationDate
        )
    }

    private func encode<T: Encodable>(_ value: T, reply: (Data?, Error?) -> Void) {
        do {
            reply(try JSONEncoder().encode(value), nil)
        } catch {
            reply(nil, error)
        }
    }
}

private extension MTPError {

    func posixError() -> POSIXError {
        switch self {
        case .deviceNotFound: POSIXError(.ENODEV)
        case .outOfMemory: POSIXError(.ENOMEM)
        case .storageFull: POSIXError(.ENOSPC)
        case .operationCancelled: POSIXError(.ECANCELED)
        case .accessDenied: POSIXError(.EACCES)
        case .writeProtected: POSIXError(.EROFS)
        case .objectNotFound: POSIXError(.ENOENT)
        case .storageOffline: POSIXError(.ENXIO)
        case .deviceBusy: POSIXError(.EAGAIN)
        case .deviceTimedOut: POSIXError(.ETIMEDOUT)
        case .invalidData: POSIXError(.EINVAL)
        case .folderNotEmpty: POSIXError(.ENOTEMPTY)
        case .operationUnsupported: POSIXError(.ENOTSUP)
        case .storageNotReady: POSIXError(.EAGAIN)
        case .ioFailure: POSIXError(.EIO)
        case .deviceError: POSIXError(.EIO)
        }
    }
}
