import Foundation
#if canImport(Network)
import Network

/// Raw TCP for the China Academy of ICT nodes (plain HTTP on IP:port, outside App Transport Security) and
/// URLSession for the HTTPS control server. Every wait responds to task cancellation by closing the connection.
public struct NetworkCAICTTransport: CAICTTransport {
    public init() {}

    public func fetch(_ url: URL, userAgent: String) async throws -> Data {
        if url.scheme == "https" {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10; configuration.urlCache = nil
            configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw NetworkToolError.unexpectedResponse }
            guard http.statusCode == 200 else { throw NetworkToolError.httpStatus(http.statusCode) }
            guard data.count <= 262_144 else { throw NetworkToolError.unexpectedResponse }
            return data
        }
        guard url.scheme == "http", let host = url.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw NetworkToolError.unexpectedResponse }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let target = path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        let port = UInt16(clamping: url.port ?? 80)
        let request = HTTPWire.request("GET", target, headers: [
            ("Host", "\(host):\(port)"), ("User-Agent", userAgent), ("Accept", "*/*"), ("Connection", "close"),
        ])
        let response = try await exchange(host: host, port: port, request: request)
        guard response.status == 200 else { throw NetworkToolError.httpStatus(response.status) }
        return response.body
    }

    public func connectTime(host: String, port: UInt16) async throws -> TimeInterval {
        let connection = TCPConnection(host: host, port: port)
        defer { connection.close() }
        let clock = ContinuousClock()
        let start = clock.now
        try await connection.open(timeout: 3)
        return (clock.now - start).timeInterval
    }

    public func exchange(host: String, port: UInt16, request: Data) async throws -> HTTPWire.Response {
        let connection = TCPConnection(host: host, port: port)
        defer { connection.close() }
        try await connection.open(timeout: 5)
        connection.closeAfter(seconds: 10)
        try await connection.send(request)
        var data = Data()
        while let chunk = try await connection.receive(maximum: 65_536) {
            data += chunk
            guard data.count <= 262_144 else { throw NetworkToolError.unexpectedResponse }
        }
        guard let response = HTTPWire.parse(data) else { throw NetworkToolError.unexpectedResponse }
        return response
    }

    public func stream(host: String, port: UInt16, request: Data, upload filler: Data?, counter: ByteCounter) async throws {
        let connection = TCPConnection(host: host, port: port)
        defer { connection.close() }
        try await connection.open(timeout: 5)
        try await connection.send(request)
        if let filler, !filler.isEmpty {
            let preamble = Int64(request.count - (HTTPWire.headerEnd([UInt8](request)) ?? request.count))
            var sent = preamble
            while !Task.isCancelled && sent + Int64(filler.count) <= CAICT.uploadDeclaredLength {
                try await connection.send(filler)
                sent += Int64(filler.count)
                counter.add(filler.count)
            }
            return
        }
        // Download: check the status line first (a refused key answers 403 with a short page), then count body bytes.
        var head: [UInt8] = []
        while true {
            guard let chunk = try await connection.receive(maximum: 16_384) else { throw NetworkToolError.unexpectedResponse }
            head += chunk
            if let end = HTTPWire.headerEnd(head) {
                let code = HTTPWire.status(ofHead: head) ?? 0
                guard code == 200 else { throw NetworkToolError.httpStatus(code) }
                counter.add(head.count - end)
                break
            }
            guard head.count <= 16_384 else { throw NetworkToolError.unexpectedResponse }
        }
        while let chunk = try await connection.receive(maximum: 262_144) { counter.add(chunk.count) }
    }
}

/// async wrappers over one NWConnection (TCP, no TLS).
final class TCPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "aiutility.tcp")

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 80,
                                  using: NWParameters(tls: nil, tcp: tcp))
    }

    func open(timeout: TimeInterval) async throws {
        let connection = self.connection, queue = self.queue
        let once = Once<NetworkToolError?>()
        let failure: NetworkToolError? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                once.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.finish(nil)
                    case .waiting, .failed: once.finish(.network)
                    case .cancelled: once.finish(.cancelled)
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) { once.finish(.timeout) }
                connection.start(queue: queue)
            }
        } onCancel: {
            once.finish(.cancelled)
        }
        if let failure {
            connection.cancel()
            throw failure
        }
    }

    func send(_ data: Data) async throws {
        let connection = self.connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Next bytes, an empty chunk when nothing new arrived yet, nil once the peer closed.
    func receive(maximum: Int) async throws -> Data? {
        let connection = self.connection
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else if isComplete {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Hard deadline for small exchanges: the connection is closed, which ends any pending wait.
    func closeAfter(seconds: TimeInterval) {
        let connection = self.connection
        queue.asyncAfter(deadline: .now() + seconds) { connection.cancel() }
    }

    func close() { connection.cancel() }
}
#endif
