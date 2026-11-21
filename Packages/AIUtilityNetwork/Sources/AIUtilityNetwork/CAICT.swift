import Foundation

/// Where the China Academy of ICT control server places this connection.
public struct CAICTLocation: Sendable, Equatable {
    public let ip: String
    public let province: String
    public let city: String
    /// Carrier name as the server reports it (电信 / 联通 / 移动 / 广电 ...).
    public let isp: String
}

/// One test node from the node list.
public struct CAICTNode: Sendable, Equatable, Identifiable {
    public let id: String
    /// Display name such as "城市+运营商".
    public let name: String
    public let province: String
    public let city: String
    public let host: String
    public let port: UInt16
}

/// China Academy of ICT「全球网测」speed test. Unofficial interface: no documentation and no compatibility
/// promise. Request formats follow open-source reimplementations and were checked against the live servers by
/// the owner (2026-11-21); the app's real concurrency and latency method are not confirmed. See NETWORK_TOOLS.md.
public enum CAICT {
    /// HTTPS first; the two plain-HTTP fallbacks go over the raw TCP client.
    public static let controlServers: [URL] = [
        URL(string: "https://dlcv2.cnspeedtest.cn:8443")!,
        URL(string: "http://dlc.duoweisoft.com:8096")!,
        URL(string: "http://dlcv2.duoweisoft.com:8088")!,
    ]
    public static let timeURL = URL(string: "http://dlc.duoweisoft.com:8096/dataServer/time.php")!
    /// The interface only answers its own client: these identify requests as the official Android app.
    static let controlUserAgent = "Dalvik/2.1.0 (Linux; U; Android 13; CnSpeedtest Build/Android)"
    static let downloadUserAgent = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.60 Safari/537.36"
    static let uploadUserAgent = "Dalvik/1.6.0 (Linux; U; Android 4.2.2; GT-I9505 Build/JDQ39)"
    static let package = "com.cnspeedtest.globalspeed"
    static let bandwidth = 200
    static let uploadBoundary = "00content0boundary00"
    /// Upload body length declared to the node; a connection never sends more than this.
    public static let uploadDeclaredLength: Int64 = 900_000_000

    public static func locationURL(server: URL) -> URL { server.appendingPathComponent("dataServer/getIpLocSP.php") }

