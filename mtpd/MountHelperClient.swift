import Foundation
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.mtpd", category: "MountHelper")

enum MountHelperClient {

    static func prepareMountpoint(name: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let conn = NSXPCConnection(machServiceName: MTPMountHelperMachServiceName, options: [])
            conn.remoteObjectInterface = NSXPCInterface(with: MTPMountHelperProtocol.self)
            conn.resume()

            let once = OnceGuard()
            let finish = { result in
                if once.claim() {
                    conn.invalidate()
                    continuation.resume(with: result)
                }
            }

            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ finish(.failure($0)) }) as? any MTPMountHelperProtocol else {
                finish(.failure(POSIXError(.ECONNREFUSED)))
                return
            }

            proxy.prepareMountpoint(name: name) { path, error in
                if let error {
                    finish(.failure(error))
                } else if let path {
                    finish(.success(path))
                } else {
                    finish(.failure(POSIXError(.EIO)))
                }
            }
        }
    }

    static func removeMountpoint(path: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let conn = NSXPCConnection(machServiceName: MTPMountHelperMachServiceName, options: [])
            conn.remoteObjectInterface = NSXPCInterface(with: MTPMountHelperProtocol.self)

            let once = OnceGuard()
            let resume = {
                if once.claim() {
                    continuation.resume()
                }
            }
            conn.invalidationHandler = { resume() }
            conn.resume()

            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
                log.error("removeMountpoint(\(path, privacy: .public)) connection failed: \(String(describing: error), privacy: .public)")
                conn.invalidate()
                resume()
            }) as? any MTPMountHelperProtocol else {
                conn.invalidate()
                resume()
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
