import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status; self.headers = headers; self.body = body
    }
    public func header(_ name: String) -> String? {
        headers.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
    }
}

/// A transport must cooperate with Task cancellation, as URLSession does.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class URLSessionHTTPTransport: HTTPTransport, Sendable {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            try Task.checkCancellation()
            let (body, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, body.count <= 4_194_304 else {
                throw AIUtilityError.malformedResponse
            }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
                if let name = entry.key as? String, let value = entry.value as? String { result[name] = value }
            }
            return HTTPResponse(status: response.statusCode, headers: headers, body: body)
        } catch { throw AIUtilityError.sanitized(error) }
    }
}

/// Wall-clock deadline as well as URLRequest's inactivity timeout. Cancels losing work.
func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                             operation: @escaping @Sendable () async throws -> T) async throws -> T {
    guard seconds.isFinite, seconds > 0, seconds <= 300 else { throw AIUtilityError.invalidRequest }
    do {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AIUtilityError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AIUtilityError.cancelled }
            try Task.checkCancellation()
            return first
        }
    } catch { throw AIUtilityError.sanitized(error) }
}
