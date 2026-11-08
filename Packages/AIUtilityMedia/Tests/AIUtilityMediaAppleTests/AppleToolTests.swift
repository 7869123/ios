#if canImport(ImageIO) && canImport(AVFoundation)
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import AIUtilityMedia
@testable import AIUtilityMediaApple

// MARK: - Fixtures (generated in memory; no bundled personal images)

private struct RGB: Equatable { let r: UInt8, g: UInt8, b: UInt8 }

private func solidImage(width: Int, height: Int, color: RGB) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

/// Left half red, right half blue: makes orientation visible.
private func splitImage(width: Int, height: Int) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    return try #require(context.makeImage())
}

private func encoded(_ image: CGImage, type: String, properties: [CFString: Any] = [:]) throws -> Data {
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output as CFMutableData, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

/// Fake but realistic identifying metadata (test values only).
private func identifyingProperties() -> [CFString: Any] { [
    kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.5, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 2.5, kCGImagePropertyGPSLongitudeRef: "E"],
    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "ExampleCam", kCGImagePropertyTIFFModel: "Test 1"],
    kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "test comment",
                                     kCGImagePropertyExifDateTimeOriginal: "2000:01:01 00:00:00"],
] }

/// Decodes to RGBA8 and returns the colour at (x, y) with a top-left origin.
private func pixel(_ data: Data, x: Int, y: Int) throws -> RGB {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return try pixel(image, x: x, y: y)
}

