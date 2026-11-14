import Foundation
import Testing
@testable import AIUtilityMedia

// Offline samples only: IDs, titles and file names are invented, shaped like the public site APIs.
// No account, cookie or personal data. Live checks are not part of CI.

func siteJSON(_ text: String) -> Data { Data(text.utf8) }
let pixivReferer = "https://www.pixiv.net/"
let bilibiliReferer = "https://www.bilibili.com/"

struct SiteRegistrationTests {
    @Test func sitesAreOffUnlessRequested() async throws {
        let h = try Harness(); defer { try? h.cleanup() }
        await h.env.client.begin()
        await expectError(.unsupportedSource) {
            _ = try await h.env.router.resolve(URL(string: "https://www.pixiv.net/artworks/100000001")!)
        }
    }
    @Test func titlesDropControlAndFormatCharactersInsteadOfFailing() throws {
        #expect(SiteJSON.displayTitle("a\u{200B}b\u{200D}c\td\n") == "abc d")
        #expect(SiteJSON.displayTitle(nil).isEmpty)
        let cleaned = SiteJSON.displayTitle("\u{FEFF}Fixture \u{1F9DC}\u{200D}\u{2640}\u{FE0F} title")
        _ = try MediaItem(id: MediaItemID(source: .pixiv, value: "1"), title: cleaned,
                          variants: [MediaVariant(id: "original", kind: .image, qualityLabel: "Original", fileExtension: "png")])
    }
}
