import Foundation
import Testing
@testable import AIUtilityMedia

let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZQAAAABJRU5ErkJggg==")!
let mediaURL = URL(string: "https://media.example.org/file.png")!

final class TestClock: MediaClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    private var sleeps: [TimeInterval] = []
    func now() -> TimeInterval { lock.withLock { time } }
    func sleep(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock { sleeps.append(seconds); time += seconds }
        await Task.yield()
        try Task.checkCancellation()
    }
    func delays() -> [TimeInterval] { lock.withLock { sleeps } }
}
struct FixtureDestination: DestinationValidator {
    func validate(_ url: URL) async throws { try URLSafety.validate(url) }
}
actor TransferGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    func pause() async {
        entered = true; entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}
actor FixtureTransport: MediaTransport {
    enum Step: Sendable { case success, fail(MediaError), gate(TransferGate), cancellable }
    private var steps: [Step]
    private var responseHeaders: [String: (Int, [String: String])] = [:]
    private var active = 0
    private var peak = 0
    private var heads: [URL] = []
    private var downloads: [URL] = []
    private var callbacks: [@Sendable (Int64, Int64?) -> Void] = []
    private var payload: Data = png
    private var referers: [String?] = []
    /// Full URL → (status, body, content type) for site API fixtures.
    private var bodies: [String: (Int, Data, String)] = [:]
    func setBody(_ url: String, status: Int = 200, data: Data, contentType: String = "application/json") {
        bodies[url] = (status, data, contentType)
    }
    func sentReferers() -> [String?] { referers }
    func downloadedURLs() -> [String] { downloads.map(\.absoluteString) }
    init(_ steps: [Step] = []) { self.steps = steps }
    func setHeader(path: String, status: Int, headers: [String: String]) { responseHeaders[path] = (status, headers) }
    func setPayload(_ data: Data) { payload = data }
    private func response(_ url: URL) -> WireResponse {
        let values = responseHeaders[url.path] ?? (200, ["content-type": "image/png", "content-length": String(payload.count)])
        return WireResponse(status: values.0, headers: values.1, finalURL: url)
    }
    func head(_ url: URL, context: RequestContext, limits: RequestLimits) async throws -> WireResponse {
        heads.append(url); referers.append(context.referer); try Task.checkCancellation(); return response(url)
    }
    func download(_ url: URL, context: RequestContext, to destination: URL, limits: RequestLimits,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> WireResponse {
        downloads.append(url); referers.append(context.referer); callbacks.append(progress)
        if let body = bodies[url.absoluteString] {
            guard body.1.count <= limits.bytes else { throw MediaError.resourceLimitExceeded }
            try body.1.write(to: destination)
            return WireResponse(status: body.0, headers: ["content-type": body.2], finalURL: url)
        }
        active += 1; peak = max(peak, active); defer { active -= 1 }
        let step = steps.isEmpty ? Step.success : steps.removeFirst()
        switch step {
        case .success: break
        case .fail(let error): throw error
        case .gate(let gate): await gate.pause() // Intentionally ignores Task cancellation until released.
        case .cancellable: try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        progress(8, nil); progress(4, nil) // An out-of-order callback must not reduce observed bytes.
        guard payload.count <= limits.bytes else { throw MediaError.resourceLimitExceeded }
        try payload.write(to: destination)
        progress(Int64(payload.count), Int64(payload.count))
        return response(url)
    }
    func counts() -> (heads: Int, downloads: Int, peak: Int) { (heads.count, downloads.count, peak) }
    func paths() -> [String] { downloads.map(\.path) }
    func lateProgress(_ index: Int, bytes: Int64) { callbacks[index](bytes, bytes) }
}

final class FixtureManifestStore: ManifestStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value = MediaManifest()
    private var failing = false
    private var count = 0
    private var failAt: Int?
    private var failCompletion = false
    func load() throws -> MediaManifest { lock.withLock { value } }
    func save(_ manifest: MediaManifest) throws {
        try lock.withLock {
            count += 1
            if failing || count == failAt { throw MediaError.storageUnavailable }
            if failCompletion && manifest.tasks.contains(where: { if case .completed = $0.state { true } else { false } }) {
                failCompletion = false; throw MediaError.storageUnavailable
            }
            value = manifest
        }
    }
    func failWrites(_ value: Bool) { lock.withLock { failing = value } }
    func failNextWrite(offset: Int = 1) { lock.withLock { failAt = count + offset } }
    func failNextCompletion() { lock.withLock { failCompletion = true } }
}
final class FaultFiles: MediaFiles, @unchecked Sendable {
    private let lock = NSLock()
    let base: SandboxFiles
    private var cleanupFailures = 0
    private var failedRemovals: Set<UUID> = []
    init(base: SandboxFiles) { self.base = base }
    func failCleanup(_ count: Int) { lock.withLock { cleanupFailures = count } }
    func failRemove(_ ids: Set<UUID>) { lock.withLock { failedRemovals = ids } }
    func staging(_ id: DownloadID, attempt: UUID) throws -> URL { try base.staging(id, attempt: attempt) }
    func cleanup(_ id: DownloadID, attempt: UUID) throws {
        let fail = lock.withLock { if cleanupFailures > 0 { cleanupFailures -= 1; return true }; return false }
        if fail { throw MediaError.cleanupFailed }; try base.cleanup(id, attempt: attempt)
    }
    func inspect(_ url: URL, response: WireResponse, variant: MediaVariant, policy: DownloadPolicy) throws -> Int64 {
        try base.inspect(url, response: response, variant: variant, policy: policy)
    }
    func checkSpace(_ required: Int64) throws { try base.checkSpace(required) }
    func publish(_ staging: URL, files: [DownloadedFile]) throws { try base.publish(staging, files: files) }
    func locate(_ file: DownloadedFile) throws -> URL { try base.locate(file) }
    func remove(_ file: DownloadedFile) throws -> Bool {
        if lock.withLock({ failedRemovals.contains(file.id) }) { throw MediaError.storageUnavailable }
        return try base.remove(file)
    }
}

struct FixtureResolver: MediaResolver {
    let source: MediaSource
    let count: Int
    let ugoira: Bool
    init(_ source: MediaSource, count: Int = 1, ugoira: Bool = false) { self.source = source; self.count = count; self.ugoira = ugoira }
    func canResolve(_ url: URL) -> Bool { URLSafety.source(url) == source }
    func resolve(_ url: URL) async throws(MediaError) -> [MediaItem] {
        let id = try MediaItemID(source: source, value: "fixture-content")
        let variant = try MediaVariant(id: "original", kind: ugoira ? .ugoira : .image, qualityLabel: "Fixture", fileExtension: "png")
        return [try MediaItem(id: id, title: "Fixture", variants: [variant])]
    }
    func prepare(item: MediaItem, variantID: String, options: SiteOptions) async throws(MediaError) -> MediaTransferPlan {
        guard let variant = item.variants.first(where: { $0.id == variantID }) else { throw .invalidSelection }
        var components: [MediaComponent] = []
        for index in 0..<count { components.append(try MediaComponent(id: String(index), url: URL(string: "https://media.example.org/\(index).png")!)) }
        return try MediaTransferPlan(itemID: item.id, variant: variant,
            effectiveOptions: options.effective(source: source, ugoira: ugoira), components: components,
            assembly: ugoira ? .ugoiraToGIF(keepOriginalArchive: options.pixiv.keepUgoiraArchive) : .passthrough)
    }
}

struct Harness: Sendable {
    let root: URL
    let store: FixtureManifestStore
    let files: FaultFiles
    let transport: FixtureTransport
    let clock: TestClock
    let env: MediaEnvironment
    init(steps: [FixtureTransport.Step] = [], policy: DownloadPolicy = .init(minimumRequestInterval: 0, minimumFreeBytes: 0),
         resolvers: [any MediaResolver] = [], sites: Set<MediaSource> = []) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("media-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        let configuration = try DownloadConfiguration(testRoot: root, policy: policy)
        store = FixtureManifestStore(); transport = FixtureTransport(steps); clock = TestClock()
        files = FaultFiles(base: try SandboxFiles(root: configuration.root, cache: configuration.cache))
        let client = NetworkClient(policy: policy, transport: transport, validator: FixtureDestination(), clock: clock)
        let all: [any MediaResolver] = [DirectMediaResolver(client: client)] + resolvers + siteResolvers(sites, client: client)
        env = MediaEnvironment(repository: store, files: files, client: client,
            router: LinkRouter(resolvers: all, client: client), policy: policy, clock: clock, sources: Set(all.map(\.source)))
    }
    func manager() throws -> DownloadManager { try DownloadManager(environment: env) }
    func cleanup() throws { try FileManager.default.removeItem(at: root) }
}

func waitFor(_ manager: DownloadManager, id: DownloadID,
             matching predicate: @escaping @Sendable (DownloadState) -> Bool = { $0.terminal }) async throws -> DownloadState {
    try await mediaDeadline(4) {
        let stream = await manager.updates()
        for await snapshot in stream {
            if let state = snapshot.tasks.first(where: { $0.id == id })?.state, predicate(state) { return state }
        }
        throw MediaError.invalidState
    }
}
func queueSnapshot(_ manager: DownloadManager) async -> DownloadQueueSnapshot {
    let stream = await manager.updates(); var iterator = stream.makeAsyncIterator()
    return await iterator.next()!
}
func expectError(_ expected: MediaError, operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Expected a classified failure") }
    catch { #expect(MediaError.safe(error) == expected) }
}
