import Foundation
import Testing
import AIUtilityCore
import AIUtilityAppleServices

#if canImport(Security)
@Test(.enabled(if: ProcessInfo.processInfo.environment["AIUTILITY_KEYCHAIN_TESTS"] == "1"))
func keychainReplacesSingleProviderRecordAtomically() throws {
    let store = KeychainCredentialStore(service: "com.aiutility.tests." + UUID().uuidString)
    defer { try? store.remove(provider: .openAI) }
    try store.replace(provider: .openAI, configuration: ProviderConfiguration(key: APIKey("fake-first"),
        models: [.discordScreenshot: "a", .videoSubtitle: "b"]))
    try store.replace(provider: .openAI, configuration: ProviderConfiguration(key: APIKey("fake-second"),
        models: [.discordScreenshot: "c", .videoSubtitle: "d"]))
    let storedConfiguration = try store.load(provider: .openAI)
    let config = try #require(storedConfiguration)
    #expect(config.key.withValue { $0 == "fake-second" })
    #expect(config.models == [.discordScreenshot: "c", .videoSubtitle: "d"])
    #expect(try store.load(provider: .anthropic)?.models == nil)
}
#endif

#if canImport(NaturalLanguage)
@Test func appleTextDetectionUsesRealLocalEngine() async throws {
    let detector = AppleTextLanguageDetector()
    let english = try await detector.detect("This is a long English sentence about reading a book and watching a movie with friends.")
    let japanese = try await detector.detect("今日はとても良い天気ですね。友達と一緒に映画を見に行きたいと思います。")
    let chinese = try await detector.detect("今天的天气非常晴朗，我们准备和朋友一起去公园散步，然后回家阅读一本有趣的书。")
    #expect(english == .english)
    #expect(japanese == .japanese)
    #expect(chinese == .simplifiedChinese)
    let korean = try await detector.detect("오늘은 날씨가 정말 좋아서 친구들과 함께 공원에 가서 산책을 하고 맛있는 음식을 먹었습니다.")
    #expect(korean == .korean)
}
#endif

#if canImport(Vision) && canImport(CoreGraphics)
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

@Test func visionRecognizesGeneratedLocalImage() async throws {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(data: nil, width: 1200, height: 240, bitsPerComponent: 8,
        bytesPerRow: 4800, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 240))
    let font = CTFontCreateWithName("Helvetica" as CFString, 80, nil)
    let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "HELLO AIUTILITY", attributes: attributes))
    context.textPosition = CGPoint(x: 40, y: 80); CTLineDraw(line, context)
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let result = try await VisionOCRService().recognize(imageData: data as Data, languages: ["en-US"])
    #expect(result.text.uppercased().contains("HELLO"))
    #expect(result.lines.allSatisfy { $0.box.width > 0 && $0.confidence > 0 })
}

@Test func visionRejectsInvalidImageLocally() async {
    await #expect(throws: AIUtilityError.invalidRequest) {
        try await VisionOCRService().recognize(imageData: Data("not an image".utf8), languages: ["en-US"])
    }
}

@Test func visionRegionRecognizesOnlyTheSelectedHalf() async throws {
    let context = try #require(CGContext(data: nil, width: 1200, height: 600, bitsPerComponent: 8,
        bytesPerRow: 4800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
    let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 72, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
    for (text, y) in [("TOP SELECTED", 420.0), ("BOTTOM EXCLUDED", 80.0)] {
        context.textPosition = CGPoint(x: 40, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
    }
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let region = try OCRRegion(x: 0, y: 0.5, width: 1, height: 0.5)
    let result = try await VisionOCRService().recognize(imageData: data as Data, languages: ["en-US"], region: region)
    #expect(result.text.uppercased().contains("TOP"))
    #expect(!result.text.uppercased().contains("BOTTOM"))
}

@Test func cancelledVisionNeverReturnsSuccessfulOCR() async {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await VisionOCRService().recognize(imageData: Data([1]), languages: ["en-US"])
    }
    await #expect(throws: AIUtilityError.cancelled) { try await task.value }
}
#endif
