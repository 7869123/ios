import Foundation
import Testing
@testable import AIUtilityMedia
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Offline only: the transport is a fake and the response is an invented sample in SauceNAO's JSON shape.

private struct FixedKey: SearchCredentialSource {
    let key: String?
    func sauceNAOKey() async throws -> String? { key }
}

private actor RecordingTransport: SearchUploadTransport {
    private(set) var requests: [(URLRequest, Data)] = []
    private let status: Int
    private let reply: Data
    init(status: Int = 200, reply: String) { self.status = status; self.reply = Data(reply.utf8) }
    func post(_ request: URLRequest, body: Data, maxResponseBytes: Int) async throws -> SearchReply {
        requests.append((request, body))
        return SearchReply(status: status, body: reply)
    }
    func count() -> Int { requests.count }
    func last() -> (URLRequest, Data)? { requests.last }
}

private let sample = """
{"header":{"status":0,"results_returned":3,"short_remaining":3,"long_remaining":99},"results":[
 {"header":{"similarity":"61.20","thumbnail":"https://img.example.org/thumb2.jpg","index_name":"Index #9: Example Board"},
  "data":{"ext_urls":["https://board.example.org/post/2"],"creator":["artist one","artist two"]}},
 {"header":{"similarity":"93.45","thumbnail":"https://img.example.org/thumb1.jpg","index_name":"Index #5: Pixiv Images - 1_p0.jpg"},
  "data":{"ext_urls":["https://www.pixiv.net/artworks/100000001","javascript:alert(1)"],"title":"Sample artwork","member_name":"Sample Artist"}},
 {"header":{"similarity":"21.00","index_name":"Index #2: Low"},"data":{"ext_urls":["https://low.example.org/"]}}]}
"""

struct ReverseSearchTests {
    @Test func uploadsOnceAndReturnsMatchesAboveThresholdBestFirst() async throws {
        let transport = RecordingTransport(reply: sample)
        let provider = SauceNAOProvider(credentials: FixedKey(key: "sampleKey123"), transport: transport)
        let matches = try await provider.search(image: png)
        #expect(await transport.count() == 1)
        #expect(matches.map(\.similarity) == [93.45, 61.2])
        #expect(matches[0].title == "Sample artwork" && matches[0].author == "Sample Artist")
        #expect(matches[0].links == [URL(string: "https://www.pixiv.net/artworks/100000001")!]) // non-http links dropped
        #expect(matches[1].author == "artist one, artist two")
        #expect(matches[0].indexName.hasPrefix("Index #5"))
        let (request, body) = try #require(await transport.last())
        #expect(request.httpMethod == "POST")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "output_type", value: "2")))
        #expect(query.contains(URLQueryItem(name: "api_key", value: "sampleKey123")))
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(body.range(of: png) != nil)
        #expect(String(decoding: body, as: UTF8.self).contains("filename=\"image.png\""))
    }

    @Test func missingOrMalformedKeyIsNotConfiguredAndNothingIsSent() async throws {
        let transport = RecordingTransport(reply: sample)
        await expectError(.notConfigured) { _ = try await SauceNAOProvider(credentials: FixedKey(key: nil), transport: transport).search(image: png) }
        await expectError(.notConfigured) { _ = try await SauceNAOProvider(credentials: FixedKey(key: "bad key&x=1"), transport: transport).search(image: png) }
        #expect(await transport.count() == 0)
    }

    @Test func inputIsCheckedBeforeUpload() async throws {
        let transport = RecordingTransport(reply: sample)
        let provider = SauceNAOProvider(credentials: FixedKey(key: "sampleKey123"), transport: transport)
        await expectError(.invalidInput) { _ = try await provider.search(image: Data()) }
        await expectError(.unsupportedFormat) { _ = try await provider.search(image: Data("not an image".utf8)) }
        await expectError(.resourceLimitExceeded) {
            _ = try await provider.search(image: png + Data(count: SauceNAOProvider.maxUploadBytes))
        }
        #expect(await transport.count() == 0)
    }

    @Test func serviceErrorsAreClassified() throws {
        let provider = SauceNAOProvider(credentials: FixedKey(key: "k"), transport: RecordingTransport(reply: "{}"))
        #expect(throws: MediaError.accessRestricted(.permission)) { try provider.parse(status: 403, data: Data()) }
        #expect(throws: MediaError.rateLimited(retryAfter: nil)) { try provider.parse(status: 429, data: Data()) }
        #expect(throws: MediaError.parsingChanged) { try provider.parse(status: 200, data: Data("{}".utf8)) }
        #expect(throws: MediaError.network) {
            try provider.parse(status: 200, data: Data(#"{"header":{"status":1}}"#.utf8))
        }
        #expect(throws: MediaError.rateLimited(retryAfter: nil)) {
            try provider.parse(status: 200, data: Data(#"{"header":{"status":-2,"short_remaining":0}}"#.utf8))
        }
        #expect(try provider.parse(status: 200, data: Data(#"{"header":{"status":0},"results":[]}"#.utf8)).isEmpty)
    }

    @Test func formatSniffing() {
        #expect(SauceNAOProvider.imageFormat(png)?.ext == "png")
        #expect(SauceNAOProvider.imageFormat(Data([0xff, 0xd8, 0xff, 0xe0]))?.mime == "image/jpeg")
        #expect(SauceNAOProvider.imageFormat(Data("GIF89a".utf8))?.ext == "gif")
        #expect(SauceNAOProvider.imageFormat(Data("RIFF\0\0\0\0WEBPVP8 ".utf8))?.ext == "webp")
        #expect(SauceNAOProvider.imageFormat(Data([1, 2, 3])) == nil)
    }
}
