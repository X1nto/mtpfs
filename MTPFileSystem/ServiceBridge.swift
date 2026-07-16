import Foundation

extension MTPServiceProtocol {
    
    func openSession() async throws -> MTPStorageInfo {
        try await withCheckedThrowingContinuation { continuation in
            openSession { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                
                do {
                    continuation.resume(returning: try Self.decode(MTPStorageInfo.self, from: data))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func closeSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            closeSession { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func listObjects(parentID: UInt32) async throws -> [MTPObjectInfo] {
        try await withCheckedThrowingContinuation { continuation in
            listObjects(parentID: parentID) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                
                do {
                    continuation.resume(returning: try Self.decode([MTPObjectInfo].self, from: data))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func getObjectInfo(objectID: UInt32) async throws -> MTPObjectInfo {
        try await withCheckedThrowingContinuation { continuation in
            getObjectInfo(objectID: objectID) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                
                do {
                    continuation.resume(returning: try Self.decode(MTPObjectInfo.self, from: data))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func readFile(objectID: UInt32, offset: UInt64, length: UInt64) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            readFile(objectID: objectID, offset: offset, length: length) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    func writeFile(objectID: UInt32, offset: UInt64, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writeFile(objectID: objectID, offset: offset, data: data) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func truncateFile(objectID: UInt32, size: UInt64) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            truncateFile(objectID: objectID, size: size) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func createFile(parentID: UInt32, name: String, size: UInt64) async throws -> UInt32 {
        try await withCheckedThrowingContinuation { continuation in
            createFile(parentID: parentID, name: name, size: size) { id, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: id)
                }
            }
        }
    }

    func createDirectory(parentID: UInt32, name: String) async throws -> UInt32 {
        try await withCheckedThrowingContinuation { continuation in
            createDirectory(parentID: parentID, name: name) { id, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: id)
                }
            }
        }
    }

    func deleteObject(objectID: UInt32) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            deleteObject(objectID: objectID) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func renameObject(objectID: UInt32, newName: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            renameObject(objectID: objectID, newName: newName) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) throws -> T {
        guard let data else { throw POSIXError(.EIO) }
        return try JSONDecoder().decode(type, from: data)
    }
}
