import Testing
@testable import AIUtilityCapturePoC

@Test @MainActor func duplicateStartIsRejected() throws {
    let gate = ProbeLifecycle()
    let session = try #require(gate.begin())
    #expect(gate.begin() == nil)
    #expect(gate.didStart(session))
    #expect(gate.begin() == nil)
}

@Test @MainActor func stopIsIdempotentDuringAndAfterRelease() throws {
    let gate = ProbeLifecycle()
    let session = try #require(gate.begin())
    #expect(gate.beginStop() == session)
    #expect(gate.beginStop() == nil)
    #expect(!gate.accepts(session))
    gate.didStop(session)
    #expect(gate.beginStop() == nil)
}

@Test @MainActor func pendingStartCannotBecomeRunningAfterCancel() throws {
    let gate = ProbeLifecycle()
    let session = try #require(gate.begin())
    #expect(gate.beginStop(expected: session) == session)
    #expect(!gate.didStart(session))
    gate.didStop(session)
    #expect(!gate.accepts(session))
}

@Test @MainActor func restartWaitsForActualAsyncRelease() async throws {
    let gate = ProbeLifecycle()
    let session = try #require(gate.begin())
    #expect(gate.beginStop() == session)
    // This yield represents resource release suspending, as stopCapture does in production.
    await Task.yield()
    #expect(gate.begin() == nil)
    #expect(gate.phase == .stopping)
    gate.didStop(session)
    #expect(gate.begin() != nil)
}

@Test @MainActor func oldFailureCannotStopReplacement() throws {
    let gate = ProbeLifecycle()
    let old = try #require(gate.begin())
    _ = gate.beginStop(); gate.didStop(old)
    let current = try #require(gate.begin())
    #expect(!gate.accepts(old))
    #expect(gate.beginStop(expected: old) == nil)
    #expect(gate.accepts(current))
}

@Test @MainActor func staleStopCompletionCannotClearReplacement() throws {
    let gate = ProbeLifecycle()
    let old = try #require(gate.begin())
    _ = gate.beginStop(); gate.didStop(old)
    let current = try #require(gate.begin())
    gate.didStop(old)
    #expect(gate.didStart(current))
    #expect(gate.phase == .running)
}

@Test @MainActor func lateMetricsAndPickerCallbacksAreRejected() throws {
    let gate = ProbeLifecycle()
    let old = try #require(gate.begin())
    _ = gate.beginStop()
    #expect(!gate.accepts(old))
    gate.didStop(old)
    let current = try #require(gate.begin())
    #expect(!gate.accepts(old))
    #expect(gate.accepts(current))
}

@Test @MainActor func interruptedSessionRequiresExplicitRestart() throws {
    let gate = ProbeLifecycle()
    let session = try #require(gate.begin())
    gate.didStart(session)
    #expect(gate.beginStop(expected: session) == session)
    #expect(gate.begin() == nil)
    gate.didStop(session)
    #expect(gate.phase == .idle)
    #expect(!gate.accepts(session))
    let restarted = try #require(gate.begin())
    #expect(restarted != session)
}
