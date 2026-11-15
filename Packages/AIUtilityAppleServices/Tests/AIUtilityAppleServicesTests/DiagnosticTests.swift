#if canImport(Vision) && canImport(CoreGraphics)
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@preconcurrency import Vision
import AIUtilityCore
@testable import AIUtilityAppleServices

// Pre-device diagnostics (workflow input `diagnostics`), off by default: AIUTILITY_DIAGNOSTICS=1. Each case is run
// in its own `swift test --filter` process by scripts/ci_diagnostics.sh with a watchdog, so one stall cannot hide
// the others, and the results are "DIAG" lines rather than assertions about unknown platform behaviour.
private let diagnostics = ProcessInfo.processInfo.environment["AIUTILITY_DIAGNOSTICS"] == "1"
/// Appends one "DIAG" line to the file named by AIUTILITY_DIAG_REPORT (the diagnostics script prints it);
/// test sources do not log to stdout (scripts/check_repository.py).
private func report(_ line: String) {
    guard let path = ProcessInfo.processInfo.environment["AIUTILITY_DIAG_REPORT"], !path.isEmpty else { return }
    let data = Data(("DIAG " + line + "\n").utf8), url = URL(fileURLWithPath: path)
    if let handle = try? FileHandle(forWritingTo: url) {
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
    } else { try? data.write(to: url) }
}

private func pngWithText(width: Int, height: Int, lines: [(String, CGFloat)], size: CGFloat = 80) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
    for (text, y) in lines {
        context.textPosition = CGPoint(x: 40, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
    }
    return try #require(context.makeImage())
}

private func encoded(_ image: CGImage, orientation: Int? = nil) throws -> Data {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
    CGImageDestinationAddImage(destination, image, properties)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func helloImage() throws -> Data { try encoded(try pngWithText(width: 1200, height: 240, lines: [("HELLO AIUTILITY", 80)])) }

/// Through the app's service (automatic language detection is on whenever more than one language is given).
private func runService(_ name: String, _ languages: [String]) async throws {
    let started = Date()
    report("vision-\(name): start \(languages)")
    do {
        let result = try await VisionOCRService().recognize(imageData: try helloImage(), languages: languages, region: nil)
        report(String(format: "vision-\(name): ok in %.1f s, text=%@", Date().timeIntervalSince(started), result.text))
    } catch { report(String(format: "vision-\(name): error %@ after %.1f s", "\(error)", Date().timeIntervalSince(started))) }
}

/// Directly on Vision with automatic detection off, to separate "more languages" from "language detection".
private func runDirect(_ name: String, _ languages: [String]) throws {
    let started = Date()
    report("vision-\(name): start \(languages) (no automatic detection)")
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = languages
    request.automaticallyDetectsLanguage = false
    report("vision-\(name): supported = \(((try? request.supportedRecognitionLanguages()) ?? []).joined(separator: ","))")
    try VNImageRequestHandler(cgImage: try pngWithText(width: 1200, height: 240, lines: [("HELLO AIUTILITY", 80)]), options: [:])
        .perform([request])
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    report(String(format: "vision-\(name): ok in %.1f s, text=%@", Date().timeIntervalSince(started), text))
}

@Test(.enabled(if: diagnostics)) func diagVision1English() async throws { try await runService("1-en", ["en-US"]) }
@Test(.enabled(if: diagnostics)) func diagVision2EnglishJapanese() async throws { try await runService("2-en-ja", ["en-US", "ja-JP"]) }
@Test(.enabled(if: diagnostics)) func diagVision3EnglishChinese() async throws { try await runService("3-en-zh", ["en-US", "zh-Hans"]) }
@Test(.enabled(if: diagnostics)) func diagVision4EnglishKorean() async throws { try await runService("4-en-ko", ["en-US", "ko-KR"]) }
@Test(.enabled(if: diagnostics)) func diagVision5AllFour() async throws {
    try await runService("5-all", SupportedLanguage.allCases.map(\.visionLanguageIdentifier))
}
@Test(.enabled(if: diagnostics)) func diagVision6AllFourNoDetection() throws {
    try runDirect("6-all-direct", SupportedLanguage.allCases.map(\.visionLanguageIdentifier))
}
@Test(.enabled(if: diagnostics)) func diagVision7OldDefaultThree() async throws {
    try await runService("7-old-default", ["en-US", "ja-JP", "zh-Hans"])
}

@Test(.enabled(if: diagnostics)) func diagVision8TallImageScaled() async throws {
    let data = try encoded(try pngWithText(width: 1200, height: 17_000, lines: [("HELLO AIUTILITY", 16_500)], size: 120))
    let started = Date()
    report("vision-8-tall: start 1200x17000")
    do {
        let result = try await VisionOCRService().recognize(imageData: data, languages: ["en-US"])
        report(String(format: "vision-8-tall: ok in %.1f s, text=%@", Date().timeIntervalSince(started), result.text))
    } catch { report(String(format: "vision-8-tall: error %@ after %.1f s", "\(error)", Date().timeIntervalSince(started))) }
}

@Test(.enabled(if: diagnostics)) func diagVision9OrientedImageRegion() async throws {
    // Displayed upright (what the user frames in the app): "TOP SELECTED" above "BOTTOM EXCLUDED". Stored rotated
    // with EXIF orientation 6, as a camera photo would be. The region is the top half of the upright image, in
    // Vision's bottom-left coordinates. Reports whether Vision applies the orientation for data input.
    let upright = try pngWithText(width: 1200, height: 600, lines: [("TOP SELECTED", 420), ("BOTTOM EXCLUDED", 80)], size: 72)
    let stored = try #require(CGContext(data: nil, width: 600, height: 1200, bitsPerComponent: 8, bytesPerRow: 2400,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    // Orientation 6 means "rotate 90° clockwise to display": store the upright image turned 90° counter-clockwise.
    stored.translateBy(x: 600, y: 0); stored.rotate(by: .pi / 2)
    stored.draw(upright, in: CGRect(x: 0, y: 0, width: 1200, height: 600))
    let data = try encoded(try #require(stored.makeImage()), orientation: 6)
    let region = try OCRRegion(x: 0, y: 0.5, width: 1, height: 0.5)
    let full = try await VisionOCRService().recognize(imageData: data, languages: ["en-US"])
    let part = try await VisionOCRService().recognize(imageData: data, languages: ["en-US"], region: region)
    report("vision-9-orientation: full=\(full.text.replacingOccurrences(of: "\n", with: " | ")) region-top=\(part.text.replacingOccurrences(of: "\n", with: " | "))")
}
#endif
