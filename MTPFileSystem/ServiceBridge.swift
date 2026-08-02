import Foundation
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.fsext", category: "ServiceBridge")

struct MTPServiceClient {
    let connection: NSXPCConnection

    func openSession() async throws -> MTPStorageInfo {
        try await perform { service, reply in
            service.openSession(reply: reply)
        }
    }

    func closeSession() async throws {
        try await perform { service, reply in
            service.closeSession(reply: reply)
        }
    }

    func refreshStorage() async throws -> MTPStorageInfo {
        try await perform { service, reply in
            service.refreshStorage(reply: reply)
        }
    }

    func listObjects(parentID: UInt32) async throws -> [MTPObjectInfo] {
        try await perform { service, reply in
            service.listObjects(parentID: parentID, reply: reply)
        }
    }

    func getObjectInfo(objectID: UInt32) async throws -> MTPObjectInfo {
        try await perform { service, reply in
            service.getObjectInfo(objectID: objectID, reply: reply)
        }
    }

    func readFile(objectID: UInt32, offset: UInt64, length: UInt64) async throws -> Data {
        try await perform { service, finish in
            service.readFile(objectID: objectID, offset: offset, length: length) { data, error in
                if let error {
                    finish(.failure(error))
                } else {
                    finish(.success(data ?? Data()))
                }
            }
        }
    }

    func writeFile(objectID: UInt32, offset: UInt64, data: Data) async throws {
        try await perform { service, reply in
            service.writeFile(objectID: objectID, offset: offset, data: data, reply: reply)
        }
    }

    func truncateFile(objectID: UInt32, size: UInt64) async throws {
        try await perform { service, reply in
            service.truncateFile(objectID: objectID, size: size, reply: reply)
        }
    }

    func createFile(parentID: UInt32, name: String, size: UInt64) async throws -> UInt32 {
        try await perform { service, reply in
            service.createFile(parentID: parentID, name: name, size: size, reply: reply)
        }
    }

    func createDirectory(parentID: UInt32, name: String) async throws -> UInt32 {
        try await perform { service, reply in
            service.createDirectory(parentID: parentID, name: name, reply: reply)
        }
    }

    func deleteObject(objectID: UInt32) async throws {
        try await perform { service, reply in
            service.deleteObject(objectID: objectID, reply: reply)
        }
    }

    func renameObject(objectID: UInt32, newName: String) async throws {
        try await perform { service, reply in
            service.renameObject(objectID: objectID, newName: newName, reply: reply)
        }
    }

    func moveObject(objectID: UInt32, toParentID: UInt32) async throws {
        try await perform { service, reply in
            service.moveObject(objectID: objectID, toParentID: toParentID, reply: reply)
        }
    }

    private func perform<T>(_ body: (any MTPServiceProtocol, @escaping (Result<T, any Error>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceGuard()
            let finish: @Sendable (Result<T, any Error>) -> Void = { result in
                if once.claim() {
                    continuation.resume(with: result.mapError(Self.posixError))
                }
            }

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                finish(.failure(error))
            }
            guard let service = proxy as? any MTPServiceProtocol else {
                finish(.failure(POSIXError(.ECONNREFUSED)))
                return
            }

            body(service, finish)
        }
    }

    private func perform<T: Decodable>(_ body: (any MTPServiceProtocol, @escaping (Data?, (any Error)?) -> Void) -> Void) async throws -> T {
        try await perform { service, finish in
            body(service) { data, error in
                if let error {
                    finish(.failure(error))
                    return
                }
                
                guard let data else {
                    finish(.failure(POSIXError(.EIO)))
                    return
                }
                
                finish(Result { try JSONDecoder().decode(T.self, from: data) })
            }
        }
    }

    private func perform(_ body: (any MTPServiceProtocol, @escaping ((any Error)?) -> Void) -> Void) async throws {
        try await perform { service, finish in
            body(service) { error in
                finish(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    private func perform<T>(_ body: (any MTPServiceProtocol, @escaping (T, (any Error)?) -> Void) -> Void) async throws -> T {
        try await perform { service, finish in
            body(service) { value, error in
                finish(error.map { .failure($0) } ?? .success(value))
            }
        }
    }
    
    private static func posixError(_ error: any Error) -> any Error {
        if (error as NSError).domain == NSPOSIXErrorDomain {
            return error
        }

        log.error("XPC failure mapped to EIO: \(String(describing: error), privacy: .public)")
        return POSIXError(.EIO)
    }
}
