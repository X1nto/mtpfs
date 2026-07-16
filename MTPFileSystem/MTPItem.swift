import FSKit
import Foundation

final class MTPItem: FSItem {
    
    // MTP's reserved handle for "the root of the storage"
    static let rootObjectID: UInt32 = 0xFFFFFFFF

    static func identifier(for objectID: UInt32) -> FSItem.Identifier {
        // 1 << 32 to avoid clashing with FSKit's reserved IDs
        objectID == rootObjectID
            ? .rootDirectory
            : FSItem.Identifier(rawValue: UInt64(objectID) + 1 << 32) ?? .invalid
    }

    let objectID: UInt32

    let parentObjectID: UInt32

    private let stateLock = NSLock()

    private var _info: MTPObjectInfo?
    private var _snapshot: DirectorySnapshot?
    private var _pendingListing: Task<DirectorySnapshot, Error>?

    private var _generation: UInt64 = 0

    init(objectID: UInt32, parentObjectID: UInt32 = MTPItem.rootObjectID, info: MTPObjectInfo? = nil) {
        self.objectID = objectID
        self.parentObjectID = parentObjectID
        self._info = info
        super.init()
    }

    var isRoot: Bool {
        objectID == MTPItem.rootObjectID
    }

    var isDirectory: Bool {
        isRoot || info?.isDirectory == true
    }

    var info: MTPObjectInfo? {
        get { stateLock.withLock { _info } }
        set { stateLock.withLock { _info = newValue } }
    }

    func updateInfo(_ mutate: (inout MTPObjectInfo) -> Void) {
        stateLock.withLock {
            guard var info = _info else {
                return
            }
            mutate(&info)
            _info = info
        }
    }

    func attributes() -> FSItem.Attributes {
        guard let info else {
            return isRoot ? .makeForRoot() : .makeForUnknownItem(self)
        }
        return .make(for: info)
    }

    var snapshot: DirectorySnapshot? { stateLock.withLock { _snapshot } }

    func listingTask(orInstall make: () -> Task<DirectorySnapshot, Error>) -> (task: Task<DirectorySnapshot, Error>, generation: UInt64) {
        stateLock.lock()
        if let existing = _pendingListing {
            let generation = _generation
            stateLock.unlock()
            return (existing, generation)
        }
        let generation = _generation
        stateLock.unlock()

        let task = make()

        stateLock.lock()
        if let raced = _pendingListing {
            stateLock.unlock()
            task.cancel()
            return (raced, generation)
        }
        _pendingListing = task
        stateLock.unlock()
        return (task, generation)
    }

    @discardableResult
    func publish(_ snapshot: DirectorySnapshot, ifGeneration generation: UInt64) -> Bool {
        stateLock.withLock {
            _pendingListing = nil
            guard _generation == generation else { return false }
            _snapshot = snapshot
            return true
        }
    }

    func clearPendingListing(ifGeneration generation: UInt64) {
        stateLock.withLock {
            guard _generation == generation else { return }
            _pendingListing = nil
        }
    }

    func invalidateListing() {
        stateLock.withLock {
            _snapshot = nil
            _generation &+= 1
        }
    }
}

struct DirectorySnapshot {
    let entries: [MTPObjectInfo]
    let byName: [String: MTPObjectInfo]
    let verifier: UInt64

    init(entries: [MTPObjectInfo]) {
        self.entries = entries
        self.byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.verifier = Self.computeVerifier(for: entries)
    }

    /// Computes the FNV-1a hash
    private static func computeVerifier(for entries: [MTPObjectInfo]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325           // FNV offset basis
        func mix(_ value: UInt64) {
            hash = (hash ^ value) &* 0x0000_0100_0000_01b3 // FNV prime
        }

        mix(UInt64(entries.count))
        for entry in entries {
            mix(UInt64(entry.objectID))
            for byte in entry.name.utf8 {
                mix(UInt64(byte))
            }
            mix(entry.fileSize)
        }
        
        // FSKit treats 0 as "verifier not yet established"
        return hash == 0 ? 1 : hash
    }
}

private let mtpFallbackTimespec: timespec = {
    var ts = timespec()
    clock_gettime(CLOCK_REALTIME, &ts)
    return ts
}()

extension FSItem.Attributes {
    
    private static let mtpDirMode = UInt32(S_IFDIR | S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH)
    private static let mtpFileMode = UInt32(S_IFREG | S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)

    static func make(for info: MTPObjectInfo) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.fileID = MTPItem.identifier(for: info.objectID)
        attrs.parentID = (info.parentID == 0 || info.parentID == MTPItem.rootObjectID)
            ? .rootDirectory
            : MTPItem.identifier(for: info.parentID)
        attrs.type = info.isDirectory ? .directory : .file
        attrs.mode = info.isDirectory ? mtpDirMode : mtpFileMode
        attrs.linkCount = 1
        attrs.uid = 0
        attrs.gid = 0
        attrs.flags = 0
        attrs.size = info.fileSize
        attrs.allocSize = info.fileSize
        attrs.stampAllTimes(modify: info.modificationDate?.timespec, birth: info.creationDate?.timespec)
        return attrs
    }

    fileprivate static func makeForUnknownItem(_ item: MTPItem) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.fileID = MTPItem.identifier(for: item.objectID)
        attrs.parentID = item.parentObjectID == MTPItem.rootObjectID || item.parentObjectID == 0
            ? .rootDirectory
            : MTPItem.identifier(for: item.parentObjectID)
        attrs.type = .file
        attrs.mode = mtpFileMode
        attrs.linkCount = 1
        attrs.uid = 0
        attrs.gid = 0
        attrs.flags = 0
        attrs.size = 0
        attrs.allocSize = 0
        attrs.stampAllTimes(modify: nil, birth: nil)
        return attrs
    }

    fileprivate static func makeForRoot() -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.fileID = .rootDirectory
        attrs.parentID = .parentOfRoot
        attrs.type = .directory
        attrs.mode = mtpDirMode
        attrs.linkCount = 1
        attrs.uid = 0
        attrs.gid = 0
        attrs.flags = 0
        attrs.size = 0
        attrs.allocSize = 0
        attrs.stampAllTimes(modify: nil, birth: nil)
        return attrs
    }
    
    private func stampAllTimes(modify: timespec?, birth: timespec?) {
        let m = modify ?? mtpFallbackTimespec
        let b = birth ?? m
        birthTime = b
        addedTime = b
        accessTime = m
        changeTime = m
        modifyTime = m
        backupTime = m
    }
}

private extension Date {
    var timespec: timespec {
        let seconds = timeIntervalSince1970
        return Foundation.timespec(
            tv_sec: __darwin_time_t(seconds),
            tv_nsec: Int((seconds - floor(seconds)) * 1_000_000_000)
        )
    }
}
