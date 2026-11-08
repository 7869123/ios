import Foundation

/// Bilibili videos through the public web API without an account. One part (分 P) per link: `?p=N`
/// or the first part. The download is the single progressive MP4 the public player API offers to
/// anonymous visitors (`fnval=1`, usually up to 480p/720p), so no audio/video assembly is needed.
/// Higher qualities, paid, member-only, region-locked or hidden videos are not worked around: they
/// fail with `.requiresLogin` / `.accessRestricted(...)` / `.notFound`.
actor BilibiliResolver: MediaResolver {
    nonisolated let source = MediaSource.bilibili
    static let referer = "https://www.bilibili.com/"
    private let client: NetworkClient
    private var parts: [MediaItemID: (bvid: String, cid: Int)] = [:]
    init(client: NetworkClient) { self.client = client }

    enum VideoID: Equatable { case bvid(String), aid(String) }

    nonisolated func canResolve(_ url: URL) -> Bool { Self.videoID(url) != nil }

    static func videoID(_ url: URL) -> VideoID? {
        guard URLSafety.source(url) == .bilibili, url.host?.lowercased() != "b23.tv" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "video" else { return nil }
        let value = parts[1]
        if value.hasPrefix("BV"), value.count == 12, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            return .bvid(String(value))
        }
        if value.lowercased().hasPrefix("av"), let digits = SiteJSON.digits(value.dropFirst(2), maxLength: 19) {
            return .aid(digits)
        }
        return nil
    }

    static func requestedPart(_ url: URL) -> Int {
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "p" })?.value
        return value.flatMap(Int.init).flatMap { (1...1000).contains($0) ? $0 : nil } ?? 1
    }

    /// `data` is only decoded for code 0; error responses may carry null or unrelated objects.
    struct Envelope<Body: Decodable & Sendable>: Decodable, Sendable {
        let code: Int
        let data: Body?
        enum CodingKeys: String, CodingKey { case code, data }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try container.decode(Int.self, forKey: .code)
            data = code == 0 ? try container.decodeIfPresent(Body.self, forKey: .data) : nil
        }
    }
    struct View: Decodable, Sendable {
        struct Part: Decodable, Sendable { let cid: Int; let page: Int; let part: String?; let duration: Int? }
        let bvid: String
        let title: String?
        let pages: [Part]
    }
    struct PlayURL: Decodable, Sendable {
        struct Segment: Decodable, Sendable { let url: String; let size: Int64? }
        let durl: [Segment]?
        let is_preview: Int?
    }

    /// Public API codes (anything else is treated as a changed format, never as success).
    static func error(for code: Int) -> MediaError {
        switch code {
        case -404, 62002, 62004: .notFound
        case -403, 62012: .accessRestricted(.permission)
        case -10403: .accessRestricted(.region)
        case -101: .requiresLogin
        case -412, -509, -799: .rateLimited(retryAfter: nil)
        case -400: .invalidURL
        default: .parsingChanged
        }
    }

    func resolve(_ url: URL) async throws(MediaError) -> [MediaItem] {
        parts = [:]
        guard let id = Self.videoID(url) else { throw .unsupportedSource }
        let query: String
        switch id {
        case .bvid(let value): query = "bvid=" + value
        case .aid(let value): query = "aid=" + value
        }
        let view = try await SiteJSON.fetch(Envelope<View>.self,
                                            URL(string: "https://api.bilibili.com/x/web-interface/view?" + query)!,
                                            client: client, context: RequestContext(referer: Self.referer))
        guard view.code == 0 else { throw Self.error(for: view.code) }
        guard let data = view.data, !data.pages.isEmpty, data.bvid.hasPrefix("BV"), data.bvid.count == 12 else {
            throw .parsingChanged
        }
        if case .bvid(let value) = id, value != data.bvid { throw .parsingChanged }
        let wanted = Self.requestedPart(url)
        guard let part = data.pages.first(where: { $0.page == wanted }) else { throw .notFound }
        guard part.cid > 0 else { throw .parsingChanged }
        let itemID = try MediaItemID(source: .bilibili, value: "\(data.bvid)-p\(part.page)")
        let variant = try MediaVariant(id: "mp4", kind: .video, qualityLabel: "MP4", fileExtension: "mp4")
        var title = (data.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = data.bvid }
        if data.pages.count > 1, let name = part.part?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            title += " · P\(part.page) " + name
        }
        if title.utf8.count > 480 { title = String(title.prefix(120)) }
        parts[itemID] = (data.bvid, part.cid)
        return [try MediaItem(id: itemID, title: title, variants: [variant])]
    }

    func prepare(item: MediaItem, variantID: String, options: SiteOptions) async throws(MediaError) -> MediaTransferPlan {
        guard let part = parts[item.id], let variant = item.variants.first(where: { $0.id == variantID }), variant.id == "mp4" else {
            throw .invalidSelection
        }
        let url = URL(string: "https://api.bilibili.com/x/player/playurl?bvid=\(part.bvid)&cid=\(part.cid)&qn=64&fnval=1&fnver=0&platform=html5")!
        let play = try await SiteJSON.fetch(Envelope<PlayURL>.self, url, client: client, context: RequestContext(referer: Self.referer))
        guard play.code == 0 else { throw Self.error(for: play.code) }
        guard let data = play.data else { throw .parsingChanged }
        // A preview means the full video needs payment or membership.
        if (data.is_preview ?? 0) != 0 { throw .accessRestricted(.payment) }
        guard let segments = data.durl, !segments.isEmpty else { throw .parsingChanged }
        // Several segments would need joining; not supported rather than delivering a partial video.
        guard segments.count == 1 else { throw .unsupportedFormat }
        let media = try SiteJSON.url(segments[0].url, hosts: Self.isVideoHost)
        let sized = try MediaVariant(id: variant.id, kind: .video, qualityLabel: variant.qualityLabel,
                                     estimatedBytes: segments[0].size.flatMap { $0 > 0 ? $0 : nil }, fileExtension: "mp4")
        // The plan carries the size the player API reported, for the free-space check.
        return try MediaTransferPlan(itemID: item.id, variant: sized, effectiveOptions: options.effective(source: .bilibili),
                                     components: [try MediaComponent(id: "file", url: media, context: RequestContext(referer: Self.referer))])
    }

    static func isVideoHost(_ host: String) -> Bool {
        host.hasSuffix(".bilivideo.com") || host.hasSuffix(".bilivideo.cn") || host.hasSuffix(".hdslb.com")
    }
}
