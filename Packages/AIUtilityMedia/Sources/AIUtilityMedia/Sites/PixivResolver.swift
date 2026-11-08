import Foundation

/// Pixiv artworks through the public web API (`/ajax/illust/...`) without an account. Each page is
/// one item with its original image. R-18 / restricted works and works whose originals are hidden
/// from anonymous visitors fail with `.requiresLogin`. Ugoira yields its original frame archive with
/// `.ugoiraToGIF` assembly; until the Apple assembly step is wired the download manager refuses it
/// (`unsupportedPlatform`) instead of delivering a bare archive as the default result.
actor PixivResolver: MediaResolver {
    nonisolated let source = MediaSource.pixiv
    static let referer = "https://www.pixiv.net/"
    static let maxPages = 64
    private let client: NetworkClient
    private var originals: [MediaItemID: URL] = [:]
    init(client: NetworkClient) { self.client = client }

    nonisolated func canResolve(_ url: URL) -> Bool { Self.artworkID(url) != nil }

    static func artworkID(_ url: URL) -> String? {
        guard URLSafety.source(url) == .pixiv else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "artworks" else { return nil }
        return SiteJSON.digits(parts[1], maxLength: 12)
    }

    /// `body` is read leniently: error responses carry an empty array or object there.
    struct Envelope<Body: Decodable & Sendable>: Decodable, Sendable {
        let error: Bool
        let body: Body?
        enum CodingKeys: String, CodingKey { case error, body }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            error = try container.decode(Bool.self, forKey: .error)
            body = error ? nil : try container.decodeIfPresent(Body.self, forKey: .body)
        }
    }
    struct Illust: Decodable, Sendable {
        struct URLs: Decodable, Sendable { let original: String? }
        let illustId: String
        let illustTitle: String?
        let illustType: Int
        let xRestrict: Int?
        let pageCount: Int
        let width: Int?
        let height: Int?
        let urls: URLs?
    }
    struct Page: Decodable, Sendable {
        struct URLs: Decodable, Sendable { let original: String? }
        let urls: URLs
        let width: Int?
        let height: Int?
    }
    struct UgoiraMeta: Decodable, Sendable {
        struct Frame: Decodable, Sendable { let file: String; let delay: Int }
        let originalSrc: String?
        let frames: [Frame]
    }

    func resolve(_ url: URL) async throws(MediaError) -> [MediaItem] {
        originals = [:]
        guard let id = Self.artworkID(url) else { throw .unsupportedSource }
        let context = RequestContext(referer: Self.referer)
        let base = "https://www.pixiv.net/ajax/illust/" + id
        let envelope = try await SiteJSON.fetch(Envelope<Illust>.self, URL(string: base)!, client: client, context: context)
        guard !envelope.error, let illust = envelope.body else { throw .notFound }
        guard illust.illustId == id else { throw .parsingChanged }
        if (illust.xRestrict ?? 0) > 0 { throw .requiresLogin }
        guard illust.pageCount >= 1 else { throw .parsingChanged }
        guard illust.pageCount <= Self.maxPages else { throw .resourceLimitExceeded }
        let title = Self.title(illust.illustTitle, id: id)

        if illust.illustType == 2 {
            let meta = try await SiteJSON.fetch(Envelope<UgoiraMeta>.self, URL(string: base + "/ugoira_meta")!,
                                                client: client, context: context)
            guard !meta.error, let body = meta.body else { throw .requiresLogin }
            guard !body.frames.isEmpty, body.frames.allSatisfy({ $0.delay > 0 }) else { throw .parsingChanged }
            let archive = try SiteJSON.url(body.originalSrc, hosts: Self.isImageHost)
            let itemID = try MediaItemID(source: .pixiv, value: id + "-ugoira")
            let variant = try MediaVariant(id: "ugoira", kind: .ugoira, qualityLabel: "Ugoira → GIF",
                                           width: illust.width.flatMap(Self.positive), height: illust.height.flatMap(Self.positive),
                                           fileExtension: "gif", requiresAssembly: true)
            originals[itemID] = archive
            return [try MediaItem(id: itemID, title: title, variants: [variant])]
        }

        var pages: [(URL, Int?, Int?)] = []
        if illust.pageCount == 1 {
            guard let original = illust.urls?.original else { throw .requiresLogin }
            pages = [(try SiteJSON.url(original, hosts: Self.isImageHost), illust.width, illust.height)]
        } else {
            let list = try await SiteJSON.fetch(Envelope<[Page]>.self, URL(string: base + "/pages")!, client: client, context: context)
            guard !list.error, let body = list.body else { throw .requiresLogin }
            guard body.count == illust.pageCount else { throw .parsingChanged }
            for page in body {
                guard let original = page.urls.original else { throw .requiresLogin }
                pages.append((try SiteJSON.url(original, hosts: Self.isImageHost), page.width, page.height))
            }
        }
        var items: [MediaItem] = []
        for (index, page) in pages.enumerated() {
            let itemID = try MediaItemID(source: .pixiv, value: "\(id)-p\(index)")
            let variant = try MediaVariant(id: "original", kind: .image, qualityLabel: "Original",
                                           width: page.1.flatMap(Self.positive), height: page.2.flatMap(Self.positive),
                                           fileExtension: SiteJSON.fileExtension(of: page.0, fallback: "jpg"))
            let pageTitle = pages.count > 1 ? "\(title) (\(index + 1)/\(pages.count))" : title
            items.append(try MediaItem(id: itemID, title: pageTitle, variants: [variant]))
            originals[itemID] = page.0
        }
        return items
    }

    func prepare(item: MediaItem, variantID: String, options: SiteOptions) async throws(MediaError) -> MediaTransferPlan {
        guard let url = originals[item.id], let variant = item.variants.first(where: { $0.id == variantID }) else {
            throw .invalidSelection
        }
        let component = try MediaComponent(id: variant.kind == .ugoira ? "archive" : "file", url: url,
                                           context: RequestContext(referer: Self.referer))
        if variant.kind == .ugoira {
            return try MediaTransferPlan(itemID: item.id, variant: variant,
                                         effectiveOptions: options.effective(source: .pixiv, ugoira: true), components: [component],
                                         assembly: .ugoiraToGIF(keepOriginalArchive: options.pixiv.keepUgoiraArchive))
        }
        return try MediaTransferPlan(itemID: item.id, variant: variant, effectiveOptions: options.effective(source: .pixiv),
                                     components: [component])
    }

    static func isImageHost(_ host: String) -> Bool { host == "i.pximg.net" }
    static func positive(_ value: Int) -> Int? { value > 0 && value <= 100_000 ? value : nil }
    static func title(_ text: String?, id: String) -> String {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Pixiv \(id)" : trimmed
        return String(base.utf8.count <= 400 ? base : String(base.prefix(120)))
    }
}
