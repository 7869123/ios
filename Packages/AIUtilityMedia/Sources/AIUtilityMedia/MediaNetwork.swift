import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol MediaClock: Sendable {
    func now() -> TimeInterval
    func sleep(_ seconds: TimeInterval) async throws
}
struct SystemMediaClock: MediaClock {
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(min(seconds, 7200) * 1_000_000_000)) }
    }
}

struct WireResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let finalURL: URL
    func header(_ name: String) -> String? { headers[name.lowercased()] }
}
struct RequestLimits: Sendable { let inactivity: TimeInterval; let total: TimeInterval; let bytes: Int64 }
protocol MediaTransport: Sendable {
    func head(_ url: URL, limits: RequestLimits) async throws -> WireResponse
    func download(_ url: URL, to destination: URL, limits: RequestLimits,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> WireResponse
}

/// One foreground ephemeral session per request. All mutable delegate state is protected by lock.
private final class SessionTransfer: NSObject, URLSessionDownloadDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL?
    private let limits: RequestLimits
    private let progress: @Sendable (Int64, Int64?) -> Void
    private var continuation: CheckedContinuation<WireResponse, any Error>?
    private var task: URLSessionTask?
    private var cancelled = false
    private var failure: MediaError?
    private var moved = false
    private var received: Int64 = 0

