import Foundation
import Testing
@testable import AIUtilityMedia

struct RoutingTests {
    @Test func exactHostAndPathRouting() {
        let router = LinkRouter(resolvers: [])
        #expect(router.source(for: URL(string: "https://www.bilibili.com/video/BVfixture?p=2")!) == .bilibili)
        #expect(router.source(for: URL(string: "https://b23.tv/fixture")!) == .bilibili)
        #expect(router.source(for: URL(string: "https://x.com/example/status/123")!) == .x)
        #expect(router.source(for: URL(string: "https://t.co/fixture")!) == .x)
        #expect(router.source(for: URL(string: "https://www.pixiv.net/artworks/123")!) == .pixiv)
        #expect(router.source(for: URL(string: "https://x.com.example.org/example/status/123")!) == .direct)
        #expect(router.source(for: URL(string: "https://www.pixiv.net/users/123")!) == .direct)
        #expect(router.source(for: URL(string: "file:///example.png")!) == nil)
    }
    @Test func unsafeDestinationsRejectedWithoutNetwork() throws {
        for text in ["http://example.org/video", "https://localhost/file", "https://127.0.0.1/file",
                     "https://10.0.0.1/file", "https://172.20.0.1/file", "https://192.168.0.1/file",
                     "https://[::1]/file", "https://[::ffff:127.0.0.1]/file", "https://user@example.org/file",
                     "https://example.org:8080/file"] {
            #expect(throws: MediaError.invalidURL) { try URLSafety.validate(URL(string: text)!) }
        }
        #expect(URLSafety.publicAddress("8.8.8.8"))
        #expect(!URLSafety.publicAddress("100.64.0.1"))
        #expect(URLSafety.publicAddress("2001:4860:4860::8888"))
    }
    @Test func canonicalIdentityPreservesSemanticQuery() throws {
        #expect(try URLSafety.canonical(URL(string: "https://EXAMPLE.org:443/file?p=2#fragment")!) == "https://example.org/file?p=2")
        #expect(try URLSafety.canonical(URL(string: "https://example.org/file?p=1")!) != URLSafety.canonical(URL(string: "https://example.org/file?p=2")!))
        #expect(StableDigest.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(StableDigest.hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
    @Test func shortLinkReroutesAfterBoundedRedirect() async throws {
        let h = try Harness(resolvers: [FixtureResolver(.bilibili)]); defer { try? h.cleanup() }
        await h.transport.setHeader(path: "/short", status: 302, headers: ["location": "https://www.bilibili.com/video/BVfixture"])
        await h.env.client.begin()
        let items = try await h.env.router.resolve(URL(string: "https://b23.tv/short")!)
        #expect(items.first?.id.source == .bilibili)
        #expect(await h.transport.counts().heads == 2)
    }
    @Test func redirectToPrivateOrCycleIsRejected() async throws {
        let h = try Harness(); defer { try? h.cleanup() }
        await h.transport.setHeader(path: "/private", status: 302, headers: ["location": "https://127.0.0.1/file"])
        await h.env.client.begin()
        await expectError(.invalidURL) { _ = try await h.env.client.headers(URL(string: "https://media.example.org/private")!) }
        await h.transport.setHeader(path: "/loop", status: 302, headers: ["location": "/loop"])
        await expectError(.invalidURL) { _ = try await h.env.client.headers(URL(string: "https://media.example.org/loop")!) }
    }
    @Test func htmlAndUnavailableSitesDoNotBecomeMedia() async throws {
        let h = try Harness(); defer { try? h.cleanup() }
        await h.transport.setHeader(path: "/page", status: 200, headers: ["content-type": "text/html"])
        let manager = try h.manager()
        let page = try await manager.enqueue(link: URL(string: "https://media.example.org/page")!)
        #expect(try await waitFor(manager, id: page.id) == .failed(.unsupportedSource))
        let site = try await manager.enqueue(link: URL(string: "https://x.com/example/status/123")!)
        #expect(try await waitFor(manager, id: site.id) == .failed(.unsupportedSource))
        #expect(await manager.capabilities().sources == [.direct])
        #expect(await h.transport.counts().downloads == 0)
        try await manager.shutdown()
    }
    @Test func optionsDecodeMissingFieldsAndRoundTrip() throws {
        let defaults = try JSONDecoder().decode(SiteOptions.self, from: Data("{}".utf8))
        #expect(defaults == SiteOptions())
        let value = SiteOptions(bilibili: .init(allParts: true), pixiv: .init(keepUgoiraArchive: true))
        #expect(try JSONDecoder().decode(SiteOptions.self, from: JSONEncoder().encode(value)) == value)
        #expect(value.effective(source: .x) == SiteOptions())
        #expect(value.effective(source: .pixiv).pixiv.keepUgoiraArchive == false)
        #expect(value.effective(source: .pixiv, ugoira: true).pixiv.keepUgoiraArchive)
    }
    @Test func selectionAndOptionsAreOrthogonalAndAssemblyUsesEffectiveOption() async throws {
        let resolver = FixtureResolver(.pixiv, ugoira: true), router = LinkRouter(resolvers: [resolver])
        let items = try await resolver.resolve(URL(string: "https://www.pixiv.net/artworks/123")!)
        let item = try #require(items.first)
        let options = SiteOptions(bilibili: .init(allParts: true), pixiv: .init(keepUgoiraArchive: true))
        let plan = try await router.prepare(item: item, variantID: "original", options: options)
        #expect(plan.assembly == .ugoiraToGIF(keepOriginalArchive: true))
        #expect(!plan.effectiveOptions.bilibili.allParts)
        #expect(plan.effectiveOptions.pixiv.keepUgoiraArchive)
        let selection = MediaSelection.variant(itemID: item.id, variantID: "original")
        #expect(try JSONDecoder().decode(MediaSelection.self, from: JSONEncoder().encode(selection)) == selection)
    }
    @Test func unsupportedAllPartsFailsEvenWithSpecifiedVariant() async throws {
        let resolver = FixtureResolver(.bilibili), router = LinkRouter(resolvers: [resolver])
        let items = try await resolver.resolve(URL(string: "https://www.bilibili.com/video/BVfixture")!)
        let item = try #require(items.first)
        await expectError(.unsupportedFormat) {
            _ = try await router.prepare(item: item, variantID: "original", options: SiteOptions(bilibili: .init(allParts: true)))
        }
    }
    @Test func statusClassificationAndRetryRules() {
        #expect(DownloadManager.retryDelay(.requiresLogin, retry: 0) == nil)
        #expect(DownloadManager.retryDelay(.accessRestricted(.permission), retry: 0) == nil)
        #expect(DownloadManager.retryDelay(.cancelled, retry: 0) == nil)
        #expect(DownloadManager.retryDelay(.network, retry: 0) == 1)
        #expect(DownloadManager.retryDelay(.network, retry: 1) == 2)
        #expect(DownloadManager.retryDelay(.rateLimited(retryAfter: 15), retry: 0) == 15)
        #expect(NetworkClient.retryAfter("nan") == nil)
        #expect(NetworkClient.retryAfter("-1") == nil)
        #expect(NetworkClient.retryAfter("7") == 7)
    }
}
