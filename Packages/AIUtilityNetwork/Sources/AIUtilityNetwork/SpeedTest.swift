import Foundation

/// One timed transfer. `transferSeconds` covers the body only (first to last byte), so connection set-up does not
/// lower the bandwidth figure; `latencySeconds` is time to first byte minus the server's own processing time.
public struct TransferSample: Sendable, Equatable {
    public let bytes: Int64
    public let transferSeconds: TimeInterval
    public let latencySeconds: TimeInterval?
    public init(bytes: Int64, transferSeconds: TimeInterval, latencySeconds: TimeInterval? = nil) {
        self.bytes = bytes; self.transferSeconds = transferSeconds; self.latencySeconds = latencySeconds
    }
}

/// The wire side of a speed test, so the measuring logic can be tested without a network.
public protocol SpeedTransport: Sendable {
    /// Round-trip estimate of one minimal request, in seconds.
    func latencyProbe() async throws -> TimeInterval
    func download(bytes: Int) async throws -> TransferSample
    func upload(bytes: Int) async throws -> TransferSample
}

public enum SpeedDirection: String, Sendable { case download, upload }

/// Request sizes and counts, smallest first (the sequence Cloudflare's own engine uses), with a data cap.
public struct SpeedTestPlan: Sendable {
    public struct Step: Sendable, Equatable {
        public let bytes: Int
        public let count: Int
        public init(bytes: Int, count: Int) { self.bytes = bytes; self.count = count }
    }
    public var latencyProbes: Int
    public var download: [Step]
    public var upload: [Step]
    /// After a step in which one request took at least this long, larger sizes are skipped (enough data).
    public var finishSeconds: TimeInterval
    /// Requests shorter than this are too short to time reliably and are left out of the bandwidth figure.
    public var minimumSampleSeconds: TimeInterval
    /// Total bytes moved (both directions) before the test stops early.
    public var maxTotalBytes: Int64
    /// Interval between latency probes while data is moving (loaded latency).
    public var loadedProbeInterval: TimeInterval
    /// Bandwidth reported: this percentile of the timed requests.
    public var bandwidthPercentile: Double

    public init(latencyProbes: Int = 20,
                download: [Step] = [.init(bytes: 100_000, count: 10), .init(bytes: 1_000_000, count: 8),
                                    .init(bytes: 10_000_000, count: 6), .init(bytes: 25_000_000, count: 4),
                                    .init(bytes: 100_000_000, count: 3)],
                upload: [Step] = [.init(bytes: 100_000, count: 8), .init(bytes: 1_000_000, count: 6),
                                  .init(bytes: 10_000_000, count: 4), .init(bytes: 25_000_000, count: 4),
                                  .init(bytes: 50_000_000, count: 3)],
                finishSeconds: TimeInterval = 1, minimumSampleSeconds: TimeInterval = 0.01,
                maxTotalBytes: Int64 = 300_000_000, loadedProbeInterval: TimeInterval = 0.4,
                bandwidthPercentile: Double = 0.9) {
        self.latencyProbes = latencyProbes; self.download = download; self.upload = upload
        self.finishSeconds = finishSeconds; self.minimumSampleSeconds = minimumSampleSeconds
        self.maxTotalBytes = maxTotalBytes; self.loadedProbeInterval = loadedProbeInterval
        self.bandwidthPercentile = bandwidthPercentile
    }
}

public struct SpeedTestProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case latency, download, upload, finished }
    public let phase: Phase
    /// Current estimate for the running direction, Mbps.
    public let currentMbps: Double?
    public let bytesUsed: Int64
    public let completedRequests: Int
}

public struct SpeedTestResult: Sendable, Equatable {
    public let latencyMilliseconds: Double?
    public let jitterMilliseconds: Double?
    public let downloadMbps: Double?
    public let uploadMbps: Double?
    public let loadedLatencyDownloadMilliseconds: Double?
    public let loadedLatencyUploadMilliseconds: Double?
    public let bytesUsed: Int64
    /// True when the data cap stopped a direction before its larger sizes.
    public let stoppedByDataCap: Bool
    public let downloadSamples: Int
    public let uploadSamples: Int
}