    /// `{ip}|["中国","{省}","{市}","","{运营商}"]|3|{运营商}|{数字}`.
    public static func location(_ text: String) -> CAICTLocation? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let ip = parts[0].trimmingCharacters(in: .whitespaces)
        guard IPAddressText.family(ip) != nil,
              let fields = (try? JSONSerialization.jsonObject(with: Data(parts[1].utf8))) as? [Any] else { return nil }
        func field(_ index: Int) -> String {
            guard index < fields.count, let value = fields[index] as? String else { return "" }
            return clean(value)
        }
        var isp = field(4)
        if isp.isEmpty, parts.count >= 4 { isp = clean(parts[3]) }
        return CAICTLocation(ip: ip, province: field(1), city: field(2), isp: isp)
    }

    /// JSON array of {hostid, pname, city, port, hostname, hostip}; entries without a literal address are dropped.
    public static func nodes(_ data: Data) -> [CAICTNode] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        var out: [CAICTNode] = []
        for entry in list.prefix(30) {
            func text(_ key: String) -> String? {
                if let value = entry[key] as? String { return value }
                if let value = entry[key] as? Int { return String(value) }
                return nil
            }
            guard let host = text("hostip")?.trimmingCharacters(in: .whitespaces), IPAddressText.family(host) != nil,
                  let portText = text("port"), let port = UInt16(portText.trimmingCharacters(in: .whitespaces)), port > 0 else { continue }
            out.append(CAICTNode(id: clean(text("hostid") ?? host), name: clean(text("hostname") ?? ""), province: clean(text("pname") ?? ""),
                                 city: clean(text("city") ?? ""), host: host, port: port))
        }
        return out
    }

    public static func nodeListURL(server: URL, location: CAICTLocation) -> URL? {
        guard var components = URLComponents(url: server.appendingPathComponent("dataServer/mobilematch_many.php"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "ip", value: location.ip),
            URLQueryItem(name: "network", value: "4"),
            URLQueryItem(name: "province", value: location.province),
            URLQueryItem(name: "city", value: location.city),
            URLQueryItem(name: "wifioper", value: location.isp),
            URLQueryItem(name: "mobileoperid", value: operatorID(location.isp)),
            URLQueryItem(name: "ipv6", value: IPAddressText.family(location.ip) == .v6 ? "1" : "0"),
            URLQueryItem(name: "model", value: "Android"),
            URLQueryItem(name: "pkg", value: package),
        ]
        return components.url
    }

    static func operatorID(_ isp: String) -> String {
        if isp.contains("联通") { return "46001" }
        if isp.contains("移动") { return "46000" }
        if isp.contains("广电") { return "46015" }
        return "46003"
    }

    /// md5(md5("model=Android&imei=…") + md5("stime=…&band=…&rand=12345555")), lower-case hex.
    public static func token(imei: String, time: Int) -> String {
        let first = MD5.hex("model=Android&imei=" + imei)
        let second = MD5.hex("stime=\(time)&band=\(bandwidth)&rand=12345555")
        return MD5.hex(first + second)
    }

    /// A made-up device number in the format the server checks (15 digits, "35" prefix, Luhn check digit).
    /// Generated per test; nothing about this device is sent.
    public static func randomIMEI() -> String {
        var digits = [3, 5] + (0..<12).map { _ in Int.random(in: 0...9) }
        digits.append(luhnDigit(digits))
        return digits.map(String.init).joined()
    }

    static func luhnDigit(_ digits: [Int]) -> Int {
        var sum = 0
        for (index, digit) in digits.enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return (10 - sum % 10) % 10
    }

    public enum Grant: Sendable, Equatable {
        case granted(key: String)
        /// Node busy ("0-") or asks to retry ("2-").
        case busy
        /// Parameters or signature refused ("-1-"); bad nodes answer this too.
        case rejected
        case unknown
    }

    public static func grant(_ body: String) -> Grant {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("-1") { return .rejected }
        if text.hasPrefix("1-") {
            let key = String(text.dropFirst(2))
            let allowed = !key.isEmpty && key.count <= 64 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            return allowed ? .granted(key: key) : .unknown
        }
        if text.hasPrefix("0-") || text.hasPrefix("2-") { return .busy }
        return .unknown
    }

    static func dovalidRequest(node: CAICTNode, imei: String, time: Int) -> Data {
        let query = "key=&flag=true&bandwidth=\(bandwidth)&model=Android&imei=\(imei)&time=\(time)&app=globalspeed"
            + "&token=\(token(imei: imei, time: time))&pkg=\(package)"
        return HTTPWire.request("GET", "/speed/dovalid?" + query, headers: [
            ("Host", hostHeader(node)), ("User-Agent", controlUserAgent), ("Accept", "*/*"), ("Connection", "close"),
        ])
    }

    static func releaseRequest(node: CAICTNode, key: String) -> Data {
        HTTPWire.request("POST", "/speed/dovalid?key=" + key, headers: [
            ("Host", hostHeader(node)), ("User-Agent", controlUserAgent), ("Content-Length", "0"), ("Connection", "close"),
        ])
    }

    static func downloadRequest(node: CAICTNode, key: String, time: Int) -> Data {
        HTTPWire.request("GET", "/speed/File(1G).dl?r=\(time)&key=" + key, headers: [
            ("Accept", "*/*"), ("Connection", "close"), ("User-Agent", downloadUserAgent), ("Host", hostHeader(node)),
        ])
    }

    /// Headers and the multipart preamble; the body bytes that follow are streamed by the transport.
    static func uploadRequest(node: CAICTNode, key: String, time: Int) -> Data {
        let preamble = "--\(uploadBoundary)\r\nContent-Disposition: form-data; name=\"upload\";filename=\"SPEED_\(time)\"\r\n\r\n"
        return HTTPWire.request("POST", "/speed/doAnalsLoad.do", headers: [
            ("Connection", "close"), ("Cache-Control", "no-cache"), ("Charset", "UTF-8"), ("Key", key),
            ("Content-Type", "multipart/form-data;boundary=\(uploadBoundary)"), ("User-Agent", uploadUserAgent),
            ("Host", hostHeader(node)), ("Accept-Encoding", "gzip"), ("Content-Length", String(uploadDeclaredLength)),
        ], body: Data(preamble.utf8))
    }

    static func hostHeader(_ node: CAICTNode) -> String {
        (IPAddressText.family(node.host) == .v6 ? "[" + node.host + "]" : node.host) + ":\(node.port)"
    }

    /// Server text shown in the app: printable, short.
    static func clean(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isNewline && $0 != "\u{0}" }.prefix(40))
    }
}

