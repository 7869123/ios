import Foundation
import Testing
@testable import AIUtilityMediaApple

// Byte-level structure (ContainerText does not check CRCs), so these run on every platform. Chunks still carry a
// correct CRC so ImageIO reads them as a real encoder would have written them.
private func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
    }
    return ~crc
}
private func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
    let typed = Array(type.utf8) + body
    return withUnsafeBytes(of: UInt32(body.count).bigEndian) { [UInt8]($0) } + typed
        + withUnsafeBytes(of: crc32(typed).bigEndian) { [UInt8]($0) }
}
private let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

struct ContainerTextTests {
    @Test func pngTextAndTimeChunksAreFoundAndRemovedOthersKept() throws {
        let ihdr = chunk("IHDR", Array(repeating: 1, count: 13)), idat = chunk("IDAT", [1, 2, 3])
        let text = chunk("tEXt", Array("parameters".utf8) + [0] + Array("fixture prompt".utf8))
        let png = Data(signature + ihdr + text + chunk("tIME", [0, 0, 0, 0, 0, 0, 0]) + idat + chunk("IEND", []))
        #expect(ContainerText.hasText(png))
        let stripped = try #require(ContainerText.removingText(png))
        #expect(stripped == Data(signature + ihdr + idat + chunk("IEND", [])))
        #expect(!ContainerText.hasText(stripped))
    }
    @Test func jpegCommentsAreRemovedAndScanDataKept() throws {
        let app0: [UInt8] = [0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46]
        let comment: [UInt8] = [0xFF, 0xFE, 0x00, 0x07] + Array("hello".utf8)
        let scan: [UInt8] = [0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9]
        let jpeg = Data([0xFF, 0xD8] + app0 + comment + scan)
        #expect(ContainerText.hasText(jpeg))
        #expect(try #require(ContainerText.removingText(jpeg)) == Data([0xFF, 0xD8] + app0 + scan))
    }
    @Test func malformedOrOtherFormatsAreLeftAlone() {
        #expect(ContainerText.removingText(Data("not an image".utf8)) == nil)
        // A chunk length running past the end of the file is malformed: nothing is removed.
        #expect(ContainerText.removingText(Data(signature + [0x7F, 0, 0, 0] + Array("tEXt".utf8))) == nil)
        #expect(!ContainerText.hasText(Data([0xFF, 0xD8, 0xFF])))
    }
}

#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO

@Test func stripMetadataRemovesAPNGPromptChunkAndSaysSo() async throws {
    let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    var bytes = [UInt8](data as Data)
    bytes.insert(contentsOf: chunk("tEXt", Array("parameters".utf8) + [0] + Array("fixture prompt".utf8)), at: bytes.count - 12)
    let result = try await rewriteFingerprint(Data(bytes), options: FingerprintOptions(method: .stripMetadata))
    #expect(result.metadataRemoved)
    #expect(result.data.range(of: Data("fixture prompt".utf8)) == nil)
    let decoded = try #require(CGImageSourceCreateWithData(result.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    #expect(decoded.width == 32 && decoded.height == 32)
}
#endif
