import Foundation

struct MediaEnvironment: Sendable {
    let repository: any ManifestStore
    let files: any MediaFiles
    let client: NetworkClient
    let router: LinkRouter
    let policy: DownloadPolicy
    let clock: any MediaClock
    let sources: Set<MediaSource>
    static func production(_ configuration: DownloadConfiguration) throws -> MediaEnvironment {
        let clock = SystemMediaClock()
        let client = NetworkClient(policy: configuration.policy, transport: URLSessionMediaTransport(),
                                   validator: PublicDNSValidator(), clock: clock)
        let resolvers: [any MediaResolver] = [DirectMediaResolver(client: client)] + configuration.resolvers.filter { $0.source != .direct }
        return MediaEnvironment(repository: try DiskManifestStore(root: configuration.root),
                                files: try SandboxFiles(root: configuration.root, cache: configuration.cache),
                                client: client, router: LinkRouter(resolvers: resolvers, client: client), policy: configuration.policy,
                                clock: clock, sources: Set(resolvers.map(\.source)))
    }
}

public actor DownloadManager {
    private enum RuntimeInput: Sendable {
        case link(URL, MediaSelection)
        case selected(MediaItem, MediaVariant)
    }
    private let env: MediaEnvironment
    private var manifest: MediaManifest
    private var inputs: [DownloadID: RuntimeInput] = [:]
    private var observers: [UUID: AsyncStream<DownloadQueueSnapshot>.Continuation] = [:]
    private var worker: Task<Void, Never>?
    private var active: (id: DownloadID, attempt: UUID)?
    private var blockingError: MediaError?
    private var pendingFinish: DownloadState?
    private var closing = false

    public init(configuration: DownloadConfiguration) async throws(MediaError) {
        do {
            try Task.checkCancellation()
            let env = try MediaEnvironment.production(configuration)
            self.env = env; self.manifest = try Self.restore(env)
            try Task.checkCancellation()
        } catch { throw Self.storageError(error) }
    }
    init(environment: MediaEnvironment) throws {
        env = environment; manifest = try Self.restore(environment)
    }
    private static func storageError(_ error: any Error) -> MediaError {
        if error is CancellationError { return .cancelled }
        return error as? MediaError ?? .storageUnavailable
    }
    private static func restore(_ env: MediaEnvironment) throws -> MediaManifest {
        var value = try env.repository.load()
        guard value.schemaVersion == 1 else { throw MediaError.storageUnavailable }
        // A published-but-uncommitted directory is rolled back, never promoted without final metadata.
        for i in value.tasks.indices {
            if let journal = value.tasks[i].journal {
                for file in journal { _ = try env.files.remove(file) }
                value.tasks[i].journal = nil
            }
            if !value.tasks[i].state.terminal {
                if case .queued = value.tasks[i].state { /* Preserve pending FIFO order. */ }
                else { value.tasks[i].state = .interrupted }
                try env.files.cleanup(value.tasks[i].id, attempt: value.tasks[i].attemptID)
            }
        }
        try reconcileDeletions(&value, env: env)
        value.revision += 1
        try env.repository.save(value)
        return value
    }
    private static func reconcileDeletions(_ value: inout MediaManifest, env: MediaEnvironment) throws {
        for key in Array(value.ownership.keys) {
            guard let owner = value.ownership[key], owner.deleting else { continue }
            var remaining: [DownloadedFile] = []
            for file in owner.files {
                do { _ = try env.files.locate(file); remaining.append(file) }
                catch MediaError.outputMissing { continue }
            }
            if remaining.isEmpty { value.ownership.removeValue(forKey: key) }
            else { value.ownership[key] = Ownership(files: remaining, deleting: false) }
            if let index = value.tasks.firstIndex(where: { $0.id.rawValue.uuidString == key }) {
                value.tasks[index].identity = nil
                if remaining.isEmpty { value.tasks.remove(at: index) }
                else { value.tasks[index].state = .deletionIncomplete(remainingFiles: remaining) }
            }
        }
    }

    public func capabilities() -> DownloadCapabilities {
        DownloadCapabilities(sources: env.sources, supportsDownloadResume: false, supportsAllBilibiliParts: false,
                             assemblies: ["passthrough"], localTools: [])
    }
    public func enqueue(link: URL, selection: MediaSelection = .automatic,
                        options: SiteOptions = .init()) async throws(MediaError) -> EnqueueReceipt {
        do {
            try Task.checkCancellation(); try URLSafety.validate(link)
            guard !closing else { throw MediaError.invalidState }
            let source = URLSafety.source(link) ?? .direct
            // Content-specific Pixiv normalization waits until resolve distinguishes originals/Ugoira.
            let effective = options.effective(source: source, ugoira: source == .pixiv)
            let alias = StableDigest.hex(try URLSafety.canonical(link) + Self.selectionKey(selection) + Self.optionKey(effective))
            if let receipt = receipt(alias: alias) {
                if receipt.disposition != .alreadyCompleted { inputs[receipt.id] = .link(link, selection) }
                schedule()
                return receipt
            }
            return try append(alias: alias, source: source, selection: selection, options: options, input: .link(link, selection))
        } catch { throw MediaError.safe(error) }
    }
    public func enqueue(_ item: MediaItem, variant: MediaVariant, options: SiteOptions = .init()) async throws(MediaError) -> EnqueueReceipt {
        guard !Task.isCancelled else { throw .cancelled }
        guard !closing else { throw .invalidState }
        try variant.validate()
        guard item.variants.contains(variant) else { throw .invalidSelection }
        let selection = MediaSelection.variant(itemID: item.id, variantID: variant.id)
        let effective = options.effective(source: item.id.source, ugoira: variant.kind == .ugoira)
        let alias = StableDigest.hex(Self.selectionKey(selection) + Self.optionKey(effective))
        if let receipt = receipt(alias: alias) {
            if receipt.disposition != .alreadyCompleted { inputs[receipt.id] = .selected(item, variant) }
            schedule(); return receipt
        }
        return try append(alias: alias, source: item.id.source, selection: selection, options: options, input: .selected(item, variant))
    }
    private func append(alias: String, source: MediaSource, selection: MediaSelection,
                        options: SiteOptions, input: RuntimeInput) throws(MediaError) -> EnqueueReceipt {
        guard !closing, blockingError == nil else { throw .invalidState }
        guard manifest.tasks.count < 10_000 else { throw .resourceLimitExceeded }
        var next = manifest; next.nextOrdinal += 1
        let id = DownloadID(), date = Date()
        let storedSelection: MediaSelection
        switch selection {
        case .automatic: storedSelection = .automatic
        case .variant(let item, let variant):
            storedSelection = .variant(itemID: try MediaItemID(source: item.source, value: StableDigest.hex(item.value)),
                                       variantID: StableDigest.hex(variant))
        }
        next.tasks.append(StoredTask(id: id, ordinal: next.nextOrdinal, alias: alias, selection: storedSelection,
                                    options: options, identity: nil, source: source, effectiveOptions: nil,
                                    state: .queued(position: 1), attemptID: UUID(), createdAt: date, updatedAt: date, journal: nil))
        try commit(next)
        inputs[id] = input
        broadcast(); schedule()
        return EnqueueReceipt(id: id, disposition: .created)
    }
    private func receipt(alias: String) -> EnqueueReceipt? {
        guard let row = manifest.tasks.first(where: {
            if case .deletionIncomplete = $0.state { return false }; return $0.alias == alias
        }) else { return nil }
        let disposition: EnqueueReceipt.Disposition
        switch row.state {
        case .completed(let files): disposition = files.allSatisfy { (try? env.files.locate($0)) != nil } ? .alreadyCompleted : .retryRequired
        case .duplicate(let existing):
            if let original = manifest.tasks.first(where: { $0.id == existing }), case .completed(let files) = original.state {
                return EnqueueReceipt(id: existing, disposition: files.allSatisfy { (try? env.files.locate($0)) != nil } ? .alreadyCompleted : .retryRequired)
            }
            return nil // The referenced history/output was removed; do not keep an orphan dedup alias.
        case .failed, .cancelled, .interrupted, .deletionIncomplete: disposition = .retryRequired
        default: disposition = .alreadyQueued
        }
        return EnqueueReceipt(id: row.id, disposition: disposition)
    }
    public func cancel(_ id: DownloadID) -> CancelResult {
        guard let index = manifest.tasks.firstIndex(where: { $0.id == id }) else { return .notFound }
        if case .committing = manifest.tasks[index].state { return .tooLate }
        if manifest.tasks[index].state.terminal { return .alreadyTerminal }
        if case .cancelling = manifest.tasks[index].state { return .accepted }
        var next = manifest
        next.tasks[index].state = active?.id == id ? .cancelling : .cancelled
        next.tasks[index].updatedAt = Date()
        do { try commit(next) }
        catch { manifest = next; blockingError = .storageUnavailable }
        if active?.id == id { worker?.cancel() }
        broadcast(); return .accepted
    }
    public func retry(_ id: DownloadID) async throws(MediaError) {
        guard !Task.isCancelled else { throw .cancelled }
        guard !closing, blockingError == nil,
              let index = manifest.tasks.firstIndex(where: { $0.id == id }) else { throw .invalidState }
        switch manifest.tasks[index].state {
        case .failed, .cancelled, .interrupted: break
        case .completed(let files):
            guard files.contains(where: { (try? env.files.locate($0)) == nil }) else { throw .invalidState }
        default: throw .invalidState
        }
        guard inputs[id] != nil else { throw .notConfigured } // Re-enter sensitive links after restart.
        var next = manifest; next.nextOrdinal += 1
        next.tasks[index].ordinal = next.nextOrdinal; next.tasks[index].attemptID = UUID()
        next.tasks[index].state = .queued(position: 1); next.tasks[index].updatedAt = Date()
        try commit(next); broadcast(); schedule()
    }
    public func retryCleanup(_ id: DownloadID) async throws(MediaError) {
        guard blockingError != nil, worker == nil else { throw .invalidState }
        if let active {
            guard active.id == id, let index = manifest.tasks.firstIndex(where: { $0.id == id }) else { throw .invalidState }
            do {
                try env.files.cleanup(id, attempt: active.attempt)
                if let journal = manifest.tasks[index].journal { for file in journal { _ = try env.files.remove(file) } }
                var next = manifest; next.tasks[index].state = pendingFinish ?? .cancelled
                next.tasks[index].journal = nil
                try commit(next)
            } catch { throw Self.storageError(error) }
            self.active = nil; pendingFinish = nil
        } else {
            do { var next = manifest; try Self.reconcileDeletions(&next, env: env); try commit(next) }
            catch { throw Self.storageError(error) }
        }
        blockingError = nil; broadcast(); schedule()
    }
    public func updates() -> AsyncStream<DownloadQueueSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: DownloadQueueSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        continuation.yield(snapshot())
        if closing { continuation.finish(); observers.removeValue(forKey: id) }
        return stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    public func history() async throws(MediaError) -> [DownloadRecord] {
        guard !Task.isCancelled else { throw .cancelled }
        return manifest.tasks.filter { $0.state.terminal }.sorted { $0.ordinal < $1.ordinal }.map(\.record)
    }
    public func clearHistory() async throws(MediaError) {
        guard !Task.isCancelled else { throw .cancelled }
        var next = manifest; next.tasks.removeAll { $0.state.terminal }
        try commit(next)
        let ids = Set(next.tasks.map(\.id)); inputs = inputs.filter { ids.contains($0.key) }
        broadcast()
    }
    public func deleteFiles(for id: DownloadID) async throws(MediaError) -> DeleteResult {
        guard !closing else { throw .invalidState }
        let index = manifest.tasks.firstIndex(where: { $0.id == id })
        if let index, !manifest.tasks[index].state.terminal { throw .invalidState }
        let key = id.rawValue.uuidString
        guard var owner = manifest.ownership[key], !owner.deleting else { throw .notFound }
        if Task.isCancelled { throw .cancelled }
        owner.deleting = true; var next = manifest; next.ownership[key] = owner
        try commit(next) // Durable intent before irreversible file operations.
        var deleted: [DownloadedFile] = [], missing: [DownloadedFile] = [], failed: [FileDeletionFailure] = []
        var remaining: [DownloadedFile] = []
        for file in owner.files {
            if Task.isCancelled {
                failed.append(FileDeletionFailure(fileID: file.id, error: .cancelled)); remaining.append(file); continue
            }
            do { if try env.files.remove(file) { deleted.append(file) } else { missing.append(file) } }
            catch { failed.append(FileDeletionFailure(fileID: file.id, error: Self.storageError(error))); remaining.append(file) }
        }
        next = manifest
        if remaining.isEmpty { next.ownership.removeValue(forKey: key) }
        else { next.ownership[key] = Ownership(files: remaining, deleting: false) }
        if let index = next.tasks.firstIndex(where: { $0.id == id }) {
            if remaining.isEmpty { next.tasks.remove(at: index) }
            else { next.tasks[index].identity = nil; next.tasks[index].state = .deletionIncomplete(remainingFiles: remaining) }
        }
        next.tasks.removeAll { if case .duplicate(let existing) = $0.state { existing == id } else { false } }
        do { try commit(next) }
        catch { blockingError = .storageUnavailable; broadcast(); throw .storageUnavailable }
        inputs.removeValue(forKey: id); broadcast()
        return DeleteResult(id: id, deleted: deleted, alreadyMissing: missing, failed: failed)
    }
    public func fileURL(for file: DownloadedFile) async throws(MediaError) -> URL {
        guard !Task.isCancelled else { throw .cancelled }
        guard manifest.ownership.values.contains(where: { !$0.deleting && $0.files.contains(file) }) else { throw .outputMissing }
        do { return try env.files.locate(file) } catch { throw Self.storageError(error) }
    }
    public func shutdown() async throws(MediaError) {
        closing = true
        if let active { _ = cancel(active.id) }
        let task = worker; await task?.value
        guard blockingError == nil else { throw blockingError ?? .cleanupFailed }
        try commit(manifest)
        observers.values.forEach { $0.finish() }; observers.removeAll(); inputs.removeAll()
    }

    private func commit(_ value: MediaManifest) throws(MediaError) {
        var value = value; value.revision = manifest.revision + 1
        do { try env.repository.save(value); manifest = value }
        catch { throw Self.storageError(error) }
    }
    private func snapshot() -> DownloadQueueSnapshot {
        var position = 0
        let tasks = manifest.tasks.sorted { $0.ordinal < $1.ordinal }.map { task -> DownloadSnapshot in
            var task = task
            if case .queued = task.state { position += 1; task.state = .queued(position: position) }
            return task.snapshot(revision: manifest.revision)
        }
        return DownloadQueueSnapshot(revision: manifest.revision, tasks: tasks, activeID: active?.id, blockingError: blockingError)
    }
    private func broadcast() { let value = snapshot(); observers.values.forEach { $0.yield(value) } }
    private func schedule() {
        guard !closing, worker == nil, blockingError == nil,
              let row = manifest.tasks.filter({ if case .queued = $0.state { true } else { false } }).min(by: { $0.ordinal < $1.ordinal }) else { return }
        active = (row.id, row.attemptID)
        worker = Task { await self.execute(row.id, attempt: row.attemptID) }
    }
    private func isCurrent(_ id: DownloadID, _ attempt: UUID) -> Bool { active?.id == id && active?.attempt == attempt }
    private func setState(_ id: DownloadID, _ attempt: UUID, _ state: DownloadState) throws {
        guard isCurrent(id, attempt), let index = manifest.tasks.firstIndex(where: { $0.id == id }) else { throw MediaError.cancelled }
        try Task.checkCancellation()
        var next = manifest; next.tasks[index].state = state; next.tasks[index].updatedAt = Date()
        try commit(next); broadcast()
    }
    private func execute(_ id: DownloadID, attempt: UUID) async {
        var outcome: DownloadState = .failed(.network)
        await env.client.begin()
        do {
            let deadline = env.clock.now() + env.policy.taskTimeout
            try await mediaDeadline(env.policy.taskTimeout) {
                try await self.runAttempts(id, initialAttempt: attempt, deadline: deadline)
            }
            return // runAttempts commits success/duplicate and releases the slot itself.
        } catch {
            let error = MediaError.safe(error)
            outcome = Task.isCancelled || error == .cancelled ? .cancelled : error == .notConfigured ? .interrupted : .failed(error)
        }
        // runAttempts may have advanced generation for a full retry.
        guard let current = active, current.id == id else { return }
        finish(id, attempt: current.attempt, state: outcome)
    }
    private func runAttempts(_ id: DownloadID, initialAttempt: UUID, deadline: TimeInterval) async throws {
        var attempt = initialAttempt
        for retry in 0...env.policy.maxRetries {
            do {
                try Task.checkCancellation()
                try setState(id, attempt, .resolving)
                try await perform(id, attempt: attempt)
                return
            } catch {
                let failure = MediaError.safe(error)
                try env.files.cleanup(id, attempt: attempt)
                guard !Task.isCancelled, retry < env.policy.maxRetries,
                      let delay = Self.retryDelay(failure, retry: retry) else { throw failure }
                guard env.clock.now() + delay < deadline else { throw MediaError.timeout }
                try setState(id, attempt, .waitingToRetry(attempt: retry + 1, delay: delay))
                try await env.clock.sleep(delay); try Task.checkCancellation()
                guard let index = manifest.tasks.firstIndex(where: { $0.id == id }), isCurrent(id, attempt) else { throw MediaError.cancelled }
                attempt = UUID(); active = (id, attempt)
                var next = manifest; next.tasks[index].attemptID = attempt; next.tasks[index].state = .resolving
                try commit(next); broadcast()
            }
        }
    }
    static func retryDelay(_ error: MediaError, retry: Int) -> TimeInterval? {
        switch error {
        case .network, .timeout: min(30, pow(2, Double(retry)))
        case .rateLimited(let after): max(min(30, pow(2, Double(retry))), after ?? 0)
        default: nil
        }
    }
    private func perform(_ id: DownloadID, attempt: UUID) async throws {
        guard let input = inputs[id], let row = manifest.tasks.first(where: { $0.id == id }) else { throw MediaError.notConfigured }
        let chosen: [(MediaItem, MediaVariant)]
        switch input {
        case .link(let url, let selection):
            let items = try await env.router.resolve(url)
            switch selection {
            case .automatic: chosen = items.compactMap { item in item.variants.first.map { (item, $0) } }
            case .variant(let itemID, let variantID):
                guard let item = items.first(where: { $0.id == itemID }), let variant = item.variants.first(where: { $0.id == variantID }) else { throw MediaError.invalidSelection }
                chosen = [(item, variant)]
            }
        case .selected(let item, let variant): chosen = [(item, variant)]
        }
        try Task.checkCancellation()
        guard !chosen.isEmpty, chosen.count <= env.policy.maxOutputs else { throw MediaError.resourceLimitExceeded }
        var plans: [MediaTransferPlan] = []
        for (item, variant) in chosen {
            let plan = try await env.router.prepare(item: item, variantID: variant.id, options: row.options)
            guard plan.assembly == .passthrough, !variant.requiresAssembly, variant.kind != .ugoira else { throw MediaError.unsupportedPlatform }
            plans.append(plan)
        }
        let identity = StableDigest.hex(plans.map { Self.selectionKey(.variant(itemID: $0.itemID, variantID: $0.variant.id)) + Self.optionKey($0.effectiveOptions) }.joined(separator: "|"))
        guard let index = manifest.tasks.firstIndex(where: { $0.id == id }), isCurrent(id, attempt) else { throw MediaError.cancelled }
        var next = manifest
        next.tasks[index].identity = identity; next.tasks[index].source = plans.first?.itemID.source
        next.tasks[index].effectiveOptions = plans.first?.effectiveOptions
        try commit(next)
        if let other = manifest.tasks.first(where: { task in
            guard task.id != id, task.identity == identity else { return false }
            if case .completed(let files) = task.state { return files.allSatisfy { (try? env.files.locate($0)) != nil } }
            return false
        }) {
            try setState(id, attempt, .duplicate(existing: other.id)); release(id); return
        }
        let staging = try env.files.staging(id, attempt: attempt)
        var files: [DownloadedFile] = [], written: Int64 = 0
        let components = plans.reduce(0) { $0 + $1.components.count }
        guard components <= env.policy.maxOutputs else { throw MediaError.resourceLimitExceeded }
        for plan in plans {
            for component in plan.components {
                try Task.checkCancellation()
                try env.files.checkSpace(env.policy.minimumFreeBytes + min(plan.variant.estimatedBytes ?? env.policy.maxFileBytes, env.policy.maxFileBytes))
                try setState(id, attempt, .running(DownloadProgress(attemptID: attempt, phase: .transfer, bytesWritten: written, totalBytes: nil)))
                let part = staging.appendingPathComponent(UUID().uuidString + ".part")
                let base = written
                let response = try await env.client.download(component.requestURL(), to: part,
                    limit: min(env.policy.maxFileBytes, env.policy.maxTaskBytes - written)) { [weak self] bytes, total in
                        Task { await self?.progress(id, attempt: attempt, bytes: base + bytes, total: components == 1 ? total : nil) }
                    }
                try Task.checkCancellation()
                let size = try env.files.inspect(part, response: response, variant: plan.variant, policy: env.policy)
                written += size
                guard written <= env.policy.maxTaskBytes else { throw MediaError.resourceLimitExceeded }
                let fileID = UUID(), name = fileID.uuidString + "." + plan.variant.fileExtension
                let stagedFile = staging.appendingPathComponent(name)
                try FileManager.default.moveItem(at: part, to: stagedFile)
                guard let inode = (try FileManager.default.attributesOfItem(atPath: stagedFile.path)[.systemFileNumber] as? NSNumber)?.uint64Value else {
                    throw MediaError.storageUnavailable
                }
                files.append(DownloadedFile(id: fileID, fileName: name,
                    relativePath: "outputs/" + id.rawValue.uuidString + "/" + attempt.uuidString + "/" + name,
                    bytes: size, kind: plan.variant.kind, fileIdentity: inode))
            }
        }
        try Task.checkCancellation()
        guard isCurrent(id, attempt), let index = manifest.tasks.firstIndex(where: { $0.id == id }) else { throw MediaError.cancelled }
        // No await between the final cancellation check, journal, directory publication and metadata commit.
        next = manifest; next.tasks[index].state = .committing; next.tasks[index].journal = files
        try commit(next); broadcast()
        try env.files.publish(staging, files: files)
        next = manifest; next.tasks[index].state = .completed(files: files); next.tasks[index].journal = nil
        let retained = next.ownership[id.rawValue.uuidString]?.files ?? []
        next.ownership[id.rawValue.uuidString] = Ownership(files: retained + files, deleting: false)
        try commit(next); broadcast(); inputs.removeValue(forKey: id); release(id)
    }
    // Internal callback seam also permits deterministic out-of-order/generation regression tests.
    func progress(_ id: DownloadID, attempt: UUID, bytes: Int64, total: Int64?) {
        guard isCurrent(id, attempt), let index = manifest.tasks.firstIndex(where: { $0.id == id }),
              case .running(let previous) = manifest.tasks[index].state, bytes >= previous.bytesWritten,
              bytes >= 0, bytes <= env.policy.maxTaskBytes else { return }
        let stableTotal = previous.totalBytes ?? total
        manifest.tasks[index].state = .running(DownloadProgress(attemptID: attempt, phase: .transfer, bytesWritten: bytes, totalBytes: stableTotal))
        manifest.revision += 1; broadcast()
    }
    private func finish(_ id: DownloadID, attempt: UUID, state: DownloadState) {
        guard isCurrent(id, attempt), let index = manifest.tasks.firstIndex(where: { $0.id == id }) else { return }
        worker = nil
        do {
            try env.files.cleanup(id, attempt: attempt)
            // A failed final metadata write may leave a published directory: remove only journal-owned outputs.
            if let journal = manifest.tasks[index].journal { for file in journal { _ = try env.files.remove(file) } }
            var next = manifest; next.tasks[index].state = state; next.tasks[index].journal = nil
            next.tasks[index].updatedAt = Date()
            try commit(next); release(id)
        } catch {
            pendingFinish = state; blockingError = .cleanupFailed
            manifest.tasks[index].state = .cancelling; broadcast()
        }
    }
    private func release(_ id: DownloadID) {
        guard active?.id == id else { return }
        active = nil; worker = nil; pendingFinish = nil; broadcast(); schedule()
    }
    private static func selectionKey(_ selection: MediaSelection) -> String {
        switch selection {
        case .automatic: return "automatic"
        case .variant(let item, let variant): return item.source.rawValue + ":" + StableDigest.hex(item.value) + ":" + StableDigest.hex(variant)
        }
    }
    private static func optionKey(_ options: SiteOptions) -> String {
        ":" + (options.bilibili.allParts ? "all" : "one") + ":" + (options.pixiv.keepUgoiraArchive ? "archive" : "gif")
    }
}
