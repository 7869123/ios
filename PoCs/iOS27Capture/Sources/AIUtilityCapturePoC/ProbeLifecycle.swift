/// Main-actor ownership for one start/stop transaction. No Apple frameworks are needed to test it.
/// A new session cannot begin until the previous asynchronous resource release finishes.
@MainActor
final class ProbeLifecycle {
    enum Phase: Equatable { case idle, starting, running, stopping, releaseFailed }
    private(set) var phase: Phase = .idle
    private(set) var revision: UInt64 = 0
    private var releaseTask: Task<Bool, Never>?

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
              phase == .starting || phase == .running || phase == .releaseFailed else { return nil }
        phase = .stopping
        return revision
    }
    func didStop(_ revision: UInt64) {
        guard self.revision == revision, phase == .stopping else { return }
        phase = .idle
    }
    /// Every caller awaits the same release; nobody can observe idle before release finishes.
    @discardableResult
    func stop(expected: UInt64? = nil, release: @escaping @MainActor () async -> Bool) async -> Bool {
        guard expected == nil || expected == revision else { return false }
        if let releaseTask { return await releaseTask.value }
        guard let session = beginStop(expected: expected) else { return phase == .idle }
        let task = Task { @MainActor [self] in
            let succeeded = await release()
            releaseTask = nil
            if succeeded { didStop(session) }
            else { phase = .releaseFailed }
            return succeeded
        }
        releaseTask = task
        return await task.value
    }
}
