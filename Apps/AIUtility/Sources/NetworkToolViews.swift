import SwiftUI
import WebKit
import AIUtilityNetwork

// Network tools: speed test (Cloudflare, or China Academy of ICT through its unofficial interface) and IP / DNS /
// WebRTC leak check.
// Both only contact third-party services after the user taps start, and both are marked 未实测 until they
// have been run on a device.

extension NetworkToolError {
    var userMessage: String {
        switch self {
        case .network: "网络连接失败。"
        case .timeout: "连接超时。"
        case .cancelled: "已停止。"
        case .unexpectedResponse: "服务返回了无法识别的内容（可能被网络拦截，或接口有变化）。"
        case .httpStatus(let code): "服务返回 HTTP \(code)。"
        case .unsupportedPlatform: "这台设备不支持。"
        case .notConfigured: "还没有接入。"
        case .noServer: "没有可用的测速节点（节点忙、拒绝，或当前网络没有分配到节点）。"
        }
    }
}

/// Shortened addresses for screenshots: "203.0.*.*", "2001:db8:…".
enum AddressMask {
    static func mask(_ ip: String) -> String {
        switch IPAddressText.family(ip) {
        case .v4:
            let parts = ip.split(separator: ".")
            return parts.count == 4 ? "\(parts[0]).\(parts[1]).*.*" : ip
        case .v6:
            let groups = ip.split(separator: ":", omittingEmptySubsequences: false)
            return groups.prefix(2).joined(separator: ":") + ":…"
        case nil:
            return ip
        }
    }

    /// Replaces each known address in a sentence (longest first, so one address is not cut inside another).
    static func mask(_ text: String, addresses: Set<String>) -> String {
        addresses.sorted { $0.count > $1.count }.reduce(text) { $0.replacingOccurrences(of: $1, with: mask($1)) }
    }
}

private func megabits(_ value: Double?) -> String {
    guard let value else { return "—" }
    return value.formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1)))
}

private func milliseconds(_ value: Double?) -> String {
    guard let value else { return "—" }
    return value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)))
}

private struct MetricCell: View {
    let title: String
    let value: String
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(UtilityTheme.ink)
                Text(unit).font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Speed test

enum SpeedProvider: String, CaseIterable, Identifiable {
    case cloudflare, caict
    var id: String { rawValue }
    var title: String { self == .cloudflare ? "Cloudflare" : "信通院" }
}

@MainActor @Observable final class SpeedTestModel {
    /// The CAICT session interface rate-limits; consecutive tests closer than this are refused there.
    static let caictInterval: TimeInterval = 30

    private(set) var running = false
    private(set) var progress: SpeedTestProgress?
    private(set) var result: SpeedTestResult?
    private(set) var provider: SpeedProvider = .cloudflare
    /// Cloudflare's view of this connection: colo (data centre), egress address, country.
    private(set) var node: EgressObservation?
    /// CAICT: the node used and where the control server placed this connection.
    private(set) var caict: CAICTOutcome?
    private(set) var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastCAICTStart: Date?

    func start(_ provider: SpeedProvider, maxBytes: Int64) {
        guard task == nil else { return }
        if provider == .caict, let last = lastCAICTStart, Date().timeIntervalSince(last) < Self.caictInterval {
            let wait = Int((Self.caictInterval - Date().timeIntervalSince(last)).rounded(.up))
            message = "信通院接口限制测速频率，请 \(wait) 秒后再测。"
            return
        }
        running = true; progress = nil; result = nil; node = nil; caict = nil; message = nil
        self.provider = provider
        if provider == .caict { lastCAICTStart = Date() }
        let (stream, continuation) = AsyncStream.makeStream(of: SpeedTestProgress.self, bufferingPolicy: .bufferingNewest(1))
        task = Task {
            let updates = Task { for await update in stream { self.progress = update } }
            switch provider {
            case .cloudflare: await runCloudflare(maxBytes: maxBytes, continuation: continuation)
            case .caict: await runCAICT(maxBytes: maxBytes, continuation: continuation)
            }
            continuation.finish()
            await updates.value
            running = false
            task = nil
        }
    }

    private func runCloudflare(maxBytes: Int64, continuation: AsyncStream<SpeedTestProgress>.Continuation) async {
        let transport = CloudflareSpeedTransport()
        let engine = SpeedTestEngine(transport: transport, plan: SpeedTestPlan(maxTotalBytes: maxBytes))
        node = try? await EgressLookup(fetch: EgressLookup.urlSessionFetch).observe(.cloudflareDefault)
        do {
            result = try await engine.run { update in _ = continuation.yield(update) }
        } catch {
            message = Self.failure(error)
        }
        transport.invalidate()
    }

