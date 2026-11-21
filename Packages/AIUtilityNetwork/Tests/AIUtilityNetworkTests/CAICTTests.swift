import Foundation
import Testing
@testable import AIUtilityNetwork

// Only made-up data: documentation addresses (RFC 5737), placeholder place and node names.

@Suite("MD5")
struct MD5Tests {
    @Test func rfc1321Vectors() {
        #expect(MD5.hex("") == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(MD5.hex("abc") == "900150983cd24fb0d6963f7d28e17f72")
        #expect(MD5.hex("message digest") == "f96b697d7cb7938d525a2f31aaf161d0")
        #expect(MD5.hex("The quick brown fox jumps over the lazy dog") == "9e107d9d372bb6826bd81d3542a419d6")
        #expect(MD5.hex(String(repeating: "1234567890", count: 8)) == "57edf4a22be3c955ac49da2e2107b67a")
    }

    @Test func paddingBoundaries() {
        // 55, 56 and 64 bytes: the length field fits, does not fit, and a full extra block.
        #expect(MD5.hex(String(repeating: "a", count: 55)) == "ef1772b6dff9a122358552954ad0df65")
        #expect(MD5.hex(String(repeating: "a", count: 56)) == "3b0c8ac703f828b04c6c197006d17218")
        #expect(MD5.hex(String(repeating: "a", count: 64)) == "014842d480b571495a4a0363793f7367")
    }
}

@Suite("CAICT protocol")
struct CAICTProtocolTests {
    private let node = CAICTNode(id: "80", name: "示例电信", province: "示例省", city: "示例市", host: "198.51.100.10", port: 65499)

    @Test func signature() {
        // Cross-checked with Python hashlib: md5(md5("model=Android&imei=…") + md5("stime=…&band=200&rand=12345555")).
        #expect(CAICT.token(imei: "351234567890124", time: 1_700_000_000) == "031392fbddb92a0e538f69ed57bbcc73")
    }

    @Test func deviceNumber() {
        #expect(CAICT.luhnDigit([4, 9, 0, 1, 5, 4, 2, 0, 3, 2, 3, 7, 5, 1]) == 8)
        for _ in 0..<20 {
            let imei = CAICT.randomIMEI()
            #expect(imei.count == 15 && imei.hasPrefix("35") && imei.allSatisfy(\.isNumber))
            let digits = imei.compactMap { $0.wholeNumberValue }
            #expect(CAICT.luhnDigit(Array(digits.prefix(14))) == digits[14])
        }
    }

    @Test func location() throws {
        let parsed = try #require(CAICT.location(#"203.0.113.5|["中国","示例省","示例市","","电信"]|3|电信|12345"# + "\n"))
        #expect(parsed == CAICTLocation(ip: "203.0.113.5", province: "示例省", city: "示例市", isp: "电信"))
        let fallback = try #require(CAICT.location(#"203.0.113.5|["中国","示例省","示例市"]|3|联通|1"#))
        #expect(fallback.isp == "联通")
        #expect(CAICT.location("<html>error</html>") == nil)
        #expect(CAICT.location(#"not-an-ip|["中国"]|3|电信|1"#) == nil)
    }

