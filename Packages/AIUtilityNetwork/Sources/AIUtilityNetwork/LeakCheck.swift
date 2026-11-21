import Foundation

/// ICE candidates gathered by a WebRTC peer connection (in a web view), as browsers expose them.
public struct ICECandidate: Sendable, Equatable {
    public enum Kind: String, Sendable { case host, srflx, prflx, relay }
    public let address: String
    public let port: Int
    public let kind: Kind
    public let isMDNS: Bool

    /// "candidate:842163049 1 udp 1677729535 203.0.113.5 50000 typ srflx raddr 0.0.0.0 rport 0 ..."
    public init?(_ line: String) {
        let text = line.hasPrefix("a=") ? String(line.dropFirst(2)) : line
        let fields = text.split(separator: " ").map(String.init)
        guard fields.count >= 8, fields[0].lowercased().hasPrefix("candidate:"),
              let typIndex = fields.firstIndex(of: "typ"), typIndex + 1 < fields.count,
              let kind = Kind(rawValue: fields[typIndex + 1].lowercased()), let port = Int(fields[5]) else { return nil }
        let address = fields[4]
        isMDNS = address.lowercased().hasSuffix(".local")
        guard isMDNS || IPAddressText.family(address) != nil, address.count <= 64 else { return nil }
        self.address = address; self.port = port; self.kind = kind
    }
}

/// Whether traffic is meant to go through a VPN or a proxy, from the system proxy settings.
public struct TunnelState: Sendable, Equatable {
    public let vpnInterfaces: [String]
    public let httpProxy: Bool
    public var vpnActive: Bool { !vpnInterfaces.isEmpty }

    /// `__SCOPED__` keys name the interfaces with their own settings; utun/ipsec/ppp/tap/tun are tunnels.
    public static func classify(scopedInterfaces: [String], httpProxyEnabled: Bool) -> TunnelState {
        let tunnels = scopedInterfaces.filter { name in
            ["utun", "ipsec", "ppp", "tap", "tun"].contains { name.lowercased().hasPrefix($0) }
        }.sorted()
        return TunnelState(vpnInterfaces: tunnels, httpProxy: httpProxyEnabled)
    }

    public init(vpnInterfaces: [String], httpProxy: Bool) {
        self.vpnInterfaces = vpnInterfaces; self.httpProxy = httpProxy
    }

    #if canImport(Darwin)
    public static func current() -> TunnelState {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return TunnelState(vpnInterfaces: [], httpProxy: false)
        }
        let scoped = (settings["__SCOPED__"] as? [String: Any]).map { Array($0.keys) } ?? []
        let proxy = (settings["HTTPEnable"] as? Int == 1) || (settings["HTTPSEnable"] as? Int == 1)
            || (settings["ProxyAutoConfigEnable"] as? Int == 1)
        return classify(scopedInterfaces: scoped, httpProxyEnabled: proxy)
    }
    #endif
}

/// Everything one leak check observed; addresses only, no page content.
public struct LeakObservations: Sendable, Equatable {
    public var tunnel: TunnelState
    /// HTTPS egress per source (nil: that source failed).
    public var egress: [EgressObservation.Source: EgressObservation?]
    /// Native UDP STUN results per server name (nil: no answer).
    public var stun: [String: STUN.Endpoint?]
    /// Server-reflexive / host candidates from the web view's WebRTC (nil: WebRTC unavailable or blocked).
    public var webRTC: [ICECandidate]?
    /// DNS resolver per query name (nil: no answer).
    public var dns: [String: DNSWhoami.Answer?]
    /// Geo of every address involved, by address.
    public var geo: [String: IPGeo]

    public init(tunnel: TunnelState, egress: [EgressObservation.Source: EgressObservation?] = [:], stun: [String: STUN.Endpoint?] = [:],
                webRTC: [ICECandidate]? = nil, dns: [String: DNSWhoami.Answer?] = [:], geo: [String: IPGeo] = [:]) {
        self.tunnel = tunnel; self.egress = egress; self.stun = stun; self.webRTC = webRTC; self.dns = dns; self.geo = geo
    }
}

