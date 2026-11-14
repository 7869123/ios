import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 搜图 Bot 酱 (soutubot.moe). Uses the same request its web page sends: `POST /api/search` with a
/// multipart form (`file`, `factor`, `metadata_mode`, `top_k`), no account, cookie, key or signature.
/// This endpoint is not documented as a public API: its shape was taken from the web page's own
/// request, so any unexpected response is `.parsingChanged` and the feature is labelled untested.
/// `similarity` carries the site's own score, which is not a percentage.
public struct SoutubotProvider: ReverseImageSearchProvider {
    public let service = ReverseSearchService.soutubot
    static let endpoint = URL(string: "https://soutubot.moe/api/search")!
    static let maxResponseBytes = 4 * 1_048_576
    private let transport: any SearchUploadTransport
    private let strict: Bool
    private let perLibrary: Int
    private let maxResults: Int

    /// `strict` matches the web page's strict mode (factor 1.4 instead of 1.2).
    public init(strict: Bool = false, perLibrary: Int = 5, maxResults: Int = 12) {
        self.init(transport: URLSessionSearchTransport(), strict: strict, perLibrary: perLibrary, maxResults: maxResults)
    }
    init(transport: any SearchUploadTransport, strict: Bool = false, perLibrary: Int = 5, maxResults: Int = 12) {
        self.transport = transport; self.strict = strict
        self.perLibrary = min(50, max(1, perLibrary)); self.maxResults = min(50, max(1, maxResults))
    }

    public func search(image: Data) async throws(MediaError) -> [ReverseSearchMatch] {
        guard !image.isEmpty else { throw .invalidInput }
        guard image.count <= SauceNAOProvider.maxUploadBytes else { throw .resourceLimitExceeded }
        guard let format = SauceNAOProvider.imageFormat(image) else { throw .unsupportedFormat }
        guard !Task.isCancelled else { throw .cancelled }
        let (request, body) = makeRequest(image: image, ext: format.ext, mime: format.mime)
        let reply: SearchReply
        do { reply = try await transport.post(request, body: body, maxResponseBytes: Self.maxResponseBytes) }
        catch let error as MediaError { throw error }
        catch { throw MediaError.safe(error) }
        guard !Task.isCancelled else { throw .cancelled }
        return try parse(status: reply.status, data: reply.body)
    }

    /// The exact request the web page sends (also used by the live diagnostics).
    func makeRequest(image: Data, ext: String, mime: String) -> (URLRequest, Data) {
        let form = MultipartForm(fields: [("factor", strict ? "1.4" : "1.2"), ("metadata_mode", "display"),
                                          ("top_k", String(perLibrary))],
                                 file: (name: "file", fileName: "image.\(ext)", mime: mime, data: image))
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("AIUtility/1.0", forHTTPHeaderField: "User-Agent")
        return (request, form.body)
    }

    func parse(status: Int, data: Data) throws(MediaError) -> [ReverseSearchMatch] {
        switch status {
        case 200: break
        case 400, 415, 422: throw .unsupportedFormat
        case 403: throw .accessRestricted(.permission)
        case 413: throw .resourceLimitExceeded
        case 429: throw .rateLimited(retryAfter: nil)
        case 500...599: throw .network
        default: throw .parsingChanged
        }
        let response: SoutubotResponse
        do { response = try JSONDecoder().decode(SoutubotResponse.self, from: data) } catch { throw .parsingChanged }
        guard response.status == "ok" || response.status == "partial" else {
            throw response.results == nil ? .parsingChanged : .network
        }
        var matches: [ReverseSearchMatch] = []
        for hit in response.results ?? [] {
            guard let segment = hit.path_segments?.first else { continue }
            let metadata = segment.metadata
            var linkTexts: [String?] = [segment.source_url, segment.page_url, segment.chapter_url, metadata?.post?.post_url]
            linkTexts += (metadata?.mirrors ?? []).map { $0.post_url }
            var links: [URL] = []
            for text in linkTexts.compactMap({ $0 }) {
                guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                      url.host != nil, !links.contains(url) else { continue }
                links.append(url)
                if links.count == 5 { break }
            }
            let creators = (metadata?.creators ?? []).compactMap { $0.name }
            let artists = (metadata?.tags?.artists ?? []).compactMap { $0.text }
            let author = (creators.isEmpty ? artists : creators).prefix(4).joined(separator: ", ")
            let thumbnail = segment.thumbnail_url.flatMap(URL.init(string:)).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
            let index = SauceNAOProvider.clean(metadata?.source?.name) ?? SauceNAOProvider.clean(segment.source_key) ?? "搜图 Bot 酱"
            matches.append(ReverseSearchMatch(service: .soutubot, similarity: hit.score.flatMap { $0.isFinite ? $0 : nil },
                                              indexName: index,
                                              title: SauceNAOProvider.clean(metadata?.title?.primary),
                                              author: SauceNAOProvider.clean(author),
                                              links: links, thumbnail: thumbnail))
            if matches.count == maxResults { break }
        }
        return matches.sorted { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
    }
}

/// Only the fields the app shows; everything else in the response is ignored.
private struct SoutubotResponse: Decodable {
    struct Hit: Decodable {
        struct Segment: Decodable {
            struct Metadata: Decodable {
                struct Source: Decodable { let name: String? }
                struct Title: Decodable { let primary: String? }
                struct Creator: Decodable { let name: String? }
                struct Post: Decodable { let post_url: String? }
                struct Tags: Decodable {
                    struct Tag: Decodable { let text: String? }
                    let artists: [Tag]?
                }
                let source: Source?
                let title: Title?
                let creators: [Creator]?
                let post: Post?
                let mirrors: [Post]?
                let tags: Tags?
            }
            let source_key: String?
            let metadata: Metadata?
            let thumbnail_url: String?
            let source_url: String?
            let page_url: String?
            let chapter_url: String?
        }
        let score: Double?
        let path_segments: [Segment]?
    }
    let status: String?
    let results: [Hit]?
}

/// multipart/form-data body with text fields and one file.
struct MultipartForm {
    let boundary: String
    let body: Data
    var contentType: String { "multipart/form-data; boundary=\(boundary)" }
    init(fields: [(String, String)], file: (name: String, fileName: String, mime: String, data: Data)) {
        var body = Data()
        let boundary = "AIUtility-" + UUID().uuidString
        self.boundary = boundary
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(file.mime)\r\n\r\n".utf8))
        body.append(file.data)
        body.append(Data("\r\n".utf8))
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        self.body = body
    }
}
