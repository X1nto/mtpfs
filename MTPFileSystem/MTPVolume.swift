import FSKit
import Foundation
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.fsext", category: "Volume")

class MTPVolume: FSVolume {

    // MARK: - XPC Service

    private struct ServiceBinding {
        let connection: NSXPCConnection
        let client: MTPServiceClient
    }

    private var _binding: ServiceBinding?
    private let serviceLock = NSLock()
    private var service: MTPServiceClient? {
        serviceLock.withLock {
            _binding?.client
        }
    }

    // MARK: - Storage Info

    private static let storageTTL: UInt64 = 3 * NSEC_PER_SEC
    private let storageLock = NSLock()
    private var _storageInfo: MTPStorageInfo?
    private var _storageStamp: UInt64 = 0
    private var _storageRefreshing = false

    // MARK: - Item Cache

    private let identity = MTPIdentityTable()
    private let root = MTPItem(objectID: MTPItem.rootObjectID)
    private let itemsLock = NSLock()
    private var itemsByID: [UInt32: MTPItem] = [:]

    init(
        volumeName: String = "MTP Device",
        volumeID: FSVolume.Identifier = .init(uuid: UUID())
    ) {
        super.init(volumeID: volumeID, volumeName: FSFileName(string: volumeName))
    }

    // MARK: - Service Management

    private func makeBinding() throws -> ServiceBinding {
        let conn = NSXPCConnection(machServiceName: MTPMachServiceName, options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: MTPServiceProtocol.self)
        conn.invalidationHandler = { [weak self] in
            self?.dropService()
        }
        conn.interruptionHandler = { [weak self] in
            self?.dropService()
        }
        conn.resume()
        return ServiceBinding(connection: conn, client: MTPServiceClient(connection: conn))
    }

    private func requireService() throws -> MTPServiceClient {
        try serviceLock.withLock {
            if let existing = _binding?.client {
                return existing
            }

            let binding = try makeBinding()

            let previousConnection = _binding?.connection
            _binding = binding
            DispatchQueue.global(qos: .utility).async {
                previousConnection?.invalidate()
            }

            let client = binding.client
            Task {
                do {
                    _ = try await client.openSession()
                } catch {
                    log.error("reconnect openSession failed: \(String(describing: error), privacy: .public)")
                }
            }
            return client
        }
    }

    private func dropService() {
        serviceLock.withLock {
            _binding = nil
        }
    }

    // MARK: - Item Management

    private func item(for info: MTPObjectInfo, parent: UInt32) -> MTPItem {
        itemsLock.withLock {
            if let existing = itemsByID[info.objectID] {
                existing.info = info
                return existing
            }
            let created = MTPItem(objectID: info.objectID, parentObjectID: parent, info: info)
            itemsByID[info.objectID] = created
            return created
        }
    }

    private func rekeyItem(from oldObjectID: UInt32, to newObjectID: UInt32, item: MTPItem) {
        itemsLock.withLock {
            itemsByID[oldObjectID] = nil
            itemsByID[newObjectID] = item
        }
    }

    private func forget(objectID: UInt32) {
        itemsLock.withLock {
            itemsByID[objectID] = nil
        }
    }

    // MARK: - Directory Listing

    private func listing(for directory: MTPItem) async throws -> DirectorySnapshot {
        if let snapshot = directory.snapshot {
            return snapshot
        }

        let (task, generation) = directory.listingTask {
            Task { [weak self] () throws -> DirectorySnapshot in
                guard let self else {
                    throw POSIXError(.EIO)
                }
                let entries = try await self.requireService().listObjects(parentID: directory.objectID)
                for entry in entries {
                    _ = self.item(for: entry, parent: directory.objectID)
                }
                return DirectorySnapshot(entries: entries)
            }
        }

        do {
            let snapshot = try await task.value
            directory.publish(snapshot, ifGeneration: generation)
            return snapshot
        } catch {
            directory.clearPendingListing()
            throw error
        }
    }
}

