import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// P4: reverse image search. Only an image the user explicitly chose is uploaded, once per call; nothing
// is stored, logged or added to download history. Real network calls happen only in the app; CI uses
// offline samples.

public protocol ReverseImageSearchProvider: Sendable {
    var service: ReverseSearchService { get }
    func search(image: Data) async throws(MediaError) -> [ReverseSearchMatch]
}

public enum ReverseSearchService: String, Sendable, Codable { case sauceNAO, soutubot }

/// One candidate source. `similarity` is the service's own score (SauceNAO: percent) and is not a
/// probability comparable across services.
public struct ReverseSearchMatch: Sendable, Hashable {
    public let service: ReverseSearchService
    public let similarity: Double?
    /// Index or site the match came from, as named by the service.
    public let indexName: String
    public let title: String?
    public let author: String?
    /// Source pages (http/https only), most relevant first.
    public let links: [URL]
    public let thumbnail: URL?
}

/// Supplies the SauceNAO API key on demand from a separate credential store (never an AI provider key).
/// Returning nil means not configured.
public protocol SearchCredentialSource: Sendable {
    func sauceNAOKey() async throws -> String?
}

/// SauceNAO JSON API (`output_type=2`). The key travels in the query string as the API requires; the
/// request is built in memory only and never described or logged.
public struct SauceNAOProvider: ReverseImageSearchProvider {
    public let service = ReverseSearchService.sauceNAO
    public static let maxUploadBytes = 15 * 1024 * 1024
    static let maxResponseBytes = 1_048_576
    private let credentials: any SearchCredentialSource
    private let transport: any SearchUploadTransport
    private let minimumSimilarity: Double
    private let maxResults: Int

    public init(credentials: any SearchCredentialSource, minimumSimilarity: Double = 50, maxResults: Int = 8) {
        self.init(credentials: credentials, transport: URLSessionSearchTransport(), minimumSimilarity: minimumSimilarity, maxResults: maxResults)
    }
    init(credentials: any SearchCredentialSource, transport: any SearchUploadTransport, minimumSimilarity: Double = 50, maxResults: Int = 8) {
        self.credentials = credentials; self.transport = transport
        self.minimumSimilarity = min(100, max(0, minimumSimilarity.isFinite ? minimumSimilarity : 50))
        self.maxResults = min(16, max(1, maxResults))
    }

