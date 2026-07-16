import Foundation
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.mtpd", category: "MountTable")

enum MTPMountTable {

    struct Mount {
        let deviceKey: String
        let path: String
    }

    static func current() -> [Mount] {
        let probe = getfsstat(nil, 0, MNT_NOWAIT)
        if probe <= 0 {
            if probe < 0 {
                log.error("getfsstat probe failed: \(String(cString: strerror(errno)), privacy: .public)")
            }
            return []
        }
        let capacity = Int(probe) + 8
        let buffer = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        let n = getfsstat(buffer, Int32(MemoryLayout<statfs>.stride * capacity), MNT_NOWAIT)
        if n <= 0 {
            if n < 0 {
                log.error("getfsstat failed: \(String(cString: strerror(errno)), privacy: .public)")
            }
            return []
        }

        return (0..<Int(min(n, Int32(capacity)))).compactMap { i -> Mount? in
            var fs = buffer[i]
            let from = cString(&fs.f_mntfromname)

            guard let key = deviceKey(fromName: from) else {
                return nil
            }

            let on = cString(&fs.f_mntonname)
            return Mount(deviceKey: key, path: on)
        }
    }

    /// - Returns: Where this device is mounted right now, or null if it is not.
    static func mountPoint(forDeviceKey key: String) -> String? {
        current().first { $0.deviceKey == key }?.path
    }

    private static func deviceKey(fromName: String) -> String? {
        var file = (fromName as NSString).lastPathComponent

        // `%25` coresponds to `%`. Its presence means at least one layer too many, so we peel it.
        // 4 peels should be more than enough.
        var peels = 0
        while file.contains("%25"), peels < 4, let decoded = file.removingPercentEncoding, decoded != file {
            file = decoded
            peels += 1
        }

        if !file.hasSuffix(".mtpvol") {
            return nil
        }
        
        let parts = file.components(separatedBy: ".")
        if parts.count < 3 {
            return nil
        }

        let key = parts[parts.count - 2].removingPercentEncoding ?? parts[parts.count - 2]
        return key.isEmpty ? nil : key
    }

    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