    @Test func nodeList() {
        let json = #"""
        [{"hostid":"80","pname":"示例省","city":"示例市","port":"65499","hostname":"示例电信","hostip":"198.51.100.10"},
         {"hostid":"81","pname":"示例省","city":"另一市","port":65500,"hostname":"另一电信","hostip":"198.51.100.11"},
         {"hostid":"82","pname":"x","city":"y","port":"65499","hostname":"坏地址","hostip":"node.example"},
         {"hostid":"83","pname":"x","city":"y","port":"abc","hostname":"坏端口","hostip":"198.51.100.13"}]
        """#
        let nodes = CAICT.nodes(Data(json.utf8))
        #expect(nodes.map(\.host) == ["198.51.100.10", "198.51.100.11"])
        #expect(nodes.first == node)
        #expect(nodes.last?.port == 65500)
        #expect(CAICT.nodes(Data("[]".utf8)).isEmpty)
        #expect(CAICT.nodes(Data("<html>".utf8)).isEmpty)
    }

    @Test func nodeListQuery() throws {
        let location = CAICTLocation(ip: "203.0.113.5", province: "示例省", city: "示例市", isp: "移动")
        let url = try #require(CAICT.nodeListURL(server: CAICT.controlServers[0], location: location))
        #expect(url.absoluteString.hasPrefix("https://dlcv2.cnspeedtest.cn:8443/dataServer/mobilematch_many.php?ip=203.0.113.5&network=4&province="))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        #expect(query["province"] == "示例省")
        #expect(query["wifioper"] == "移动")
        #expect(query["mobileoperid"] == "46000")
        #expect(query["ipv6"] == "0")
        #expect(query["pkg"] == "com.cnspeedtest.globalspeed")
        #expect(CAICT.operatorID("中国电信") == "46003")
        #expect(CAICT.operatorID("联通") == "46001")
        #expect(CAICT.operatorID("广电") == "46015")
        #expect(CAICT.locationURL(server: CAICT.controlServers[0]).absoluteString == "https://dlcv2.cnspeedtest.cn:8443/dataServer/getIpLocSP.php")
    }

    @Test func grantReplies() {
        #expect(CAICT.grant("1-0f8e2a6c-1b2c-4d5e-8f90-a1b2c3d4e5f6\r\n") == .granted(key: "0f8e2a6c-1b2c-4d5e-8f90-a1b2c3d4e5f6"))
        #expect(CAICT.grant("-1-") == .rejected)
        #expect(CAICT.grant("0-busy") == .busy)
        #expect(CAICT.grant("2-") == .busy)
        #expect(CAICT.grant("1-") == .unknown)
        #expect(CAICT.grant("1-bad key&x=1") == .unknown)
        #expect(CAICT.grant("<html>403 caict</html>") == .unknown)
    }

    @Test func requests() {
        let download = String(decoding: CAICT.downloadRequest(node: node, key: "k-1", time: 1_700_000_000), as: UTF8.self)
        #expect(download.hasPrefix("GET /speed/File(1G).dl?r=1700000000&key=k-1 HTTP/1.1\r\nAccept: */*\r\nConnection: close\r\n"))
        #expect(download.hasSuffix("Host: 198.51.100.10:65499\r\n\r\n"))

        let upload = String(decoding: CAICT.uploadRequest(node: node, key: "k-1", time: 1_700_000_000), as: UTF8.self)
        #expect(upload.hasPrefix("POST /speed/doAnalsLoad.do HTTP/1.1\r\n"))
        #expect(upload.contains("\r\nKey: k-1\r\n"))
        #expect(upload.contains("\r\nContent-Type: multipart/form-data;boundary=00content0boundary00\r\n"))
        #expect(upload.contains("\r\nContent-Length: 900000000\r\n"))
        #expect(upload.hasSuffix("\r\n\r\n--00content0boundary00\r\nContent-Disposition: form-data; name=\"upload\";filename=\"SPEED_1700000000\"\r\n\r\n"))

        let session = String(decoding: CAICT.dovalidRequest(node: node, imei: "351234567890124", time: 1_700_000_000), as: UTF8.self)
        #expect(session.hasPrefix("GET /speed/dovalid?key=&flag=true&bandwidth=200&model=Android&imei=351234567890124&time=1700000000"
                                  + "&app=globalspeed&token=031392fbddb92a0e538f69ed57bbcc73&pkg=com.cnspeedtest.globalspeed HTTP/1.1\r\n"))

        let release = String(decoding: CAICT.releaseRequest(node: node, key: "k-1"), as: UTF8.self)
        #expect(release.hasPrefix("POST /speed/dovalid?key=k-1 HTTP/1.1\r\n"))
        #expect(release.contains("\r\nContent-Length: 0\r\n"))

        let v6 = CAICTNode(id: "1", name: "", province: "", city: "", host: "2001:db8::10", port: 65499)
        #expect(CAICT.hostHeader(v6) == "[2001:db8::10]:65499")
    }
}

@Suite("HTTP wire")
struct HTTPWireTests {
    @Test func contentLength() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 5\r\n\r\nhello-extra"
        let response = try #require(HTTPWire.parse(Data(raw.utf8)))
        #expect(response.status == 200)
        #expect(response.headers["content-type"] == "text/html")
        #expect(response.body == Data("hello".utf8))
    }

    @Test func chunked() throws {
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n1-\r\na;ext=1\r\nabcdef0123\r\n0\r\n\r\n"
        let response = try #require(HTTPWire.parse(Data(raw.utf8)))
        #expect(String(decoding: response.body, as: UTF8.self) == "1-abcdef0123")
        #expect(HTTPWire.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nff\r\nshort".utf8)) == nil)
    }

    @Test func untilClose() throws {
        let response = try #require(HTTPWire.parse(Data("HTTP/1.0 403 Forbidden\r\n\r\ncaict".utf8)))
        #expect(response.status == 403)
        #expect(response.body == Data("caict".utf8))
    }

    @Test func malformed() {
        #expect(HTTPWire.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort".utf8)) == nil)
        #expect(HTTPWire.parse(Data("hello".utf8)) == nil)
        #expect(HTTPWire.parse(Data("SSH-2.0\r\n\r\n".utf8)) == nil)
        #expect(HTTPWire.status(ofHead: Array("HTTP/1.1 999 X\r\n".utf8)) == nil)
        #expect(HTTPWire.headerEnd(Array("ab".utf8)) == nil)
    }
}

/// In-memory nodes: .10 refuses sessions (answers "-1-") but has the fastest handshake, .11 grants, .12 is slow.
private final class FakeCAICT: CAICTTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var releasedKeys: [String] = []
    private var sessionRequests: [String] = []
    let grantingHost: String?
    let bytesPerTick: Int

    init(grantingHost: String? = "198.51.100.11", bytesPerTick: Int = 10_000) {
        self.grantingHost = grantingHost; self.bytesPerTick = bytesPerTick
    }

    var released: [String] { lock.lock(); defer { lock.unlock() }; return releasedKeys }
    var asked: [String] { lock.lock(); defer { lock.unlock() }; return sessionRequests }

    func fetch(_ url: URL, userAgent: String) async throws -> Data {
        #expect(userAgent.contains("CnSpeedtest"))
        if url.path.hasSuffix("getIpLocSP.php") { return Data(#"203.0.113.5|["中国","示例省","示例市","","电信"]|3|电信|1"#.utf8) }
        if url.path.hasSuffix("mobilematch_many.php") {
            return Data(#"""
            [{"hostid":"1","pname":"示例省","city":"甲市","port":"65499","hostname":"甲电信","hostip":"198.51.100.10"},
             {"hostid":"2","pname":"示例省","city":"乙市","port":"65499","hostname":"乙电信","hostip":"198.51.100.11"},
             {"hostid":"3","pname":"示例省","city":"丙市","port":"65499","hostname":"丙电信","hostip":"198.51.100.12"},
             {"hostid":"4","pname":"示例省","city":"丁市","port":"65499","hostname":"丁电信","hostip":"198.51.100.13"}]
            """#.utf8)
        }
        if url.path.hasSuffix("time.php") { return Data("1700000000\n".utf8) }
        throw NetworkToolError.network
    }

    func connectTime(host: String, port: UInt16) async throws -> TimeInterval {
        switch host {
        case "198.51.100.10": 0.005
        case "198.51.100.11": 0.010
        case "198.51.100.12": 0.050
        default: throw NetworkToolError.timeout
        }
    }

    func exchange(host: String, port: UInt16, request: Data) async throws -> HTTPWire.Response {
        let text = String(decoding: request, as: UTF8.self)
        if text.hasPrefix("GET /speed/dovalid?") {
            lock.lock(); sessionRequests.append(host); lock.unlock()
            #expect(text.contains("&time=1700000000&"))
            return HTTPWire.Response(status: 200, body: Data((host == grantingHost ? "1-key-" + host : "-1-").utf8))
        }
        if text.hasPrefix("POST /speed/dovalid?key=") {
            let key = String(text.dropFirst("POST /speed/dovalid?key=".count).prefix { $0 != " " })
            lock.lock(); releasedKeys.append(key); lock.unlock()
            return HTTPWire.Response(status: 200, body: Data(("1-" + key).utf8))
        }
        return HTTPWire.Response(status: 404, body: Data())
    }

    func stream(host: String, port: UInt16, request: Data, upload filler: Data?, counter: ByteCounter) async throws {
        #expect(host == grantingHost)
        while true {
            counter.add(bytesPerTick)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

@Suite("CAICT engine", .serialized)
struct CAICTEngineTests {
    private let quick = CAICTPlan(latencyProbes: 3, downloadConnections: 4, uploadConnections: 2, downloadSeconds: 0.5,
                                  uploadSeconds: 0.4, warmupSeconds: 0.1, sampleInterval: 0.05, loadedProbeInterval: 0.1,
                                  maxTotalBytes: 10_000_000_000)

    @Test(.timeLimit(.minutes(1))) func choosesFirstGrantingNodeAndReleasesTheKey() async throws {
        let fake = FakeCAICT()
        let stream = AsyncStream<SpeedTestProgress>.makeStream()
        let outcome = try await CAICTSpeedTest(transport: fake, plan: quick).run { update in _ = stream.continuation.yield(update) }
        stream.continuation.finish()
        var phases: [SpeedTestProgress.Phase] = []
        for await update in stream.stream where phases.last != update.phase { phases.append(update.phase) }

        #expect(fake.asked == ["198.51.100.10", "198.51.100.11"])
        #expect(fake.released == ["key-198.51.100.11"])
        #expect(outcome.node.name == "乙电信")
        #expect(outcome.location.city == "示例市")
        #expect((outcome.result.downloadMbps ?? 0) > 1)
        #expect((outcome.result.uploadMbps ?? 0) > 1)
        #expect((outcome.downloadPeakMbps ?? 0) >= (outcome.result.downloadMbps ?? 0))
        #expect(outcome.result.latencyMilliseconds == 10)
        #expect(outcome.result.stoppedByDataCap == false)
        #expect(outcome.result.bytesUsed > 0)
        #expect(phases == [.preparing, .latency, .download, .upload, .finished])
    }

    @Test(.timeLimit(.minutes(1))) func dataCapEndsEarly() async throws {
        var plan = quick
        plan.maxTotalBytes = 200_000
        plan.downloadSeconds = 5
        plan.uploadSeconds = 5
        let fake = FakeCAICT()
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = try await CAICTSpeedTest(transport: fake, plan: plan).run()
        #expect(outcome.result.stoppedByDataCap)
        #expect((clock.now - start).timeInterval < 4)
        #expect(fake.released.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func stopReleasesTheKey() async throws {
        var plan = quick
        plan.downloadSeconds = 30
        let fake = FakeCAICT()
        let task = Task { try await CAICTSpeedTest(transport: fake, plan: plan).run() }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        await #expect(throws: NetworkToolError.cancelled) { try await task.value }
        #expect(fake.released == ["key-198.51.100.11"])
    }

    @Test(.timeLimit(.minutes(1))) func noGrantingNode() async {
        let fake = FakeCAICT(grantingHost: nil)
        await #expect(throws: NetworkToolError.noServer) { try await CAICTSpeedTest(transport: fake, plan: quick).run() }
        // Only the reachable nodes, fastest first, up to `candidates`.
        #expect(fake.asked == ["198.51.100.10", "198.51.100.11", "198.51.100.12"])
        #expect(fake.released.isEmpty)
    }
}
