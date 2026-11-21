import Foundation

/// RFC 1321 MD5, only for the China Academy of ICT request signature (not for security). Pure Swift so it
/// builds on Linux, where CryptoKit is not available.
enum MD5 {
    private static let shifts: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                           5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                           4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                           6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
    private static let table: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
        0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
        0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
        0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
        0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
        0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
        0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
        0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var a0: UInt32 = 0x6745_2301, b0: UInt32 = 0xefcd_ab89, c0: UInt32 = 0x98ba_dcfe, d0: UInt32 = 0x1032_5476
        var bytes = message
        let bitLength = UInt64(message.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for index in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(index)))) }
        for chunk in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 16)
            for index in 0..<16 {
                let base = chunk + 4 * index
                let low = UInt32(bytes[base]) | UInt32(bytes[base + 1]) << 8
                let high = UInt32(bytes[base + 2]) << 16 | UInt32(bytes[base + 3]) << 24
                words[index] = low | high
            }
            var a = a0, b = b0, c = c0, d = d0
            for round in 0..<64 {
                let mixed: UInt32
                let word: Int
                switch round {
                case 0..<16: mixed = (b & c) | (~b & d); word = round
                case 16..<32: mixed = (d & b) | (~d & c); word = (5 * round + 1) % 16
                case 32..<48: mixed = b ^ c ^ d; word = (3 * round + 5) % 16
                default: mixed = c ^ (b | ~d); word = (7 * round) % 16
                }
                let f = mixed &+ a &+ table[round] &+ words[word]
                a = d; d = c; c = b
                b = b &+ ((f << shifts[round]) | (f >> (32 - shifts[round])))
            }
            a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
        }
        var out: [UInt8] = []
        for value in [a0, b0, c0, d0] {
            for index in 0..<4 { out.append(UInt8(truncatingIfNeeded: value >> (8 * UInt32(index)))) }
        }
        return out
    }

    /// Lower-case hex digest of the UTF-8 text.
    static func hex(_ text: String) -> String {
        digest(Array(text.utf8)).map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }
}
