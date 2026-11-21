import Foundation
#if canImport(Network)
import Network
#endif

/// Minimal RFC 5389 STUN: a Binding request, and the mapped (public) address from the response. A UDP path
/// that bypasses a VPN or proxy shows a different address here than HTTPS does, which is what browsers leak
/// through WebRTC.
public enum STUN {
    public static let magicCookie: UInt32 = 0x2112_A442

    public struct Endpoint: Sendable, Equatable {
        public let address: String
        public let port: UInt16
    }

    public static func bindingRequest(transactionID: [UInt8]) -> Data {
        precondition(transactionID.count == 12)
        var bytes: [UInt8] = [0x00, 0x01, 0x00, 0x00] // Binding request, no attributes
        bytes += withUnsafeBytes(of: magicCookie.bigEndian) { [UInt8]($0) }
        bytes += transactionID
        return Data(bytes)
    }

    public static func randomTransactionID() -> [UInt8] { (0..<12).map { _ in UInt8.random(in: 0...255) } }

    /// The XOR-MAPPED-ADDRESS (or plain MAPPED-ADDRESS) of a Binding success response for this transaction.
    public static func mappedAddress(in data: Data, transactionID: [UInt8]) -> Endpoint? {
        let b = [UInt8](data)
        guard b.count >= 20, b[0] == 0x01, b[1] == 0x01 else { return nil } // Binding success response
        let length = Int(b[2]) << 8 | Int(b[3])
        guard 20 + length <= b.count, Array(b[4..<8]) == withUnsafeBytes(of: magicCookie.bigEndian, { [UInt8]($0) }),
              Array(b[8..<20]) == transactionID else { return nil }
        var offset = 20, plain: Endpoint?
        while offset + 4 <= 20 + length {
            let type = Int(b[offset]) << 8 | Int(b[offset + 1])
            let size = Int(b[offset + 2]) << 8 | Int(b[offset + 3])
            let value = offset + 4
            guard value + size <= 20 + length else { return nil }
            if type == 0x0020, let endpoint = address(Array(b[value..<value + size]), xorWith: Array(b[4..<20])) { return endpoint }
            if type == 0x0001 { plain = address(Array(b[value..<value + size]), xorWith: nil) }
            offset = value + (size + 3) / 4 * 4 // attributes are padded to 4 bytes
        }
        return plain
    }

    private static func address(_ v: [UInt8], xorWith key: [UInt8]?) -> Endpoint? {
        guard v.count >= 8 else { return nil }
        var port = UInt16(v[2]) << 8 | UInt16(v[3])
        if let key { port ^= UInt16(key[0]) << 8 | UInt16(key[1]) }
        switch v[1] {
        case 0x01:
            let raw = (0..<4).map { v[4 + $0] ^ (key?[$0] ?? 0) }
            return Endpoint(address: raw.map(String.init).joined(separator: "."), port: port)
        case 0x02 where v.count >= 20:
            let raw = (0..<16).map { v[4 + $0] ^ (key?[$0] ?? 0) }
            let groups = stride(from: 0, to: 16, by: 2).map { String(UInt16(raw[$0]) << 8 | UInt16(raw[$0 + 1]), radix: 16) }
            return Endpoint(address: compressed(groups), port: port)
        default:
            return nil
        }
    }

    /// RFC 5952-style text: the longest run of two or more zero groups becomes "::".
    static func compressed(_ groups: [String]) -> String {
        var best = (start: -1, length: 0), run = (start: -1, length: 0)
        for (i, group) in groups.enumerated() {
            if group == "0" { run = run.start < 0 ? (i, 1) : (run.start, run.length + 1); if run.length > best.length { best = run } }
            else { run = (-1, 0) }
        }
        guard best.length >= 2 else { return groups.joined(separator: ":") }
        let head = groups[..<best.start].joined(separator: ":"), tail = groups[(best.start + best.length)...].joined(separator: ":")
        return head + "::" + tail
    }

    public static let servers: [(name: String, host: String, port: UInt16)] = [
        ("Cloudflare STUN", "stun.cloudflare.com", 3478),
        ("Google STUN", "stun.l.google.com", 19302),
    ]
}

#if canImport(Network)
public enum STUNClient {
    /// One Binding request over UDP (resent once), the mapped address or nil on timeout.
    public static func query(host: String, port: UInt16, timeout: TimeInterval = 4) async throws(NetworkToolError) -> STUN.Endpoint? {
        let id = STUN.randomTransactionID(), request = STUN.bindingRequest(transactionID: id)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 3478, using: .udp)
        let box = Once<STUN.Endpoint?>()
        let result: STUN.Endpoint? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.install(continuation)
                let queue = DispatchQueue(label: "aiutility.stun")
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        receive(on: connection, transactionID: id, into: box)
                        connection.send(content: request, completion: .contentProcessed { _ in })
                        queue.asyncAfter(deadline: .now() + timeout / 2) { connection.send(content: request, completion: .contentProcessed { _ in }) }
                    case .failed, .cancelled: box.finish(nil)
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) { box.finish(nil) }
                connection.start(queue: queue)
            }
        } onCancel: { box.finish(nil) }
        connection.cancel()
        if Task.isCancelled { throw .cancelled }
        return result
    }

    /// Reads datagrams until one is the answer to this transaction (stray packets are skipped).
    private static func receive(on connection: NWConnection, transactionID: [UInt8], into box: Once<STUN.Endpoint?>) {
        connection.receiveMessage { data, _, _, error in
            if let data, let endpoint = STUN.mappedAddress(in: data, transactionID: transactionID) {
                box.finish(endpoint)
            } else if error == nil {
                receive(on: connection, transactionID: transactionID, into: box)
            }
        }
    }
}

#endif
