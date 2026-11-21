import Foundation
import Testing
@testable import AIUtilityNetwork

// Live checks against the real services the network tools use. Off by default; run only when
// AIUTILITY_LIVE_TESTS=1 (manual `live_checks` workflow input). Small requests only: trace pages, a 1 MB
// download and a 100 KB upload to speed.cloudflare.com, one STUN binding per server, three DNS TXT lookups.
//
// Each check appends `LIVE-CHECK <name>: <outcome>` to AIUTILITY_LIVE_REPORT:
// - ok: the answer matched what the parser expects (addresses are not written to the report);
// - unavailable: refused, blocked or unreachable from this runner (for example no IPv6, UDP filtered);
// - FORMAT: the answer arrived but no longer parses -> the test fails.

#if canImport(Darwin)
private let liveEnabled = ProcessInfo.processInfo.environment["AIUTILITY_LIVE_TESTS"] == "1"

private func record(_ line: String) {
    guard let path = ProcessInfo.processInfo.environment["AIUTILITY_LIVE_REPORT"], !path.isEmpty else { return }
    let url = URL(fileURLWithPath: path)
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

/// The body returns a short description, or nil when the service answered with something that does not parse.
private func check(_ name: String, _ body: () async throws -> String?) async {
    do {
        if let detail = try await body() {
            record("LIVE-CHECK \(name): ok - \(detail)")
        } else {
            record("LIVE-CHECK \(name): FORMAT - answer did not parse")
            Issue.record("\(name): answer did not parse")
        }
    } catch {
        record("LIVE-CHECK \(name): unavailable - \(NetworkToolError.classify(error))")
    }
}

private func family(_ ip: String) -> String { IPAddressText.family(ip)?.rawValue ?? "?" }

@Suite("Live network checks", .serialized, .enabled(if: liveEnabled))
struct LiveNetworkChecks {
    @Test func cloudflareTraces() async {
        let fetch = EgressLookup.urlSessionFetch
        for (name, url) in [("trace-default", Cloudflare.traceDefault), ("trace-ipv4", Cloudflare.traceIPv4), ("trace-ipv6", Cloudflare.traceIPv6)] {
            await check(name) {
                let text = String(decoding: try await fetch(url), as: UTF8.self)
                return CloudflareTrace(text).map { "family \(family($0.ip)), colo \($0.colo ?? "-"), http \($0.httpVersion ?? "-")" }
            }
        }
    }

    @Test func egressServices() async {
        let lookup = EgressLookup(fetch: EgressLookup.urlSessionFetch)
        await check("ip.sb") {
            let geo = IPLookupParsing.ipSB(try await EgressLookup.urlSessionFetch(EgressLookup.ipSBURL))
            return geo.map { "family \(family($0.ip)), country \($0.countryCode ?? "-"), asn \($0.asn.map(String.init) ?? "-")" }
        }
        await check("ip.sb-geo") {
            guard let own = try await lookup.observe(.ipSB) else { return nil }
            return await lookup.geo(own.ip).map { "country \($0.countryCode ?? "-")" }
        }
        await check("ipip") {
            let text = String(decoding: try await EgressLookup.urlSessionFetch(EgressLookup.ipipURL), as: UTF8.self)
            return IPLookupParsing.ipip(text).map { "family \(family($0.ip)), location \($0.location == nil ? "missing" : "present")" }
        }
    }

    @Test func cloudflareSpeedEndpoints() async {
        let transport = CloudflareSpeedTransport()
        defer { transport.invalidate() }
        await check("speed-latency") {
            let seconds = try await transport.latencyProbe()
            return seconds >= 0 && seconds < 5 ? String(format: "%.0f ms", seconds * 1000) : nil
        }
        await check("speed-download-1MB") {
            let sample = try await transport.download(bytes: 1_000_000)
            guard sample.bytes == 1_000_000, sample.transferSeconds > 0 else { return nil }
            return String(format: "%.1f Mbps, server timing %@", SpeedStatistics.megabitsPerSecond(bytes: sample.bytes, seconds: sample.transferSeconds) ?? 0,
                          sample.latencySeconds == nil ? "missing" : "present")
        }
        await check("speed-upload-100KB") {
            let sample = try await transport.upload(bytes: 100_000)
            return sample.bytes == 100_000 && sample.transferSeconds >= 0 ? String(format: "%.3f s", sample.transferSeconds) : nil
        }
    }

    @Test func stunServers() async {
        for server in STUN.servers {
            await check("stun-\(server.host)") {
                guard let endpoint = try await STUNClient.query(host: server.host, port: server.port) else {
                    throw NetworkToolError.timeout // no answer: UDP filtered on this runner, not a format change
                }
                return "family \(family(endpoint.address))"
            }
        }
    }

    @Test func dnsWhoami() async {
        for name in DNSWhoami.names {
            await check("dns-\(name)") {
                guard let answer = try await DNSWhoami.query(name) else { throw NetworkToolError.timeout }
                return "resolver family \(family(answer.resolver)), ecs \(answer.clientSubnet == nil ? "absent" : "present")"
            }
        }
    }
}
#endif
