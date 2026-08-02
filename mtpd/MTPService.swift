import Foundation
import MTPKit
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.mtpd", category: "Engine")

final class MTPService: NSObject, MTPServiceProtocol {

    // MARK: - Device session

    private var device: MTPDevice?
    private var openVendorID: Int?
    private var openProductID: Int?

    private var cachedStorage: MTPStorageInfo?

    private let readStage = MTPReadStage()
    private let writeStage = MTPWriteStage()

    private var freshlyCreated: Set<UInt32> = []

    private func writeStrategy(for device: MTPDevice) -> MTPWriteStrategy {
        device.capabilities.writeStrategy
    }

    // MARK: - Listings cache

    private var listings: [UInt32: (entries: [MTPObjectInfo], stamp: DispatchTime)] = [:]

    private var listingParent: [UInt32: UInt32] = [:]

    private static let listingTTL: DispatchTimeInterval = .seconds(10)

    private static let rangedReadAttempts = 3
    private static let rangedReadRetryInterval: TimeInterval = 0.25

    private static let transientAttempts = 3
    private static let transientRetryInterval: TimeInterval = 0.2

    // MARK: - Write buffer

    private struct WriteBuffer {
        let objectID: UInt32
        let start: UInt64
        var data: Data

        /// Device offset the next byte would land at
        var end: UInt64 { start + UInt64(data.count) }
    }

    private var writeBuffer: WriteBuffer?

    private static let writeBufferLimit = 8 << 20

    private var pendingWriteFailure: (objectID: UInt32, error: Error)?

    private var coalescedWrites = 0
    private var coalescedFlushes = 0

    private func consumeWriteFailure(for objectID: UInt32) throws {
        guard let pending = pendingWriteFailure, pending.objectID == objectID else {
            return
        }
        pendingWriteFailure = nil
        throw pending.error
    }

    private func flushWriteBuffer() {
        guard let buffer = writeBuffer, let device else {
            writeBuffer = nil
            return
        }

        writeBuffer = nil

        guard !buffer.data.isEmpty else {
            return
        }

        coalescedFlushes += 1

        do {
            try device.write(objectID: buffer.objectID, offset: buffer.start, data: buffer.data)
            invalidateReadAhead(objectID: buffer.objectID)
            invalidateListings(around: buffer.objectID)
        } catch {
            log.error(
                """
                flushWriteBuffer(obj=\(buffer.objectID), off=\(buffer.start), \
                len=\(buffer.data.count)): \(String(describing: error), privacy: .public)
                """
            )
            pendingWriteFailure = (buffer.objectID, self.fail(error, "flushWriteBuffer"))
        }
    }

    private func flushWriteBuffer(touching objectID: UInt32) {
        if writeBuffer?.objectID == objectID {
            flushWriteBuffer()
        }
    }

    // MARK: - Read-ahead

    private struct ReadAhead {
        let objectID: UInt32
        let start: UInt64
        let data: Data

        var nextExpected: UInt64
    }

    private var readAhead: ReadAhead?

    private static let readAheadSize: UInt64 = 4 << 20

    private func readAheadHit(objectID: UInt32, offset: UInt64, length: UInt64) -> Data? {
        guard var window = readAhead,
              window.objectID == objectID,
              offset >= window.start
        else {
            return nil
        }

        let available = window.start + UInt64(window.data.count)
        guard offset < available else {
            return nil
        }

        let wanted = min(length, available - offset)
        guard wanted == length else {
            return nil
        }

        let lower = window.data.startIndex + Int(offset - window.start)
        window.nextExpected = offset + wanted
        readAhead = window
        return window.data.subdata(in: lower..<(lower + Int(wanted)))
    }

    private func isSequential(objectID: UInt32, offset: UInt64) -> Bool {
        guard let window = readAhead, window.objectID == objectID else {
            return false
        }
        return window.nextExpected == offset
    }

    private func storeReadAhead(objectID: UInt32, start: UInt64, data: Data, served: UInt64) {
        readAhead = ReadAhead(
            objectID: objectID,
            start: start,
            data: data,
            nextExpected: start + served
        )
    }

