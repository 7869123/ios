import Foundation
import Testing
@testable import AIUtilityMedia
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Offline only. The response follows the shape of the site's own search response, with invented
// titles, IDs and example.org addresses.

private actor CapturingTransport: SearchUploadTransport {
    private var sent: [(URLRequest, Data)] = []
    private let status: Int
    private let reply: Data
    init(status: Int = 200, reply: String) { self.status = status; self.reply = Data(reply.utf8) }
    func post(_ request: URLRequest, body: Data, maxResponseBytes: Int) async throws -> SearchReply {
        sent.append((request, body))
        return SearchReply(status: status, body: reply)
    }
    func count() -> Int { sent.count }
    func last() -> (URLRequest, Data)? { sent.last }
}

private let botSample = """
{"schema_version":"2.2","metadata_mode":"display","result_id":"20000101000000_sample","status":"ok","partial":false,
 "api_results":[{"api_id":"fixed-sample","status":"ok","result_count":2}],
 "results":[
  {"hit_id":"h-000002","api_id":"fixed-sample","score":42.5,
   "path_segments":[{"source_key":"booru-sample","thumbnail_url":"https://img.example.org/thumb2.webp",
     "source_url":"https://booru.example.org/posts/2","page_url":null,"chapter_url":null,
     "metadata":{"display_kind":"booru","post":{"post_url":"https://booru.example.org/posts/2"},
       "mirrors":[{"post_url":"https://mirror.example.org/post/2"}],
       "tags":{"artists":[{"kind":"artist","text":"sample_artist"}]}}}]},
  {"hit_id":"h-000001","api_id":"fixed-sample","score":49.25,
   "path_segments":[{"source_key":"comic-sample","thumbnail_url":"https://img.example.org/thumb1.webp",
     "source_url":"https://comic.example.org/album/1/","page_url":null,"chapter_url":"https://comic.example.org/photo/1",
     "metadata":{"display_kind":"doujinshi","source":{"key":"comic-sample","name":"Sample Comics","id":"1"},
       "title":{"primary":"Sample Work"},"creators":[{"name":"Author A"},{"name":"Author B"}]}}]},
  {"hit_id":"h-000003","score":10.0,"path_segments":[]}],
 "warnings":[]}
"""

struct SoutubotTests {
    @Test func searchesWithoutAnyCredentialAndMapsResultsBestFirst() async throws {
        let transport = CapturingTransport(reply: botSample)
        let matches = try await SoutubotProvider(transport: transport).search(image: png)
        #expect(await transport.count() == 1)
        #expect(matches.map(\.similarity) == [49.25, 42.5])   // the hit without a path segment is skipped
        #expect(matches.allSatisfy { $0.service == .soutubot })
        #expect(matches[0].title == "Sample Work" && matches[0].author == "Author A, Author B")
        #expect(matches[0].indexName == "Sample Comics")
        #expect(matches[0].links.map(\.absoluteString) == ["https://comic.example.org/album/1/", "https://comic.example.org/photo/1"])
        #expect(matches[1].author == "sample_artist" && matches[1].indexName == "booru-sample")
        #expect(matches[1].links.map(\.absoluteString) == ["https://booru.example.org/posts/2", "https://mirror.example.org/post/2"])
        #expect(matches[1].thumbnail?.absoluteString == "https://img.example.org/thumb2.webp")

        let (request, body) = try #require(await transport.last())
        #expect(request.url?.absoluteString == "https://soutubot.moe/api/search")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("name=\"file\"; filename=\"image.png\""))
        #expect(text.contains("name=\"factor\"\r\n\r\n1.2\r\n"))
        #expect(text.contains("name=\"metadata_mode\"\r\n\r\ndisplay\r\n"))
        #expect(text.contains("name=\"top_k\"\r\n\r\n5\r\n"))
        #expect(body.range(of: png) != nil)
    }

    @Test func strictModeUsesTheWebPageFactor() async throws {
        let transport = CapturingTransport(reply: botSample)
        _ = try await SoutubotProvider(transport: transport, strict: true).search(image: png)
        let body = try #require(await transport.last()).1
        #expect(String(decoding: body, as: UTF8.self).contains("name=\"factor\"\r\n\r\n1.4\r\n"))
    }

    @Test func inputIsCheckedBeforeUpload() async throws {
        let transport = CapturingTransport(reply: botSample)
        let provider = SoutubotProvider(transport: transport)
        await expectError(.invalidInput) { _ = try await provider.search(image: Data()) }
        await expectError(.unsupportedFormat) { _ = try await provider.search(image: Data("text".utf8)) }
        #expect(await transport.count() == 0)
    }

    @Test func responsesAreClassified() throws {
        let provider = SoutubotProvider(transport: CapturingTransport(reply: "{}"))
        #expect(throws: MediaError.rateLimited(retryAfter: nil)) { try provider.parse(status: 429, data: Data()) }
        #expect(throws: MediaError.resourceLimitExceeded) { try provider.parse(status: 413, data: Data()) }
        #expect(throws: MediaError.network) { try provider.parse(status: 502, data: Data()) }
        #expect(throws: MediaError.parsingChanged) { try provider.parse(status: 200, data: Data("<html>".utf8)) }
        #expect(throws: MediaError.parsingChanged) { try provider.parse(status: 200, data: Data(#"{"status":"error"}"#.utf8)) }
        let empty = try provider.parse(status: 200, data: Data(#"{"status":"ok","results":[]}"#.utf8))
        #expect(empty.isEmpty)
    }
}
