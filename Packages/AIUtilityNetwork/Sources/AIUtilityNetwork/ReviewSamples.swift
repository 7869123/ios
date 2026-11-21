import Foundation

/// Made-up results for the app's DEBUG review screenshots only (`-AIUtilityPage speed-sample` and similar), so the
/// result layouts can be checked without a network. Documentation addresses (RFC 5737), placeholder names.
public enum NetworkReviewSamples {
    public static let cloudflareResult = SpeedTestResult(
        latencyMilliseconds: 18.4, jitterMilliseconds: 2.1, downloadMbps: 286.4, uploadMbps: 41.7,
        loadedLatencyDownloadMilliseconds: 46, loadedLatencyUploadMilliseconds: 118, bytesUsed: 268_000_000,
        stoppedByDataCap: false, downloadSamples: 24, uploadSamples: 18)

    public static let cloudflareNode = EgressObservation(source: .cloudflareDefault, ip: "203.0.113.10", country: "JP", detail: "节点 NRT")

    public static let caict = CAICTOutcome(
        result: SpeedTestResult(
            latencyMilliseconds: 9.6, jitterMilliseconds: 0.8, downloadMbps: 912.3, uploadMbps: 48.2,
            loadedLatencyDownloadMilliseconds: 21, loadedLatencyUploadMilliseconds: 64, bytesUsed: 300_000_000,
            stoppedByDataCap: true, downloadSamples: 14, uploadSamples: 12),
        node: CAICTNode(id: "80", name: "示例电信", province: "示例省", city: "示例市", host: "198.51.100.10", port: 65499),
        location: CAICTLocation(ip: "198.51.100.20", province: "示例省", city: "示例市", isp: "电信"),
        downloadPeakMbps: 941.9, uploadPeakMbps: 52.3)

    /// VPN on, UDP leaking past it, rule-based split routing: shows a warning, information and OK rows together.
    public static let leak = LeakObservations(
        tunnel: TunnelState(vpnInterfaces: ["utun4"], httpProxy: false),
        egress: [
            .cloudflareDefault: EgressObservation(source: .cloudflareDefault, ip: "203.0.113.10", country: "JP", detail: "节点 NRT"),
            .cloudflareIPv4: EgressObservation(source: .cloudflareIPv4, ip: "203.0.113.10", country: "JP", detail: "节点 NRT"),
            .cloudflareIPv6: nil,
            .ipSB: EgressObservation(source: .ipSB, ip: "203.0.113.10", country: "JP", detail: "AS64500 Example Hosting"),
            .ipipDomestic: EgressObservation(source: .ipipDomestic, ip: "198.51.100.20", country: "示例国 示例省 示例市 示例运营商", detail: nil),
        ],
        stun: ["Cloudflare STUN": STUN.Endpoint(address: "198.51.100.20", port: 54_321), "Google STUN": nil],
        webRTC: [
            ICECandidate("candidate:1 1 udp 1677729535 198.51.100.20 54322 typ srflx raddr 0.0.0.0 rport 0"),
            ICECandidate("candidate:2 1 udp 2122260223 4f1c6d7e-1111-2222-3333-444455556666.local 54323 typ host"),
        ].compactMap { $0 },
        dns: ["whoami.ds.akahelp.net": DNSWhoami.Answer(resolver: "203.0.113.53", clientSubnet: nil),
              "whoami.ipv4.akahelp.net": DNSWhoami.Answer(resolver: "203.0.113.53", clientSubnet: nil),
              "whoami.ipv6.akahelp.net": nil],
        geo: [
            "203.0.113.10": IPGeo(ip: "203.0.113.10", countryCode: "JP", country: "Japan", asn: 64500, organization: "Example Hosting"),
            "198.51.100.20": IPGeo(ip: "198.51.100.20", countryCode: "CN", country: "China", asn: 64501, organization: "Example ISP"),
            "203.0.113.53": IPGeo(ip: "203.0.113.53", countryCode: "JP", country: "Japan", asn: 64500, organization: "Example Hosting"),
        ])
}