    private func runCAICT(maxBytes: Int64, continuation: AsyncStream<SpeedTestProgress>.Continuation) async {
        let engine = CAICTSpeedTest(transport: NetworkCAICTTransport(), plan: CAICTPlan(maxTotalBytes: maxBytes))
        do {
            let outcome = try await engine.run { update in _ = continuation.yield(update) }
            caict = outcome
            result = outcome.result
        } catch {
            message = Self.failure(error)
        }
    }

    private static func failure(_ error: NetworkToolError) -> String {
        error == .cancelled ? "已停止，没有结果。" : "测速失败：" + error.userMessage
    }

    func cancel() { task?.cancel() }
}

@MainActor struct SpeedTestView: View {
    /// Data caps offered; the test stops once the next request (Cloudflare) or the running total (CAICT) would cross it.
    struct Cap: Hashable {
        let title: String
        let bytes: Int
    }
    static let caps = [Cap(title: "100 MB", bytes: 100_000_000), Cap(title: "300 MB", bytes: 300_000_000),
                       Cap(title: "1 GB", bytes: 1_000_000_000)]

    @State private var model = SpeedTestModel()
    @State private var provider: SpeedProvider = .cloudflare
    @AppStorage("speedTestDataCap") private var cap = 300_000_000
    @State private var showIP = false

    var body: some View {
        WorkspacePage {
            PageHeader(title: "网络测速", subtitle: "延迟、抖动、下载、上传与负载下的延迟")
            UtilityCard {
                HStack { Text("测速服务").font(.headline); Spacer(); StatusChip(status: .untested) }
                Picker("测速服务", selection: $provider) {
                    ForEach(SpeedProvider.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(model.running)
                HStack {
                    Text("流量上限").font(.subheadline)
                    Spacer()
                    Picker("流量上限", selection: $cap) {
                        ForEach(Self.caps, id: \.self) { Text($0.title).tag($0.bytes) }
                    }
                    .pickerStyle(.menu)
                    .disabled(model.running)
                }
                Text(provider == .cloudflare ? Self.cloudflareNote : Self.caictNote)
                    .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                HStack(spacing: 12) {
                    if model.running {
                        Button { model.cancel() } label: { Label("停止", systemImage: "stop.circle.fill") }
                            .buttonStyle(PrimaryActionStyle())
                        ProgressView()
                    } else {
                        Button { model.start(provider, maxBytes: Int64(cap)) } label: { Label("开始测速", systemImage: "play.circle.fill") }
                            .buttonStyle(PrimaryActionStyle())
                    }
                }
                if model.running, let progress = model.progress { progressRow(progress) }
                if let message = model.message {
                    Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(UtilityTheme.danger)
                }
            }
            if let result = model.result { resultCard(result) }
        }
        // Leaving the page stops the test, so it never keeps using data in the background.
        .onDisappear { model.cancel() }
    }

    private static let cloudflareNote = "连接 speed.cloudflare.com，点「开始测速」后才发起。请求由小到大，下载和上传合计达到上限就不再发起新请求，网速很快时结果可能偏低。用蜂窝网络时会消耗相应流量。"
    private static let caictNote = "连接信通院「全球网测」的控制服务器（dlcv2.cnspeedtest.cn）和它分配的测速节点（节点用明文 HTTP）。这是非官方接口：按开源实现还原，请求以官方安卓客户端的身份和一个每次随机生成的设备号发出，随时可能失效。按时间测：下载 8 条连接约 10 秒、上传 4 条连接约 8 秒，快速网络下用量大，达到上限提前结束；两次测速至少间隔 30 秒。需要中国大陆网络，开着 VPN / 代理时可能找不到节点。上传结果可能偏低（未与官方 App 核对）。"

    private func progressRow(_ progress: SpeedTestProgress) -> some View {
        let phase: String = switch progress.phase {
        case .preparing: "查找测速节点"
        case .latency: "测量空载延迟"
        case .download: "测量下载"
        case .upload: "测量上传"
        case .finished: "完成"
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(phase).font(.subheadline.weight(.semibold)).foregroundStyle(UtilityTheme.brandStrong)
            if let mbps = progress.currentMbps {
                MetricCell(title: "当前估计", value: megabits(mbps), unit: "Mbps")
            }
            Text("已用流量 " + ByteCountFormatter.string(fromByteCount: progress.bytesUsed, countStyle: .file))
                .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
        }
    }

    private static func nodeText(_ node: EgressObservation) -> String {
        let colo = node.detail.flatMap { $0.isEmpty ? nil : $0 } ?? "节点未知"
        let country = node.country.map { " · 地区 " + $0 } ?? ""
        return "Cloudflare " + colo + country
    }

    private static func place(_ parts: [String]) -> String {
        let text = parts.filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? "" : "（" + text + "）"
    }

    private func ip(_ value: String) -> String { showIP ? value : AddressMask.mask(value) }

    private func resultCard(_ result: SpeedTestResult) -> some View {
        UtilityCard {
            HStack { Text("结果 · " + model.provider.title).font(.headline); Spacer(); StatusChip(status: .untested) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], alignment: .leading, spacing: 14) {
                MetricCell(title: "下载", value: megabits(result.downloadMbps), unit: "Mbps")
                MetricCell(title: "上传", value: megabits(result.uploadMbps), unit: "Mbps")
                MetricCell(title: "空载延迟", value: milliseconds(result.latencyMilliseconds), unit: "ms")
                MetricCell(title: "抖动", value: milliseconds(result.jitterMilliseconds), unit: "ms")
                MetricCell(title: "下载时延迟", value: milliseconds(result.loadedLatencyDownloadMilliseconds), unit: "ms")
                MetricCell(title: "上传时延迟", value: milliseconds(result.loadedLatencyUploadMilliseconds), unit: "ms")
            }
            if let node = model.node {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.nodeText(node))
                    Text("出口 IP " + ip(node.ip)).textSelection(.enabled)
                }
                .font(.footnote).foregroundStyle(UtilityTheme.ink)
                Toggle("显示完整 IP", isOn: $showIP).font(.footnote)
            }
            if let caict = model.caict {
                VStack(alignment: .leading, spacing: 4) {
                    Text("信通院节点 " + (caict.node.name.isEmpty ? caict.node.id : caict.node.name)
                         + Self.place([caict.node.province, caict.node.city]))
                    Text("峰值 下载 " + megabits(caict.downloadPeakMbps) + " · 上传 " + megabits(caict.uploadPeakMbps) + " Mbps")
                    Text("出口 " + ip(caict.location.ip) + Self.place([caict.location.province, caict.location.city, caict.location.isp]))
                        .textSelection(.enabled)
                }
                .font(.footnote).foregroundStyle(UtilityTheme.ink)
                Toggle("显示完整 IP", isOn: $showIP).font(.footnote)
            }
            Text(usageText(result)).font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
            Text(model.provider == .cloudflare
                 ? "带宽取各次请求速度的第 90 百分位；延迟取中位数，抖动是相邻两次延迟之差的平均值。负载下的延迟在传输进行时每 0.4 秒测一次。"
                 : "带宽取预热 2 秒之后各 0.5 秒区间的平均值，峰值是最快的一个区间；延迟是到节点的 TCP 握手时间（中位数），负载下的延迟在传输进行时每 0.5 秒测一次。")
                .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
        }
    }