/// Latency → download (with loaded latency) → upload (with loaded latency). Cancellable at every request.
public struct SpeedTestEngine: Sendable {
    public let transport: any SpeedTransport
    public let plan: SpeedTestPlan
    public init(transport: any SpeedTransport, plan: SpeedTestPlan = SpeedTestPlan()) {
        self.transport = transport; self.plan = plan
    }

    public func run(progress: @escaping @Sendable (SpeedTestProgress) -> Void = { _ in }) async throws(NetworkToolError) -> SpeedTestResult {
        do {
            var latencies: [Double] = []
            for index in 0..<max(0, plan.latencyProbes) {
                try Task.checkCancellation()
                latencies.append(try await transport.latencyProbe() * 1000)
                progress(SpeedTestProgress(phase: .latency, currentMbps: nil, bytesUsed: 0, completedRequests: index + 1))
            }
            let usage = Usage()
            let down = try await direction(.download, steps: plan.download, usage: usage, progress: progress)
            let up = try await direction(.upload, steps: plan.upload, usage: usage, progress: progress)
            let used = await usage.total
            let result = SpeedTestResult(
                latencyMilliseconds: SpeedStatistics.median(latencies), jitterMilliseconds: SpeedStatistics.jitter(latencies),
                downloadMbps: down.mbps, uploadMbps: up.mbps,
                loadedLatencyDownloadMilliseconds: SpeedStatistics.median(down.loaded),
                loadedLatencyUploadMilliseconds: SpeedStatistics.median(up.loaded),
                bytesUsed: used, stoppedByDataCap: down.capped || up.capped,
                downloadSamples: down.samples, uploadSamples: up.samples)
            progress(SpeedTestProgress(phase: .finished, currentMbps: nil, bytesUsed: used, completedRequests: 0))
            return result
        } catch {
            throw Task.isCancelled ? .cancelled : NetworkToolError.classify(error)
        }
    }

    private actor Usage {
        private(set) var total: Int64 = 0
        func add(_ bytes: Int64) { total += bytes }
    }

    private struct DirectionResult: Sendable { let mbps: Double?; let loaded: [Double]; let samples: Int; let capped: Bool }

    private func direction(_ direction: SpeedDirection, steps: [SpeedTestPlan.Step], usage: Usage,
                           progress: @escaping @Sendable (SpeedTestProgress) -> Void) async throws -> DirectionResult {
        let transport = self.transport, plan = self.plan
        let phase: SpeedTestProgress.Phase = direction == .download ? .download : .upload
        return try await withThrowingTaskGroup(of: [Double]?.self, returning: DirectionResult.self) { group in
            // Loaded latency: probe at an interval while the transfers run; stopped when they finish.
            group.addTask {
                var values: [Double] = []
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(max(0.05, plan.loadedProbeInterval) * 1_000_000_000))
                    guard !Task.isCancelled else { break }
                    if let value = try? await transport.latencyProbe() { values.append(value * 1000) }
                }
                return values
            }
            var speeds: [Double] = [], samples = 0, capped = false
            stepLoop: for step in steps {
                var slowest: TimeInterval = 0
                for _ in 0..<max(0, step.count) {
                    try Task.checkCancellation()
                    let before = await usage.total
                    guard before + Int64(step.bytes) <= plan.maxTotalBytes else { capped = true; break stepLoop }
                    let sample: TransferSample
                    if direction == .download {
                        sample = try await transport.download(bytes: step.bytes)
                    } else {
                        sample = try await transport.upload(bytes: step.bytes)
                    }
                    await usage.add(sample.bytes)
                    slowest = max(slowest, sample.transferSeconds)
                    if sample.transferSeconds >= plan.minimumSampleSeconds,
                       let mbps = SpeedStatistics.megabitsPerSecond(bytes: sample.bytes, seconds: sample.transferSeconds) {
                        speeds.append(mbps); samples += 1
                    }
                    let used = await usage.total
                    progress(SpeedTestProgress(phase: phase, currentMbps: SpeedStatistics.percentile(speeds, plan.bandwidthPercentile),
                                               bytesUsed: used, completedRequests: samples))
                }
                if slowest >= plan.finishSeconds { break }
            }
            group.cancelAll()
            var loaded: [Double] = []
            for try await values in group { if let values { loaded += values } }
            return DirectionResult(mbps: SpeedStatistics.percentile(speeds, plan.bandwidthPercentile),
                                   loaded: loaded, samples: samples, capped: capped)
        }
    }
}
