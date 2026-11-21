import Foundation

/// Classified failures; never carries server text, addresses or headers.
public enum NetworkToolError: Error, Sendable, Equatable {
    case network
    case timeout
    case cancelled
    /// The service answered with something this code does not understand (format change or captive portal).
    case unexpectedResponse
    /// HTTP status that is neither success nor a known refusal.
    case httpStatus(Int)
    case unsupportedPlatform
    /// The provider is not available yet (for example China Academy of ICT, pending its request format).
    case notConfigured

    static func classify(_ error: any Error) -> NetworkToolError {
        if let error = error as? NetworkToolError { return error }
        if error is CancellationError { return .cancelled }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            default: return .network
            }
        }
        return .network
    }
}

/// Which family an address belongs to; leak comparisons are made within one family.
public enum IPFamily: String, Sendable, Codable { case v4, v6 }

public enum IPAddressText {
    /// "v4" / "v6" for a literal address, nil for anything else (host names, mDNS ".local" names, garbage).
    public static func family(_ text: String) -> IPFamily? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) <= 255
        }) { return .v4 }
        let hex = text.split(separator: "%").first.map(String.init) ?? text
        if hex.contains(":"), hex.count <= 45,
           hex.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }), hex.components(separatedBy: "::").count <= 2 {
            return .v6
        }
        return nil
    }

    /// Private, loopback, link-local, CGNAT and unique-local addresses are not "public egress" addresses.
    public static func isPublic(_ text: String) -> Bool {
        switch family(text) {
        case .v4:
            let n = text.split(separator: ".").compactMap { Int($0) }
            guard n.count == 4 else { return false }
            return !(n[0] == 0 || n[0] == 10 || n[0] == 127 || n[0] >= 224 || (n[0] == 100 && (64...127).contains(n[1]))
                     || (n[0] == 169 && n[1] == 254) || (n[0] == 172 && (16...31).contains(n[1])) || (n[0] == 192 && n[1] == 168))
        case .v6:
            let lower = text.lowercased()
            return !(lower == "::1" || lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea")
                     || lower.hasPrefix("feb") || lower.hasPrefix("fc") || lower.hasPrefix("fd") || lower.hasPrefix("::"))
        case nil:
            return false
        }
    }
}
