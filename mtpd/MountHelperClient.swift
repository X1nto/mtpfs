import Foundation
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.mtpd", category: "MountHelper")

enum MountHelperClient {

    static func prepareMountpoint(name: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let conn = NSXPCConnection(machServiceName: MTPMountHelperMachServiceName, options: [])
            conn.remoteObjectInterface = NSXPCInterface(with: MTPMountHelperProtocol.self)
            conn.resume()

            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
                conn.invalidate()
                continuation.resume(throwing: error)
            }) as? any MTPMountHelperProtocol else {
                conn.invalidate()
                continuation.resume(throwing: POSIXError(.ECONNREFUSED))
                return
            }

            proxy.prepareMountpoint(name: name) { path, error in
                conn.invalidate()
                if let error {
                    continuation.resume(throwing: error)
                } else if let path {
                    continuation.resume(returning: path)
                } else {
                    continuation.resume(throwing: POSIXError(.EIO))
                }
            }
        }
    }

    static func removeMountpoint(path: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let conn = NSXPCConnection(machServiceName: MTPMountHelperMachServiceName, options: [])
            conn.remoteObjectInterface = NSXPCInterface(with: MTPMountHelperProtocol.self)

            var resumed = false
            let resume: () -> Void = {
                if !resumed {
                    resumed = true
                    continuation.resume()
                }
            }
            conn.invalidationHandler = { resume() }
            conn.resume()

            guard let proxy = conn.remoteObjectProxy as? any MTPMountHelperProtocol else {
                conn.invalidate()
                return
            }

            proxy.removeMountpoint(path: path) { error in
                conn.invalidate()
                if let error {
                    log.error("removeMountpoint(\(path, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
                }
                resume()
            }
        }
    }
}