public struct LeakFinding: Sendable, Equatable, Identifiable {
    public enum Severity: Int, Sendable, Comparable {
        case ok, info, warning
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public enum Kind: String, Sendable { case webRTC, dns, ipv6, splitRouting, summary }
    public let kind: Kind
    public let severity: Severity
    public let title: String
    public let detail: String
    public var id: String { kind.rawValue + title }
}

/// Plain rules over the observations. A difference only counts as a leak while a VPN or proxy is on: without
/// one, every path is expected to show the same real address.
public enum LeakAnalysis {
    public static func findings(_ o: LeakObservations) -> [LeakFinding] {
        let tunnelOn = o.tunnel.vpnActive || o.tunnel.httpProxy
        let https: [EgressObservation] = o.egress.values.compactMap { $0 }.filter { $0.source != .ipipDomestic }
        var out: [LeakFinding] = []
        out += webRTCFindings(o, https: https, tunnelOn: tunnelOn)
        out += dnsFindings(o, https: https, tunnelOn: tunnelOn)
        out += ipv6Findings(o, tunnelOn: tunnelOn)
        out += splitRoutingFindings(o, https: https)

        let worst = out.map(\.severity).max() ?? .ok
        let title: String
        if worst == .warning {
            title = "发现可能的泄漏"
        } else if tunnelOn {
            title = "开着 VPN / 代理，未发现泄漏"
        } else {
            title = "未开 VPN / 代理，以下是当前网络的出口信息"
        }
        let detail: String
        if o.tunnel.vpnActive {
            detail = "检测到 VPN 接口：" + o.tunnel.vpnInterfaces.joined(separator: "、")
        } else if o.tunnel.httpProxy {
            detail = "检测到系统 HTTP 代理。"
        } else {
            detail = "未检测到 VPN 或系统代理（路由器上的代理从手机上看不到）。"
        }
        out.insert(LeakFinding(kind: .summary, severity: worst == .warning ? .warning : .ok, title: title, detail: detail), at: 0)
        return out
    }

    /// "203.0.113.5（JP AS64500 Example）" when the geo lookup returned something.
    static func describe(_ ip: String, _ o: LeakObservations) -> String {
        guard let g = o.geo[ip] else { return ip }
        var parts: [String] = []
        if let country = g.countryCode ?? g.country { parts.append(country) }
        if let asn = g.asn { parts.append("AS\(asn)") }
        if let organization = g.organization { parts.append(organization) }
        return parts.isEmpty ? ip : ip + "（" + parts.joined(separator: " ") + "）"
    }

    static func describe(_ ips: [String], _ o: LeakObservations) -> String {
        ips.isEmpty ? "未取到" : ips.map { describe($0, o) }.joined(separator: "、")
    }

