import Foundation
import Testing
@testable import AIUtilityNetwork

/// Documentation addresses only (RFC 5737 / RFC 3849), private-use AS numbers.
private let homeIP = "198.51.100.20"
private let exitIP = "203.0.113.10"
private let geo: [String: IPGeo] = [
    homeIP: IPGeo(ip: homeIP, countryCode: "AA", country: "Home", asn: 64501, organization: "Home ISP"),
    exitIP: IPGeo(ip: exitIP, countryCode: "BB", country: "Exit", asn: 64500, organization: "Exit Hosting"),
    "198.51.100.53": IPGeo(ip: "198.51.100.53", countryCode: "AA", country: "Home", asn: 64501, organization: "Home ISP"),
    "203.0.113.53": IPGeo(ip: "203.0.113.53", countryCode: "BB", country: "Exit", asn: 64500, organization: "Exit Hosting"),
    "2001:db8::10": IPGeo(ip: "2001:db8::10", countryCode: "AA", country: "Home", asn: 64501, organization: "Home ISP"),
]
private let vpn = TunnelState.classify(scopedInterfaces: ["utun4", "en0"], httpProxyEnabled: false)
private let direct = TunnelState.classify(scopedInterfaces: ["en0"], httpProxyEnabled: false)

private func egress(_ ip: String, v6: String? = nil, domestic: String? = nil) -> [EgressObservation.Source: EgressObservation?] {
    var result: [EgressObservation.Source: EgressObservation?] = [
        .cloudflareDefault: EgressObservation(source: .cloudflareDefault, ip: ip, country: geo[ip]?.countryCode, detail: nil),
        .cloudflareIPv4: EgressObservation(source: .cloudflareIPv4, ip: ip, country: geo[ip]?.countryCode, detail: nil),
        .ipSB: EgressObservation(source: .ipSB, ip: ip, country: geo[ip]?.countryCode, detail: nil),
    ]
    result.updateValue(v6.map { EgressObservation(source: .cloudflareIPv6, ip: $0, country: nil, detail: nil) }, forKey: .cloudflareIPv6)
    result.updateValue(domestic.map { EgressObservation(source: .ipipDomestic, ip: $0, country: "示例地区", detail: nil) }, forKey: .ipipDomestic)
    return result
}

private func severities(_ findings: [LeakFinding], _ kind: LeakFinding.Kind) -> [LeakFinding.Severity] {
    findings.filter { $0.kind == kind }.map(\.severity)
}

@Suite("Leak analysis")
struct LeakAnalysisTests {
    @Test func consistentDirectConnectionHasNoWarning() {
        let o = LeakObservations(tunnel: direct, egress: egress(homeIP), stun: ["Cloudflare STUN": STUN.Endpoint(address: homeIP, port: 5000)],
                                 webRTC: [], dns: ["whoami.ds.akahelp.net": DNSWhoami.Answer(resolver: "198.51.100.53", clientSubnet: nil)],
                                 geo: geo)
        let findings = LeakAnalysis.findings(o)
        #expect(findings.first?.kind == .summary)
        #expect(findings.first?.title.contains("未开 VPN") == true)
        #expect(findings.allSatisfy { $0.severity != .warning })
        #expect(severities(findings, .webRTC) == [.ok])
        #expect(severities(findings, .dns) == [.ok])
    }

    @Test func udpBypassingTheVPNIsAWarning() {
        let o = LeakObservations(tunnel: vpn, egress: egress(exitIP), stun: ["Cloudflare STUN": STUN.Endpoint(address: homeIP, port: 5000)],
                                 dns: ["whoami.ds.akahelp.net": DNSWhoami.Answer(resolver: "203.0.113.53", clientSubnet: nil)], geo: geo)
        let findings = LeakAnalysis.findings(o)
        #expect(findings.first?.severity == .warning)
        #expect(severities(findings, .webRTC) == [.warning])
        #expect(findings.first { $0.kind == .webRTC }?.detail.contains(homeIP + "（AA AS64501 Home ISP）") == true)
        #expect(severities(findings, .dns) == [.ok])
    }

