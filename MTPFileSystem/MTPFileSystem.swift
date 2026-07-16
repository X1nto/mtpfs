import CryptoKit
import ExtensionFoundation
import Foundation
import FSKit
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.fsext", category: "Extension")

final class MTPFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    func probeResource(resource: FSResource) async throws -> FSProbeResult {
        guard let path = resource as? FSPathURLResource else {
            return .notRecognized
        }
        let (name, key) = parse(path.url)
        return .usable(
            name: name,
            containerID: FSContainerIdentifier(uuid: stableUUID(from: key))
        )
    }

    func loadResource(resource: FSResource, options: FSTaskOptions) async throws -> FSVolume {
        containerStatus = .ready

        let parsed = (resource as? FSPathURLResource).map { parse($0.url) }
            ?? (name: "MTP Device", key: "mtp")

        return MTPVolume(
            volumeName: parsed.name,
            volumeID: .init(uuid: stableUUID(from: parsed.key))
        )
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {}
    
    private func parse(_ url: URL) -> (name: String, key: String) {
        let parts = url.lastPathComponent.components(separatedBy: ".")
        
        if parts.count < 3 {
            return (name: "MTP Device", key: url.lastPathComponent)
        }
        
        if parts[parts.count - 1] != "mtpvol" {
            return (name: "MTP Device", key: url.lastPathComponent)
        }
        
        guard let name = parts[0].removingPercentEncoding, !name.isEmpty else {
            return (name: "MTP Device", key: url.lastPathComponent)
        }
 
        guard let key = parts[1].removingPercentEncoding else {
            return (name: "MTP Device", key: url.lastPathComponent)
        }
        
        return (name, key)
    }

    private func stableUUID(from string: String) -> UUID {
        let digest = SHA256.hash(data: Data(string.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.withUnsafeBytes { bytes in
            UUID(uuid: bytes.load(as: uuid_t.self))
        }
    }
}

@main
struct MTPFSExtension: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations { MTPFileSystem() }
}
