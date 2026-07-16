import FSKit
import Foundation
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.fsext", category: "Volume")

class MTPVolume: FSVolume {
    private struct ServiceBinding {
        let connection: NSXPCConnection
        let proxy: any MTPServiceProtocol
    }

    private var _binding: ServiceBinding?
    private let serviceLock = NSLock()
    private var service: (any MTPServiceProtocol)? {
        serviceLock.withLock {
            _binding?.proxy
        }
    }
    
    private var storageInfo: MTPStorageInfo?
    
    private let root = MTPItem(objectID: MTPItem.rootObjectID)

    private var itemsByID: [UInt32: MTPItem] = [:]
    private let itemsLock = NSLock()

    init(
        volumeName: String = "MTP Device",
        volumeID: FSVolume.Identifier = .init(uuid: UUID())
    ) {
        super.init(volumeID: volumeID, volumeName: FSFileName(string: volumeName))
    }

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
        guard let proxy = conn.remoteObjectProxy as? any MTPServiceProtocol else {
            conn.invalidate()
            throw POSIXError(.ECONNREFUSED)
        }
        return ServiceBinding(connection: conn, proxy: proxy)
    }

    private func requireService() throws -> any MTPServiceProtocol {
        serviceLock.lock()
        defer { serviceLock.unlock() }
        if let existing = _binding?.proxy {
            return existing
        }

        let binding = try makeBinding()

        let previousConnection = _binding?.connection
        _binding = binding
        DispatchQueue.global(qos: .utility).async {
            previousConnection?.invalidate()
        }

        binding.proxy.openSession { _, error in
            if let error {
                log.error("reconnect openSession failed: \(String(describing: error), privacy: .public)")
            }
        }
        return binding.proxy
    }

    private func dropService() {
        serviceLock.withLock {
            _binding = nil
        }
    }

    private func item(for info: MTPObjectInfo, parent: UInt32) -> MTPItem {
        itemsLock.lock()
        defer { itemsLock.unlock() }
        if let existing = itemsByID[info.objectID] {
            existing.info = info
            return existing
        }
        let created = MTPItem(objectID: info.objectID, parentObjectID: parent, info: info)
        itemsByID[info.objectID] = created
        return created
    }

    private func forget(objectID: UInt32) {
        itemsLock.lock()
        defer { itemsLock.unlock() }
        itemsByID[objectID] = nil
    }

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
            directory.clearPendingListing(ifGeneration: generation)
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
        capabilities.doesNotSupportVolumeSizes = false
        capabilities.supportsHiddenFiles = true
        capabilities.supports64BitObjectIDs = true
        capabilities.caseFormat = .insensitiveCasePreserving
        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        let stats = FSStatFSResult(fileSystemTypeName: "mtpfs")
        stats.blockSize = 4096
        stats.ioSize = 1 << 20
        if let info = storageInfo, info.totalBytes > 0 {
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

    func activate(options: FSTaskOptions) async throws -> FSItem {
        var binding: ServiceBinding?
        do {
            binding = try makeBinding()
            storageInfo = try await binding!.proxy.openSession()
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
        try? await binding?.proxy.closeSession()
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
            // On 27+ the Handler family uses reference-counted reclaim; the callback fires
            // when the last holder releases the item.
            mtpItem.tryReclaim { [weak self] in
                self?.forget(objectID: mtpItem.objectID)
            }
        } else {
            // On 26, FSKit calls reclaimItem only after the item's refcount reaches zero,
            // so we can forget it immediately.
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

    func attributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem
    ) async throws -> FSItem.Attributes {
        guard let mtpItem = item as? MTPItem else {
            throw POSIXError(.EIO)
        }
        return mtpItem.attributes()
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem
    ) async throws -> FSItem.Attributes {
        guard let mtpItem = item as? MTPItem else {
            throw POSIXError(.EIO)
        }
        
        guard newAttributes.isValid(.size), !mtpItem.isDirectory else {
            newAttributes.consumedAttributes = []
            return mtpItem.attributes()
        }

        let size = newAttributes.size
        try await requireService().truncateFile(objectID: mtpItem.objectID, size: size)
        mtpItem.updateInfo { info in
            info.fileSize = size
            info.modificationDate = Date()
        }
        newAttributes.consumedAttributes = [.size]
        return mtpItem.attributes()
    }

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    ) async throws -> FSDirectoryVerifier {
        guard let mtpDir = directory as? MTPItem else { throw POSIXError(.EIO) }

        guard service != nil else {
            return FSDirectoryVerifier(rawValue: DirectorySnapshot(entries: []).verifier)
        }

        do {
            let snapshot: DirectorySnapshot
            if cookie == .initial {
                mtpDir.invalidateListing()
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
                            ? MTPItem.identifier(for: mtpDir.objectID)
                            : (mtpDir.isRoot ? .rootDirectory : MTPItem.identifier(for: mtpDir.parentObjectID)),
                        nextCookie: nextCookie,
                        attributes: nil)
                } else {
                    let info = snapshot.entries[index - dotCount]
                    packed = packer.packEntry(
                        name: FSFileName(string: info.name),
                        itemType: info.isDirectory ? .directory : .file,
                        itemID: MTPItem.identifier(for: info.objectID),
                        nextCookie: nextCookie,
                        attributes: attributes != nil ? FSItem.Attributes.make(for: info) : nil
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
        
        // MTP renames in place and has no combined move
        // A cross-directory rename would rename without moving
        guard sourceDirectory.objectID == destinationDirectory.objectID else {
            throw POSIXError(.EXDEV)
        }

        try await requireService().renameObject(objectID: mtpItem.objectID, newName: newName)
        mtpItem.updateInfo { info in
            info.name = newName
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