    private static func webRTCFindings(_ o: LeakObservations, https: [EgressObservation], tunnelOn: Bool) -> [LeakFinding] {
        var out: [LeakFinding] = []
        let httpsIPs = Set(https.map(\.ip))
        let stunIPs: [String] = o.stun.values.compactMap { $0?.address }
        let candidates: [ICECandidate] = o.webRTC ?? []
        let reflexive: [String] = candidates.filter { $0.kind == .srflx && !$0.isMDNS }.map(\.address)
        let udp = Set(stunIPs + reflexive).filter { IPAddressText.isPublic($0) }
        // Compared within one family: a v6 STUN answer is not a leak just because HTTPS went over v4.
        let httpsFamilies = Set(httpsIPs.compactMap { IPAddressText.family($0) })
        let unexpected = udp.filter { ip in
            guard let family = IPAddressText.family(ip), httpsFamilies.contains(family) else { return false }
            return !httpsIPs.contains(ip)
        }.sorted()

        if !unexpected.isEmpty {
            let seen = "通过 UDP（STUN / WebRTC）看到的地址：" + describe(unexpected, o)
            let web = "，网页（HTTPS）看到的是：" + describe(httpsIPs.sorted(), o)
            let meaning = tunnelOn
                ? "。开着 VPN / 代理时，说明 UDP 流量没有走代理，网页里的 WebRTC 会暴露这个地址。"
                : "。没有开 VPN / 代理时，通常是运营商对 UDP 用了不同的出口，不算泄漏。"
            out.append(LeakFinding(kind: .webRTC, severity: tunnelOn ? .warning : .info,
                                   title: tunnelOn ? "WebRTC / UDP 可能泄漏真实 IP" : "UDP 出口与网页出口不同",
                                   detail: seen + web + meaning))
        } else if !udp.isEmpty {
            out.append(LeakFinding(kind: .webRTC, severity: .ok, title: "WebRTC / UDP 未发现泄漏",
                                   detail: "UDP 看到的地址与网页出口一致：" + describe(udp.sorted(), o) + "。"))
        } else {
            out.append(LeakFinding(kind: .webRTC, severity: .ok, title: "WebRTC / UDP 没有取到公网地址",
                                   detail: "STUN 没有回应，网页里的 WebRTC 也没有给出公网地址（UDP 被拦截时也是这样），不会通过这条路暴露地址。"))
        }
        let exposesLAN = candidates.contains { $0.kind == .host && !$0.isMDNS && !IPAddressText.isPublic($0.address) }
        if exposesLAN {
            out.append(LeakFinding(kind: .webRTC, severity: .info, title: "WebRTC 列出了局域网地址",
                                   detail: "网页里的 WebRTC 给出了本机局域网地址（没有用 mDNS 名称隐藏）。"))
        }
        return out
    }

    private static func dnsFindings(_ o: LeakObservations, https: [EgressObservation], tunnelOn: Bool) -> [LeakFinding] {
        let resolvers: [String] = Set(o.dns.values.compactMap { $0?.resolver }).sorted()
        guard !resolvers.isEmpty else {
            return [LeakFinding(kind: .dns, severity: .info, title: "没有取到 DNS 解析器",
                                detail: "检测用的域名没有解析成功，可能是网络拦截了这个查询。")]
        }
        var exitCountries = Set<String>()
        for observation in https {
            if let code = o.geo[observation.ip]?.countryCode ?? observation.country { exitCountries.insert(code.uppercased()) }
        }
        var resolverCountries = Set<String>()
        for resolver in resolvers {
            if let code = o.geo[resolver]?.countryCode { resolverCountries.insert(code.uppercased()) }
        }
        let elsewhere = resolverCountries.subtracting(exitCountries).sorted()
        if tunnelOn, !exitCountries.isEmpty, !elsewhere.isEmpty {
            let detail = "DNS 解析器在 " + elsewhere.joined(separator: "、") + "，网页出口在 "
                + exitCountries.sorted().joined(separator: "、") + "。解析器：" + describe(resolvers, o)
                + "。域名查询可能没有走 VPN / 代理，本地网络可能看到你访问了哪些网站。"
            return [LeakFinding(kind: .dns, severity: .warning, title: "DNS 可能泄漏", detail: detail)]
        }
        let suffix = tunnelOn && !resolverCountries.isEmpty ? "，与网页出口在同一地区。" : "。"
        return [LeakFinding(kind: .dns, severity: .ok, title: "DNS 解析器", detail: describe(resolvers, o) + suffix)]
    }

    private static func ipv6Findings(_ o: LeakObservations, tunnelOn: Bool) -> [LeakFinding] {
        guard tunnelOn, let v6 = o.egress[.cloudflareIPv6] ?? nil, IPAddressText.family(v6.ip) == .v6 else { return [] }
        let v4Observation = (o.egress[.cloudflareIPv4] ?? nil) ?? (o.egress[.cloudflareDefault] ?? nil)
        guard let v4 = v4Observation, IPAddressText.family(v4.ip) == .v4,
              let asn6 = o.geo[v6.ip]?.asn, let asn4 = o.geo[v4.ip]?.asn, asn6 != asn4 else { return [] }
        let detail = "IPv6 出口 " + describe(v6.ip, o) + " 与 IPv4 出口 " + describe(v4.ip, o)
            + " 属于不同网络，IPv6 流量可能没有经过 VPN / 代理。"
        return [LeakFinding(kind: .ipv6, severity: .warning, title: "IPv6 可能绕过 VPN / 代理", detail: detail)]
    }