    init(destination: URL?, limits: RequestLimits, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination; self.limits = limits; self.progress = progress
    }
    func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
    }
    func start(_ url: URL, continuation: CheckedContinuation<WireResponse, any Error>) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = limits.inactivity
        configuration.timeoutIntervalForResource = limits.total
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url); request.httpMethod = destination == nil ? "HEAD" : "GET"
        request.timeoutInterval = limits.inactivity
        request.setValue("AIUtility/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task: URLSessionTask = destination == nil ? session.dataTask(with: request) : session.downloadTask(with: request)
        let stop = lock.withLock {
            if cancelled { return true }
            self.continuation = continuation; self.task = task; return false
        }
        if stop {
            session.invalidateAndCancel(); continuation.resume(throwing: MediaError.cancelled)
        } else { task.resume() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // NetworkClient validates, budgets and follows each hop explicitly.
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Keep normal TLS trust evaluation; never answer HTTP authentication using stored credentials.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic ||
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest {
            completionHandler(.cancelAuthenticationChallenge, nil)
        } else { completionHandler(.performDefaultHandling, nil) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over = lock.withLock {
            received += Int64(data.count)
            if received > limits.bytes { failure = .resourceLimitExceeded; return true }; return false
        }
        if over { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let response = downloadTask.response as? HTTPURLResponse
        let cap = response.map { (200...299).contains($0.statusCode) ? limits.bytes : min(limits.bytes, 16_384) } ?? limits.bytes
        let stop = lock.withLock {
            if totalBytesWritten > cap || totalBytesExpectedToWrite > cap {
                failure = .resourceLimitExceeded; return true
            }
            return cancelled
        }
        if stop { downloadTask.cancel() }
        else if response?.statusCode == 200 { progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destination else { return }
        do {
            guard !lock.withLock({ cancelled || failure != nil }) else { return }
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size <= limits.bytes else { throw MediaError.resourceLimitExceeded }
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock { moved = true }
        } catch { lock.withLock { failure = MediaError.safe(error) } }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let state = lock.withLock { () -> (CheckedContinuation<WireResponse, any Error>?, MediaError?, Bool) in
            let c = continuation; continuation = nil; self.task = nil
            return (c, cancelled ? .cancelled : failure, moved)
        }
        session.finishTasksAndInvalidate()
        // didComplete is the final task message: no continuation is resumed on Task.cancel() alone.
        guard let continuation = state.0 else { return }
        if let failure = state.1 { continuation.resume(throwing: failure); return }
        if let error { continuation.resume(throwing: MediaError.safe(error)); return }
        guard let response = task.response as? HTTPURLResponse, let url = response.url,
              destination == nil || state.2 else { continuation.resume(throwing: MediaError.network); return }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String { headers[key.lowercased()] = String(describing: value) }
        }
        continuation.resume(returning: WireResponse(status: response.statusCode, headers: headers, finalURL: url))
    }
}

struct URLSessionMediaTransport: MediaTransport {
    func head(_ url: URL, limits: RequestLimits) async throws -> WireResponse {
        try await run(url, destination: nil, limits: limits, progress: { _, _ in })
    }
    func download(_ url: URL, to destination: URL, limits: RequestLimits,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> WireResponse {
        try await run(url, destination: destination, limits: limits, progress: progress)
    }
    private func run(_ url: URL, destination: URL?, limits: RequestLimits,
                     progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> WireResponse {
        let transfer = SessionTransfer(destination: destination, limits: limits, progress: progress)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { transfer.start(url, continuation: $0) }
        } onCancel: { transfer.cancel() }
    }
}

actor NetworkClient {
    let policy: DownloadPolicy
    let transport: any MediaTransport
    let validator: any DestinationValidator
    let clock: any MediaClock
    private var last: [String: TimeInterval] = [:]
    private var count = 0
    private var deadline: TimeInterval = 0
    private var notBefore: TimeInterval = 0
    init(policy: DownloadPolicy, transport: any MediaTransport, validator: any DestinationValidator, clock: any MediaClock) {
        self.policy = policy; self.transport = transport; self.validator = validator; self.clock = clock
    }
    func begin() { count = 0; deadline = clock.now() + policy.taskTimeout }
    func headers(_ url: URL) async throws -> WireResponse {
        try await follow(url, destination: nil, limit: Int64(policy.maxMetadataBytes), progress: { _, _ in })
    }
    func download(_ url: URL, to destination: URL, limit: Int64,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> WireResponse {
        try await follow(url, destination: destination, limit: limit, progress: progress)
    }
    private func follow(_ url: URL, destination: URL?, limit: Int64,
                        progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> WireResponse {
        var current = url; var visited: Set<String> = []
        let source = URLSafety.source(url) ?? .direct
        let origin = source == .direct ? (url.host ?? "") : source.rawValue
        for hop in 0...policy.maxRedirects {
            try Task.checkCancellation(); try URLSafety.validate(current)
            let canonical = try URLSafety.canonical(current)
            guard visited.insert(canonical).inserted else { throw MediaError.invalidURL }
            try await validator.validate(current)
            // A conservative global cooldown also prevents signed CDN addresses resetting the source budget.
            let keys = Set(["global", origin, current.host?.lowercased() ?? ""])
            let sourceDelay = keys.compactMap { last[$0] }.map { $0 + policy.minimumRequestInterval - clock.now() }.max() ?? 0
            let delay = max(sourceDelay, notBefore - clock.now())
            let remaining = deadline - clock.now()
            guard remaining > max(0, delay), count < policy.maxRequestsPerTask else {
                throw remaining <= max(0, delay) ? MediaError.timeout : MediaError.resourceLimitExceeded
            }
            try await clock.sleep(max(0, delay)); try Task.checkCancellation()
            for key in keys { last[key] = clock.now() }; count += 1
            let limits = RequestLimits(inactivity: policy.requestTimeout,
                                       total: min(destination == nil ? policy.requestTimeout : policy.taskTimeout, deadline - clock.now()), bytes: limit)
            let response: WireResponse
            if let destination {
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                response = try await transport.download(current, to: destination, limits: limits, progress: progress)
            } else { response = try await transport.head(current, limits: limits) }
            try Task.checkCancellation()
            guard clock.now() <= deadline else { throw MediaError.timeout }
            if [301,302,303,307,308].contains(response.status) {
                guard hop < policy.maxRedirects, let location = response.header("location"),
                      let target = URL(string: location, relativeTo: current)?.absoluteURL else { throw MediaError.invalidURL }
                current = target; continue
            }
            if [429, 503, 504].contains(response.status), let delay = Self.retryAfter(response.header("retry-after")) {
                notBefore = max(notBefore, clock.now() + delay)
            }
            try Self.validateStatus(response)
            return response
        }
        throw MediaError.invalidURL
    }
    static func validateStatus(_ response: WireResponse) throws {
        switch response.status {
        case 200: return
        case 401: throw MediaError.requiresLogin
        case 403: throw MediaError.accessRestricted(.permission)
        case 404, 410: throw MediaError.notFound
        case 429: throw MediaError.rateLimited(retryAfter: retryAfter(response.header("retry-after")))
        case 503, 504: throw MediaError.network
        case 206: throw MediaError.integrityMismatch // P1 never requests a range.
        default: throw MediaError.unsupportedFormat
        }
    }
    static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let number = Double(value), number.isFinite, number >= 0 { return min(number, 86_400) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value).map { min(86_400, max(0, $0.timeIntervalSinceNow)) }
    }
}

func mediaDeadline<T: Sendable>(_ seconds: TimeInterval,
                              operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0.001, min(seconds, 7200)) * 1_000_000_000))
            throw MediaError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw MediaError.cancelled }
        try Task.checkCancellation()
        return first
    }
}
