import Foundation

/// Helpers shared by the site resolvers. Site APIs are only read anonymously: no cookies, tokens,
/// accounts or signatures are sent, and content that needs login, payment, membership or a region is
/// reported with the matching `MediaError` instead of being worked around.
enum SiteJSON {
    static func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) throws(MediaError) -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw .parsingChanged }
    }

    /// Fetches and decodes, mapping transport errors to safe `MediaError`s.
    static func fetch<T: Decodable & Sendable>(_ type: T.Type, _ url: URL, client: NetworkClient,
                                    context: RequestContext) async throws(MediaError) -> T {
        let data: Data
        do { data = try await client.fetchJSON(url, context: context) } catch { throw MediaError.safe(error) }
        return try decode(T.self, from: data)
    }

    static func url(_ string: String?, hosts: (String) -> Bool) throws(MediaError) -> URL {
        guard let string, let url = URL(string: string), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), hosts(host) else { throw .parsingChanged }
        try URLSafety.validate(url)
        return url
    }

    /// File extension of a media URL path, limited to the formats a variant may declare.
    static func fileExtension(of url: URL, fallback: String) -> String {
        let ext = url.pathExtension.lowercased()
        let normalised = ext == "jpeg" ? "jpg" : ext
        return MediaVariant.extensions.contains(normalised) ? normalised : fallback
    }

    static func digits(_ text: Substring, maxLength: Int = 20) -> String? {
        guard !text.isEmpty, text.count <= maxLength, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(text)
    }
}
