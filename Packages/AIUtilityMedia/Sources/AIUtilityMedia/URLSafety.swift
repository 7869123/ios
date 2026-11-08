import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum URLSafety {
    static func validate(_ url: URL) throws(MediaError) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "https", c.user == nil, c.password == nil,
              let host = c.host?.lowercased(), !host.isEmpty, host.utf8.count <= 253,
              url.absoluteString.utf8.count <= 8192, c.port == nil || c.port == 443,
              !host.contains("%"), !host.hasSuffix("."), host != "localhost", !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"), !host.hasSuffix(".internal"), !host.hasSuffix(".test"),
              !host.contains("\\") else { throw .invalidURL }
        let literal = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if literal.contains(":") || literal.allSatisfy({ $0.isNumber || $0 == "." }) {
            guard publicAddress(literal) else { throw .invalidURL }
        }
    }
    static func canonical(_ url: URL) throws(MediaError) -> String {
        try validate(url)
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw .invalidURL }
        c.scheme = "https"; c.host = c.host?.lowercased(); c.fragment = nil
        if c.port == 443 { c.port = nil }
        if c.percentEncodedPath.isEmpty { c.percentEncodedPath = "/" }
        guard let value = c.string else { throw .invalidURL }
        return value
    }
    static func source(_ url: URL) -> MediaSource? {
        guard (try? validate(url)) != nil, let host = url.host?.lowercased() else { return nil }
        let path = url.path
        if host == "b23.tv" { return .bilibili }
        if ["bilibili.com", "www.bilibili.com", "m.bilibili.com"].contains(host),
           path.hasPrefix("/video/") { return .bilibili }
        if host == "t.co" { return .x }
        if ["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"].contains(host),
           path.split(separator: "/").contains("status") { return .x }
        if ["pixiv.net", "www.pixiv.net"].contains(host), path.hasPrefix("/artworks/") { return .pixiv }
        return .direct
    }
    static func publicAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        if text.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let n = UInt32(bigEndian: v4.s_addr)
            let a = n >> 24, b = (n >> 16) & 255
            return !(a == 0 || a == 10 || a == 127 || a >= 224 ||
                     (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254) ||
                     (a == 172 && (16...31).contains(b)) || (a == 192 && [0, 168].contains(b)) ||
                     (a == 198 && (18...19).contains(b)))
        }
        var v6 = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        // Only native global-unicast IPv6; reject mapped IPv4, NAT64, local and multicast ranges.
        return bytes[0] & 0xe0 == 0x20 && !(bytes[0] == 0x20 && bytes[1] == 0x02)
    }
}

protocol DestinationValidator: Sendable { func validate(_ url: URL) async throws }
struct PublicDNSValidator: DestinationValidator {
    func validate(_ url: URL) async throws {
        try URLSafety.validate(url)
        guard let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { throw MediaError.invalidURL }
        // getaddrinfo owns no URLSession state. The queue still waits for this bounded OS lookup on cancellation.
        let addresses: [String] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, nil, &result) == 0, let first = result else {
                    continuation.resume(returning: []); return
                }
                defer { freeaddrinfo(first) }
                var values: [String] = [], cursor: UnsafeMutablePointer<addrinfo>? = first
                while let entry = cursor {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let capacity = socklen_t(buffer.count)
                    if let address = entry.pointee.ai_addr,
                       getnameinfo(address, entry.pointee.ai_addrlen, &buffer, capacity, nil, 0, NI_NUMERICHOST) == 0 {
                        let value = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                        values.append(String(decoding: value, as: UTF8.self))
                    }
                    cursor = entry.pointee.ai_next
                }
                continuation.resume(returning: values)
            }
        }
        try Task.checkCancellation()
        guard !addresses.isEmpty else { throw MediaError.network }
        guard addresses.allSatisfy(URLSafety.publicAddress) else { throw MediaError.invalidURL }
        // URLSession performs a subsequent lookup: this preflight does not pin DNS or defeat rebinding.
    }
}

/// Stable SHA-256 identity, independent of Swift.Hasher's per-process random seed.
enum StableDigest {
    static func hex(_ text: String) -> String { hash(Array(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func hash(_ input: [UInt8]) -> [UInt8] {
        let k: [UInt32] = [
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
        var data = input; let bits = UInt64(input.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: bits >> shift)) }
        var h: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for offset in stride(from: 0, to: data.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 { for j in 0..<4 { w[i] = (w[i] << 8) | UInt32(data[offset + i * 4 + j]) } }
            for i in 16..<64 {
                let a = w[i-15], b = w[i-2]
                w[i] = w[i-16] &+ (rotate(a,7) ^ rotate(a,18) ^ (a >> 3)) &+ w[i-7] &+ (rotate(b,17) ^ rotate(b,19) ^ (b >> 10))
            }
            var v = h
            for i in 0..<64 {
                let t = v[7] &+ (rotate(v[4],6) ^ rotate(v[4],11) ^ rotate(v[4],25)) &+
                    ((v[4] & v[5]) ^ (~v[4] & v[6])) &+ k[i] &+ w[i]
                let u = (rotate(v[0],2) ^ rotate(v[0],13) ^ rotate(v[0],22)) &+
                    ((v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]))
                v = [t &+ u, v[0], v[1], v[2], v[3] &+ t, v[4], v[5], v[6]]
            }
            for i in 0..<8 { h[i] = h[i] &+ v[i] }
        }
        return h.flatMap { x in [UInt8(truncatingIfNeeded: x >> 24), UInt8(truncatingIfNeeded: x >> 16), UInt8(truncatingIfNeeded: x >> 8), UInt8(truncatingIfNeeded: x)] }
    }
}
