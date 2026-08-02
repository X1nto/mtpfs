import FSKit
import Foundation

final class MTPIdentityTable {

    /// FSKit reserves some identifiers like 0, 1 and 2
    private static let firstIdentifier: UInt64 = 1 << 32

    private let lock = NSLock()
    private var identifiers: [UInt32: UInt64] = [:]
    private var next: UInt64 = firstIdentifier

    func identifier(for objectID: UInt32) -> FSItem.Identifier {
        if objectID == MTPItem.rootObjectID {
            return .rootDirectory
        }

        let raw = lock.withLock { () -> UInt64 in
            if let existing = identifiers[objectID] {
                return existing
            }
            let allocated = next
            next &+= 1
            identifiers[objectID] = allocated
            return allocated
        }

        return FSItem.Identifier(rawValue: raw) ?? .invalid
    }

    func parentIdentifier(for parentObjectID: UInt32) -> FSItem.Identifier {
        if parentObjectID == 0 || parentObjectID == MTPItem.rootObjectID {
            return .rootDirectory
        }
            
        return identifier(for: parentObjectID)
    }

    func rebind(from oldObjectID: UInt32, to newObjectID: UInt32) {
        if oldObjectID == newObjectID {
            return
        }
        
        lock.withLock {
            guard let existing = identifiers.removeValue(forKey: oldObjectID) else {
                return
            }
            identifiers[newObjectID] = existing
        }
    }

    func retire(objectID: UInt32) {
        lock.withLock {
            identifiers[objectID] = nil
        }
    }
}
