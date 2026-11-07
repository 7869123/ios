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
    let config = try #require(store.load(provider: .openAI))
    #expect(config.key.withValue { $0 == "fake-second" })
    #expect(config.models == [.discordScreenshot: "c", .videoSubtitle: "d"])
    #expect(try store.load(provider: .anthropic)?.models == nil)
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
#endif
