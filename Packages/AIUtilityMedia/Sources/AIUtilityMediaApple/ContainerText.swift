import Foundation

/// Free-text metadata that ImageIO neither reports nor drops on a lossless copy: PNG text/time chunks (image
/// generators store prompts and settings there) and JPEG comment segments. Pure byte handling, every length is
/// checked; anything malformed is left to ImageIO (nil / false).
enum ContainerText {
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// Free-text and time chunks; none affects how the pixels are decoded. Not eXIf, and not the iTXt that holds XMP:
    /// ImageIO writes both itself (orientation, pixel size) and already reports and filters their identifying fields;
    /// removing them would drop the orientation.
    static let pngTextChunks: Set<String> = ["tEXt", "zTXt", "iTXt", "tIME"]
    private static let xmpKeyword = Array("XML:com.adobe.xmp".utf8) + [0]

    private static func isFreeText(_ chunk: Chunk, in bytes: [UInt8]) -> Bool {
        guard pngTextChunks.contains(chunk.type) else { return false }
        guard chunk.type == "iTXt" else { return true }
        let body = chunk.range.lowerBound + 8
        return !(body + xmpKeyword.count <= chunk.range.upperBound && Array(bytes[body..<body + xmpKeyword.count]) == xmpKeyword)
    }

    static func hasText(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        if let chunks = pngChunks(bytes) { return chunks.contains { isFreeText($0, in: bytes) } }
        if let segments = jpegSegments(bytes) { return segments.contains { $0.marker == 0xFE } }
        return false
    }

    /// The same file without those chunks/segments, or nil when it is not a well-formed PNG/JPEG.
    static func removingText(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        if let chunks = pngChunks(bytes) {
            var output = pngSignature
            for chunk in chunks where !isFreeText(chunk, in: bytes) { output += bytes[chunk.range] }
            return Data(output)
        }
        if let segments = jpegSegments(bytes) {
            var output: [UInt8] = [0xFF, 0xD8]
            for segment in segments where segment.marker != 0xFE { output += bytes[segment.range] }
            return Data(output)
        }
        return nil
    }

    private struct Chunk { let type: String; let range: Range<Int> }
    /// Whole chunks (length, type, data, CRC) after the signature, up to and including IEND.
    private static func pngChunks(_ bytes: [UInt8]) -> [Chunk]? {
        guard bytes.count >= 8, Array(bytes[0..<8]) == pngSignature else { return nil }
        var chunks: [Chunk] = [], offset = 8
        while offset + 12 <= bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let end = offset + 12 + length
            guard length >= 0, end <= bytes.count, let type = String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii)
            else { return nil }
            chunks.append(Chunk(type: type, range: offset..<end))
            offset = end
            if type == "IEND" { return chunks }
        }
        return nil
    }

    private struct Segment { let marker: UInt8; let range: Range<Int> }
    /// Marker segments after SOI; the last one runs from SOS (or EOI) to the end of the file.
    private static func jpegSegments(_ bytes: [UInt8]) -> [Segment]? {
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var segments: [Segment] = [], offset = 2
        while offset + 4 <= bytes.count {
            guard bytes[offset] == 0xFF else { return nil }
            let marker = bytes[offset + 1]
            if marker == 0xDA || marker == 0xD9 { // Scan data (or end): keep the rest untouched.
                segments.append(Segment(marker: marker, range: offset..<bytes.count)); return segments
            }
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let end = offset + 2 + length
            guard length >= 2, end <= bytes.count else { return nil }
            segments.append(Segment(marker: marker, range: offset..<end))
            offset = end
        }
        return nil
    }
}
