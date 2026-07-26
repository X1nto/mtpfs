import Foundation
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.mtpd", category: "Stage")

/// Cache of whole MTP objects, used when a device cannot serve ranged reads.
final class MTPObjectStage {

    /// Receives one chunk of a streaming download. Returning false aborts the transfer.
    typealias ChunkSink = (UnsafeRawBufferPointer) -> Bool
    
    /// Streams a whole object into `sink`.
    /// - Returns: true if the object arrived complete, false if the sink aborted it
    /// - Throws: any device error
    typealias Download = (_ sink: ChunkSink) throws -> Bool

    private enum Payload {
        case memory(Data)
        case file(URL)
    }

    private struct Entry {
        let payload: Payload
        let size: UInt64
        var lastUsed: UInt64

        var isMemory: Bool {
            if case .memory = payload { return true }
            return false
        }
    }

    private let memoryBudget: UInt64
    private let diskBudget: UInt64
    private let freeSpaceFloor: UInt64

    private let root: URL
    private var entries: [UInt32: Entry] = [:]
    private var memoryBytes: UInt64 = 0
    private var diskBytes: UInt64 = 0
    private var clock: UInt64 = 0

    init(
        memoryBudget: UInt64 = 512 << 20,
        diskBudget: UInt64 = 4 << 30,
        freeSpaceFloor: UInt64 = 2 << 30
    ) {
        self.memoryBudget = memoryBudget
        self.diskBudget = diskBudget
        self.freeSpaceFloor = freeSpaceFloor
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("dev.xinto.mtpfs.stage", isDirectory: true)
        resetRoot()
    }

