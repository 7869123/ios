import Foundation
import Testing
@testable import AIUtilityNetwork

@Suite("Address text")
struct AddressTextTests {
    @Test func families() {
        #expect(IPAddressText.family("203.0.113.1") == .v4)
        #expect(IPAddressText.family("2001:db8::1") == .v6)
        #expect(IPAddressText.family("fe80::1%en0") == .v6)
        #expect(IPAddressText.family("256.1.1.1") == nil)
        #expect(IPAddressText.family("1.2.3") == nil)
        #expect(IPAddressText.family("example.com") == nil)
        #expect(IPAddressText.family("abcd.local") == nil)
        #expect(IPAddressText.family("1::2::3") == nil)
    }

    @Test func publicRanges() {
        for address in ["10.0.0.1", "127.0.0.1", "100.64.0.1", "169.254.1.1", "172.16.0.1", "192.168.1.1", "0.0.0.0",
                        "224.0.0.1", "::1", "fe80::1", "fd00::1", "::ffff:192.0.2.1", "example.com"] {
            #expect(!IPAddressText.isPublic(address), "\(address)")
        }
        for address in ["203.0.113.1", "198.51.100.20", "172.32.0.1", "2001:db8::1"] {
            #expect(IPAddressText.isPublic(address), "\(address)")
        }
    }
}

@Suite("Cloudflare formats")
struct CloudflareFormatTests {
    @Test func trace() throws {
        let text = "fl=1f1\nh=speed.cloudflare.com\nip=203.0.113.7\nts=1700000000.1\nvisit_scheme=https\nuag=test\n"
            + "colo=NRT\nsliver=none\nhttp=http/2\nloc=JP\ntls=TLSv1.3\nsni=plaintext\nwarp=off\ngateway=off\n"
        let trace = try #require(CloudflareTrace(text))
        #expect(trace.ip == "203.0.113.7")
        #expect(trace.colo == "NRT")
        #expect(trace.country == "JP")
        #expect(trace.httpVersion == "http/2")
        #expect(trace.warp == "off")
    }

    @Test func traceRejectsMissingOrOddValues() {
        #expect(CloudflareTrace("colo=NRT\nloc=JP\n") == nil)
        #expect(CloudflareTrace("ip=<b>x</b>\n") == nil)
        let odd = CloudflareTrace("ip=2001:db8::7\ncolo=<script>\nloc=\n")
        #expect(odd?.ip == "2001:db8::7")
        #expect(odd?.colo == nil)
        #expect(odd?.country == nil)
    }

    @Test func serverTiming() {
        #expect(Cloudflare.serverSeconds(fromServerTiming: "cfRequestDuration;dur=12.5") == 0.0125)
        #expect(Cloudflare.serverSeconds(fromServerTiming: "cfL4;desc=\"?proto=TCP\", cfRequestDuration;dur=3") == 0.003)
        #expect(Cloudflare.serverSeconds(fromServerTiming: "cfL4;desc=x") == nil)
        #expect(Cloudflare.serverSeconds(fromServerTiming: "cfRequestDuration;dur=-1") == nil)
        #expect(Cloudflare.serverSeconds(fromServerTiming: nil) == nil)
    }

    @Test func urls() {
        #expect(Cloudflare.downloadURL(bytes: 1_000).absoluteString == "https://speed.cloudflare.com/__down?bytes=1000")
        #expect(Cloudflare.downloadURL(bytes: -5).absoluteString == "https://speed.cloudflare.com/__down?bytes=0")
        #expect(Cloudflare.traceIPv6.host?.contains("2606:4700:4700::1111") == true)
    }
}

@Suite("STUN")
struct STUNTests {
    private let transaction: [UInt8] = [0xb7, 0xe7, 0xa7, 0x01, 0xbc, 0x34, 0xd6, 0x86, 0xfa, 0x87, 0xdf, 0xae]

    @Test func bindingRequestHeader() {
        let request = [UInt8](STUN.bindingRequest(transactionID: transaction))
        #expect(request.count == 20)
        #expect(Array(request[0..<8]) == [0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xa4, 0x42])
        #expect(Array(request[8...]) == transaction)
        #expect(STUN.randomTransactionID().count == 12)
    }

    /// RFC 5769 section 2.2, sample IPv4 response.
    @Test func rfc5769IPv4() throws {
        let response: [UInt8] = [
            0x01, 0x01, 0x00, 0x3c, 0x21, 0x12, 0xa4, 0x42, 0xb7, 0xe7, 0xa7, 0x01, 0xbc, 0x34, 0xd6, 0x86, 0xfa, 0x87, 0xdf, 0xae,
            0x80, 0x22, 0x00, 0x0b, 0x74, 0x65, 0x73, 0x74, 0x20, 0x76, 0x65, 0x63, 0x74, 0x6f, 0x72, 0x20,
            0x00, 0x20, 0x00, 0x08, 0x00, 0x01, 0xa1, 0x47, 0xe1, 0x12, 0xa6, 0x43,
            0x00, 0x08, 0x00, 0x14, 0x2b, 0x91, 0xf5, 0x99, 0xfd, 0x9e, 0x90, 0xc3, 0x8c, 0x74, 0x89, 0xf9,
            0x2a, 0xf9, 0xba, 0x53, 0xf0, 0x6b, 0xe7, 0xd7,
            0x80, 0x28, 0x00, 0x04, 0xc0, 0x7d, 0x4c, 0x96,
        ]
        let endpoint = try #require(STUN.mappedAddress(in: Data(response), transactionID: transaction))
        #expect(endpoint == STUN.Endpoint(address: "192.0.2.1", port: 32853))
        var otherTransaction = transaction
        otherTransaction[0] ^= 0xff
        #expect(STUN.mappedAddress(in: Data(response), transactionID: otherTransaction) == nil)
        #expect(STUN.mappedAddress(in: Data(response.prefix(30)), transactionID: transaction) == nil)
    }

