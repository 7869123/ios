import Foundation
import Testing
@testable import AIUtilityMedia
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

// Live checks against the real public sites. Off by default; run only when AIUTILITY_LIVE_TESTS=1
// (manual `live_checks` workflow input). They read public metadata and send HEAD requests for media;
// no media file is downloaded, no account or key is used, and SauceNAO is not called.
//
// Each check appends one `LIVE-CHECK <name>: <outcome>` line to the file named by
// AIUTILITY_LIVE_REPORT (the workflow prints it):
// - ok: the real response matched what the resolver expects;
// - unavailable: the site refused or limited this runner (login, region, rate limit, network);
//   that is reported, not counted as a pass;
// - FORMAT: the response no longer matches the parser (or the code is wrong) -> the test fails.

private let liveEnabled = ProcessInfo.processInfo.environment["AIUTILITY_LIVE_TESTS"] == "1"

/// Appends one outcome line to the report file; checks run serially, so appends do not interleave.
private func record(_ line: String) {
    guard let path = ProcessInfo.processInfo.environment["AIUTILITY_LIVE_REPORT"], !path.isEmpty else { return }
    let url = URL(fileURLWithPath: path)
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

private func liveClient() async -> NetworkClient {
    let client = NetworkClient(policy: DownloadPolicy(minimumRequestInterval: 1), transport: URLSessionMediaTransport(),
                               validator: PublicDNSValidator(), clock: SystemMediaClock())
    await client.begin()
    return client
}

private func check(_ name: String, _ body: () async throws -> String) async {
    do {
        let detail = try await body()
        record("LIVE-CHECK \(name): ok - \(detail)")
    } catch let error as MediaError {
        switch error {
        case .parsingChanged, .invalidURL, .invalidInput, .invalidSelection, .integrityMismatch, .invalidState:
            record("LIVE-CHECK \(name): FORMAT - \(error)")
            Issue.record("\(name): \(error)")
        default:
            record("LIVE-CHECK \(name): unavailable - \(error)")
        }
    } catch let refusal as LiveRefusal {
        record("LIVE-CHECK \(name): unavailable - \(refusal.text)")
    } catch {
        record("LIVE-CHECK \(name): FORMAT - \(type(of: error))")
        Issue.record("\(name): \(type(of: error))")
    }
}

/// HEAD for a media address with the component's referer; reports status-relevant facts only.
private func head(_ component: MediaComponent, client: NetworkClient) async throws -> String {
    let response = try await client.headers(component.requestURL(), context: component.requestContext())
    let type = response.header("content-type") ?? "?"
    let length = response.header("content-length") ?? "?"
    return "HEAD \(response.status) \(type) \(length) bytes"
}

/// A site refused this runner in a way worth naming in the report.
private enum LiveRefusal: Error {
    case cloudflareChallenge(Int), status(Int, String)
    var text: String {
        switch self {
        case .cloudflareChallenge(let code): "HTTP \(code) Cloudflare challenge (datacenter address blocked)"
        case .status(let code, let detail): "\(code) \(detail)"
        }
    }
}

private struct BilibiliCode: Decodable, Sendable { let code: Int; let message: String? }
private struct BilibiliPopular: Decodable, Sendable {
    struct Page: Decodable, Sendable { struct Video: Decodable, Sendable { let bvid: String }; let list: [Video] }
    let code: Int
    let message: String?
    let data: Page?
}

private struct PixivRanking: Decodable, Sendable {
    struct Entry: Decodable, Sendable { let illust_id: Int }
    let contents: [Entry]
}

@Suite(.enabled(if: liveEnabled), .serialized)
struct LiveSiteChecks {
    @Test func pixivIllustration() async {
        await check("pixiv-illust") {
            let client = await liveClient()
            let ranking = try await SiteJSON.fetch(PixivRanking.self,
                URL(string: "https://www.pixiv.net/ranking.php?mode=daily&content=illust&format=json&p=1")!,
                client: client, context: RequestContext(referer: PixivResolver.referer))
            guard let first = ranking.contents.first else { throw MediaError.parsingChanged }
            let resolver = PixivResolver(client: client)
            let items = try await resolver.resolve(URL(string: "https://www.pixiv.net/artworks/\(first.illust_id)")!)
            let item = items[0]
            let plan = try await resolver.prepare(item: item, variantID: item.variants[0].id, options: .init())
            let host = plan.components[0].requestURL().host ?? "?"
            let probe = try await head(plan.components[0], client: client)
            return "\(items.count) page(s), .\(item.variants[0].fileExtension) on \(host); " + probe
        }
    }

    @Test func pixivUgoira() async {
        await check("pixiv-ugoira") {
            let client = await liveClient()
            let ranking = try await SiteJSON.fetch(PixivRanking.self,
                URL(string: "https://www.pixiv.net/ranking.php?mode=daily&content=ugoira&format=json&p=1")!,
                client: client, context: RequestContext(referer: PixivResolver.referer))
            guard let first = ranking.contents.first else { throw MediaError.parsingChanged }
            let resolver = PixivResolver(client: client)
            let items = try await resolver.resolve(URL(string: "https://www.pixiv.net/artworks/\(first.illust_id)")!)
            let item = items[0]
            guard item.variants[0].kind == .ugoira else { throw MediaError.parsingChanged }
            let plan = try await resolver.prepare(item: item, variantID: item.variants[0].id, options: .init())
            let delays = plan.ugoiraFrames.map(\.delayMilliseconds)
            let odd = delays.filter { $0 % 10 != 0 }.count
            let probe = try await head(plan.components[0], client: client)
            return "\(plan.ugoiraFrames.count) frames, \(odd) not on 10 ms, min \(delays.min() ?? 0) ms; " + probe
        }
    }

    @Test func bilibiliPublicVideo() async {
        // Raw API codes first, so a refusal can be told apart from a parser problem.
        await check("bilibili-view-code") {
            let client = await liveClient()
            let data = try await client.fetchJSON(URL(string: "https://api.bilibili.com/x/web-interface/view?bvid=BV1GJ411x7h7")!,
                                                  context: RequestContext(referer: BilibiliResolver.referer))
            let reply = try SiteJSON.decode(BilibiliCode.self, from: data)
            return "fixed video: code \(reply.code) \(String((reply.message ?? "").prefix(40)))"
        }
        await check("bilibili-popular") {
            let client = await liveClient()
            let data = try await client.fetchJSON(URL(string: "https://api.bilibili.com/x/web-interface/popular?ps=5&pn=1")!,
                                                  context: RequestContext(referer: BilibiliResolver.referer))
            let popular = try SiteJSON.decode(BilibiliPopular.self, from: data)
            guard popular.code == 0, let bvid = popular.data?.list.first?.bvid else {
                throw LiveRefusal.status(popular.code, "popular list API code: " + String((popular.message ?? "").prefix(40)))
            }
            let resolver = BilibiliResolver(client: client)
            let items = try await resolver.resolve(URL(string: "https://www.bilibili.com/video/\(bvid)")!)
            let plan = try await resolver.prepare(item: items[0], variantID: "mp4", options: .init())
            let host = plan.components[0].requestURL().host ?? "?"
            let probe = try await head(plan.components[0], client: client)
            return "today's video: part \(items[0].id.value), \(plan.variant.estimatedBytes ?? 0) bytes on \(host); " + probe
        }
    }

    @Test func xEmbedEndpoint() async {
        // Post 20 is a well-known public text-only post: reaching "no media" proves the endpoint,
        // token and response shape work.
        await check("x-embed") {
            let client = await liveClient()
            do {
                _ = try await XResolver(client: client).resolve(URL(string: "https://x.com/jack/status/20")!)
                return "unexpected media on a text-only post"
            } catch MediaError.unsupportedFormat {
                return "endpoint and token accepted; text-only post correctly has no media"
            }
        }
    }

    #if canImport(ImageIO) && canImport(Darwin)
    @Test func soutubotSearch() async {
        // Send the web page's request once and report what answered: the site's JSON, or a
        // Cloudflare challenge for this datacenter address. Only the verdict is reported, not the page.
        await check("soutubot") {
            let provider = SoutubotProvider(perLibrary: 2, maxResults: 5)
            let (request, body) = provider.makeRequest(image: try gradientPNG(), ext: "png", mime: "image/png")
            let reply = try await URLSessionSearchTransport().post(request, body: body, maxResponseBytes: SoutubotProvider.maxResponseBytes)
            let text = String(decoding: reply.body.prefix(4096), as: UTF8.self).lowercased()
            let challenge = reply.headers["cf-mitigated"] == "challenge" || text.contains("just a moment")
                || text.contains("cf-chl") || text.contains("challenge-platform")
            let type = reply.headers["content-type"] ?? "?"
            guard reply.status == 200 else {
                if challenge { throw LiveRefusal.cloudflareChallenge(reply.status) }
                throw LiveRefusal.status(reply.status, "HTTP, " + type)
            }
            let matches = try provider.parse(status: reply.status, data: reply.body)
            return "\(matches.count) match(es) parsed; top score \(matches.first?.similarity.map { String(format: "%.1f", $0) } ?? "-")"
        }
    }
    #endif
}

#if canImport(ImageIO)
/// A generated 256x256 gradient with some structure, so feature-based search has something to match.
private func gradientPNG() throws -> Data {
    let size = 256
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw MediaError.unsupportedPlatform }
    for y in stride(from: 0, to: size, by: 16) {
        for x in stride(from: 0, to: size, by: 16) {
            context.setFillColor(CGColor(srgbRed: Double(x) / 256, green: Double(y) / 256, blue: Double((x + y) % 256) / 256, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 16, height: 16))
        }
    }
    let output = NSMutableData()
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil)
    else { throw MediaError.unsupportedPlatform }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw MediaError.unsupportedPlatform }
    return output as Data
}
#endif