    private static func splitRoutingFindings(_ o: LeakObservations, https: [EgressObservation]) -> [LeakFinding] {
        guard let domestic = o.egress[.ipipDomestic] ?? nil, let foreign = https.map(\.ip).sorted().first,
              !https.contains(where: { $0.ip == domestic.ip }) else { return [] }
        let place = domestic.country.map { "（" + $0 + "）" } ?? ""
        let detail = "国内网站看到 " + domestic.ip + place + "，国外网站看到 " + foreign + "。使用分流规则的代理通常如此，不算泄漏。"
        return [LeakFinding(kind: .splitRouting, severity: .info, title: "国内外出口不同（分流）", detail: detail)]
    }
}

#if canImport(Network) && canImport(dnssd)
/// Runs every probe once. WebRTC candidates come from the caller (a web view in the app).
public struct LeakCheckRunner: Sendable {
    public let egress: EgressLookup
    public init(egress: EgressLookup = EgressLookup(fetch: EgressLookup.urlSessionFetch)) { self.egress = egress }

    public func run(webRTC: @escaping @Sendable () async -> [ICECandidate]?) async throws(NetworkToolError) -> LeakObservations {
        var observations = LeakObservations(tunnel: TunnelState.current())
        async let egressResults = egress.observe()
        async let stunResults = Self.stunAll()
        async let dnsResults = Self.dnsAll()
        async let candidates = webRTC()
        observations.egress = await egressResults
        observations.stun = await stunResults
        observations.dns = await dnsResults
        observations.webRTC = await candidates
        if Task.isCancelled { throw .cancelled }

        var addresses = Set<String>()
        for case let observation? in observations.egress.values where observation.source != .ipipDomestic { addresses.insert(observation.ip) }
        for case let endpoint? in observations.stun.values { addresses.insert(endpoint.address) }
        for case let answer? in observations.dns.values { addresses.insert(answer.resolver) }
        for candidate in observations.webRTC ?? [] where candidate.kind == .srflx && !candidate.isMDNS { addresses.insert(candidate.address) }
        let lookup = egress
        let publicAddresses = addresses.filter { IPAddressText.isPublic($0) }.sorted().prefix(12)
        observations.geo = await withTaskGroup(of: IPGeo?.self, returning: [String: IPGeo].self) { group in
            for ip in publicAddresses { group.addTask { await lookup.geo(ip) } }
            var geo: [String: IPGeo] = [:]
            for await value in group { if let value { geo[value.ip] = value } }
            return geo
        }
        if Task.isCancelled { throw .cancelled }
        return observations
    }

    private static func stunAll() async -> [String: STUN.Endpoint?] {
        await withTaskGroup(of: (String, STUN.Endpoint?).self, returning: [String: STUN.Endpoint?].self) { group in
            for server in STUN.servers {
                group.addTask { (server.name, (try? await STUNClient.query(host: server.host, port: server.port)) ?? nil) }
            }
            var results: [String: STUN.Endpoint?] = [:]
            for await (name, endpoint) in group { results.updateValue(endpoint, forKey: name) }
            return results
        }
    }

    private static func dnsAll() async -> [String: DNSWhoami.Answer?] {
        await withTaskGroup(of: (String, DNSWhoami.Answer?).self, returning: [String: DNSWhoami.Answer?].self) { group in
            for name in DNSWhoami.names {
                group.addTask { (name, (try? await DNSWhoami.query(name)) ?? nil) }
            }
            var results: [String: DNSWhoami.Answer?] = [:]
            for await (name, answer) in group { results.updateValue(answer, forKey: name) }
            return results
        }
    }
}
#endif