extension MTPVolume: FSVolume.Operations {

    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { 0 }
    var maximumFileSize: UInt64 { UInt64.max }

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsHardLinks = false
        capabilities.supportsSymbolicLinks = false
        capabilities.supportsPersistentObjectIDs = false
        capabilities.supports64BitObjectIDs = true

        //TODO: figure this out
        capabilities.supportsHiddenFiles = false

        capabilities.doesNotSupportVolumeSizes = false
        capabilities.doesNotSupportImmutableFiles = true
        capabilities.doesNotSupportSettingFilePermissions = true
        capabilities.doesNotSupportRootTimes = true

        capabilities.caseFormat = .insensitiveCasePreserving

        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        refreshStorageIfStale()
        let info = storageLock.withLock { _storageInfo }

        let stats = FSStatFSResult(fileSystemTypeName: MTPFSShortName)
        stats.blockSize = 4096
        stats.ioSize = 1 << 20
        if let info, info.totalBytes > 0 {
            stats.totalBlocks = info.totalBytes / 4096
            stats.availableBlocks = info.freeBytes / 4096
            stats.freeBlocks = info.freeBytes / 4096
        } else {
            stats.totalBlocks = 1024
            stats.availableBlocks = 0
            stats.freeBlocks = 0
        }
        stats.totalFiles = 0
        stats.freeFiles = 0
        return stats
    }

    private func refreshStorageIfStale() {
        let shouldRefresh = storageLock.withLock { () -> Bool in
            if _storageRefreshing {
                return false
            }

            let age = DispatchTime.now().uptimeNanoseconds &- _storageStamp
            if _storageInfo != nil && age < Self.storageTTL {
                return false
            }

            _storageRefreshing = true
            return true
        }

        if !shouldRefresh {
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }

            defer {
                self.storageLock.withLock {
                    self._storageRefreshing = false
                }
            }

            guard let service = try? self.requireService() else {
                return
            }

            guard let fresh = try? await service.refreshStorage() else {
                return
            }

            self.storageLock.withLock {
                self._storageInfo = fresh
                self._storageStamp = DispatchTime.now().uptimeNanoseconds
            }
        }
    }

    private func setStorageInfo(_ info: MTPStorageInfo?) {
        storageLock.withLock {
            _storageInfo = info
            _storageStamp = DispatchTime.now().uptimeNanoseconds
        }
    }

    func activate(options: FSTaskOptions) async throws -> FSItem {
        var binding: ServiceBinding?
        do {
            binding = try makeBinding()
            setStorageInfo(try await binding!.client.openSession())
            serviceLock.withLock { _binding = binding }
        } catch {
            log.error("activate: daemon session failed — \(String(describing: error), privacy: .public); volume will retry on first access")
            binding?.connection.invalidate()
        }
        return root
    }

    func deactivate(options: FSDeactivateOptions) async throws {
        let binding = serviceLock.withLock {
            let b = _binding
            _binding = nil
            return b
        }
        try? await binding?.client.closeSession()
        binding?.connection.invalidate()
    }

    func mount(options: FSTaskOptions) async throws {}
    func unmount() async {}
    func synchronize(flags: FSSyncFlags) async throws {}

    func reclaimItem(_ item: FSItem) async throws {
        guard let mtpItem = item as? MTPItem, !mtpItem.isRoot else {
            return
        }

        if #available(macOS 27.0, *) {
            mtpItem.tryReclaim { [weak self] in
                self?.forget(objectID: mtpItem.objectID)
            }
        } else {
            forget(objectID: mtpItem.objectID)
        }
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        guard let dir = directory as? MTPItem else {
            throw POSIXError(.EIO)
        }

        guard let nameStr = name.string else {
            throw POSIXError(.EIO)
        }

        if let info = dir.snapshot?.byName[nameStr] {
            if let result = lookupResult(for: info, in: dir) {
                return result
            }
        }

        let snapshot = try await listing(for: dir)
        guard let info = snapshot.byName[nameStr] else {
            throw POSIXError(.ENOENT)
        }

        guard let result = lookupResult(for: info, in: dir) else {
            throw POSIXError(.ENOENT)
        }

        return result
    }

    private func lookupResult(for info: MTPObjectInfo, in directory: MTPItem) -> (FSItem, FSFileName)? {
        let foundItem = item(for: info, parent: directory.objectID)
        let itemName = FSFileName(string: info.name)
        return (foundItem, itemName)
    }

    func attributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
        guard let mtpItem = item as? MTPItem else {
            throw POSIXError(.EIO)
        }

        return mtpItem.attributes(identity: identity)
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        guard let mtpItem = item as? MTPItem else {
            throw POSIXError(.EIO)
        }

        guard newAttributes.isValid(.size), !mtpItem.isDirectory else {
            newAttributes.consumedAttributes = []
            return mtpItem.attributes(identity: identity)
        }

        let size = newAttributes.size
        try await requireService().truncateFile(objectID: mtpItem.objectID, size: size)
        mtpItem.updateInfo { info in
            info.fileSize = size
            info.modificationDate = Date()
        }
        newAttributes.consumedAttributes = [.size]
        return mtpItem.attributes(identity: identity)
    }

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    ) async throws -> FSDirectoryVerifier {
        guard let mtpDir = directory as? MTPItem else {
            throw POSIXError(.EIO)
        }

        do {
            let snapshot: DirectorySnapshot
            if cookie == .initial {
                snapshot = try await listing(for: mtpDir)
            } else {
                guard let pinned = mtpDir.snapshot, verifier.rawValue == 0 || verifier.rawValue == pinned.verifier else {
                    throw fs_errorForPOSIXError(Int32(FSError.Code.invalidDirectoryCookie.rawValue))
                }
                snapshot = pinned
            }

            let wantsDotEntries = attributes == nil
            let dotCount = wantsDotEntries ? 2 : 0
            var index = Int(cookie.rawValue)

            while index < dotCount + snapshot.entries.count {
                let nextCookie = FSDirectoryCookie(rawValue: UInt64(index + 1))
                let packed: Bool

                if wantsDotEntries && index < 2 {
                    let isSelf = index == 0
                    packed = packer.packEntry(
                        name: FSFileName(string: isSelf ? "." : ".."),
                        itemType: .directory,
                        itemID: isSelf
                            ? self.identity.identifier(for: mtpDir.objectID)
                            : self.identity.parentIdentifier(for: mtpDir.parentObjectID),
                        nextCookie: nextCookie,
                        attributes: nil)
                } else {
                    let info = snapshot.entries[index - dotCount]
                    packed = packer.packEntry(
                        name: FSFileName(string: info.name),
                        itemType: info.isDirectory ? .directory : .file,
                        itemID: self.identity.identifier(for: info.objectID),
                        nextCookie: nextCookie,
                        attributes: attributes != nil ? FSItem.Attributes.make(for: info, identity: self.identity) : nil
                    )
                }

                if !packed {
                    break
                }

                index += 1
            }

            return FSDirectoryVerifier(rawValue: snapshot.verifier)
        } catch {
            log.error("enumerateDirectory failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest
    ) async throws -> (FSItem, FSFileName) {
        guard let dir = directory as? MTPItem, let nameStr = name.string else {
            throw POSIXError(.EIO)
        }

        #if DEBUG
        log.info("createItem: name=\(nameStr, privacy: .public) inDir=\(dir.objectID) type=\(String(describing: type), privacy: .public)")
        #endif

        // Delete the file immediately instead of hoarding .Trashes on the device
        if dir.isRoot, nameStr == ".Trashes" {
            throw POSIXError(.EPERM)
        }

        let service = try requireService()
        let objectID = switch type {
            case .directory: try await service.createDirectory(parentID: dir.objectID, name: nameStr)
            case .file: try await service.createFile(parentID: dir.objectID, name: nameStr, size: 0)
            default: throw POSIXError(.ENOTSUP)
        }
        let info = MTPObjectInfo(
            objectID: objectID,
            parentID: dir.objectID,
            name: nameStr,
            isDirectory: type == .directory,
            fileSize: 0,
            modificationDate: Date(),
            creationDate: Date()
        )
        dir.invalidateListing()
        return (item(for: info, parent: dir.objectID), name)
    }

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?
    ) async throws -> FSFileName {
        guard let mtpItem = item as? MTPItem else {
            throw POSIXError(.EIO)
        }
        guard let sourceDirectory = sourceDirectory as? MTPItem else {
            throw POSIXError(.EIO)
        }
        guard let destinationDirectory = destinationDirectory as? MTPItem else {
            throw POSIXError(.EIO)
        }

        guard let newName = destinationName.string else {
            throw POSIXError(.EIO)
        }

        #if DEBUG
        log.info("renameItem: \(sourceName.string ?? "?", privacy: .public) -> \(newName, privacy: .public) srcDir=\(sourceDirectory.objectID) dstDir=\(destinationDirectory.objectID)")
        #endif

        // Delete the file immediately instead of hoarding .Trashes on the device
        if destinationDirectory.isRoot, newName == ".Trashes" {
            throw POSIXError(.EPERM)
        }

        let service = try requireService()
        let crossDirectory = sourceDirectory.objectID != destinationDirectory.objectID

        if newName != sourceName.string {
            try await service.renameObject(objectID: mtpItem.objectID, newName: newName)
            mtpItem.updateInfo { info in
                info.name = newName
            }
        }

        if crossDirectory {
            do {
                try await service.moveObject(
                    objectID: mtpItem.objectID,
                    toParentID: destinationDirectory.objectID
                )
            } catch let error as POSIXError where error.code == .ENOTSUP {
                sourceDirectory.invalidateListing()
                throw POSIXError(.EXDEV)
            }
            destinationDirectory.invalidateListing()
        }

        sourceDirectory.invalidateListing()
        return destinationName
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws {
        guard let mtpItem = item as? MTPItem, let dir = directory as? MTPItem else {
            throw POSIXError(.EIO)
        }

        try await requireService().deleteObject(objectID: mtpItem.objectID)
        forget(objectID: mtpItem.objectID)
        identity.retire(objectID: mtpItem.objectID)
        dir.invalidateListing()
    }

    // Methods below are required by FSVolume.Operations, even though MTP doesn't support symlinks

    func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName
    ) async throws -> (FSItem, FSFileName) {
        throw POSIXError(.ENOTSUP)
    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> FSFileName {
        throw POSIXError(.ENOTSUP)
    }

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        throw POSIXError(.ENOTSUP)
    }
}

extension MTPVolume: FSVolume.ReadWriteOperations {

    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> Int {
        guard let mtpItem = item as? MTPItem else {
            throw POSIXError(.EIO)
        }

        let data = try await requireService().readFile(
            objectID: mtpItem.objectID,
            offset: UInt64(offset),
            length: UInt64(length)
        )
        let count = min(data.count, length)
        if count > 0 {
            _ = buffer.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    memcpy(destination.baseAddress!, source.baseAddress!, count)
                }
            }
        }
        return count
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        guard let mtpItem = item as? MTPItem else {
            throw POSIXError(.EIO)
        }

        try await requireService().writeFile(
            objectID: mtpItem.objectID,
            offset: UInt64(offset),
            data: contents
        )
        mtpItem.updateInfo { info in
            info.fileSize = max(info.fileSize, UInt64(offset) + UInt64(contents.count))
            info.modificationDate = Date()
        }
        return contents.count
    }
}

