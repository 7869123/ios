import Foundation
import Testing
@testable import AIUtilityMedia

struct BilibiliResolverTests {
    private let view = """
    {"code":0,"message":"0","data":{"bvid":"BV1xx411c7mD","aid":1,"title":"Sample video",
     "pages":[{"cid":1001,"page":1,"part":"Opening","duration":30},{"cid":1002,"page":2,"part":"Second","duration":40}]}}
    """
    private func playURL(_ cid: Int) -> String {
        "https://api.bilibili.com/x/player/playurl?bvid=BV1xx411c7mD&cid=\(cid)&qn=64&fnval=1&fnver=0&platform=html5"
    }

    @Test func requestedPartResolvesToSingleProgressiveMP4() async throws {
        let h = try Harness(sites: [.bilibili]); defer { try? h.cleanup() }
        await h.env.client.begin()
        await h.transport.setBody("https://api.bilibili.com/x/web-interface/view?bvid=BV1xx411c7mD", data: siteJSON(view))
        await h.transport.setBody(playURL(1002), data: siteJSON("""
        {"code":0,"data":{"quality":64,"format":"mp4720","durl":[{"order":1,"size":123456,
         "url":"https://upos-sz-example.bilivideo.com/upgcxcode/sample.mp4?deadline=1"}]}}
        """))
        let items = try await h.env.router.resolve(URL(string: "https://www.bilibili.com/video/BV1xx411c7mD?p=2")!)
        let item = try #require(items.first)
        #expect(items.count == 1 && item.id.value == "BV1xx411c7mD-p2" && item.title == "Sample video · P2 Second")
        let plan = try await h.env.router.prepare(item: item, variantID: "mp4")
        #expect(plan.components.count == 1 && plan.assembly == .passthrough)
        #expect(plan.components[0].requestURL().host == "upos-sz-example.bilivideo.com")
        #expect(plan.components[0].requestContext().referer == bilibiliReferer)
        #expect(plan.variant.estimatedBytes == 123456)
    }

    @Test func defaultPartIsTheFirstAndAvLinksWork() async throws {
        let h = try Harness(sites: [.bilibili]); defer { try? h.cleanup() }
        await h.env.client.begin()
        await h.transport.setBody("https://api.bilibili.com/x/web-interface/view?aid=170001", data: siteJSON(view))
        let items = try await h.env.router.resolve(URL(string: "https://www.bilibili.com/video/av170001")!)
        #expect(items.first?.id.value == "BV1xx411c7mD-p1")
    }

    @Test func restrictionsAreReportedNotBypassed() async throws {
        let h = try Harness(sites: [.bilibili]); defer { try? h.cleanup() }
        await h.env.client.begin()
        await h.transport.setBody("https://api.bilibili.com/x/web-interface/view?bvid=BV1xx411c7mD", data: siteJSON(view))
        await h.transport.setBody(playURL(1001), data: siteJSON("""
        {"code":0,"data":{"is_preview":1,"durl":[{"url":"https://upos-sz-example.bilivideo.com/preview.mp4","size":10}]}}
        """))
        await h.transport.setBody(playURL(1002), data: siteJSON("""
        {"code":-10403,"message":"region"}
        """))
        let one = try await h.env.router.resolve(URL(string: "https://www.bilibili.com/video/BV1xx411c7mD")!)
        await expectError(.accessRestricted(.payment)) { _ = try await h.env.router.prepare(item: one[0], variantID: "mp4") }
        let two = try await h.env.router.resolve(URL(string: "https://www.bilibili.com/video/BV1xx411c7mD?p=2")!)
        await expectError(.accessRestricted(.region)) { _ = try await h.env.router.prepare(item: two[0], variantID: "mp4") }
        await expectError(.notFound) { _ = try await h.env.router.resolve(URL(string: "https://www.bilibili.com/video/BV1xx411c7mD?p=9")!) }
    }

    @Test func apiCodesAndSegmentedOrForeignStreamsFailClearly() async throws {
        #expect(BilibiliResolver.error(for: -404) == .notFound)
        #expect(BilibiliResolver.error(for: 62012) == .accessRestricted(.permission))
        #expect(BilibiliResolver.error(for: -412) == .rateLimited(retryAfter: nil))
        #expect(BilibiliResolver.error(for: 12345) == .parsingChanged)
        let h = try Harness(sites: [.bilibili]); defer { try? h.cleanup() }
        await h.env.client.begin()
        await h.transport.setBody("https://api.bilibili.com/x/web-interface/view?bvid=BV1xx411c7mD", data: siteJSON(view))
        await h.transport.setBody(playURL(1001), data: siteJSON("""
        {"code":0,"data":{"durl":[{"url":"https://upos-sz-example.bilivideo.com/1.mp4"},{"url":"https://upos-sz-example.bilivideo.com/2.mp4"}]}}
        """))
        await h.transport.setBody(playURL(1002), data: siteJSON("""
        {"code":0,"data":{"durl":[{"url":"https://elsewhere.example.org/1.mp4"}]}}
        """))
        let one = try await h.env.router.resolve(URL(string: "https://www.bilibili.com/video/BV1xx411c7mD")!)
        await expectError(.unsupportedFormat) { _ = try await h.env.router.prepare(item: one[0], variantID: "mp4") }
        let two = try await h.env.router.resolve(URL(string: "https://www.bilibili.com/video/BV1xx411c7mD?p=2")!)
        await expectError(.parsingChanged) { _ = try await h.env.router.prepare(item: two[0], variantID: "mp4") }
    }

    @Test func allPartsStaysUnsupported() async throws {
        let h = try Harness(sites: [.bilibili]); defer { try? h.cleanup() }
        await h.env.client.begin()
        await h.transport.setBody("https://api.bilibili.com/x/web-interface/view?bvid=BV1xx411c7mD", data: siteJSON(view))
        let items = try await h.env.router.resolve(URL(string: "https://www.bilibili.com/video/BV1xx411c7mD")!)
        await expectError(.unsupportedFormat) {
            _ = try await h.env.router.prepare(item: items[0], variantID: "mp4", options: SiteOptions(bilibili: .init(allParts: true)))
        }
    }

    @Test func videoIDParsing() {
        #expect(BilibiliResolver.videoID(URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!) == .bvid("BV1xx411c7mD"))
        #expect(BilibiliResolver.videoID(URL(string: "https://m.bilibili.com/video/av42")!) == .aid("42"))
        #expect(BilibiliResolver.videoID(URL(string: "https://www.bilibili.com/video/BVshort")!) == nil)
        #expect(BilibiliResolver.requestedPart(URL(string: "https://www.bilibili.com/video/BV1xx411c7mD?p=3")!) == 3)
        #expect(BilibiliResolver.requestedPart(URL(string: "https://www.bilibili.com/video/BV1xx411c7mD?p=0")!) == 1)
    }
}
