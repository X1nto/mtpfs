import Foundation

public struct MTPObject: Sendable {
    public let objectID: UInt32
    public let parentID: UInt32
    public let name: String
    public let isDirectory: Bool
    public let size: UInt64
    public let modificationDate: Date?
    public let creationDate: Date?
}

public struct MTPStorage: Sendable {
    public let id: UInt32
    public let label: String
    public let freeBytes: UInt64
    public let totalBytes: UInt64
}

public struct MTPCapabilities: Sendable {
    /// random-access reads
    public let rangedRead: Bool

    /// in-place editing
    public let editObjects: Bool

    /// re-parenting an object without moving its bytes
    public let moveObject: Bool

    public var writeStrategy: MTPWriteStrategy {
        editObjects ? .incremental : .wholeFile
    }
}

public enum MTPWriteStrategy: String, Sendable, CaseIterable {
    case incremental
    case wholeFile
}

public struct MTPDeviceMatch: Sendable {
    public let vendorID: Int?
    public let productID: Int?

    public init(vendorID: Int? = nil, productID: Int? = nil) {
        self.vendorID = vendorID
        self.productID = productID
    }
}
