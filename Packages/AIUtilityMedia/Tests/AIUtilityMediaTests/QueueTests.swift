import Foundation
import Testing
@testable import AIUtilityMedia

struct QueueTests {
    @Test func fifoSingleSlotIncludingQueuedCancellation() async throws {
        let gate = TransferGate(), h = try Harness(steps: [.gate(gate)])
        defer { try? h.cleanup() }
        let manager = try h.manager()
        let first = try await manager.enqueue(link: URL(string: "https://media.example.org/first.png")!)
        await gate.waitUntilEntered()
        let second = try await manager.enqueue(link: URL(string: "https://media.example.org/second.png")!)
        let third = try await manager.enqueue(link: URL(string: "https://media.example.org/third.png")!)
        #expect(await manager.cancel(second.id) == .accepted)
        #expect(await h.transport.counts().downloads == 1)
        await gate.release()
        _ = try await waitFor(manager, id: first.id)
        _ = try await waitFor(manager, id: third.id)
        #expect(await h.transport.paths() == ["/first.png", "/third.png"])
        #expect(await h.transport.counts().peak == 1)
        try await manager.shutdown()
    }
    @Test func cancellationDoesNotReleaseSlotUntilLateTransferAcknowledges() async throws {
        let gate = TransferGate(), h = try Harness(steps: [.gate(gate)])
        defer { try? h.cleanup() }
        let manager = try h.manager(), first = try await manager.enqueue(link: mediaURL)
        await gate.waitUntilEntered()
        let second = try await manager.enqueue(link: URL(string: "https://media.example.org/next.png")!)
        #expect(await manager.cancel(first.id) == .accepted)
        #expect(await manager.cancel(first.id) == .accepted)
        let before = await queueSnapshot(manager)
        #expect(before.tasks.first(where: { $0.id == first.id })?.state == .cancelling)
        #expect(await h.transport.counts().downloads == 1)
        await gate.release() // Fake returns a success after cancellation; manager must discard it.
        #expect(try await waitFor(manager, id: first.id) == .cancelled)
        _ = try await waitFor(manager, id: second.id)
        #expect(await h.transport.counts().peak == 1)
        #expect(await manager.cancel(first.id) == .alreadyTerminal)
        try await manager.shutdown()
    }
    @Test func cleanupFailureBlocksNextUntilExplicitRetry() async throws {
        let gate = TransferGate(), h = try Harness(steps: [.gate(gate)])
        defer { try? h.cleanup() }
        let manager = try h.manager(), first = try await manager.enqueue(link: mediaURL)
        await gate.waitUntilEntered()
        let second = try await manager.enqueue(link: URL(string: "https://media.example.org/next.png")!)
        h.files.failCleanup(2)
        _ = await manager.cancel(first.id); await gate.release()
        try await mediaDeadline(4) {
            let stream = await manager.updates()
            for await snapshot in stream { if snapshot.blockingError == .cleanupFailed { return } }
            throw MediaError.invalidState
        }
        #expect(await h.transport.counts().downloads == 1)
        try await manager.retryCleanup(first.id)
        #expect(try await waitFor(manager, id: first.id) == .cancelled)
        _ = try await waitFor(manager, id: second.id)
        #expect(await h.transport.counts().peak == 1)
        try await manager.shutdown()
    }
    @Test func finiteRetriesStartOverAndManualRetryUsesSameID() async throws {
        let h = try Harness(steps: [.fail(.network), .fail(.network), .fail(.network), .success])
        defer { try? h.cleanup() }
        let manager = try h.manager(), receipt = try await manager.enqueue(link: mediaURL)
        #expect(try await waitFor(manager, id: receipt.id) == .failed(.network))
        #expect(await h.transport.counts().downloads == 3)
        #expect(h.clock.delays().contains(1) && h.clock.delays().contains(2))
        let oldAttempt = try #require(try await manager.history().first?.attemptID)
        try await manager.retry(receipt.id)
        let state = try await waitFor(manager, id: receipt.id)
        guard case .completed = state else { Issue.record("Manual retry did not complete"); return }
        #expect(try await manager.history().first?.attemptID != oldAttempt)
        #expect(await h.transport.counts().downloads == 4)
        try await manager.shutdown()
    }
    @Test func taskDeadlineCancelsTransportAndKeepsTimeoutDistinct() async throws {
        let h = try Harness(steps: [.cancellable], policy: .init(taskTimeout: 0.03, minimumRequestInterval: 0, maxRetries: 0, minimumFreeBytes: 0))
        defer { try? h.cleanup() }
        let manager = try h.manager(), receipt = try await manager.enqueue(link: mediaURL)
        #expect(try await waitFor(manager, id: receipt.id) == .failed(.timeout))
        #expect(await h.transport.counts().downloads == 1)
        try await manager.shutdown()
    }
    @Test func progressRejectsRegressionsAndWrongGenerations() async throws {
        let gate = TransferGate(), h = try Harness(steps: [.gate(gate)])
        defer { try? h.cleanup() }
        let manager = try h.manager(), receipt = try await manager.enqueue(link: mediaURL)
        await gate.waitUntilEntered()
        let snapshot = await queueSnapshot(manager), attempt = try #require(snapshot.tasks.first?.attemptID)
        await manager.progress(receipt.id, attempt: attempt, bytes: 20, total: 100)
        await manager.progress(receipt.id, attempt: attempt, bytes: 8, total: 100)
        await manager.progress(receipt.id, attempt: UUID(), bytes: 99, total: 100)
        let current = await queueSnapshot(manager)
        guard let state = current.tasks.first?.state, case .running(let value) = state else { Issue.record("Missing running progress"); return }
        #expect(value.bytesWritten == 20 && value.fraction == 0.2)
        _ = await manager.cancel(receipt.id)
        await manager.progress(receipt.id, attempt: attempt, bytes: 99, total: 100)
        #expect(await queueSnapshot(manager).tasks.first?.state == .cancelling)
        await gate.release(); _ = try await waitFor(manager, id: receipt.id)
        try await manager.shutdown()
    }
    @Test func duplicatePendingCompletedAndIrrelevantOptions() async throws {
        let gate = TransferGate(), h = try Harness(steps: [.gate(gate)])
        defer { try? h.cleanup() }
        let manager = try h.manager(), first = try await manager.enqueue(link: mediaURL)
        await gate.waitUntilEntered()
        let irrelevant = SiteOptions(bilibili: .init(allParts: true), pixiv: .init(keepUgoiraArchive: true))
        let pending = try await manager.enqueue(link: mediaURL, options: irrelevant)
        #expect(pending.id == first.id && pending.disposition == .alreadyQueued)
        await gate.release(); _ = try await waitFor(manager, id: first.id)
        let completed = try await manager.enqueue(link: mediaURL)
        #expect(completed.id == first.id && completed.disposition == .alreadyCompleted)
        #expect(await h.transport.counts().downloads == 1)
        try await manager.shutdown()
    }
    @Test func twoSubscribersReceiveIndependentCompleteSnapshots() async throws {
        let h = try Harness(); defer { try? h.cleanup() }
        let manager = try h.manager()
        let first = await manager.updates(), second = await manager.updates()
        var a = first.makeAsyncIterator(), b = second.makeAsyncIterator()
        #expect(await a.next()?.tasks.isEmpty == true)
        #expect(await b.next()?.tasks.isEmpty == true)
        let job = try await manager.enqueue(link: mediaURL)
        _ = try await waitFor(manager, id: job.id)
        #expect(await a.next()?.tasks.contains(where: { $0.id == job.id }) == true)
        #expect(await b.next()?.tasks.contains(where: { $0.id == job.id }) == true)
        try await manager.shutdown()
    }
    @Test func requestCooldownAndBudgetAreEnforced() async throws {
        let h = try Harness(policy: .init(minimumRequestInterval: 2, maxRetries: 0, minimumFreeBytes: 0, maxRequestsPerTask: 1))
        defer { try? h.cleanup() }
        let manager = try h.manager(), job = try await manager.enqueue(link: mediaURL)
        #expect(try await waitFor(manager, id: job.id) == .failed(.resourceLimitExceeded))
        #expect(await h.transport.counts().downloads == 0)
        try await manager.shutdown()
        let second = try Harness(policy: .init(minimumRequestInterval: 2, minimumFreeBytes: 0)); defer { try? second.cleanup() }
        let other = try second.manager(), task = try await other.enqueue(link: mediaURL)
        _ = try await waitFor(other, id: task.id)
        #expect(second.clock.delays().contains(2))
        try await other.shutdown()
    }
}
