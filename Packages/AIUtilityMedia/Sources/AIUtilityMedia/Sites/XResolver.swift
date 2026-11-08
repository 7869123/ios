import Foundation

/// X (Twitter) posts through the public embed endpoint (`cdn.syndication.twimg.com/tweet-result`), the
/// same anonymous data source used by embedded posts; no account, cookie or API key is used. Its
/// availability is not documented as a stable API (unconfirmed), so any unexpected response is
/// `.parsingChanged`. Posts that are not publicly embeddable (protected, age-restricted, deleted)
/// return a tombstone and fail with `.accessRestricted(.permission)` instead of being worked around.
/// Photos are taken at original size; videos and GIF animations offer their progressive MP4 variants.
actor XResolver: MediaResolver {
    nonisolated let source = MediaSource.x
    static let maxVideoVariants = 6
    private let client: NetworkClient
    private var urls: [MediaItemID: [String: URL]] = [:]
    init(client: NetworkClient) { self.client = client }

    nonisolated func canResolve(_ url: URL) -> Bool { Self.statusID(url) != nil }

    static func statusID(_ url: URL) -> String? {
        guard URLSafety.source(url) == .x, url.host?.lowercased() != "t.co" else { return nil }
        let parts = url.path.split(separator: "/")
        guard let index = parts.firstIndex(of: "status"), index + 1 < parts.count else { return nil }
        return SiteJSON.digits(parts[index + 1], maxLength: 20)
    }

    /// The embed endpoint's `token`: JavaScript `((id / 1e15) * Math.PI).toString(36)` with every
    /// "0" and "." removed. Reproduces V8's shortest radix conversion for the fractional part.
    static func token(for id: String) -> String? {
        guard let number = Double(id), number.isFinite, number > 0 else { return nil }
        return radix36(number / 1e15 * Double.pi).filter { $0 != "0" && $0 != "." }
    }

    static func radix36(_ value: Double) -> String {
        let chars = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var integer = value.rounded(.down)
        var fraction = value - integer
        var delta = max(0.5 * (value.nextUp - value), Double.leastNonzeroMagnitude)
        var digits: [Int] = []
        var hasFraction = false
        if fraction >= delta {
            hasFraction = true
            repeat {
                fraction *= 36; delta *= 36
                let digit = Int(fraction)
                digits.append(digit)
                fraction -= Double(digit)
                if fraction > 0.5 || (fraction == 0.5 && digit & 1 == 1), fraction + delta > 1 {
                    // Round up, carrying into earlier digits and possibly the integer part.
                    while true {
                        guard let last = digits.popLast() else { integer += 1; hasFraction = false; break }
                        if last + 1 < 36 { digits.append(last + 1); break }
                    }
                    break
                }
            } while fraction >= delta
        }
        var integerDigits: [Character] = []
        repeat {
            let remainder = integer.truncatingRemainder(dividingBy: 36)
            integerDigits.insert(chars[Int(remainder)], at: 0)
            integer = (integer - remainder) / 36
        } while integer > 0
        let fractionText = String(digits.map { chars[$0] })
        return String(integerDigits) + (hasFraction && !digits.isEmpty ? "." + fractionText : "")
    }

    struct Tweet: Decodable, Sendable {
        struct User: Decodable, Sendable { let screen_name: String? }
        struct Media: Decodable, Sendable {
            struct Size: Decodable, Sendable { let width: Int?; let height: Int? }
            struct VideoInfo: Decodable, Sendable {
                struct Variant: Decodable, Sendable { let bitrate: Int?; let content_type: String?; let url: String }
                let variants: [Variant]
            }
            let type: String
            let media_url_https: String?
            let original_info: Size?
            let video_info: VideoInfo?
        }
        let __typename: String?
        let id_str: String?
        let user: User?
        let mediaDetails: [Media]?
    }

    func resolve(_ url: URL) async throws(MediaError) -> [MediaItem] {
        urls = [:]
        guard let id = Self.statusID(url), let token = Self.token(for: id) else { throw .unsupportedSource }
        let endpoint = URL(string: "https://cdn.syndication.twimg.com/tweet-result?id=\(id)&lang=en&token=\(token)")!
        let tweet = try await SiteJSON.fetch(Tweet.self, endpoint, client: client, context: .none)
        if tweet.__typename == "TweetTombstone" { throw .accessRestricted(.permission) }
        guard let returned = tweet.id_str else { throw .notFound }
        guard returned == id else { throw .parsingChanged }
        let media = tweet.mediaDetails ?? []
        guard !media.isEmpty else { throw .unsupportedFormat } // A text-only post has nothing to download.
        guard media.count <= 64 else { throw .resourceLimitExceeded }
        let author = tweet.user?.screen_name.flatMap { name in
            name.count <= 50 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } ? "@" + name : nil
        }
        var items: [MediaItem] = []
        for (index, entry) in media.enumerated() {
            let itemID = try MediaItemID(source: .x, value: "\(id)-\(index + 1)")
            let title = (author ?? "X \(id)") + (media.count > 1 ? " · \(index + 1)/\(media.count)" : "")
            var map: [String: URL] = [:]
            var variants: [MediaVariant] = []
            switch entry.type {
            case "photo":
                let original = try Self.originalPhoto(entry.media_url_https)
                variants.append(try MediaVariant(id: "original", kind: .image, qualityLabel: "Original",
                                                 width: entry.original_info?.width.flatMap(Self.positive),
                                                 height: entry.original_info?.height.flatMap(Self.positive),
                                                 fileExtension: original.ext))
                map["original"] = original.url
            case "video", "animated_gif":
                let mp4 = (entry.video_info?.variants ?? [])
                    .filter { $0.content_type == "video/mp4" }
                    .sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }
                guard !mp4.isEmpty else { throw .unsupportedFormat }
                for candidate in mp4.prefix(Self.maxVideoVariants) {
                    let link = try SiteJSON.url(candidate.url, hosts: { $0 == "video.twimg.com" })
                    let bitrate = candidate.bitrate ?? 0
                    let variantID = "mp4-\(bitrate)"
                    guard map[variantID] == nil else { continue }
                    variants.append(try MediaVariant(id: variantID, kind: .video,
                                                     qualityLabel: bitrate > 0 ? "MP4 \(bitrate / 1000) kbps" : "MP4",
                                                     fileExtension: "mp4"))
                    map[variantID] = link
                }
            default:
                throw .unsupportedFormat
            }
            urls[itemID] = map
            items.append(try MediaItem(id: itemID, title: title, variants: variants))
        }
        return items
    }

    func prepare(item: MediaItem, variantID: String, options: SiteOptions) async throws(MediaError) -> MediaTransferPlan {
        guard let url = urls[item.id]?[variantID], let variant = item.variants.first(where: { $0.id == variantID }) else {
            throw .invalidSelection
        }
        return try MediaTransferPlan(itemID: item.id, variant: variant, effectiveOptions: options.effective(source: .x),
                                     components: [try MediaComponent(id: "file", url: url)])
    }

    /// `https://pbs.twimg.com/media/NAME.jpg` → `https://pbs.twimg.com/media/NAME?format=jpg&name=orig`.
    static func originalPhoto(_ string: String?) throws(MediaError) -> (url: URL, ext: String) {
        let url = try SiteJSON.url(string, hosts: { $0 == "pbs.twimg.com" })
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "media" else { throw .parsingChanged }
        let file = parts[1]
        guard let dot = file.lastIndex(of: ".") else { throw .parsingChanged }
        let name = file[..<dot], ext = file[file.index(after: dot)...].lowercased()
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              ["jpg", "png", "webp"].contains(ext),
              let original = URL(string: "https://pbs.twimg.com/media/\(name)?format=\(ext)&name=orig") else {
            throw .parsingChanged
        }
        return (original, ext)
    }

    static func positive(_ value: Int) -> Int? { value > 0 && value <= 100_000 ? value : nil }
}
