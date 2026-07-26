import os

final class OnceGuard: Sendable {
    private let claimed = OSAllocatedUnfairLock(initialState: false)

    func claim() -> Bool {
        claimed.withLock { alreadyClaimed in
            if alreadyClaimed {
                return false
            }
            alreadyClaimed = true
            return true
        }
    }
}
