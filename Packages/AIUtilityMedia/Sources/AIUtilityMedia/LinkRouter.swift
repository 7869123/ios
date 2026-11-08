import Foundation

public protocol MediaResolver: Sendable {
    var source: MediaSource { get }
    func canResolve(_ url: URL) -> Bool
    func resolve(_ url: URL) async throws(MediaError) -> [MediaItem]
    func prepare(item: MediaItem, variantID: String, options: SiteOptions) async throws(MediaError) -> MediaTransferPlan
}

public struct LinkRouter: Sendable {
    private let resolvers: [any MediaResolver]
    private let client: NetworkClient?
    public init(resolvers: [any MediaResolver]) { self.resolvers = resolvers; client = nil }
    init(resolvers: [any MediaResolver], client: NetworkClient) { self.resolvers = resolvers; self.client = client }
    public func source(for url: URL) -> MediaSource? { URLSafety.source(url) }
    public func resolve(_ url: URL) async throws(MediaError) -> [MediaItem] {
        do {
            try Task.checkCancellation(); try URLSafety.validate(url)
            var target = url
            if ["b23.tv", "t.co"].contains(url.host?.lowercased() ?? ""), let client {
                target = try await client.headers(url).finalURL
            }
            guard let source = source(for: target),
                  let resolver = resolvers.first(where: { $0.source == source && $0.canResolve(target) }) else { throw MediaError.unsupportedSource }
            let items = try await resolver.resolve(target)
            try Task.checkCancellation()
            guard !items.isEmpty, items.count <= 64, items.allSatisfy({ $0.id.source == source && !$0.variants.isEmpty }) else {
                throw MediaError.parsingChanged
            }
            return items
        } catch { throw MediaError.safe(error) }
    }
    public func prepare(item: MediaItem, variantID: String, options: SiteOptions = .init()) async throws(MediaError) -> MediaTransferPlan {
        do {
            try Task.checkCancellation()
            guard item.variants.contains(where: { $0.id == variantID }),
                  let resolver = resolvers.first(where: { $0.source == item.id.source }) else { throw MediaError.invalidSelection }
            if item.id.source == .bilibili && options.bilibili.allParts { throw MediaError.unsupportedFormat }
            let plan = try await resolver.prepare(item: item, variantID: variantID, options: options)
            try Task.checkCancellation()
            guard plan.itemID == item.id, plan.variant.id == variantID,
                  plan.effectiveOptions == options.effective(source: item.id.source, ugoira: plan.variant.kind == .ugoira) else {
                throw MediaError.invalidSelection
            }
            return plan
        } catch { throw MediaError.safe(error) }
    }
}

actor DirectMediaResolver: MediaResolver {
    nonisolated let source = MediaSource.direct
    private let client: NetworkClient
    private var current: (MediaItemID, URL)?
    init(client: NetworkClient) { self.client = client }
    nonisolated func canResolve(_ url: URL) -> Bool { URLSafety.source(url) == .direct }
    func resolve(_ url: URL) async throws(MediaError) -> [MediaItem] {
        do {
            current = nil
            let response = try await client.headers(url)
            guard URLSafety.source(response.finalURL) == .direct,
                  let format = MediaFormat.from(response.header("content-type")) else { throw MediaError.unsupportedSource }
            let id = try MediaItemID(source: .direct, value: StableDigest.hex(try URLSafety.canonical(response.finalURL)))
            let variant = try MediaVariant(id: "original", kind: format.kind, qualityLabel: "Original",
                                           estimatedBytes: response.header("content-length").flatMap(Int64.init).flatMap { $0 > 0 ? $0 : nil },
                                           fileExtension: format.ext)
            let item = try MediaItem(id: id, title: "Media download", variants: [variant])
            current = (id, response.finalURL)
            return [item]
        } catch { throw MediaError.safe(error) }
    }
    func prepare(item: MediaItem, variantID: String, options: SiteOptions) async throws(MediaError) -> MediaTransferPlan {
        guard let current, current.0 == item.id, let variant = item.variants.first(where: { $0.id == variantID }),
              variant.id == "original", !variant.requiresAssembly else { throw .invalidSelection }
        let plan = try MediaTransferPlan(itemID: item.id, variant: variant, components: [try MediaComponent(id: "file", url: current.1)])
        self.current = nil
        return plan
    }
}

enum MediaFormat: Equatable {
    case jpeg, png, gif, webp, mp4, mov, webm, mp3, wav, ogg
    static func from(_ value: String?) -> MediaFormat? {
        switch value?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "image/jpeg": .jpeg
        case "image/png": .png
        case "image/gif": .gif
        case "image/webp": .webp
        case "video/mp4": .mp4
        case "video/quicktime": .mov
        case "video/webm": .webm
        case "audio/mpeg": .mp3
        case "audio/wav", "audio/x-wav": .wav
        case "audio/ogg": .ogg
        default: nil
        }
    }
    var ext: String {
        switch self { case .jpeg: "jpg"; case .png: "png"; case .gif: "gif"; case .webp: "webp"; case .mp4: "mp4"
        case .mov: "mov"; case .webm: "webm"; case .mp3: "mp3"; case .wav: "wav"; case .ogg: "ogg" }
    }
    var kind: MediaVariant.Kind {
        switch self { case .jpeg, .png, .gif, .webp: .image; case .mp4, .mov, .webm: .video; default: .audio }
    }
    func matches(_ data: Data) -> Bool {
        let b = Array(data)
        func text(_ range: Range<Int>) -> String { range.upperBound <= b.count ? String(decoding: b[range], as: UTF8.self) : "" }
        switch self {
        case .jpeg: return b.starts(with: [0xff,0xd8,0xff])
        case .png: return b.starts(with: [137,80,78,71,13,10,26,10])
        case .gif: return text(0..<6) == "GIF89a" || text(0..<6) == "GIF87a"
        case .webp: return text(0..<4) == "RIFF" && text(8..<12) == "WEBP"
        case .mp4, .mov: return text(4..<8) == "ftyp" || (self == .mov && text(4..<8) == "moov")
        case .webm: return b.starts(with: [0x1a,0x45,0xdf,0xa3])
        case .mp3: return text(0..<3) == "ID3" || (b.count >= 2 && b[0] == 0xff && b[1] & 0xe0 == 0xe0)
        case .wav: return text(0..<4) == "RIFF" && text(8..<12) == "WAVE"
        case .ogg: return text(0..<4) == "OggS"
        }
    }
}