    private func invalidateReadAhead(objectID: UInt32) {
        if readAhead?.objectID == objectID {
            readAhead = nil
        }
    }

    private func cachedListing(parentID: UInt32) -> [MTPObjectInfo]? {
        guard let entry = listings[parentID] else {
            return nil
        }

        if entry.stamp + Self.listingTTL < .now() {
            dropListing(parentID: parentID)
            return nil
        }

        return entry.entries
    }

    private func storeListing(_ entries: [MTPObjectInfo], parentID: UInt32) {
        dropListing(parentID: parentID)
        listings[parentID] = (entries, .now())
        for entry in entries {
            listingParent[entry.objectID] = parentID
        }
    }

    private func dropListing(parentID: UInt32) {
        guard let existing = listings.removeValue(forKey: parentID) else {
            return
        }
        for entry in existing.entries where listingParent[entry.objectID] == parentID {
            listingParent[entry.objectID] = nil
        }
    }

    private func invalidateListings(around objectID: UInt32) {
        dropListing(parentID: objectID)
        if let parent = listingParent[objectID] {
            dropListing(parentID: parent)
        }
    }

    // MARK: - Concurrency

    private let queue = DispatchQueue(label: "dev.xinto.mtpfs.session", qos: .userInitiated)

    private var sessionOwners: Set<Int32> = []
    static let localOwnerPID: Int32 = 0

    var onDeviceLost: (() -> Void)?

    private var callerPID: Int32 {
        NSXPCConnection.current()?.processIdentifier ?? Self.localOwnerPID
    }

