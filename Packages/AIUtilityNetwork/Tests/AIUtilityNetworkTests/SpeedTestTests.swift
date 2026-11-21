import Foundation
import Testing
@testable import AIUtilityNetwork

/// Instant transfers at a fixed rate; records the sizes asked for.
private struct FixedRateTransport: SpeedTransport {
    actor Log {
        private(set) var downloads: [Int] = []
        private(set) var uploads: [Int] = []
        func down(_ bytes: Int) { downloads.append(bytes) }
        func up(_ bytes: Int) { uploads.append(bytes) }
    }
    let mbps: Double
    let log = Log()

    func latencyProbe() async throws -> TimeInterval { 0.02 }
    func download(bytes: Int) async throws -> TransferSample {
        await log.down(bytes)
        return TransferSample(bytes: Int64(bytes), transferSeconds: Double(bytes) * 8 / (mbps * 1_000_000), latencySeconds: 0.02)
    }
    func upload(bytes: Int) async throws -> TransferSample {
        await log.up(bytes)
        return TransferSample(bytes: Int64(bytes), transferSeconds: Double(bytes) * 8 / (mbps * 1_000_000), latencySeconds: 0.02)
    }
}

/// Every transfer waits far longer than a test should run, so only cancellation ends it.
private struct StalledTransport: SpeedTransport {
    func latencyProbe() async throws -> TimeInterval { 0.02 }
    func download(bytes: Int) async throws -> TransferSample {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return TransferSample(bytes: Int64(bytes), transferSeconds: 1)
    }
    func upload(bytes: Int) async throws -> TransferSample { try await download(bytes: bytes) }
}

private struct FailingTransport: SpeedTransport {
    func latencyProbe() async throws -> TimeInterval { throw URLError(.timedOut) }
    func download(bytes: Int) async throws -> TransferSample { throw URLError(.notConnectedToInternet) }
    func upload(bytes: Int) async throws -> TransferSample { throw URLError(.notConnectedToInternet) }
}

@Suite("Speed statistics")
struct SpeedStatisticsTests {
    @Test func medianAndPercentile() {
        #expect(SpeedStatistics.median([3, 1, 2]) == 2)
        #expect(SpeedStatistics.median([1, 2, 3, 4]) == 2.5)
        #expect(SpeedStatistics.median([]) == nil)
        let p90 = SpeedStatistics.percentile([1, 2, 3, 4], 0.9) ?? 0
        #expect(abs(p90 - 3.7) < 1e-9)
        #expect(SpeedStatistics.percentile([5], 0.9) == 5)
        #expect(SpeedStatistics.percentile([1, .nan, 3], 1) == 3)
    }

    @Test func jitterIsMeanConsecutiveDifference() {
        #expect(SpeedStatistics.jitter([10, 20, 15]) == 7.5)
        #expect(SpeedStatistics.jitter([10]) == nil)
    }

    @Test func megabits() {
        #expect(SpeedStatistics.megabitsPerSecond(bytes: 1_000_000, seconds: 1) == 8)
        #expect(SpeedStatistics.megabitsPerSecond(bytes: 1, seconds: 0) == nil)
        #expect(SpeedStatistics.megabitsPerSecond(bytes: 1, seconds: .infinity) == nil)
    }
}

@Suite("Speed test engine")
struct SpeedTestEngineTests {
    @Test func stopsGrowingAfterASlowStep() async throws {
        let transport = FixedRateTransport(mbps: 1)
        let plan = SpeedTestPlan(latencyProbes: 3,
                                 download: [.init(bytes: 1_000, count: 2), .init(bytes: 10_000, count: 2), .init(bytes: 100_000, count: 2)],
                                 upload: [.init(bytes: 1_000, count: 1)],
                                 finishSeconds: 0.05, minimumSampleSeconds: 0, maxTotalBytes: 10_000_000)
        let result = try await SpeedTestEngine(transport: transport, plan: plan).run()
        // 1 000 bytes at 1 Mbps take 8 ms, 10 000 bytes 80 ms (>= 50 ms): the 100 000-byte step is skipped.
        #expect(await transport.log.downloads == [1_000, 1_000, 10_000, 10_000])
        #expect(await transport.log.uploads == [1_000])
        #expect(result.bytesUsed == 23_000)
        #expect(result.downloadSamples == 4 && result.uploadSamples == 1)
        #expect(abs((result.downloadMbps ?? 0) - 1) < 1e-6)
        #expect(abs((result.uploadMbps ?? 0) - 1) < 1e-6)
        #expect(result.latencyMilliseconds == 20)
        #expect(result.jitterMilliseconds == 0)
        #expect(result.stoppedByDataCap == false)
    }