    private func resetRoot() {
        try? FileManager.default.removeItem(at: root)
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            log.error("could not create spill directory: \(String(describing: error), privacy: .public)")
        }
        entries.removeAll()
        memoryBytes = 0
        diskBytes = 0
    }

    func read(
        objectID: UInt32,
        offset: UInt64,
        length: UInt64,
        totalSize: UInt64,
        download: Download
    ) throws -> Data {
        if offset >= totalSize {
            return Data()
        }
        
        let wanted = Int(min(length, totalSize - offset))
        if wanted <= 0 {
            return Data()
        }

        switch try entry(objectID: objectID, totalSize: totalSize, download: download).payload {
        case .memory(let data):
            let start = Int(min(offset, UInt64(data.count)))
            let end = Int(min(offset + UInt64(wanted), UInt64(data.count)))
            if start >= end {
                return Data()
            }
            return Data(data[start..<end])

        case .file(let url):
            return try readFromFile(url, objectID: objectID, offset: offset, count: wanted)
        }
    }

    private func readFromFile(_ url: URL, objectID: UInt32, offset: UInt64, count: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY)
        if fd < 0  {
            invalidate(objectID)
            throw POSIXError(.EIO)
        }
        
        defer {
            close(fd)
        }

        var buffer = Data(count: count)
        let got = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else {
                return -1
            }
            return pread(fd, base, count, off_t(offset))
        }
        
        if got < 0 {
            throw POSIXError(.EIO)
        }
        
        return got == count ? buffer : buffer.prefix(got)
    }

    private func entry(objectID: UInt32, totalSize: UInt64, download: Download) throws -> Entry {
        clock += 1

        if var existing = entries[objectID], existing.size == totalSize, isPresent(existing) {
            existing.lastUsed = clock
            entries[objectID] = existing
            return existing
        }

        invalidate(objectID)

        let entry = totalSize <= memoryBudget
            ? try fetchIntoMemory(objectID: objectID, totalSize: totalSize, download: download)
            : try fetchIntoFile(objectID: objectID, totalSize: totalSize, download: download)

        entries[objectID] = entry
        return entry
    }

    private func isPresent(_ entry: Entry) -> Bool {
        switch entry.payload {
        case .memory:
            return true
        case .file(let url):
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    private func fetchIntoMemory(objectID: UInt32, totalSize: UInt64, download: Download) throws -> Entry {
        try makeMemoryRoom(for: totalSize)

        var buffer = Data()
        buffer.reserveCapacity(Int(clamping: totalSize))
        let succeeded = try download { chunk in
            buffer.append(chunk.bindMemory(to: UInt8.self))
            return true
        }
        
        if !succeeded {
            throw POSIXError(.EIO)
        }

        let size = UInt64(buffer.count)
        memoryBytes += size
        
        #if DEBUG
        log.info("cached object \(objectID) in memory (\(size) bytes, \(self.memoryBytes) resident)")
        #endif
        
        return Entry(payload: .memory(buffer), size: size, lastUsed: clock)
    }

    private func fetchIntoFile(objectID: UInt32, totalSize: UInt64, download: Download) throws -> Entry {
        try makeDiskRoom(for: totalSize)

        let url = root.appendingPathComponent("\(objectID)", isDirectory: false)
        try? FileManager.default.removeItem(at: url)

        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if fd < 0 {
            log.error("could not create spill file for object \(objectID)")
            throw POSIXError(.EIO)
        }

        var written: UInt64 = 0
        var writeFailed = false
        let succeeded: Bool
        do {
            succeeded = try download { chunk in
                guard let base = chunk.baseAddress, !chunk.isEmpty else {
                    return true
                }
                
                var remaining = chunk.count
                var cursor = base
                while remaining > 0 {
                    let n = write(fd, cursor, remaining)
                    if n < 0 {
                        writeFailed = true
                        return false
                    }
                    cursor = cursor.advanced(by: n)
                    remaining -= n
                    written += UInt64(n)
                }
                
                return true
            }
        } catch {
            close(fd)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        close(fd)

        if !succeeded || writeFailed {
            try? FileManager.default.removeItem(at: url)
            throw POSIXError(.EIO)
        }

        diskBytes += written
        
        #if DEBUG
        log.info("spilled object \(objectID) to disk (\(written) bytes, \(self.diskBytes) on disk)")
        #endif
        
        return Entry(payload: .file(url), size: written, lastUsed: clock)
    }


    private func makeMemoryRoom(for needed: UInt64) throws {
        while memoryBytes + needed > memoryBudget, evictOldest(memory: true) {}
        
        if memoryBytes + needed > memoryBudget {
            throw POSIXError(.ENOSPC)
        }
    }

    private func makeDiskRoom(for needed: UInt64) throws {
        if needed > diskBudget {
            log.error("object of \(needed) bytes exceeds the \(self.diskBudget) byte spill budget")
            throw POSIXError(.ENOSPC)
        }

        while diskBytes + needed > diskBudget, evictOldest(memory: false) {}
        if diskBytes + needed > diskBudget {
            throw POSIXError(.ENOSPC)
        }

        while availableBytes() < needed + freeSpaceFloor {
            if !evictOldest(memory: false) {
                log.error("not enough free space to spill \(needed) bytes")
                throw POSIXError(.ENOSPC)
            }
        }
    }

    private func evictOldest(memory: Bool) -> Bool {
        let candidates = entries.filter { $0.value.isMemory == memory }
        guard let (objectID, entry) = candidates.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else {
            return false
        }
        
        #if DEBUG
        log.info("evicting cached object \(objectID) (\(entry.size) bytes, memory=\(memory))")
        #endif
        
        invalidate(objectID)
        return true
    }

    private func availableBytes() -> UInt64 {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values?.volumeAvailableCapacityForImportantUsage else {
            return .max
        }
        
        return capacity < 0 ? 0 : UInt64(capacity)
    }

    func invalidate(_ objectID: UInt32) {
        guard let entry = entries.removeValue(forKey: objectID) else {
            return
        }
        
        switch entry.payload {
        case .memory:
            memoryBytes = memoryBytes >= entry.size ? memoryBytes - entry.size : 0
        case .file(let url):
            diskBytes = diskBytes >= entry.size ? diskBytes - entry.size : 0
            try? FileManager.default.removeItem(at: url)
        }
    }

    func removeAll() {
        resetRoot()
    }
}
