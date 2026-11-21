import Foundation

#if canImport(Darwin)
/// Resumes a continuation exactly once from whichever callback comes first (also before `install`).
final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    /// Holds the value when it arrives before the continuation (an array avoids Optional-of-Optional when T is optional).
    private var early: [T] = []
    private var done = false

    func install(_ continuation: CheckedContinuation<T, Never>) {
        let ready: T? = lock.withLock {
            if let first = early.first { return first }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(returning: ready) }
    }

    func finish(_ value: T) {
        let target: CheckedContinuation<T, Never>? = lock.withLock {
            guard !done else { return nil }
            done = true
            guard let waiting = continuation else { early = [value]; return nil }
            continuation = nil
            return waiting
        }
        target?.resume(returning: value)
    }
}
#endif
