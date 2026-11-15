#if canImport(ImageIO) && canImport(AVFoundation)
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import AIUtilityMedia
@testable import AIUtilityMediaApple

// Pre-device diagnostics (workflow input `diagnostics`). They measure and report with "DIAG" lines rather than
// assert a guess, so an unknown platform behaviour shows up as data. Off by default: AIUTILITY_DIAGNOSTICS=1.
private let diagnostics = ProcessInfo.processInfo.environment["AIUTILITY_DIAGNOSTICS"] == "1"

private func report(_ line: String) { print("DIAG " + line) }

private func peakResidentMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576 // bytes on Darwin
}

private func gradientImage(width: Int, height: Int) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    for x in stride(from: 0, to: width, by: 8) {
        context.setFillColor(CGColor(red: Double(x) / Double(width), green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: x, y: 0, width: 8, height: height))
    }
    return try #require(context.makeImage())
}

private func encode(_ image: CGImage, type: String) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

private func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
    }
    return ~crc
}

/// Inserts a PNG tEXt chunk (keyword, text) before IEND, like image generators that store their prompt.
private func pngWithText(_ png: Data, keyword: String, text: String) -> Data {
    var bytes = [UInt8](png)
    let iend = bytes.count - 12
    let type = Array("tEXt".utf8), body = Array(keyword.utf8) + [0] + Array(text.utf8)
    var chunk = withUnsafeBytes(of: UInt32(body.count).bigEndian) { [UInt8]($0) } + type + body
    chunk += withUnsafeBytes(of: crc32(type + body).bigEndian) { [UInt8]($0) }
    bytes.insert(contentsOf: chunk, at: iend)
    return Data(bytes)
}

@Test(.enabled(if: diagnostics))
func diagPNGTextChunkIsDetectedAndStripped() async throws {
    let png = try #require(encode(try gradientImage(width: 64, height: 64), type: "public.png"))
    let tagged = pngWithText(png, keyword: "parameters", text: "fixture prompt, seed 1234")
    let source = try #require(CGImageSourceCreateWithData(tagged as CFData, nil))
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    let pngKeys = (properties["{PNG}"] as? [String: Any]).map { Array($0.keys).sorted() } ?? []
    report("png-text: ImageIO {PNG} keys = \(pngKeys)")
    report("png-text: detected before strip = \(MetadataInspector.hasRemovableMetadata(source))")
    for method in [FingerprintMethod.stripMetadata, .reencode] {
        do {
            let result = try await rewriteFingerprint(tagged, options: FingerprintOptions(method: method))
            let stillThere = result.data.range(of: Data("fixture prompt".utf8)) != nil
            report("png-text: \(method) -> metadataRemoved=\(result.metadataRemoved), text still in output=\(stillThere)")
        } catch { report("png-text: \(method) -> error \(error)") }
    }
}

@Test(.enabled(if: diagnostics))
func diagHEICStripAndReencode() async throws {
    let image = try gradientImage(width: 256, height: 192)
    guard let heic = encode(image, type: "public.heic") else { report("heic: encoder unavailable on this machine"); return }
    report("heic: encoded \(heic.count) bytes")
    for method in [FingerprintMethod.stripMetadata, .reencode] {
        do {
            let result = try await rewriteFingerprint(heic, options: FingerprintOptions(method: method))
            report("heic: \(method) -> \(result.typeIdentifier), \(result.data.count) bytes")
        } catch { report("heic: \(method) -> error \(error)") }
    }
}

@Test(.enabled(if: diagnostics), .timeLimit(.minutes(5)))
func diagGIFPeakMemoryAtTheUILimits() async throws {
    // The largest GIF the UI allows: 600 frames, 640 px wide (16:9 source), the default total-pixel cap.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diag-gif-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let video = directory.appendingPathComponent("input.mov")
    let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                         AVVideoWidthKey: 1280, AVVideoHeightKey: 720])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 720])
    writer.add(input); _ = writer.startWriting(); writer.startSession(atSourceTime: .zero)
    for frame in 0..<600 { // 60 s at 10 fps
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels)!, Int32(frame % 255), CVPixelBufferGetBytesPerRow(pixels) * 720)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        _ = adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
    }
    input.markAsFinished(); await writer.finishWriting()
    let before = peakResidentMB(), started = Date()
    do {
        let result = try await makeGIF(fromVideo: video, outputDirectory: directory,
                                       options: GIFOptions(start: 0, duration: 59.9, fps: 10, maxWidth: 640))
        report(String(format: "gif-memory: %d frames %dx%d, %.1f MB file, peak RSS %.0f MB -> %.0f MB, %.1f s",
                      result.frameCount, result.width, result.height, Double(result.bytes) / 1_048_576,
                      before, peakResidentMB(), Date().timeIntervalSince(started)))
    } catch { report("gif-memory: error \(error) after \(Date().timeIntervalSince(started)) s, peak RSS \(peakResidentMB()) MB") }
}
#endif
