import Foundation

enum MTPPathMarker {

    /// - Returns: `<percent-encoded name>.<percent-encoded key>.mtpvol`
    static func fileName(volumeName: String, deviceKey: String) -> String {
        "\(encode(volumeName)).\(encode(deviceKey)).mtpvol"
    }

    static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("mtpfs", isDirectory: true)
        .appendingPathComponent("paths", isDirectory: true)
    
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func create(volumeName: String, deviceKey: String) throws -> URL {
        remove(deviceKey: deviceKey)

        let directory = try directory().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(fileName(volumeName: volumeName, deviceKey: deviceKey))
        try Data().write(to: url)
        return url
    }

    static func remove(deviceKey: String) {
        guard let dir = try? directory() else {
            return
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }

        let suffix = ".\(encode(deviceKey)).mtpvol"
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                let markers = (try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
                if markers.contains(where: { $0.lastPathComponent.hasSuffix(suffix) }) {
                    try? FileManager.default.removeItem(at: entry)
                }
            } else if entry.lastPathComponent.hasSuffix(suffix) {
                // Flat marker written by an older build.
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}