    /// RFC 5769 section 2.3, sample IPv6 response.
    @Test func rfc5769IPv6() throws {
        let response: [UInt8] = [
            0x01, 0x01, 0x00, 0x48, 0x21, 0x12, 0xa4, 0x42, 0xb7, 0xe7, 0xa7, 0x01, 0xbc, 0x34, 0xd6, 0x86, 0xfa, 0x87, 0xdf, 0xae,
            0x80, 0x22, 0x00, 0x0b, 0x74, 0x65, 0x73, 0x74, 0x20, 0x76, 0x65, 0x63, 0x74, 0x6f, 0x72, 0x20,
            0x00, 0x20, 0x00, 0x14, 0x00, 0x02, 0xa1, 0x47, 0x01, 0x13, 0xa9, 0xfa, 0xa5, 0xd3, 0xf1, 0x79,
            0xbc, 0x25, 0xf4, 0xb5, 0xbe, 0xd2, 0xb9, 0xd9,
            0x00, 0x08, 0x00, 0x14, 0xa3, 0x82, 0x95, 0x4e, 0x4b, 0xe6, 0x7b, 0xf1, 0x17, 0x84, 0xc9, 0x7c,
            0x82, 0x92, 0xc2, 0x75, 0xbf, 0xe3, 0xed, 0x41,
            0x80, 0x28, 0x00, 0x04, 0xc8, 0xfb, 0x0b, 0x4c,
        ]
        let endpoint = try #require(STUN.mappedAddress(in: Data(response), transactionID: transaction))
        #expect(endpoint == STUN.Endpoint(address: "2001:db8:1234:5678:11:2233:4455:6677", port: 32853))
    }

    @Test func plainMappedAddressFallback() throws {
        var response: [UInt8] = [0x01, 0x01, 0x00, 0x0c, 0x21, 0x12, 0xa4, 0x42] + transaction
        response += [0x00, 0x01, 0x00, 0x08, 0x00, 0x01, 0x1f, 0x90, 198, 51, 100, 20]
        let endpoint = try #require(STUN.mappedAddress(in: Data(response), transactionID: transaction))
        #expect(endpoint == STUN.Endpoint(address: "198.51.100.20", port: 8080))
        // An error response (0x0111) is not a mapped address.
        response[1] = 0x11
        #expect(STUN.mappedAddress(in: Data(response), transactionID: transaction) == nil)
    }

    @Test func ipv6Text() {
        #expect(STUN.compressed(["2001", "db8", "0", "0", "0", "0", "0", "1"]) == "2001:db8::1")
        #expect(STUN.compressed(["0", "0", "0", "0", "0", "0", "0", "0"]) == "::")
        #expect(STUN.compressed(["0", "0", "0", "0", "0", "0", "0", "1"]) == "::1")
        #expect(STUN.compressed(["fe80", "0", "0", "0", "0", "0", "0", "0"]) == "fe80::")
        #expect(STUN.compressed(["2001", "db8", "0", "1", "0", "0", "0", "1"]) == "2001:db8:0:1::1")
        #expect(STUN.compressed(["2001", "db8", "0", "1", "1", "1", "1", "1"]) == "2001:db8:0:1:1:1:1:1")
    }
}

@Suite("DNS whoami")
struct DNSWhoamiTests {
    @Test func characterStrings() {
        let rdata: [UInt8] = [2] + Array("ns".utf8) + [10] + Array("192.0.2.53".utf8)
        #expect(DNSWhoami.characterStrings(rdata) == ["ns", "192.0.2.53"])
        #expect(DNSWhoami.characterStrings([5, 0x61]) == nil)
        #expect(DNSWhoami.characterStrings([]) == [])
    }

    @Test func answerFromRecords() {
        let answer = DNSWhoami.answer(fromRecords: [["ns", "192.0.2.53"], ["ecs", "198.51.100.0/24/0"], ["ip", "203.0.113.9"]])
        #expect(answer == DNSWhoami.Answer(resolver: "192.0.2.53", clientSubnet: "198.51.100.0/24/0"))
        #expect(DNSWhoami.answer(fromRecords: [["ns", "2001:db8::53"]])?.resolver == "2001:db8::53")
        #expect(DNSWhoami.answer(fromRecords: [["ns", "not an address"]]) == nil)
        #expect(DNSWhoami.answer(fromRecords: [["ecs", "198.51.100.0/24"]]) == nil)
        #expect(DNSWhoami.answer(fromRecords: [["ns", "192.0.2.53"], ["ecs", "<x>"]])?.clientSubnet == nil)
    }
}