    public func search(image: Data) async throws(MediaError) -> [ReverseSearchMatch] {
        guard !image.isEmpty else { throw .invalidInput }
        guard image.count <= Self.maxUploadBytes else { throw .resourceLimitExceeded }
        guard let format = Self.imageFormat(image) else { throw .unsupportedFormat }
        let key: String
        do {
            guard let stored = try await credentials.sauceNAOKey() else { throw MediaError.notConfigured }
            key = stored
        } catch let error as MediaError { throw error } catch { throw .storageUnavailable }
        guard Self.validKey(key) else { throw .notConfigured }
        guard !Task.isCancelled else { throw .cancelled }

        var components = URLComponents(string: "https://saucenao.com/search.php")!
        components.queryItems = [URLQueryItem(name: "output_type", value: "2"),
                                 URLQueryItem(name: "numres", value: String(maxResults)),
                                 URLQueryItem(name: "db", value: "999"),
                                 URLQueryItem(name: "api_key", value: key)]
        let boundary = "AIUtility-" + UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"image.\(format.ext)\"\r\n".utf8))
        body.append(Data("Content-Type: \(format.mime)\r\n\r\n".utf8))
        body.append(image)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("AIUtility/1.0", forHTTPHeaderField: "User-Agent")

        let reply: SearchReply
        do { reply = try await transport.post(request, body: body, maxResponseBytes: Self.maxResponseBytes) }
        catch let error as MediaError { throw error }
        catch { throw MediaError.safe(error) }
        guard !Task.isCancelled else { throw .cancelled }
        return try parse(status: reply.status, data: reply.body)
    }

    func parse(status: Int, data: Data) throws(MediaError) -> [ReverseSearchMatch] {
        switch status {
        case 200: break
        case 401, 403: throw .accessRestricted(.permission) // Key rejected.
        case 413: throw .resourceLimitExceeded
        case 429: throw .rateLimited(retryAfter: nil)
        case 500...599: throw .network
        default: throw .parsingChanged
        }
        let response: SauceNAOResponse
        do { response = try JSONDecoder().decode(SauceNAOResponse.self, from: data) } catch { throw .parsingChanged }
        // SauceNAO: 0 = ok, > 0 server-side problem, < 0 client-side problem (bad image, key or limit).
        if response.header.status > 0 { throw .network }
        if response.header.status < 0 {
            if response.header.short_remaining == 0 || response.header.long_remaining == 0 { throw .rateLimited(retryAfter: nil) }
            throw .unsupportedFormat
        }
        var matches: [ReverseSearchMatch] = []
        for result in response.results ?? [] {
            let similarity = result.header.similarity.flatMap(Double.init)
            if let similarity, similarity < minimumSimilarity { continue }
            var links: [URL] = []
            for text in (result.data.ext_urls ?? []) + [result.data.source].compactMap({ $0 }) {
                guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                      url.host != nil, !links.contains(url) else { continue }
                links.append(url)
                if links.count == 5 { break }
            }
            let thumbnail = result.header.thumbnail.flatMap(URL.init(string:)).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
            matches.append(ReverseSearchMatch(service: .sauceNAO, similarity: similarity,
                                              indexName: Self.clean(result.header.index_name) ?? "SauceNAO",
                                              title: Self.clean(result.data.title),
                                              author: Self.clean(result.data.member_name ?? result.data.author_name ?? result.data.creator?.text),
                                              links: links, thumbnail: thumbnail))
            if matches.count == maxResults { break }
        }
        return matches.sorted { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
    }

    static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 128 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func imageFormat(_ data: Data) -> (ext: String, mime: String)? {
        let bytes = Array(data.prefix(12))
        if bytes.starts(with: [0xff, 0xd8, 0xff]) { return ("jpg", "image/jpeg") }
        if bytes.starts(with: [137, 80, 78, 71]) { return ("png", "image/png") }
        if bytes.starts(with: Array("GIF8".utf8)) { return ("gif", "image/gif") }
        if bytes.count >= 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return ("webp", "image/webp") }
        return nil
    }

    static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(200))
    }
}

private struct SauceNAOResponse: Decodable {
    struct Header: Decodable { let status: Int; let short_remaining: Int?; let long_remaining: Int? }
    struct Result: Decodable {
        struct Header: Decodable { let similarity: String?; let thumbnail: String?; let index_name: String? }
        struct Body: Decodable {
            let ext_urls: [String]?
            let title: String?
            let source: String?
            let member_name: String?
            let author_name: String?
            let creator: FlexibleText?
        }
        let header: Header
        let data: Body
    }
    let header: Header
    let results: [Result]?
}

/// SauceNAO returns `creator` as a string or an array of strings depending on the index.
struct FlexibleText: Decodable {
    let text: String?
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { text = value }
        else if let values = try? container.decode([String].self) { text = values.joined(separator: ", ") }
        else { text = nil }
    }
}

struct SearchReply: Sendable { let status: Int; let body: Data }

protocol SearchUploadTransport: Sendable {
    func post(_ request: URLRequest, body: Data, maxResponseBytes: Int) async throws -> SearchReply
}

#if canImport(Darwin)
/// Ephemeral session: no cookies, cache or stored credentials; redirects are not followed.
struct URLSessionSearchTransport: SearchUploadTransport {
    final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    func post(_ request: URLRequest, body: Data, maxResponseBytes: Int) async throws -> SearchReply {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw MediaError.network }
        guard data.count <= maxResponseBytes else { throw MediaError.resourceLimitExceeded }
        return SearchReply(status: http.statusCode, body: data)
    }
}
#else
/// Searching is an app feature; other platforms only run the offline parsing tests.
struct URLSessionSearchTransport: SearchUploadTransport {
    func post(_ request: URLRequest, body: Data, maxResponseBytes: Int) async throws -> SearchReply {
        throw MediaError.unsupportedPlatform
    }
}
#endif
