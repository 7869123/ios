import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `/cdn-cgi/trace` lines ("key=value"): the address Cloudflare sees, its data centre (colo) and country (loc).
public struct CloudflareTrace: Sendable, Equatable {
    public let ip: String
    public let colo: String?
    public let country: String?
    public let httpVersion: String?
    public let warp: String?

    public init?(_ text: String) {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            values[String(line[..<eq])] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let ip = values["ip"], IPAddressText.family(ip) != nil else { return nil }
        func clean(_ value: String?, max: Int = 16) -> String? {
            guard let value, !value.isEmpty, value.count <= max, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "/" || $0 == ".") })
            else { return nil }
            return value
        }
        self.ip = ip; colo = clean(values["colo"]); country = clean(values["loc"])
        httpVersion = clean(values["http"]); warp = clean(values["warp"])
    }
}

public enum Cloudflare {
    public static let speedHost = "speed.cloudflare.com"
    public static let traceDefault = URL(string: "https://speed.cloudflare.com/cdn-cgi/trace")!
    /// The resolver addresses force the family regardless of the system's preference.
    public static let traceIPv4 = URL(string: "https://1.1.1.1/cdn-cgi/trace")!
    public static let traceIPv6 = URL(string: "https://[2606:4700:4700::1111]/cdn-cgi/trace")!
    public static func downloadURL(bytes: Int) -> URL { URL(string: "https://speed.cloudflare.com/__down?bytes=\(max(0, bytes))")! }
    public static let uploadURL = URL(string: "https://speed.cloudflare.com/__up")!

    /// Server processing time from `Server-Timing: cfRequestDuration;dur=1.23` (milliseconds → seconds).
    public static func serverSeconds(fromServerTiming value: String?) -> TimeInterval? {
        guard let value else { return nil }
        for metric in value.split(separator: ",") {
            let parts = metric.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.first?.lowercased() == "cfrequestduration" else { continue }
            for part in parts.dropFirst() where part.lowercased().hasPrefix("dur=") {
                if let ms = Double(part.dropFirst(4)), ms.isFinite, ms >= 0 { return ms / 1000 }
            }
        }
        return nil
    }
}

#if canImport(Darwin)
/// URLSession transport for speed.cloudflare.com. Bodies are counted and discarded (a 100 MB download is never
/// held in memory); times come from URLSessionTaskMetrics, not from wall-clock around the call.
public final class CloudflareSpeedTransport: NSObject, SpeedTransport, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        var continuation: CheckedContinuation<TransferSample, any Error>
        var received: Int64 = 0
        var metrics: URLSessionTaskTransactionMetrics?
        var direction: SpeedDirection
        var sent: Int64
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    /// Set once in init (a lazy property would not be thread-safe here).
    private var session: URLSession!

    public override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// URLSession keeps its delegate (this object) alive until invalidated: call once the test is over.
    public func invalidate() { session.invalidateAndCancel() }

    public func latencyProbe() async throws -> TimeInterval {
        let sample = try await run(request(Cloudflare.downloadURL(bytes: 0)), direction: .download, sent: 0)
        guard let latency = sample.latencySeconds else { throw NetworkToolError.unexpectedResponse }
        return latency
    }
    public func download(bytes: Int) async throws -> TransferSample {
        try await run(request(Cloudflare.downloadURL(bytes: bytes)), direction: .download, sent: 0)
    }
    public func upload(bytes: Int) async throws -> TransferSample {
        var request = request(Cloudflare.uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(count: max(0, bytes))
        return try await run(request, direction: .upload, sent: Int64(max(0, bytes)))
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("AIUtility speed test", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func run(_ request: URLRequest, direction: SpeedDirection, sent: Int64) async throws -> TransferSample {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pending[task.taskIdentifier] = Pending(continuation: continuation, direction: direction, sent: sent) }
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { pending[dataTask.taskIdentifier]?.received += Int64(data.count) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock { pending[task.taskIdentifier]?.metrics = metrics.transactionMetrics.last }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let state = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error { state.continuation.resume(throwing: NetworkToolError.classify(error)); return }
        guard let http = task.response as? HTTPURLResponse else { state.continuation.resume(throwing: NetworkToolError.unexpectedResponse); return }
        guard (200...299).contains(http.statusCode) else { state.continuation.resume(throwing: NetworkToolError.httpStatus(http.statusCode)); return }
        let server = Cloudflare.serverSeconds(fromServerTiming: http.value(forHTTPHeaderField: "Server-Timing")) ?? 0
        let m = state.metrics
        var latency: TimeInterval?
        if let start = m?.requestStartDate, let first = m?.responseStartDate {
            latency = max(0, first.timeIntervalSince(start) - server)
        }
        let seconds: TimeInterval
        let bytes: Int64
        switch state.direction {
        case .download:
            bytes = state.received
            seconds = m.flatMap { m in m.responseStartDate.flatMap { s in m.responseEndDate.map { $0.timeIntervalSince(s) } } } ?? 0
        case .upload:
            bytes = state.sent
            // requestEnd only marks the body handed to the socket buffer, which makes small uploads look far too
            // fast (live check: 100 KB in 1 ms). The server's own duration covers receiving the body; the longer
            // of the two is used.
            let written = m.flatMap { m in m.requestStartDate.flatMap { s in m.requestEndDate.map { $0.timeIntervalSince(s) } } } ?? 0
            seconds = max(written, server)
        }
        state.continuation.resume(returning: TransferSample(bytes: bytes, transferSeconds: seconds, latencySeconds: latency))
    }
}
#endif