    private func usageText(_ result: SpeedTestResult) -> String {
        let used = "用量 " + ByteCountFormatter.string(fromByteCount: result.bytesUsed, countStyle: .file)
        let counts = model.provider == .cloudflare
            ? " · 下载 \(result.downloadSamples) 次、上传 \(result.uploadSamples) 次计时请求"
            : " · 下载 \(result.downloadSamples) 个、上传 \(result.uploadSamples) 个计时区间"
        let capped = result.stoppedByDataCap ? " · 达到流量上限，测试提前结束" : ""
        return used + counts + capped
    }
}

// MARK: - WebRTC in a web view

/// Gathers the ICE candidates a web page would see, in an off-screen WKWebView with a throw-away data store.
/// No page is loaded from the network: the HTML is inline, and only the two STUN servers are contacted.
@MainActor final class WebRTCProbe: NSObject, WKScriptMessageHandler {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[ICECandidate]?, Never>?

    /// nil: WebRTC is not available in the web view (or it failed before gathering).
    static func gather(timeout: TimeInterval = 8) async -> [ICECandidate]? {
        let probe = WebRTCProbe()
        return await withTaskCancellationHandler {
            await probe.run(timeout: timeout)
        } onCancel: {
            Task { @MainActor in probe.finish(nil) }
        }
    }