/// Running total shared by the transfer connections and the sampler.
public final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    public init() {}
    public func add(_ bytes: Int) {
        lock.lock(); value += Int64(bytes); lock.unlock()
    }
    public var total: Int64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

private final class LatencyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func append(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
    var all: [Double] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

/// The wire side of the CAICT test (raw TCP on Apple platforms; a fake in tests).
public protocol CAICTTransport: Sendable {
    /// Control-plane GET (HTTPS through URLSession, plain HTTP through the raw client); body of a 200 answer.
    func fetch(_ url: URL, userAgent: String) async throws -> Data
    /// TCP handshake time to a node.
    func connectTime(host: String, port: UInt16) async throws -> TimeInterval
    /// One small request on a new connection, read until the node closes it.
    func exchange(host: String, port: UInt16, request: Data) async throws -> HTTPWire.Response
    /// Sends `request`, then counts response body bytes (download, `filler` nil) or keeps sending `filler`
    /// (upload) into `counter`, until cancelled, the node closes, or the declared upload length is reached.
    func stream(host: String, port: UInt16, request: Data, upload filler: Data?, counter: ByteCounter) async throws
}

public struct CAICTPlan: Sendable {
    public var latencyProbes: Int
    public var downloadConnections: Int
    public var uploadConnections: Int
    public var downloadSeconds: TimeInterval
    public var uploadSeconds: TimeInterval
    /// Slow start: intervals before this are left out of the average (unless the test ended earlier).
    public var warmupSeconds: TimeInterval
    public var sampleInterval: TimeInterval
    public var loadedProbeInterval: TimeInterval
    /// Both directions together; download may use this share, upload gets what is left.
    public var maxTotalBytes: Int64
    public var downloadShare: Double
    /// Nodes tried for a session, fastest handshake first.
    public var candidates: Int

    public init(latencyProbes: Int = 8, downloadConnections: Int = 8, uploadConnections: Int = 4,
                downloadSeconds: TimeInterval = 10, uploadSeconds: TimeInterval = 8, warmupSeconds: TimeInterval = 2,
                sampleInterval: TimeInterval = 0.5, loadedProbeInterval: TimeInterval = 0.5,
                maxTotalBytes: Int64 = 300_000_000, downloadShare: Double = 0.75, candidates: Int = 4) {
        self.latencyProbes = latencyProbes; self.downloadConnections = downloadConnections
        self.uploadConnections = uploadConnections; self.downloadSeconds = downloadSeconds
        self.uploadSeconds = uploadSeconds; self.warmupSeconds = warmupSeconds; self.sampleInterval = sampleInterval
        self.loadedProbeInterval = loadedProbeInterval; self.maxTotalBytes = maxTotalBytes
        self.downloadShare = downloadShare; self.candidates = candidates
    }
}

public struct CAICTOutcome: Sendable, Equatable {
    public let result: SpeedTestResult
    public let node: CAICTNode
    public let location: CAICTLocation
    public let downloadPeakMbps: Double?
    public let uploadPeakMbps: Double?
}

/// Locate → node list → handshake ranking → session key → latency, download, upload → release the key.
/// The key is released on every path after it was granted, including cancellation.
public struct CAICTSpeedTest: Sendable {
    public let transport: any CAICTTransport
    public let plan: CAICTPlan
    public init(transport: any CAICTTransport, plan: CAICTPlan = CAICTPlan()) {
        self.transport = transport; self.plan = plan
    }

    public func run(progress: @escaping @Sendable (SpeedTestProgress) -> Void = { _ in }) async throws(NetworkToolError) -> CAICTOutcome {
        do {
            progress(SpeedTestProgress(phase: .preparing, currentMbps: nil, bytesUsed: 0, completedRequests: 0))
            let location = try await locate()
            let nodes = try await nodeList(location)
            let ranked = await rank(nodes)
            try Task.checkCancellation()
            let time = await serverTime()
            let imei = CAICT.randomIMEI()
            var session: (node: CAICTNode, key: String)?
            for node in ranked.prefix(max(1, plan.candidates)) {
                try Task.checkCancellation()
                let request = CAICT.dovalidRequest(node: node, imei: imei, time: time)
                guard let reply = try? await transport.exchange(host: node.host, port: node.port, request: request),
                      reply.status == 200 else { continue }
                if case .granted(let key) = CAICT.grant(String(decoding: reply.body.prefix(512), as: UTF8.self)) {
                    session = (node, key)
                    break
                }
            }
            try Task.checkCancellation()
            guard let session else { throw NetworkToolError.noServer }
            do {
                let outcome = try await measure(session.node, key: session.key, location: location, progress: progress)
                await release(session.node, key: session.key)
                return outcome
            } catch {
                await release(session.node, key: session.key)
                throw error
            }
        } catch {
            throw Task.isCancelled ? .cancelled : NetworkToolError.classify(error)
        }
    }

    private func locate() async throws -> CAICTLocation {
        var lastError: any Error = NetworkToolError.unexpectedResponse
        for server in CAICT.controlServers {
            try Task.checkCancellation()
            do {
                let data = try await transport.fetch(CAICT.locationURL(server: server), userAgent: CAICT.controlUserAgent)
                if let location = CAICT.location(String(decoding: data.prefix(4096), as: UTF8.self)) { return location }
                lastError = NetworkToolError.unexpectedResponse
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func nodeList(_ location: CAICTLocation) async throws -> [CAICTNode] {
        for server in CAICT.controlServers {
            try Task.checkCancellation()
            guard let url = CAICT.nodeListURL(server: server, location: location),
                  let data = try? await transport.fetch(url, userAgent: CAICT.controlUserAgent) else { continue }
            let nodes = CAICT.nodes(data)
            if !nodes.isEmpty { return nodes }
        }
        throw NetworkToolError.noServer
    }

    /// Fastest TCP handshake first; nodes that do not answer are dropped.
    private func rank(_ nodes: [CAICTNode]) async -> [CAICTNode] {
        let transport = self.transport
        let timed = await withTaskGroup(of: (CAICTNode, TimeInterval?).self, returning: [(CAICTNode, TimeInterval)].self) { group in
            for node in nodes {
                group.addTask { (node, try? await transport.connectTime(host: node.host, port: node.port)) }
            }
            var out: [(CAICTNode, TimeInterval)] = []
            for await (node, time) in group { if let time { out.append((node, time)) } }
            return out
        }
        return timed.sorted { $0.1 < $1.1 }.map { $0.0 }
    }

    /// The control server's clock (the signature carries a timestamp); this device's clock if it does not answer.
    private func serverTime() async -> Int {
        if let data = try? await transport.fetch(CAICT.timeURL, userAgent: CAICT.controlUserAgent),
           let value = Int(String(decoding: data.prefix(32), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
           value > 1_600_000_000 {
            return value
        }
        return Int(Date().timeIntervalSince1970)
    }

    /// Runs outside the (possibly cancelled) test task, so the node's quota is freed even after Stop.
    private func release(_ node: CAICTNode, key: String) async {
        let transport = self.transport
        let request = CAICT.releaseRequest(node: node, key: key)
        await Task.detached {
            _ = try? await transport.exchange(host: node.host, port: node.port, request: request)
        }.value
    }

    private func measure(_ node: CAICTNode, key: String, location: CAICTLocation,
                         progress: @escaping @Sendable (SpeedTestProgress) -> Void) async throws -> CAICTOutcome {
        var handshakes: [Double] = []
        for index in 0..<max(0, plan.latencyProbes) {
            try Task.checkCancellation()
            if let seconds = try? await transport.connectTime(host: node.host, port: node.port) { handshakes.append(seconds * 1000) }
            progress(SpeedTestProgress(phase: .latency, currentMbps: nil, bytesUsed: 0, completedRequests: index + 1))
        }
        let usage = ByteCounter()
        let downLimit = Int64(Double(plan.maxTotalBytes) * min(1, max(0, plan.downloadShare)))
        let down = try await transfer(.download, node: node, key: key, limit: downLimit, usage: usage, progress: progress)
        let up = try await transfer(.upload, node: node, key: key, limit: plan.maxTotalBytes - usage.total, usage: usage, progress: progress)
        let used = usage.total
        let result = SpeedTestResult(
            latencyMilliseconds: SpeedStatistics.median(handshakes), jitterMilliseconds: SpeedStatistics.jitter(handshakes),
            downloadMbps: down.mbps, uploadMbps: up.mbps,
            loadedLatencyDownloadMilliseconds: SpeedStatistics.median(down.loaded),
            loadedLatencyUploadMilliseconds: SpeedStatistics.median(up.loaded),
            bytesUsed: used, stoppedByDataCap: down.capped || up.capped,
            downloadSamples: down.samples, uploadSamples: up.samples)
        progress(SpeedTestProgress(phase: .finished, currentMbps: nil, bytesUsed: used, completedRequests: 0))
        return CAICTOutcome(result: result, node: node, location: location, downloadPeakMbps: down.peak, uploadPeakMbps: up.peak)
    }

    private struct Transfer: Sendable {
        let mbps: Double?
        let peak: Double?
        let loaded: [Double]
        let samples: Int
        let capped: Bool
    }

    private struct Sampled: Sendable {
        var rates: [(elapsed: Double, mbps: Double)] = []
        var capped = false
    }

    /// Several connections for a fixed time, sampled at an interval: the average after warm-up and the peak.
    private func transfer(_ direction: SpeedDirection, node: CAICTNode, key: String, limit: Int64, usage: ByteCounter,
                          progress: @escaping @Sendable (SpeedTestProgress) -> Void) async throws -> Transfer {
        guard limit > 0 else { return Transfer(mbps: nil, peak: nil, loaded: [], samples: 0, capped: true) }
        let transport = self.transport, plan = self.plan
        let connections = max(1, direction == .download ? plan.downloadConnections : plan.uploadConnections)
        let seconds = direction == .download ? plan.downloadSeconds : plan.uploadSeconds
        let filler: Data? = direction == .upload ? Self.filler : nil
        let phase: SpeedTestProgress.Phase = direction == .download ? .download : .upload
        let counter = ByteCounter(), loaded = LatencyLog()
        let before = usage.total
        let clock = ContinuousClock()
        let start = clock.now

        let sampled = await withTaskGroup(of: Void.self, returning: Sampled.self) { group in
            for _ in 0..<connections {
                group.addTask {
                    // A node closes the 1 GB stream when it is done: reconnect. Give up after repeated failures,
                    // so a refusing node is not hammered.
                    var failures = 0
                    while !Task.isCancelled && failures < 3 {
                        let now = Int(Date().timeIntervalSince1970)
                        let request = direction == .download ? CAICT.downloadRequest(node: node, key: key, time: now)
                                                             : CAICT.uploadRequest(node: node, key: key, time: now)
                        do {
                            try await transport.stream(host: node.host, port: node.port, request: request, upload: filler, counter: counter)
                            failures = 0
                        } catch {
                            if Task.isCancelled { break }
                            failures += 1
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                    }
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(max(0.05, plan.loadedProbeInterval) * 1_000_000_000))
                    guard !Task.isCancelled else { break }
                    if let value = try? await transport.connectTime(host: node.host, port: node.port) { loaded.append(value * 1000) }
                }
            }
            var state = Sampled()
            var lastBytes: Int64 = 0
            var lastTime = start
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(0.02, plan.sampleInterval) * 1_000_000_000))
                let now = clock.now
                let total = counter.total
                let elapsed = (now - start).timeInterval
                let mbps = SpeedStatistics.megabitsPerSecond(bytes: total - lastBytes, seconds: (now - lastTime).timeInterval)
                if let mbps { state.rates.append((elapsed, mbps)) }
                lastBytes = total
                lastTime = now
                progress(SpeedTestProgress(phase: phase, currentMbps: mbps, bytesUsed: before + total, completedRequests: state.rates.count))
                if total >= limit { state.capped = true; break }
                if elapsed >= seconds { break }
                // Nothing at all after a few seconds: every connection was refused.
                if total == 0 && elapsed >= min(seconds, 4) { break }
            }
            group.cancelAll()
            return state
        }
        let moved = counter.total
        usage.add(Int(clamping: moved))
        try Task.checkCancellation()
        if moved == 0 && direction == .download { throw NetworkToolError.unexpectedResponse }
        let steady = sampled.rates.filter { $0.elapsed > plan.warmupSeconds }
        let used = (steady.isEmpty ? sampled.rates : steady).map(\.mbps)
        let mean = used.isEmpty || moved == 0 ? nil : used.reduce(0, +) / Double(used.count)
        return Transfer(mbps: mean, peak: moved == 0 ? nil : sampled.rates.map(\.mbps).max(), loaded: loaded.all,
                        samples: used.count, capped: sampled.capped)
    }

    /// 64 KB of random bytes, sent repeatedly (random so nothing on the path can compress it).
    static let filler = Data((0..<65_536).map { _ in UInt8.random(in: 0...255) })
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
