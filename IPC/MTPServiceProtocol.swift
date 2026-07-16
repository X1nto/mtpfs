import Foundation

let MTPDaemonLabel = "dev.xinto.mtpfs.mtpd"
let MTPMachServiceName = "85342F9WTR.dev.xinto.mtpfs.mtpd"
let MTPClientCodeRequirement = #"anchor apple generic and certificate leaf[subject.OU] = "85342F9WTR""#
let MTPModuleBundleID = "dev.xinto.mtpfs.fsext"

struct MTPObjectInfo: Codable, Sendable {
    var objectID: UInt32
    var parentID: UInt32
    var name: String
    var isDirectory: Bool
    var fileSize: UInt64
    var modificationDate: Date?
    var creationDate: Date?
}

struct MTPStorageInfo: Codable, Sendable {
    var freeBytes: UInt64
    var totalBytes: UInt64
    var label: String
}

@objc
protocol MTPServiceProtocol {
    /// - Parameter reply: JSON-encoded `MTPStorageInfo`
    func openSession(reply: @escaping (Data?, Error?) -> Void)
    func closeSession(reply: @escaping (Error?) -> Void)

    /// - Parameter reply: JSON-encoded `[MTPObjectInfo]`
    func listObjects(parentID: UInt32, reply: @escaping (Data?, Error?) -> Void)
    /// - Parameter reply: JSON-encoded `MTPObjectInfo`
    func getObjectInfo(objectID: UInt32, reply: @escaping (Data?, Error?) -> Void)
    func deleteObject(objectID: UInt32, reply: @escaping (Error?) -> Void)
    func renameObject(objectID: UInt32, newName: String, reply: @escaping (Error?) -> Void)
    
    /// - Parameter reply: Object ID of the newly created file
    func createFile(parentID: UInt32, name: String, size: UInt64, reply: @escaping (UInt32, Error?) -> Void)
    /// - Parameter reply: Object ID of the newly created directory
    func createDirectory(parentID: UInt32, name: String, reply: @escaping (UInt32, Error?) -> Void)
    /// - Parameter reply: Raw file bytes for the requested range
    func readFile(objectID: UInt32, offset: UInt64, length: UInt64, reply: @escaping (Data?, Error?) -> Void)
    /// - Parameter data: Raw bytes to write at the given offset
    func writeFile(objectID: UInt32, offset: UInt64, data: Data, reply: @escaping (Error?) -> Void)
    /// Sets the object's length, growing or shrinking it.
    func truncateFile(objectID: UInt32, size: UInt64, reply: @escaping (Error?) -> Void)
}