    @Test func dataCapStopsBothDirections() async throws {
        let transport = FixedRateTransport(mbps: 100)
        let plan = SpeedTestPlan(latencyProbes: 0, download: [.init(bytes: 1_000, count: 10)],
                                 upload: [.init(bytes: 1_000, count: 10)], minimumSampleSeconds: 0, maxTotalBytes: 5_500)
        let result = try await SpeedTestEngine(transport: transport, plan: plan).run()
        #expect(await transport.log.downloads.count == 5)
        #expect(await transport.log.uploads.isEmpty)
        #expect(result.bytesUsed == 5_000)
        #expect(result.stoppedByDataCap)
        #expect(result.uploadMbps == nil)
        #expect(result.latencyMilliseconds == nil)
    }

    @Test func tooShortRequestsAreNotTimed() async throws {
        let plan = SpeedTestPlan(latencyProbes: 0, download: [.init(bytes: 1_000, count: 3)], upload: [],
                                 minimumSampleSeconds: 0.01, maxTotalBytes: 1_000_000)
        let result = try await SpeedTestEngine(transport: FixedRateTransport(mbps: 100), plan: plan).run()
        #expect(result.downloadSamples == 0)
        #expect(result.downloadMbps == nil)
        #expect(result.bytesUsed == 3_000)
    }

    @Test func defaultPlanStaysUnderItsCap() async throws {
        let result = try await SpeedTestEngine(transport: FixedRateTransport(mbps: 100)).run()
        #expect(result.bytesUsed <= SpeedTestPlan().maxTotalBytes)
        #expect(abs((result.downloadMbps ?? 0) - 100) < 1e-6)
    }

    @Test func progressReportsEachPhase() async throws {
        let plan = SpeedTestPlan(latencyProbes: 2, download: [.init(bytes: 1_000, count: 1)], upload: [.init(bytes: 1_000, count: 1)],
                                 minimumSampleSeconds: 0)
        let stream = AsyncStream<SpeedTestProgress>.makeStream()
        _ = try await SpeedTestEngine(transport: FixedRateTransport(mbps: 1), plan: plan).run { update in
            _ = stream.continuation.yield(update)
        }
        stream.continuation.finish()
        var phases: [SpeedTestProgress.Phase] = []
        for await update in stream.stream where phases.last != update.phase { phases.append(update.phase) }
        #expect(phases == [.latency, .download, .upload, .finished])
    }

    @Test(.timeLimit(.minutes(1))) func cancellationEndsARunningTest() async throws {
        let plan = SpeedTestPlan(latencyProbes: 0, download: [.init(bytes: 1_000, count: 1)], upload: [])
        let task = Task { try await SpeedTestEngine(transport: StalledTransport(), plan: plan).run() }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await #expect(throws: NetworkToolError.cancelled) { try await task.value }
    }

    @Test func transportErrorsAreClassified() async {
        let plan = SpeedTestPlan(latencyProbes: 1)
        await #expect(throws: NetworkToolError.timeout) { try await SpeedTestEngine(transport: FailingTransport(), plan: plan).run() }
        let downOnly = SpeedTestPlan(latencyProbes: 0)
        await #expect(throws: NetworkToolError.network) { try await SpeedTestEngine(transport: FailingTransport(), plan: downOnly).run() }
    }
}
