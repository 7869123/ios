import Testing
@testable import AIUtilityCapturePoC

@MainActor private final class ReleasePause {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}

@Test @MainActor func cancellingStopCallerStillFinishesResourceRelease() async throws {
    let gate = ProbeLifecycle()
    _ = try #require(gate.begin())
    let pause = ReleasePause()
    let stop = Task { @MainActor in await gate.stop { await pause.wait(); return true } }
    for _ in 0..<1_000 { if pause.continuation != nil { break }; await Task.yield() }
    let started = pause.continuation != nil
    #expect(started)
    guard started else { stop.cancel(); return }
    stop.cancel()
    #expect(gate.phase == .stopping)
    #expect(gate.begin() == nil)
    pause.resume()
    await stop.value
    #expect(gate.phase == .idle)
    #expect(gate.begin() != nil)
}

@Test @MainActor func concurrentStopsAwaitOneActualRelease() async throws {
    let gate = ProbeLifecycle()
    _ = try #require(gate.begin())
    let pause = ReleasePause()
    var releases = 0
    var completed = 0
    let first = Task { @MainActor in
        await gate.stop { releases += 1; await pause.wait(); return true }
        completed += 1
    }
    for _ in 0..<1_000 { if pause.continuation != nil { break }; await Task.yield() }
    let started = pause.continuation != nil
    #expect(started)
    guard started else { first.cancel(); return }
    let second = Task { @MainActor in
        await gate.stop { releases += 1; return true }
        completed += 1
    }
    await Task.yield()
    #expect(completed == 0)
    #expect(gate.begin() == nil)
    pause.resume()
    await first.value; await second.value
    #expect(releases == 1)
    #expect(completed == 2)
    #expect(gate.phase == .idle)
    #expect(gate.begin() != nil)
}

@Test @MainActor func staleFailureDoesNotReleaseNewSessionResources() async throws {
    let gate = ProbeLifecycle()
    let old = try #require(gate.begin())
    await gate.stop { true }
    let current = try #require(gate.begin())
    var accidentallyReleased = false
    await gate.stop(expected: old) { accidentallyReleased = true; return true }
    #expect(!accidentallyReleased)
    #expect(gate.accepts(current))
}

@Test @MainActor func repeatedStopAfterCompletionDoesNotReleaseTwice() async throws {
    let gate = ProbeLifecycle()
    _ = try #require(gate.begin())
    var releases = 0
    await gate.stop { releases += 1; return true }
    await gate.stop { releases += 1; return true }
    #expect(releases == 1)
}

@Test @MainActor func failedReleaseBlocksRestartUntilExplicitStopRetry() async throws {
    let gate = ProbeLifecycle()
    _ = try #require(gate.begin())
    var releases = 0
    let first = await gate.stop { releases += 1; return false }
    #expect(!first)
    #expect(gate.phase == .releaseFailed)
    #expect(gate.begin() == nil)
    #expect(!gate.accepts(gate.revision))
    let retry = await gate.stop { releases += 1; return true }
    #expect(retry)
    #expect(releases == 2)
    #expect(gate.phase == .idle)
    #expect(gate.begin() != nil)
}

@Test @MainActor func concurrentStopFailureIsSharedWithoutImplicitRetry() async throws {
    let gate = ProbeLifecycle()
    _ = try #require(gate.begin())
    let pause = ReleasePause()
    var releases = 0
    let first = Task { @MainActor in
        await gate.stop { releases += 1; await pause.wait(); return false }
    }
    for _ in 0..<1_000 { if pause.continuation != nil { break }; await Task.yield() }
    let started = pause.continuation != nil
    #expect(started)
    guard started else { first.cancel(); return }
    var joined = false
    let second = Task { @MainActor in
        joined = true
        return await gate.stop { releases += 1; return true }
    }
    for _ in 0..<1_000 { if joined { break }; await Task.yield() }
    #expect(joined)
    pause.resume()
    let firstResult = await first.value
    let secondResult = await second.value
    #expect(!firstResult && !secondResult)
    #expect(releases == 1)
    #expect(gate.phase == .releaseFailed)
    #expect(gate.begin() == nil)
}

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
