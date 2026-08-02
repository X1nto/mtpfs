import Foundation
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.mtpd", category: "WriteStage")

final class MTPWriteStage {

    private struct Entry {
        let url: URL
        let fd: Int32
        
        /// Highest offset+length written, i.e. the file's logical length.
        var size: UInt64
    }

    private var entries: [UInt32: Entry] = [:]
    private let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev.xinto.mtpfs.writestage", isDirectory: true)
        reset()
    }

    private func reset() {
        for entry in entries.values {
            close(entry.fd)
        }
        entries.removeAll()

        try? FileManager.default.removeItem(at: root)
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            log.error("could not create write-stage directory: \(String(describing: error), privacy: .public)")
        }
    }

    func isStaging(_ objectID: UInt32) -> Bool {
        entries[objectID] != nil
    }

    func write(objectID: UInt32, offset: UInt64, data: Data) throws {
        let entry: Entry
        if let existing = entries[objectID] {
            entry = existing
        } else {
            let url = root.appendingPathComponent("\(objectID)", isDirectory: false)
            try? FileManager.default.removeItem(at: url)
            let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
            if fd < 0 {
                log.error("could not create write-stage file for object \(objectID)")
                throw POSIXError(.EIO)
            }
            entry = Entry(url: url, fd: fd, size: 0)
        }

        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, !raw.isEmpty else {
                return
            }
            var written = 0
            while written < raw.count {
                let n = pwrite(entry.fd, base.advanced(by: written), raw.count - written, off_t(offset) + off_t(written))
                if n <= 0 {
                    log.error("write-stage pwrite failed for object \(objectID) at \(offset)")
                    throw POSIXError(.EIO)
                }
                written += n
            }
        }

        var updated = entry
        updated.size = max(updated.size, offset + UInt64(data.count))
        entries[objectID] = updated
    }

    func take(objectID: UInt32) -> (fd: Int32, size: UInt64, url: URL)? {
        guard let entry = entries.removeValue(forKey: objectID) else {
            return nil
        }

        if lseek(entry.fd, 0, SEEK_SET) < 0 {
            log.error("write-stage lseek failed for object \(objectID)")
            close(entry.fd)
            try? FileManager.default.removeItem(at: entry.url)
            return nil
        }

        return (entry.fd, entry.size, entry.url)
    }

    func finish(fd: Int32, url: URL) {
        close(fd)
        try? FileManager.default.removeItem(at: url)
    }

    func discard(_ objectID: UInt32) {
        guard let entry = entries.removeValue(forKey: objectID) else {
            return
        }
        close(entry.fd)
        try? FileManager.default.removeItem(at: entry.url)
    }

    func removeAll() {
        reset()
    }
}
