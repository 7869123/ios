import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where an address is (country, network). Lookups only send the address that is already visible to the service.
public struct IPGeo: Sendable, Equatable {
    public let ip: String
    public let countryCode: String?
    public let country: String?
    public let asn: Int?
    public let organization: String?
}

/// What one service sees as this device's address.
public struct EgressObservation: Sendable, Equatable {
    public enum Source: String, Sendable, CaseIterable {
        case cloudflareDefault, cloudflareIPv4, cloudflareIPv6, ipSB, ipipDomestic
        public var title: String {
            switch self {
            case .cloudflareDefault: "Cloudflare（默认线路）"
            case .cloudflareIPv4: "Cloudflare（IPv4）"
            case .cloudflareIPv6: "Cloudflare（IPv6）"
            case .ipSB: "ip.sb"
            case .ipipDomestic: "IPIP（国内网站视角）"
            }
        }
    }
    public let source: Source
    public let ip: String
    /// Country as the service reports it (code or name), and extra text such as the colo or ISP.
    public let country: String?
    public let detail: String?
}

public enum IPLookupParsing {
    /// `api.ip.sb/geoip[/ip]` JSON.
    public static func ipSB(_ data: Data) -> IPGeo? {
        struct Body: Decodable {
            let ip: String
            let country_code: String?
            let country: String?
            let asn: Int?
            let organization: String?
            let asn_organization: String?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data), IPAddressText.family(body.ip) != nil else { return nil }
        func clean(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return String(s.prefix(80))
        }
        return IPGeo(ip: body.ip, countryCode: clean(body.country_code).map { String($0.prefix(3)) }, country: clean(body.country),
                     asn: body.asn, organization: clean(body.organization) ?? clean(body.asn_organization))
    }

    /// `myip.ipip.net` text, e.g. "当前 IP：203.0.113.5  来自于：中国 上海 上海  电信".
    public static func ipip(_ text: String) -> (ip: String, location: String?)? {
        let normalized = text.replacingOccurrences(of: "：", with: ":")
        guard let range = normalized.range(of: #"IP\s*:\s*([0-9a-fA-F:.]+)"#, options: .regularExpression) else { return nil }
        let ip = normalized[range].split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard IPAddressText.family(ip) != nil else { return nil }
        var location: String?
        if let from = normalized.range(of: "来自于:") {
            let rest = normalized[from.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            location = rest.isEmpty ? nil : String(rest.prefix(80)).replacingOccurrences(of: "  ", with: " ")
        }
        return (ip, location)
    }
}

/// HTTPS lookups of the device's egress address from several services, so split routing and IPv6 paths show.
public struct EgressLookup: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    public let fetch: Fetch
    public init(fetch: @escaping Fetch) { self.fetch = fetch }

    public static let ipSBURL = URL(string: "https://api.ip.sb/geoip")!
    public static let ipipURL = URL(string: "https://myip.ipip.net")!
    public static func geoURL(_ ip: String) -> URL? {
        guard IPAddressText.family(ip) != nil else { return nil }
        return URL(string: "https://api.ip.sb/geoip/" + ip)
    }

    /// Every source independently; a failing source is reported as nil, not as a failure of the whole check.
    public func observe() async -> [EgressObservation.Source: EgressObservation?] {
        await withTaskGroup(of: (EgressObservation.Source, EgressObservation?).self) { group in
            for source in EgressObservation.Source.allCases {
                group.addTask { (source, try? await self.observe(source)) }
            }
            var results: [EgressObservation.Source: EgressObservation?] = [:]
            for await (source, value) in group { results.updateValue(value, forKey: source) }
            return results
        }
    }

    public func observe(_ source: EgressObservation.Source) async throws -> EgressObservation? {
        switch source {
        case .cloudflareDefault, .cloudflareIPv4, .cloudflareIPv6:
            let url = source == .cloudflareIPv4 ? Cloudflare.traceIPv4 : source == .cloudflareIPv6 ? Cloudflare.traceIPv6 : Cloudflare.traceDefault
            guard let trace = CloudflareTrace(String(decoding: try await fetch(url).prefix(4096), as: UTF8.self)) else { return nil }
            return EgressObservation(source: source, ip: trace.ip, country: trace.country,
                                     detail: [trace.colo.map { "节点 \($0)" }, trace.warp == "on" ? "WARP" : nil].compactMap { $0 }.joined(separator: " · "))
        case .ipSB:
            guard let geo = IPLookupParsing.ipSB(try await fetch(Self.ipSBURL)) else { return nil }
            return EgressObservation(source: source, ip: geo.ip, country: geo.countryCode ?? geo.country,
                                     detail: [geo.asn.map { "AS\($0)" }, geo.organization].compactMap { $0 }.joined(separator: " "))
        case .ipipDomestic:
            guard let parsed = IPLookupParsing.ipip(String(decoding: try await fetch(Self.ipipURL).prefix(4096), as: UTF8.self)) else { return nil }
            return EgressObservation(source: source, ip: parsed.ip, country: parsed.location, detail: nil)
        }
    }

    public func geo(_ ip: String) async -> IPGeo? {
        guard let url = Self.geoURL(ip), let data = try? await fetch(url) else { return nil }
        return IPLookupParsing.ipSB(data)
    }

    #if canImport(Darwin)
    /// Plain HTTPS GET without cookies or cache, 64 KB response limit, 10 s timeout.
    public static let urlSessionFetch: Fetch = { url in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10; configuration.urlCache = nil
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("AIUtility network check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NetworkToolError.unexpectedResponse }
        guard (200...299).contains(http.statusCode) else { throw NetworkToolError.httpStatus(http.statusCode) }
        guard data.count <= 65_536 else { throw NetworkToolError.unexpectedResponse }
        return data
    }
    #endif
}