    @Test func sameUDPDifferenceWithoutVPNIsOnlyInformation() {
        let o = LeakObservations(tunnel: direct, egress: egress(exitIP), stun: ["Cloudflare STUN": STUN.Endpoint(address: homeIP, port: 5000)],
                                 geo: geo)
        let findings = LeakAnalysis.findings(o)
        #expect(severities(findings, .webRTC) == [.info])
        #expect(findings.first?.severity == .ok)
    }

    @Test func webRTCReflexiveCandidateCounts() {
        let candidate = ICECandidate("candidate:1 1 udp 1677729535 \(homeIP) 50000 typ srflx raddr 0.0.0.0 rport 0")
        let lan = ICECandidate("candidate:2 1 udp 2122260223 192.168.1.20 50001 typ host")
        let o = LeakObservations(tunnel: vpn, egress: egress(exitIP), webRTC: [candidate, lan].compactMap { $0 }, geo: geo)
        let findings = LeakAnalysis.findings(o)
        #expect(severities(findings, .webRTC) == [.warning, .info])
    }

    @Test func otherFamilyIsNotComparedAcrossFamilies() {
        // HTTPS only over IPv4; a v6 STUN answer cannot be compared with it.
        let o = LeakObservations(tunnel: vpn, egress: egress(exitIP), stun: ["Google STUN": STUN.Endpoint(address: "2001:db8::10", port: 5000)],
                                 geo: geo)
        #expect(severities(LeakAnalysis.findings(o), .webRTC) == [.ok])
    }

    @Test func resolverOutsideTheExitCountryIsADNSWarning() {
        let o = LeakObservations(tunnel: vpn, egress: egress(exitIP),
                                 dns: ["whoami.ds.akahelp.net": DNSWhoami.Answer(resolver: "198.51.100.53", clientSubnet: nil),
                                       "whoami.ipv6.akahelp.net": nil],
                                 geo: geo)
        let findings = LeakAnalysis.findings(o)
        #expect(severities(findings, .dns) == [.warning])
        #expect(findings.first?.title == "发现可能的泄漏")
    }

    @Test func noDNSAnswerIsReported() {
        let o = LeakObservations(tunnel: direct, egress: egress(homeIP), dns: ["whoami.ds.akahelp.net": nil], geo: geo)
        #expect(LeakAnalysis.findings(o).first { $0.kind == .dns }?.title == "没有取到 DNS 解析器")
    }

    @Test func ipv6OnAnotherNetworkUnderVPN() {
        let o = LeakObservations(tunnel: vpn, egress: egress(exitIP, v6: "2001:db8::10"), geo: geo)
        #expect(severities(LeakAnalysis.findings(o), .ipv6) == [.warning])
        let withoutVPN = LeakObservations(tunnel: direct, egress: egress(exitIP, v6: "2001:db8::10"), geo: geo)
        #expect(severities(LeakAnalysis.findings(withoutVPN), .ipv6).isEmpty)
    }

    @Test func splitRoutingIsInformationOnly() {
        let o = LeakObservations(tunnel: vpn, egress: egress(exitIP, domestic: homeIP),
                                 stun: ["Cloudflare STUN": STUN.Endpoint(address: exitIP, port: 5000)], geo: geo)
        let findings = LeakAnalysis.findings(o)
        #expect(severities(findings, .splitRouting) == [.info])
        #expect(findings.first?.title == "开着 VPN / 代理，未发现泄漏")
        #expect(findings.first?.detail.contains("utun4") == true)
    }

    @Test func nothingReachableStillGivesASummary() {
        let findings = LeakAnalysis.findings(LeakObservations(tunnel: direct))
        #expect(findings.first?.kind == .summary)
        #expect(findings.allSatisfy { $0.severity != .warning })
    }
}

@Suite("Review samples")
struct ReviewSampleTests {
    @Test func leakSampleShowsEverySeverity() {
        let findings = LeakAnalysis.findings(NetworkReviewSamples.leak)
        #expect(findings.first?.severity == .warning)
        #expect(Set(findings.map(\.severity)) == [.ok, .info, .warning])
        #expect(NetworkReviewSamples.leak.webRTC?.count == 2)
    }
}
