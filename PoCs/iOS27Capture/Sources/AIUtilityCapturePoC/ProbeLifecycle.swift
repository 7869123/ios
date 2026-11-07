/// Main-actor ownership for one start/stop transaction. No Apple frameworks are needed to test it.
/// A new session cannot begin until the previous asynchronous resource release finishes.
@MainActor
final class ProbeLifecycle {
    enum Phase: Equatable { case idle, starting, running, stopping }
    private(set) var phase: Phase = .idle
    private(set) var revision: UInt64 = 0

    func begin() -> UInt64? {
        guard phase == .idle else { return nil }
        revision &+= 1
        phase = .starting
        return revision
    }
    func accepts(_ revision: UInt64) -> Bool {
        self.revision == revision && (phase == .starting || phase == .running)
    }
    @discardableResult func didStart(_ revision: UInt64) -> Bool {
        guard accepts(revision), phase == .starting else { return false }
        phase = .running
        return true
    }
    func beginStop(expected: UInt64? = nil) -> UInt64? {
        guard expected == nil || expected == revision,
              phase == .starting || phase == .running else { return nil }
        phase = .stopping
        return revision
    }
    func didStop(_ revision: UInt64) {
        guard self.revision == revision, phase == .stopping else { return }
        phase = .idle
    }
}
