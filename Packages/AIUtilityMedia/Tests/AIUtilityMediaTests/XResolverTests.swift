import Foundation
import Testing
@testable import AIUtilityMedia

struct XResolverTests {
    private let id = "1800000000000000001"
    private func endpoint(_ id: String) -> String {
        "https://cdn.syndication.twimg.com/tweet-result?id=\(id)&lang=en&token=\(XResolver.token(for: id)!)"
    }

    @Test func tokenMatchesJavaScriptRadixConversion() {
        // Expected values computed with JavaScript: ((id / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, "").
        #expect(XResolver.radix36(0.5) == "0.i")
        #expect(XResolver.radix36(35) == "z")
        #expect(XResolver.radix36(36) == "10")
        #expect(XResolver.radix36(1.0 / 3.0) == "0.c")
        // Reference values produced by Node.js (V8); a JS port of radix36 matched V8 on 200,000 random IDs.
        let value = Double(id)! / 1e15 * Double.pi   // same rounding as JavaScript Number(id)
        #expect(XResolver.radix36(value) == "4d2.v7cbm2xj")
        #expect(XResolver.token(for: id) == "4d2v7cbm2xj")
    }

    @Test func photosAndVideosResolveToOriginalAndProgressiveVariants() async throws {
        let h = try Harness(sites: [.x]); defer { try? h.cleanup() }
        await h.env.client.begin()
        await h.transport.setBody(endpoint(id), data: siteJSON("""
        {"__typename":"Tweet","id_str":"\(id)","user":{"screen_name":"sample_account"},"mediaDetails":[
         {"type":"photo","media_url_https":"https://pbs.twimg.com/media/SampleName1.jpg","original_info":{"width":1600,"height":900}},
         {"type":"video","media_url_https":"https://pbs.twimg.com/ext_tw_video_thumb/1/pu/img/thumb.jpg","video_info":{"variants":[
           {"content_type":"application/x-mpegURL","url":"https://video.twimg.com/ext_tw_video/1/pu/pl/list.m3u8"},
           {"bitrate":832000,"content_type":"video/mp4","url":"https://video.twimg.com/ext_tw_video/1/pu/vid/640x360/low.mp4"},
           {"bitrate":2176000,"content_type":"video/mp4","url":"https://video.twimg.com/ext_tw_video/1/pu/vid/1280x720/high.mp4"}]}}]}
        """))
        let items = try await h.env.router.resolve(URL(string: "https://x.com/sample_account/status/\(id)?s=20")!)
        #expect(items.map(\.title) == ["@sample_account · 1/2", "@sample_account · 2/2"])
        #expect(items[0].variants.map(\.id) == ["original"] && items[0].variants[0].width == 1600)
        #expect(items[1].variants.map(\.id) == ["mp4-2176000", "mp4-832000"])
        let photo = try await h.env.router.prepare(item: items[0], variantID: "original")
        #expect(photo.components[0].requestURL().absoluteString == "https://pbs.twimg.com/media/SampleName1?format=jpg&name=orig")
        let video = try await h.env.router.prepare(item: items[1], variantID: "mp4-2176000")
        #expect(video.components[0].requestURL().lastPathComponent == "high.mp4")
        #expect(video.components[0].requestContext().referer == nil)
    }

    @Test func tombstonesTextOnlyAndForeignHostsFail() async throws {
        let h = try Harness(sites: [.x]); defer { try? h.cleanup() }
        await h.env.client.begin()
        await h.transport.setBody(endpoint("1800000000000000002"), data: siteJSON("""
        {"__typename":"TweetTombstone","tombstone":{"text":{"text":"unavailable"}}}
        """))
        await h.transport.setBody(endpoint("1800000000000000003"), data: siteJSON("""
        {"__typename":"Tweet","id_str":"1800000000000000003","mediaDetails":[]}
        """))
        await h.transport.setBody(endpoint("1800000000000000004"), data: siteJSON("""
        {"__typename":"Tweet","id_str":"1800000000000000004","mediaDetails":[{"type":"photo","media_url_https":"https://elsewhere.example.org/a.jpg"}]}
        """))
        await expectError(.accessRestricted(.permission)) {
            _ = try await h.env.router.resolve(URL(string: "https://twitter.com/a/status/1800000000000000002")!)
        }
        await expectError(.unsupportedFormat) {
            _ = try await h.env.router.resolve(URL(string: "https://x.com/a/status/1800000000000000003")!)
        }
        await expectError(.parsingChanged) {
            _ = try await h.env.router.resolve(URL(string: "https://x.com/a/status/1800000000000000004")!)
        }
    }

    @Test func statusIDParsing() {
        #expect(XResolver.statusID(URL(string: "https://x.com/a/status/123/photo/1")!) == "123")
        #expect(XResolver.statusID(URL(string: "https://x.com/a/status/abc")!) == nil)
    }
}