private func pixel(_ image: CGImage, x: Int, y: Int) throws -> RGB {
    let width = image.width, height = image.height
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    try buffer.withUnsafeMutableBytes { raw in
        let context = try #require(CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    let offset = (y * width + x) * 4
    return RGB(r: buffer[offset], g: buffer[offset + 1], b: buffer[offset + 2])
}

private func similar(_ a: RGB, _ b: RGB, tolerance: Int = 6) -> Bool {
    abs(Int(a.r) - Int(b.r)) <= tolerance && abs(Int(a.g) - Int(b.g)) <= tolerance && abs(Int(a.b) - Int(b.b)) <= tolerance
}

private let red = RGB(r: 255, g: 0, b: 0), green = RGB(r: 0, g: 255, b: 0), blue = RGB(r: 0, g: 0, b: 255)
private let white = RGB(r: 255, g: 255, b: 255)

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("aiutility-p2-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a small H.264 video whose frames get brighter over time.
private func makeVideo(at url: URL, width: Int = 64, height: Int = 48, seconds: Int = 2, fps: Int32 = 30) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let total = Int(fps) * seconds
    for frame in 0..<total {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        let pool = try #require(adaptor.pixelBufferPool)
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!
        memset(base, Int32(frame * 255 / total), CVPixelBufferGetBytesPerRow(pixels) * height)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
}

private func expectMediaError<T>(_ expected: MediaError, _ body: () async throws -> T) async {
    do { _ = try await body(); Issue.record("expected \(expected)") }
    catch let error as MediaError { #expect(error == expected) }
    catch { Issue.record("unexpected error \(error)") }
}

// MARK: - Stitching

struct StitchImageTests {
    @Test func verticalStitchKeepsOrderSizesSpacingAndBackground() async throws {
        let inputs = [try encoded(solidImage(width: 10, height: 4, color: red), type: "public.png"),
                      try encoded(solidImage(width: 6, height: 6, color: green), type: "public.png"),
                      try encoded(solidImage(width: 8, height: 2, color: blue), type: "public.png")]
        let copies = inputs
        let result = try await stitchImages(inputs, options: StitchOptions(layout: .vertical, spacing: 2))
        #expect(inputs == copies)
        #expect(result.format == .png && result.width == 10 && result.height == 16)
        #expect(similar(try pixel(result.data, x: 5, y: 2), red))
        #expect(similar(try pixel(result.data, x: 5, y: 5), white))   // spacing
        #expect(similar(try pixel(result.data, x: 5, y: 9), green))
        #expect(similar(try pixel(result.data, x: 0, y: 9), white))   // centred: margin left of the narrower image
        #expect(similar(try pixel(result.data, x: 5, y: 15), blue))
    }

    @Test func horizontalAndGridLayouts() async throws {
        let inputs = [try encoded(solidImage(width: 4, height: 4, color: red), type: "public.png"),
                      try encoded(solidImage(width: 4, height: 4, color: green), type: "public.png"),
                      try encoded(solidImage(width: 4, height: 4, color: blue), type: "public.png")]
        let row = try await stitchImages(inputs, options: StitchOptions(layout: .horizontal))
        #expect(row.width == 12 && row.height == 4)
        #expect(similar(try pixel(row.data, x: 1, y: 1), red))
        #expect(similar(try pixel(row.data, x: 5, y: 1), green))
        #expect(similar(try pixel(row.data, x: 9, y: 1), blue))
        let grid = try await stitchImages(inputs, options: StitchOptions(layout: .grid(columns: 2), spacing: 1,
                                                                         background: RGBAColor(red: 0, green: 0, blue: 0)))
        #expect(grid.width == 9 && grid.height == 9)
        #expect(similar(try pixel(grid.data, x: 1, y: 1), red))
        #expect(similar(try pixel(grid.data, x: 6, y: 1), green))
        #expect(similar(try pixel(grid.data, x: 1, y: 6), blue))
        #expect(similar(try pixel(grid.data, x: 6, y: 6), RGB(r: 0, g: 0, b: 0)))   // empty cell shows the background
    }

    @Test func orientationIsAppliedBeforeLayout() async throws {
        // 4x2 stored pixels tagged "rotate 90° clockwise" display as 2x4.
        let rotated = try encoded(splitImage(width: 4, height: 2), type: "public.jpeg",
                                  properties: [kCGImagePropertyOrientation: 6])
        let result = try await stitchImages([rotated])
        #expect(result.width == 2 && result.height == 4)
        // Stored left (red) ends up on top after a clockwise turn.
        #expect(similar(try pixel(result.data, x: 1, y: 0), red, tolerance: 40))
        #expect(similar(try pixel(result.data, x: 1, y: 3), blue, tolerance: 40))
    }

    @Test func limitsAndBadInputFailWithoutOutput() async throws {
        let png = try encoded(solidImage(width: 100, height: 100, color: red), type: "public.png")
        var limits = MediaProcessingLimits(); limits.maxPixels = 15_000
        await expectMediaError(.resourceLimitExceeded) {
            try await stitchImages([png, png], options: StitchOptions(layout: .horizontal, limits: limits))
        }
        await expectMediaError(.unsupportedFormat) { try await stitchImages([Data("not an image".utf8)]) }
        await expectMediaError(.invalidInput) { try await stitchImages([]) }
        await expectMediaError(.invalidInput) { try await stitchImages([png], options: StitchOptions(layout: .grid(columns: 0))) }
    }

    @Test func cancellationReturnsNoResult() async throws {
        let png = try encoded(solidImage(width: 8, height: 8, color: red), type: "public.png")
        let task = Task { () async throws -> ImageResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await stitchImages([png, png])
        }
        await expectMediaError(.cancelled) { try await task.value }
    }
}

// MARK: - Fingerprint

struct FingerprintTests {
    @Test func stripMetadataRemovesIdentifyingFieldsAndKeepsInputBytes() async throws {
        let input = try encoded(splitImage(width: 4, height: 2), type: "public.jpeg",
                                properties: identifyingProperties().merging([kCGImagePropertyOrientation: 6]) { a, _ in a })
        let original = input
        let source = try #require(CGImageSourceCreateWithData(input as CFData, nil))
        #expect(MetadataInspector.hasRemovableMetadata(source))
        let result = try await rewriteFingerprint(input, options: FingerprintOptions(method: .stripMetadata))
        #expect(input == original)
        #expect(result.typeIdentifier == "public.jpeg")
        #expect(result.metadataRemoved && result.bytesChanged)
        let output = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        #expect(!MetadataInspector.hasRemovableMetadata(output))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        // Orientation needed for correct display survives.
        #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 6)
    }

    @Test func cleanImageReportsNothingRemoved() async throws {
        let clean = try encoded(solidImage(width: 4, height: 4, color: green), type: "public.png")
        let result = try await rewriteFingerprint(clean, options: FingerprintOptions(method: .stripMetadata))
        #expect(!result.metadataRemoved)
    }

    @Test func reencodeChangesBytesKeepsSizeAndDropsMetadata() async throws {
        let input = try encoded(solidImage(width: 16, height: 12, color: blue), type: "public.jpeg", properties: identifyingProperties())
        let original = input
        let result = try await rewriteFingerprint(input, options: FingerprintOptions(method: .reencode, jpegQuality: 0.7))
        #expect(input == original)
        #expect(result.typeIdentifier == "public.jpeg" && result.bytesChanged && result.metadataRemoved)
        let png = try await rewriteFingerprint(input, options: FingerprintOptions(method: .reencode, format: .png))
        #expect(png.typeIdentifier == "public.png")
        let source = try #require(CGImageSourceCreateWithData(png.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 16 && image.height == 12)
    }

    @Test func pixelNoiseNeedsPermissionAndChangesPixelsByAtMostOne() async throws {
        let input = try encoded(solidImage(width: 32, height: 32, color: RGB(r: 128, g: 128, b: 128)), type: "public.png")
        await expectMediaError(.invalidInput) {
            try await rewriteFingerprint(input, options: FingerprintOptions(method: .subtlePixelNoise))
        }
        let result = try await rewriteFingerprint(input, options: FingerprintOptions(method: .subtlePixelNoise, allowPixelChanges: true))
        #expect(result.bytesChanged && result.typeIdentifier == "public.png")
        var changed = 0
        for y in 0..<32 { for x in 0..<32 {
            let a = try pixel(input, x: x, y: y), b = try pixel(result.data, x: x, y: y)
            #expect(similar(a, b, tolerance: 1))
            if a != b { changed += 1 }
        } }
        #expect(changed > 0)
        let again = try await rewriteFingerprint(input, options: FingerprintOptions(method: .subtlePixelNoise, allowPixelChanges: true))
        #expect(again.data == result.data)   // same seed, same output
    }

    @Test func oversizedInputFailsBeforeDecoding() async throws {
        let input = try encoded(solidImage(width: 8, height: 8, color: red), type: "public.png")
        var limits = MediaProcessingLimits(); limits.maxInputBytes = Int64(input.count - 1)
        await expectMediaError(.resourceLimitExceeded) {
            try await rewriteFingerprint(input, options: FingerprintOptions(method: .reencode, limits: limits))
        }
    }
}

// MARK: - GIF

struct GIFTests {
    @Test func encoderKeepsEachFrameDelayAndOrder() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("frames.gif")
        let encoder = try GIFFileEncoder(url: url, frameCount: 3, loopCount: 0)
        try encoder.append(try solidImage(width: 6, height: 4, color: red), delayCentiseconds: 3)
        try encoder.append(try solidImage(width: 6, height: 4, color: green), delayCentiseconds: 7)
        try encoder.append(try solidImage(width: 6, height: 4, color: blue), delayCentiseconds: 12)
        try encoder.finish()
        let summary = try #require(GIFInspector.inspect(url))
        #expect(summary == GIFInspector.Summary(frameCount: 3, delaysCentiseconds: [3, 7, 12], width: 6, height: 4))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let order = try (0..<3).map { try pixel(try #require(CGImageSourceCreateImageAtIndex(source, $0, nil)), x: 2, y: 2) }
        #expect(similar(order[0], red, tolerance: 30) && similar(order[1], green, tolerance: 30) && similar(order[2], blue, tolerance: 30))
    }

    @Test func encoderRejectsDelaysAGIFCannotShow() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let encoder = try GIFFileEncoder(url: directory.appendingPathComponent("bad.gif"), frameCount: 1, loopCount: 0)
        #expect(throws: MediaError.unsupportedFormat) {
            try encoder.append(try solidImage(width: 2, height: 2, color: red), delayCentiseconds: 1)
        }
        #expect(throws: MediaError.invalidState) { try encoder.finish() }
    }

    @Test func videoClipBecomesGIFWithPlannedFramesAndDuration() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("input.mov")
        try await makeVideo(at: video)
        let before = try Data(contentsOf: video)
        let result = try await makeGIF(fromVideo: video, outputDirectory: directory,
                                       options: GIFOptions(start: 0.5, duration: 1.0, fps: 10, maxWidth: 32))
        #expect(try Data(contentsOf: video) == before)
        #expect(result.frameCount == 10 && abs(result.totalDuration - 1.0) < 0.001)
        #expect(result.width == 32 && result.height == 24)
        #expect(result.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(result.url.pathExtension == "gif" && result.bytes > 0)
        // Later frames come from later, brighter video frames.
        let source = try #require(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let first = try pixel(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)), x: 16, y: 12)
        let last = try pixel(try #require(CGImageSourceCreateImageAtIndex(source, 9, nil)), x: 16, y: 12)
        #expect(Int(last.r) > Int(first.r))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".partial") }
        #expect(leftovers.isEmpty)
    }

    @Test func smallVideoIsNotUpscaledAndClipMustFit() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("input.mov")
        try await makeVideo(at: video)
        let result = try await makeGIF(fromVideo: video, outputDirectory: directory,
                                       options: GIFOptions(duration: 0.5, fps: 20, maxWidth: 480))
        #expect(result.width == 64 && result.height == 48 && result.frameCount == 10)
        await expectMediaError(.invalidInput) {
            try await makeGIF(fromVideo: video, outputDirectory: directory, options: GIFOptions(start: 1.5, duration: 1.0))
        }
        await expectMediaError(.notFound) {
            try await makeGIF(fromVideo: directory.appendingPathComponent("missing.mov"), outputDirectory: directory,
                              options: GIFOptions(duration: 1))
        }
    }

    @Test func cancelledConversionLeavesNoFiles() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("input.mov")
        try await makeVideo(at: video)
        let output = directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let task = Task { () async throws -> GIFResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await makeGIF(fromVideo: video, outputDirectory: output, options: GIFOptions(duration: 1.5))
        }
        await expectMediaError(.cancelled) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }
}
#endif