    private func run(timeout: TimeInterval) async -> [ICECandidate]? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(self, name: "rtc")
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
            webView = view
            view.loadHTMLString(Self.page, baseURL: URL(string: "https://localhost/"))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(nil)
            }
        }
    }

    fileprivate func finish(_ value: [ICECandidate]?) {
        guard let continuation else { return }
        self.continuation = nil
        // Removing the handler breaks the controller → probe reference; dropping the view ends the page.
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "rtc")
        webView?.stopLoading()
        webView = nil
        continuation.resume(returning: value)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "rtc", let body = message.body as? [String: Any] else { return }
        guard body["ok"] as? Bool == true else { finish(nil); return }
        let lines = (body["candidates"] as? [String] ?? []).prefix(50)
        finish(lines.compactMap { ICECandidate(String($0.prefix(300))) })
    }

    /// Creates a data channel offer so ICE gathering starts, then reports every candidate line once gathering
    /// completes (or after 6 s).
    private static let page = """
    <!doctype html><meta charset="utf-8"><script>
    (async () => {
      const post = m => window.webkit.messageHandlers.rtc.postMessage(m);
      if (!window.RTCPeerConnection) { post({ ok: false }); return; }
      let done = false;
      const found = [];
      let pc;
      const finish = () => {
        if (done) return;
        done = true;
        try { pc.close(); } catch (e) {}
        post({ ok: true, candidates: found });
      };
      try {
        pc = new RTCPeerConnection({ iceServers: [
          { urls: "stun:stun.cloudflare.com:3478" }, { urls: "stun:stun.l.google.com:19302" } ] });
        pc.onicecandidate = e => {
          if (e.candidate && e.candidate.candidate) { found.push(e.candidate.candidate); } else if (!e.candidate) { finish(); }
        };
        pc.createDataChannel("probe");
        await pc.setLocalDescription(await pc.createOffer());
        setTimeout(finish, 6000);
      } catch (e) {
        if (!done) { done = true; post({ ok: false }); }
      }
    })();
    </script>
    """
}

// MARK: - Leak check

@MainActor @Observable final class LeakTestModel {
    private(set) var running = false
    private(set) var observations: LeakObservations?
    private(set) var findings: [LeakFinding] = []
    private(set) var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        running = true; observations = nil; findings = []; message = nil
        task = Task {
            do {
                let result = try await LeakCheckRunner().run(webRTC: { await WebRTCProbe.gather() })
                observations = result
                findings = LeakAnalysis.findings(result)
            } catch {
                message = error == .cancelled ? "已停止。" : "检测失败：" + error.userMessage
            }
            running = false
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    /// Every address that appears in the results, for masking.
    var addresses: Set<String> {
        guard let o = observations else { return [] }
        var all = Set<String>()
        for case let observation? in o.egress.values { all.insert(observation.ip) }
        for case let endpoint? in o.stun.values { all.insert(endpoint.address) }
        for case let answer? in o.dns.values { all.insert(answer.resolver) }
        for candidate in o.webRTC ?? [] where !candidate.isMDNS { all.insert(candidate.address) }
        return all
    }
}

@MainActor struct LeakTestView: View {
    @State private var model = LeakTestModel()
    @State private var showIP = false

    private static let services = "Cloudflare（speed.cloudflare.com、1.1.1.1、STUN）、Google STUN、ip.sb、IPIP（myip.ipip.net）、Akamai DNS 诊断域名（akahelp.net）。查到的公网地址会发给 ip.sb 查询所在地区和网络。"

    var body: some View {
        WorkspacePage {
            PageHeader(title: "泄漏检测", subtitle: "出口 IP、DNS 与 WebRTC 是否绕过 VPN / 代理")
            UtilityCard {
                HStack { Text("检测").font(.headline); Spacer(); StatusChip(status: .untested) }
                Text("建议开着 VPN / 代理检测一次，关掉后再检测一次对比。点「开始检测」后才会联系这些服务：" + Self.services)
                    .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                HStack(spacing: 12) {
                    if model.running {
                        Button { model.cancel() } label: { Label("停止", systemImage: "stop.circle.fill") }
                            .buttonStyle(PrimaryActionStyle())
                        ProgressView()
                    } else {
                        Button { model.start() } label: { Label("开始检测", systemImage: "shield.lefthalf.filled") }
                            .buttonStyle(PrimaryActionStyle())
                    }
                }
                Toggle("显示完整 IP", isOn: $showIP).font(.footnote)
                if let message = model.message {
                    Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(UtilityTheme.danger)
                }
            }
            if !model.findings.isEmpty { findingsCard }
            if let o = model.observations { detailsCard(o) }
        }
        .onDisappear { model.cancel() }
    }