@Suite("Egress formats")
struct EgressFormatTests {
    @Test func ipSB() throws {
        let json = #"{"organization":"Example Net","asn":64500,"asn_organization":"EXAMPLE-AS","country":"Example Country","ip":"203.0.113.9","continent_code":"AS","country_code":"JP"}"#
        let geo = try #require(IPLookupParsing.ipSB(Data(json.utf8)))
        #expect(geo == IPGeo(ip: "203.0.113.9", countryCode: "JP", country: "Example Country", asn: 64500, organization: "Example Net"))
        let minimal = try #require(IPLookupParsing.ipSB(Data(#"{"ip":"2001:db8::9","asn_organization":"EXAMPLE-AS"}"#.utf8)))
        #expect(minimal.organization == "EXAMPLE-AS")
        #expect(minimal.asn == nil)
        #expect(IPLookupParsing.ipSB(Data(#"{"ip":"nope"}"#.utf8)) == nil)
        #expect(IPLookupParsing.ipSB(Data("<html>".utf8)) == nil)
    }

    @Test func ipip() throws {
        let parsed = try #require(IPLookupParsing.ipip("当前 IP：203.0.113.5  来自于：示例国 示例省 示例市  示例运营商\n"))
        #expect(parsed.ip == "203.0.113.5")
        #expect(parsed.location == "示例国 示例省 示例市 示例运营商")
        #expect(IPLookupParsing.ipip("当前 IP: 2001:db8::5")?.ip == "2001:db8::5")
        #expect(IPLookupParsing.ipip("<html>blocked</html>") == nil)
    }

    @Test func lookupUsesEachSource() async {
        let lookup = EgressLookup { url in
            switch url.absoluteString {
            case Cloudflare.traceDefault.absoluteString: Data("ip=203.0.113.10\ncolo=NRT\nloc=JP\nwarp=on\n".utf8)
            case Cloudflare.traceIPv4.absoluteString: Data("ip=203.0.113.10\nloc=JP\n".utf8)
            case EgressLookup.ipSBURL.absoluteString: Data(#"{"ip":"203.0.113.10","country_code":"JP","asn":64500}"#.utf8)
            case EgressLookup.ipipURL.absoluteString: Data("当前 IP：198.51.100.7  来自于：示例国".utf8)
            default: throw NetworkToolError.network
            }
        }
        let results = await lookup.observe()
        #expect(results.count == EgressObservation.Source.allCases.count)
        #expect(results[.cloudflareDefault]??.detail == "节点 NRT · WARP")
        #expect(results[.cloudflareIPv4]??.ip == "203.0.113.10")
        #expect(results[.cloudflareIPv6] == .some(nil))
        #expect(results[.ipSB]??.detail == "AS64500")
        #expect(results[.ipipDomestic]??.ip == "198.51.100.7")
        #expect(await lookup.geo("203.0.113.10") == nil)
        #expect(EgressLookup.geoURL("not-an-ip") == nil)
    }
}

@Suite("WebRTC and tunnel")
struct CandidateAndTunnelTests {
    @Test func candidates() throws {
        let srflx = try #require(ICECandidate("candidate:842163049 1 udp 1677729535 203.0.113.5 50000 typ srflx raddr 0.0.0.0 rport 0 generation 0"))
        #expect(srflx == ICECandidate("a=candidate:842163049 1 udp 1677729535 203.0.113.5 50000 typ srflx raddr 0.0.0.0 rport 0"))
        #expect(srflx.address == "203.0.113.5" && srflx.port == 50000 && srflx.kind == .srflx && !srflx.isMDNS)
        let mdns = try #require(ICECandidate("candidate:1 1 udp 2122260223 4f1c6d7e-1111-2222-3333-444455556666.local 54321 typ host generation 0"))
        #expect(mdns.isMDNS && mdns.kind == .host)
        let v6 = try #require(ICECandidate("candidate:2 1 udp 2122262783 2001:db8::5 54322 typ host"))
        #expect(v6.address == "2001:db8::5")
        #expect(ICECandidate("candidate:1 1 udp 1 not-an-address 1 typ host") == nil)
        #expect(ICECandidate("candidate:1 1 udp 1 203.0.113.5 x typ host") == nil)
        #expect(ICECandidate("candidate:1 1 udp 1 203.0.113.5 1 typ weird") == nil)
        #expect(ICECandidate("") == nil)
    }

    @Test func tunnelInterfaces() {
        let on = TunnelState.classify(scopedInterfaces: ["en0", "utun3", "ipsec0", "pdp_ip0"], httpProxyEnabled: false)
        #expect(on.vpnInterfaces == ["ipsec0", "utun3"])
        #expect(on.vpnActive && !on.httpProxy)
        let off = TunnelState.classify(scopedInterfaces: ["en0", "pdp_ip0"], httpProxyEnabled: true)
        #expect(!off.vpnActive && off.httpProxy)
    }
}
