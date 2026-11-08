import Foundation
import Testing
@testable import AIUtilityMedia

struct PixivResolverTests {
    @Test func singleIllustrationResolvesToOriginalWithReferer() async throws {
        let h = try Harness(sites: [.pixiv]); defer { try? h.cleanup() }
        await h.env.client.begin()
        await h.transport.setBody("https://www.pixiv.net/ajax/illust/100000001", data: siteJSON("""
        {"error":false,"message":"","body":{"illustId":"100000001","illustTitle":"Sample artwork","illustType":0,
         "xRestrict":0,"pageCount":1,"width":1200,"height":800,
         "urls":{"original":"https://i.pximg.net/img-original/img/2024/01/01/00/00/00/100000001_p0.png"}}}
        """))
        let items = try await h.env.router.resolve(URL(string: "https://www.pixiv.net/artworks/100000001")!)
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.title == "Sample artwork" && item.variants.first?.fileExtension == "png")
        #expect(item.variants.first?.width == 1200)
        let plan = try await h.env.router.prepare(item: item, variantID: "original")
        #expect(plan.components.first?.requestURL().absoluteString
                == "https://i.pximg.net/img-original/img/2024/01/01/00/00/00/100000001_p0.png")
        #expect(plan.components.first?.requestContext().referer == pixivReferer)
        #expect(plan.assembly == .passthrough)
        #expect(await h.transport.sentReferers() == [pixivReferer])
    }

    @Test func multiPageWorkGivesOneItemPerPageInOrder() async throws {
        let h = try Harness(sites: [.pixiv]); defer { try? h.cleanup() }
        await h.env.client.begin()
        await h.transport.setBody("https://www.pixiv.net/ajax/illust/100000002", data: siteJSON("""
        {"error":false,"body":{"illustId":"100000002","illustTitle":"Pages","illustType":1,"xRestrict":0,"pageCount":2,
         "urls":{"original":"https://i.pximg.net/img-original/img/2024/01/01/00/00/00/100000002_p0.jpg"}}}
        """))
        await h.transport.setBody("https://www.pixiv.net/ajax/illust/100000002/pages", data: siteJSON("""
        {"error":false,"body":[
         {"urls":{"original":"https://i.pximg.net/img-original/img/2024/01/01/00/00/00/100000002_p0.jpg"},"width":10,"height":20},
         {"urls":{"original":"https://i.pximg.net/img-original/img/2024/01/01/00/00/00/100000002_p1.png"},"width":30,"height":40}]}
        """))
        let items = try await h.env.router.resolve(URL(string: "https://www.pixiv.net/artworks/100000002")!)
        #expect(items.map(\.id.value) == ["100000002-p0", "100000002-p1"])
        #expect(items.map(\.title) == ["Pages (1/2)", "Pages (2/2)"])
        #expect(items.map { $0.variants[0].fileExtension } == ["jpg", "png"])
        let second = try await h.env.router.prepare(item: items[1], variantID: "original")
        #expect(second.components[0].requestURL().lastPathComponent == "100000002_p1.png")
    }

    @Test func restrictedOrHiddenWorksNeedLoginAndAreNotWorkedAround() async throws {
        let h = try Harness(sites: [.pixiv]); defer { try? h.cleanup() }
        await h.env.client.begin()
        await h.transport.setBody("https://www.pixiv.net/ajax/illust/100000003", data: siteJSON("""
        {"error":false,"body":{"illustId":"100000003","illustTitle":"R","illustType":0,"xRestrict":1,"pageCount":1,"urls":{"original":null}}}
        """))
        await h.transport.setBody("https://www.pixiv.net/ajax/illust/100000004", data: siteJSON("""
        {"error":false,"body":{"illustId":"100000004","illustTitle":"Hidden","illustType":0,"xRestrict":0,"pageCount":1,"urls":{"original":null}}}
        """))
        await h.transport.setBody("https://www.pixiv.net/ajax/illust/100000005", data: siteJSON("""
        {"error":true,"message":"not found","body":[]}
        """))
        await expectError(.requiresLogin) { _ = try await h.env.router.resolve(URL(string: "https://www.pixiv.net/artworks/100000003")!) }
        await expectError(.requiresLogin) { _ = try await h.env.router.resolve(URL(string: "https://www.pixiv.net/artworks/100000004")!) }
        await expectError(.notFound) { _ = try await h.env.router.resolve(URL(string: "https://www.pixiv.net/artworks/100000005")!) }
    }

    @Test func unexpectedHostsAndShapesAreParsingChanges() async throws {
        let h = try Harness(sites: [.pixiv]); defer { try? h.cleanup() }
        await h.env.client.begin()
        await h.transport.setBody("https://www.pixiv.net/ajax/illust/100000006", data: siteJSON("""
        {"error":false,"body":{"illustId":"100000006","illustType":0,"pageCount":1,"urls":{"original":"https://elsewhere.example.org/a.png"}}}
        """))
        await h.transport.setBody("https://www.pixiv.net/ajax/illust/100000007", data: siteJSON("""
        {"unexpected":true}
        """))
        await expectError(.parsingChanged) { _ = try await h.env.router.resolve(URL(string: "https://www.pixiv.net/artworks/100000006")!) }
        await expectError(.parsingChanged) { _ = try await h.env.router.resolve(URL(string: "https://www.pixiv.net/artworks/100000007")!) }
    }

    @Test func ugoiraPlansArchiveWithGIFAssemblyAndManagerRefusesUntilAssemblyExists() async throws {
        let h = try Harness(sites: [.pixiv]); defer { try? h.cleanup() }
        await h.env.client.begin()
        await h.transport.setBody("https://www.pixiv.net/ajax/illust/100000008", data: siteJSON("""
        {"error":false,"body":{"illustId":"100000008","illustTitle":"Motion","illustType":2,"xRestrict":0,"pageCount":1,
         "width":600,"height":600,"urls":{"original":"https://i.pximg.net/img-original/img/2024/01/01/00/00/00/100000008_ugoira0.jpg"}}}
        """))
        await h.transport.setBody("https://www.pixiv.net/ajax/illust/100000008/ugoira_meta", data: siteJSON("""
        {"error":false,"body":{"originalSrc":"https://i.pximg.net/img-zip-ugoira/img/2024/01/01/00/00/00/100000008_ugoira1920x1080.zip",
         "frames":[{"file":"000000.jpg","delay":100},{"file":"000001.jpg","delay":80}]}}
        """))
        let link = URL(string: "https://www.pixiv.net/artworks/100000008")!
        let items = try await h.env.router.resolve(link)
        let variant = try #require(items.first?.variants.first)
        #expect(variant.kind == .ugoira && variant.requiresAssembly && variant.fileExtension == "gif")
        let plan = try await h.env.router.prepare(item: items[0], variantID: "ugoira")
        #expect(plan.assembly == .ugoiraToGIF(keepOriginalArchive: false))
        #expect(plan.components[0].requestURL().pathExtension == "zip")
        let manager = try h.manager(), receipt = try await manager.enqueue(link: link)
        let state = try await waitFor(manager, id: receipt.id)
        if case .failed(let error) = state { #expect(error == .unsupportedPlatform) } else { Issue.record("expected failure, got \(state)") }
        try await manager.shutdown()
    }

    @Test func onlyArtworkPathsAreAccepted() {
        #expect(PixivResolver.artworkID(URL(string: "https://www.pixiv.net/artworks/123")!) == "123")
        #expect(PixivResolver.artworkID(URL(string: "https://www.pixiv.net/artworks/12a")!) == nil)
        #expect(PixivResolver.artworkID(URL(string: "https://www.pixiv.net/tags/123")!) == nil)
    }
}