    private func text(_ value: String) -> String {
        showIP ? value : AddressMask.mask(value, addresses: model.addresses)
    }

    private func ip(_ value: String) -> String { showIP ? value : AddressMask.mask(value) }

    private var findingsCard: some View {
        UtilityCard {
            ForEach(model.findings) { finding in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: Self.icon(finding.severity))
                        .foregroundStyle(Self.color(finding.severity))
                        .font(finding.kind == .summary ? .title3 : .body)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(finding.title).font(finding.kind == .summary ? .headline : .subheadline.weight(.semibold))
                            .foregroundStyle(UtilityTheme.ink)
                        Text(text(finding.detail)).font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text("结论只根据这几项观测推断，不能证明没有其他泄漏途径；VPN 识别依据系统网络设置，App 自带的代理或路由器上的代理从这里看不到。")
                .font(.caption2).foregroundStyle(UtilityTheme.inkSecondary)
        }
    }

    private func detailsCard(_ o: LeakObservations) -> some View {
        UtilityCard {
            Text("详细数据").font(.headline)
            group("网页出口（HTTPS）") {
                ForEach(EgressObservation.Source.allCases, id: \.self) { source in
                    row(source.title, value: egressText(o.egress[source] ?? nil))
                }
            }
            group("UDP（STUN，与网页 WebRTC 走同一条路）") {
                ForEach(Self.stunNames, id: \.self) { name in
                    row(name, value: stunText(o.stun[name] ?? nil, o))
                }
            }
            group("网页 WebRTC") {
                if let candidates = o.webRTC {
                    let reflexive = candidates.filter { $0.kind == .srflx && !$0.isMDNS }
                    let hidden = candidates.filter(\.isMDNS).count
                    let lan = candidates.filter { $0.kind == .host && !$0.isMDNS }.count
                    row("公网地址", value: addressList(reflexive.map(\.address), o))
                    row("本机地址", value: "用 mDNS 隐藏 \(hidden) 个，直接列出 \(lan) 个")
                } else {
                    row("状态", value: "网页组件没有给出结果（不支持或被禁用）")
                }
            }
            group("DNS 解析器") {
                ForEach(DNSWhoami.names, id: \.self) { name in
                    row(name, value: dnsText(o.dns[name] ?? nil, o))
                }
            }
            group("本机") {
                row("VPN 接口", value: o.tunnel.vpnInterfaces.isEmpty ? "未检测到" : o.tunnel.vpnInterfaces.joined(separator: "、"))
                row("系统 HTTP 代理", value: o.tunnel.httpProxy ? "已开启" : "未开启")
            }
        }
    }

    private static let stunNames: [String] = STUN.servers.map { $0.name }

    private func egressText(_ observation: EgressObservation?) -> String {
        guard let observation else { return "未取到" }
        var text = ip(observation.ip)
        for extra in [observation.country, observation.detail] {
            if let extra, !extra.isEmpty { text += " · " + extra }
        }
        return text
    }

    private func stunText(_ endpoint: STUN.Endpoint?, _ o: LeakObservations) -> String {
        guard let endpoint else { return "无回应" }
        return ip(endpoint.address) + geo(endpoint.address, o)
    }

    private func addressList(_ addresses: [String], _ o: LeakObservations) -> String {
        let unique = Set(addresses).sorted()
        guard !unique.isEmpty else { return "没有" }
        return unique.map { ip($0) + geo($0, o) }.joined(separator: "、")
    }

    private func dnsText(_ answer: DNSWhoami.Answer?, _ o: LeakObservations) -> String {
        guard let answer else { return "无回应" }
        var text = ip(answer.resolver) + geo(answer.resolver, o)
        if let subnet = answer.clientSubnet { text += showIP ? " · ECS " + subnet : " · 转发了客户端网段" }
        return text
    }

    private func geo(_ address: String, _ o: LeakObservations) -> String {
        guard let g = o.geo[address] else { return "" }
        let parts = [g.countryCode ?? g.country, g.asn.map { "AS\($0)" }, g.organization].compactMap { $0 }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " ")
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(UtilityTheme.brandStrong)
            content()
        }
    }

    private func row(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
            Text(value).font(.footnote).foregroundStyle(UtilityTheme.ink).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private static func icon(_ severity: LeakFinding.Severity) -> String {
        switch severity {
        case .ok: "checkmark.seal.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private static func color(_ severity: LeakFinding.Severity) -> Color {
        switch severity {
        case .ok: UtilityTheme.brandStrong
        case .info: UtilityTheme.poc
        case .warning: UtilityTheme.danger
        }
    }
}