    // MARK: - Session management

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
        flushWriteBuffer()
        device?.release()
        device = nil
        readStage.removeAll()
        writeStage.removeAll()
        freshlyCreated.removeAll()
        readAhead = nil
        listings.removeAll()
        listingParent.removeAll()
        cachedStorage = nil
        openVendorID = nil
        openProductID = nil
    }

    private func handleDeviceLost() {
        device = nil
        readStage.removeAll()
        writeStage.removeAll()
        freshlyCreated.removeAll()
        readAhead = nil
        listings.removeAll()
        listingParent.removeAll()
        cachedStorage = nil
        openVendorID = nil
        openProductID = nil
        onDeviceLost?()
    }

    // MARK: - Read

    func listObjects(parentID: UInt32, reply: @escaping (Data?, Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(nil, POSIXError(.ENODEV))
                return
            }

            if let cached = self.cachedListing(parentID: parentID) {
                self.encode(cached, reply: reply)
                return
            }

            do {
                let objects = try self.retryingTransient {
                    try device.listChildren(parentID: parentID)
                }.map(Self.dto)
                self.storeListing(objects, parentID: parentID)
                self.encode(objects, reply: reply)
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
                self.flushWriteBuffer(touching: objectID)
                let object = try self.retryingTransient { try device.metadata(objectID: objectID) }
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

            self.flushWriteBuffer(touching: objectID)

            if device.capabilities.rangedRead {
                if let hit = self.readAheadHit(objectID: objectID, offset: offset, length: length) {
                    reply(hit, nil)
                    return
                }

                let fetchLength = self.isSequential(objectID: objectID, offset: offset)
                    ? max(length, Self.readAheadSize)
                    : length

                var lastError: Error?
                for attempt in 0..<Self.rangedReadAttempts {
                    do {
                        let fetched = try device.readRange(
                            objectID: objectID, offset: offset, length: fetchLength
                        )
                        self.storeReadAhead(objectID: objectID, start: offset, data: fetched, served: length)
                        reply(fetched.count > Int(length) ? Data(fetched.prefix(Int(length))) : fetched, nil)
                        return
                    } catch let error as MTPError where error.isFatal {
                        self.handleDeviceLost()
                        reply(nil, Self.posixError(error))
                        return
                    } catch let error as MTPError where error == .operationUnsupported {
                        lastError = error
                        break
                    } catch {
                        lastError = error
                        if attempt < Self.rangedReadAttempts - 1 {
                            Thread.sleep(forTimeInterval: Self.rangedReadRetryInterval)
                        }
                    }
                }

                log.error(
                    """
                    readFile(obj=\(objectID), off=\(offset)): ranged read failed (\(String(describing: lastError), privacy: .public))
                    """
                )
            }

            let totalSize: UInt64
            do {
                totalSize = try device.metadata(objectID: objectID).size
            } catch {
                reply(nil, self.fail(error, "readFile.metadata(\(objectID))"))
                return
            }

            do {
                let data = try self.readStage.read(
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

    // MARK: - Write

    func writeFile(objectID: UInt32, offset: UInt64, data: Data, reply: @escaping (Error?) -> Void) {
        queue.async {
            guard self.device != nil else {
                reply(POSIXError(.ENODEV))
                return
            }

            do {
                try self.consumeWriteFailure(for: objectID)
            } catch {
                reply(error)
                return
            }

            self.readStage.invalidate(objectID)

            if let device = self.device,
               self.writeStrategy(for: device) == .wholeFile,
               self.freshlyCreated.contains(objectID)
            {
                do {
                    try self.writeStage.write(objectID: objectID, offset: offset, data: data)
                    reply(nil)
                } catch {
                    reply(error)
                }
                return
            }

            // Extend the open run when this write continues it; otherwise commit what we have and
            // start fresh. Anything non-consecutive therefore behaves exactly as it did before.
            if var buffer = self.writeBuffer,
               buffer.objectID == objectID,
               buffer.end == offset
            {
                buffer.data.append(data)
                self.writeBuffer = buffer
            } else {
                self.flushWriteBuffer()
                self.writeBuffer = WriteBuffer(objectID: objectID, start: offset, data: data)
            }

            self.coalescedWrites += 1

            if let buffer = self.writeBuffer, buffer.data.count >= Self.writeBufferLimit {
                self.flushWriteBuffer()
                if let pending = self.pendingWriteFailure, pending.objectID == objectID {
                    self.pendingWriteFailure = nil
                    reply(pending.error)
                    return
                }
            }

            reply(nil)
        }
    }

    /// - Parameter reply: the object's ID after the commit or 0 if unchanged.
    func closeFile(objectID: UInt32, reply: @escaping (UInt32, Error?) -> Void) {
        queue.async {
            if self.writeStage.isStaging(objectID) {
                self.commitWholeFile(objectID: objectID, reply: reply)
                return
            }

            self.flushWriteBuffer(touching: objectID)

            #if DEBUG
            if self.coalescedWrites > 0 {
                log.notice(
                    """
                    coalescing: \(self.coalescedWrites) FSKit writes -> \
                    \(self.coalescedFlushes) device transactions
                    """
                )
            }
            #endif
            self.coalescedWrites = 0
            self.coalescedFlushes = 0

            do {
                try self.consumeWriteFailure(for: objectID)
                reply(0, nil)
            } catch {
                reply(0, error)
            }
        }
    }

    private func commitWholeFile(objectID: UInt32, reply: @escaping (UInt32, Error?) -> Void) {
        guard let device else {
            writeStage.discard(objectID)
            freshlyCreated.remove(objectID)
            reply(0, POSIXError(.ENODEV))
            return
        }

        guard let staged = writeStage.take(objectID: objectID) else {
            freshlyCreated.remove(objectID)
            reply(0, POSIXError(.EIO))
            return
        }

        defer {
            writeStage.finish(fd: staged.fd, url: staged.url)
            freshlyCreated.remove(objectID)
        }

        // Name and parent have to be read before the placeholder is deleted.
        let placeholder: MTPObject
        do {
            placeholder = try device.metadata(objectID: objectID)
        } catch {
            reply(0, fail(error, "commitWholeFile.metadata(\(objectID))"))
            return
        }

        do {
            try device.delete(objectID: objectID)
        } catch {
            reply(0, fail(error, "commitWholeFile.delete(\(objectID))"))
            return
        }

        invalidateReadAhead(objectID: objectID)
        invalidateListings(around: objectID)
        readStage.invalidate(objectID)

        do {
            let newID = try device.sendFile(
                parentID: placeholder.parentID,
                name: placeholder.name,
                size: staged.size,
                fileDescriptor: staged.fd
            )
            dropListing(parentID: placeholder.parentID)

            #if DEBUG
            log.notice("wholeFile: obj \(objectID) -> \(newID), \(staged.size) bytes in one SendObject")
            #endif

            reply(newID, nil)
        } catch {
            log.error(
                """
                commitWholeFile(obj=\(objectID), size=\(staged.size)): send failed after the placeholder was removed
                """
            )
            dropListing(parentID: placeholder.parentID)
            reply(0, fail(error, "commitWholeFile.send(\(objectID))"))
        }
    }

    func truncateFile(objectID: UInt32, size: UInt64, reply: @escaping (Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(POSIXError(.ENODEV))
                return
            }

            if self.writeStrategy(for: device) == .wholeFile, self.freshlyCreated.contains(objectID) {
                reply(nil)
                return
            }

            do {
                self.flushWriteBuffer(touching: objectID)
                try device.truncate(objectID: objectID, to: size)
                self.readStage.invalidate(objectID)
                self.invalidateReadAhead(objectID: objectID)
                self.invalidateListings(around: objectID)
                reply(nil)
            } catch {
                reply(self.fail(error, "truncateFile(\(objectID))"))
            }
        }
    }

    // MARK: - Object management

    func createFile(parentID: UInt32, name: String, size: UInt64, reply: @escaping (UInt32, Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(0, POSIXError(.ENODEV))
                return
            }

            do {
                let objectID = try device.createFile(parentID: parentID, name: name)
                self.dropListing(parentID: parentID)
                if self.writeStrategy(for: device) == .wholeFile {
                    self.freshlyCreated.insert(objectID)
                }
                reply(objectID, nil)
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
                let objectID = try device.createFolder(parentID: parentID, name: name)
                self.dropListing(parentID: parentID)
                reply(objectID, nil)
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

            self.readStage.invalidate(objectID)
            self.invalidateReadAhead(objectID: objectID)

            if self.writeBuffer?.objectID == objectID {
                self.writeBuffer = nil
            }

            self.pendingWriteFailure = self.pendingWriteFailure?.objectID == objectID
                ? nil : self.pendingWriteFailure

            do {
                if try device.metadata(objectID: objectID).isDirectory,
                   try !device.listChildren(parentID: objectID).isEmpty
                {
                    reply(POSIXError(.ENOTEMPTY))
                    return
                }

                try device.delete(objectID: objectID)
                self.invalidateListings(around: objectID)
                reply(nil)
            } catch {
                self.invalidateListings(around: objectID)
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
                self.flushWriteBuffer(touching: objectID)
                try device.rename(objectID: objectID, to: newName)
                self.invalidateListings(around: objectID)
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
                self.flushWriteBuffer(touching: objectID)
                try device.move(objectID: objectID, toParent: toParentID)
                self.invalidateListings(around: objectID)
                self.dropListing(parentID: toParentID)
                reply(nil)
            } catch {
                reply(self.fail(error, "moveObject(\(objectID) -> \(toParentID))"))
            }
        }
    }

    // MARK: - Helpers

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

    private func retryingTransient<T>(_ operation: () throws -> T) throws -> T {
        var attempt = 0
        while true {
            do {
                return try operation()
            } catch let error as MTPError where error == .deviceBusy || error == .storageNotReady {
                attempt += 1
                guard attempt < Self.transientAttempts else {
                    throw error
                }
                Thread.sleep(forTimeInterval: Self.transientRetryInterval * Double(attempt))
            }
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
        case .objectTooLarge: POSIXError(.EFBIG)
        case .partialDeletion: POSIXError(.EIO)
        }
    }
}
