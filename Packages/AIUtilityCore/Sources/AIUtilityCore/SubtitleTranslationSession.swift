import Foundation

/// A recognizer epoch gets a fresh utteranceID. Sequence numbers increase within that epoch.
/// timestamp is monotonic elapsed seconds supplied by the producer, not video wall-clock time.
public struct SpeechTranscript: Sendable, CustomStringConvertible, CustomReflectable {
    public let utteranceID: UUID
    public let sequence: UInt64
    public let text: String
    public let isFinal: Bool
    public let timestamp: TimeInterval
    public init(utteranceID: UUID, sequence: UInt64, text: String, isFinal: Bool, timestamp: TimeInterval) {
        self.utteranceID = utteranceID; self.sequence = sequence; self.text = text
        self.isFinal = isFinal; self.timestamp = timestamp
    }
    public var description: String { "<SpeechTranscript: redacted>" }
    public var customMirror: Mirror { Mirror(self, children: ["transcript": "<redacted>"]) }
}

public struct SubtitlePolicy: Sendable {
    public let maxSegmentCharacters: Int
    public let maxTranscriptCharacters: Int
    public let maxPendingSegments: Int
    public let stabilityInterval: TimeInterval
    public init(maxSegmentCharacters: Int = 240, maxTranscriptCharacters: Int = 4096,
                maxPendingSegments: Int = 8, stabilityInterval: TimeInterval = 1.2) {
        self.maxSegmentCharacters = min(512, max(16, maxSegmentCharacters))
        self.maxTranscriptCharacters = min(8192, max(512, maxTranscriptCharacters))
        self.maxPendingSegments = min(32, max(1, maxPendingSegments))
        self.stabilityInterval = stabilityInterval.isFinite ? min(10, max(0.5, stabilityInterval)) : 1.2
    }
}

/// Bounded cumulative-hypothesis reducer. No context is sent beyond the emitted segment.
/// Already committed prefixes cannot be revised by a late recognizer hypothesis.
struct SubtitleSegmenter: Sendable {
    let policy: SubtitlePolicy
    private var utterance: UUID?
    private var sequence: UInt64 = 0
    private var hypothesis = ""
    private var consumed = 0
    private var lastChanged: TimeInterval = 0
    private var lastTimestamp: TimeInterval = 0
    private var retired: [UUID] = []
    private(set) var duplicateEvents = 0

    init(policy: SubtitlePolicy) { self.policy = policy }

    mutating func ingest(_ value: SpeechTranscript) throws -> [String] {
        guard value.timestamp.isFinite, value.timestamp >= 0,
              value.text.count <= policy.maxTranscriptCharacters,
              value.text.utf8.count <= 24_576 else { throw AIUtilityError.invalidRequest }
        guard !retired.contains(value.utteranceID) else { duplicateEvents += 1; return [] }
        guard value.timestamp >= lastTimestamp else { duplicateEvents += 1; return [] }
        var output: [String] = []
        if utterance != value.utteranceID {
            if let old = utterance {
                output += drain(stableCount: hypothesis.count, final: true)
                retire(old)
            }
            utterance = value.utteranceID; sequence = 0; hypothesis = ""; consumed = 0
            lastChanged = value.timestamp; lastTimestamp = value.timestamp
        } else if value.sequence <= sequence || value.timestamp < lastTimestamp {
            duplicateEvents += 1; return []
        }
        let committed = String(hypothesis.prefix(consumed))
        guard value.text.hasPrefix(committed) else { duplicateEvents += 1; return [] }
        let common = zip(hypothesis, value.text).prefix(while: { $0.0 == $0.1 }).count
        if hypothesis != value.text { lastChanged = value.timestamp }
        hypothesis = value.text; sequence = value.sequence; lastTimestamp = value.timestamp
        output += drain(stableCount: value.isFinal ? hypothesis.count : common, final: value.isFinal)
        if value.isFinal {
            retire(value.utteranceID); utterance = nil; hypothesis = ""; consumed = 0
        }
        return output
    }

    mutating func flush(at time: TimeInterval) -> [String] {
        guard time.isFinite, time >= lastTimestamp,
              time - lastChanged >= policy.stabilityInterval,
              hypothesis.count - consumed >= 8 else { return [] }
        return drain(stableCount: hypothesis.count, final: true)
    }

    private mutating func retire(_ id: UUID) {
        retired.append(id)
        if retired.count > 32 { retired.removeFirst(retired.count - 32) }
    }
    private mutating func drain(stableCount: Int, final: Bool) -> [String] {
        var output: [String] = []
        let characters = Array(hypothesis)
        while consumed < stableCount {
            let end = min(stableCount, consumed + policy.maxSegmentCharacters)
            let candidate = characters[consumed..<end]
            let boundary: Int
            if let punctuation = candidate.lastIndex(where: { ".!?。！？\n".contains($0) }) {
                boundary = punctuation + 1
                if !final && boundary - consumed < 12 { break }
            } else if final || end - consumed == policy.maxSegmentCharacters { boundary = end }
            else { break }
            let text = String(characters[consumed..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
            consumed = boundary
            if !text.isEmpty { output.append(text) }
        }
        return output
    }
}

public struct SubtitleMetrics: Sendable, Equatable {
    public let completed: Int
    public let failed: Int
    public let dropped: Int
    public let duplicateEvents: Int
    public let pending: Int
}
public enum SubtitleEvent: Sendable, CustomStringConvertible, CustomReflectable {
    case translated(session: UUID, ordinal: UInt64, text: String, apiMilliseconds: Double, queueMilliseconds: Double)
    case failed(session: UUID, ordinal: UInt64, error: AIUtilityError)
    case dropped(session: UUID, count: Int)
    case stopped(session: UUID)
    public var description: String { "<SubtitleEvent: text redacted>" }
    public var customMirror: Mirror { Mirror(self, children: ["event": "<redacted>"]) }
}

/// A single FIFO translator, isolated from audio capture, ASR and display. Never records content.
/// Stop/pause/seek/model changes invalidate the old handle, cancel and await the active operation.
public actor SubtitleTranslationSession {
    public typealias Translate = @Sendable (String, ProviderID, TranslationLanguages) async throws -> String
    private struct Segment: Sendable {
        let ordinal: UInt64
        let text: String
        let enqueued: ContinuousClock.Instant
    }
    private let translate: Translate
    private let policy: SubtitlePolicy
    private let diagnostics: TranslationDiagnostics?
    private var segmenter: SubtitleSegmenter
    private var handle: UUID?
    private var revision: UInt64 = 0
    private var provider: ProviderID = .openAI
    private var languages = TranslationLanguages()
    private var queue: [Segment] = []
    private var worker: Task<Void, Never>?
    private var ordinal: UInt64 = 0
    private var completed = 0
    private var failed = 0
    private var dropped = 0
    private var observers: [UUID: AsyncStream<SubtitleEvent>.Continuation] = [:]

    public init(engine: TranslationEngine, policy: SubtitlePolicy = SubtitlePolicy()) {
        self.init(policy: policy, diagnostics: engine.diagnostics) { text, provider, languages in
            try await engine.translate(text, provider: provider, feature: .videoSubtitle, languages: languages)
        }
    }
    public init(policy: SubtitlePolicy = SubtitlePolicy(), diagnostics: TranslationDiagnostics? = nil, translate: @escaping Translate) {
        self.translate = translate; self.policy = policy; self.segmenter = SubtitleSegmenter(policy: policy)
        self.diagnostics = diagnostics
    }
    deinit { worker?.cancel(); observers.values.forEach { $0.finish() } }

    /// Subscribe before starting. Stream buffering is bounded; UI should display newest events.
    public func events() throws -> AsyncStream<SubtitleEvent> {
        guard observers.count < 8 else { throw AIUtilityError.budgetExceeded }
        let id = UUID()
        let pair = AsyncStream<SubtitleEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        observers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return pair.stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    /// The owning controller calls this after stop when disposing its subscriptions.
    public func closeEventStreams() {
        observers.values.forEach { $0.finish() }; observers.removeAll()
    }

    /// Resume/seek/reconfigure by starting a fresh epoch. No replay of pre-pause audio or text.
    @discardableResult
    public func start(provider: ProviderID, languages: TranslationLanguages) async throws -> UUID {
        revision &+= 1
        let expected = revision
        await invalidate(expected: expected)
        guard revision == expected, !Task.isCancelled else { throw AIUtilityError.cancelled }
        self.provider = provider; self.languages = languages
        segmenter = SubtitleSegmenter(policy: policy)
        completed = 0; failed = 0; dropped = 0; ordinal = 0
        let id = UUID(); handle = id
        return id
    }
    public func stop() async {
        revision &+= 1
        await invalidate(expected: revision)
    }
    public func pause() async { await stop() }
    private func invalidate(expected: UInt64) async {
        let old = handle; handle = nil; queue.removeAll(keepingCapacity: false)
        segmenter = SubtitleSegmenter(policy: policy)
        let pending = worker; pending?.cancel()
        if let old { emit(.stopped(session: old)) }
        await pending?.value
        if revision == expected { worker = nil }
    }
    public func ingest(_ transcript: SpeechTranscript, session: UUID) throws {
        guard handle == session else { return }
        guard !Task.isCancelled else { throw AIUtilityError.cancelled }
        try enqueue(segmenter.ingest(transcript), session: session)
    }
    /// Producer calls this on a ~0.5 s timer for silence-driven segmentation.
    public func flushStable(at time: TimeInterval, session: UUID) throws {
        guard handle == session else { return }
        try enqueue(segmenter.flush(at: time), session: session)
    }
    public func metrics() -> SubtitleMetrics {
        SubtitleMetrics(completed: completed, failed: failed, dropped: dropped, duplicateEvents: segmenter.duplicateEvents, pending: queue.count)
    }
    private func enqueue(_ texts: [String], session: UUID) throws {
        guard !Task.isCancelled else { throw AIUtilityError.cancelled }
        var discarded = 0
        for text in texts {
            guard queue.count < policy.maxPendingSegments else { discarded += 1; continue }
            ordinal &+= 1
            queue.append(Segment(ordinal: ordinal, text: text, enqueued: ContinuousClock().now))
        }
        if discarded > 0 { dropped += discarded; emit(.dropped(session: session, count: discarded)) }
        if worker == nil, !queue.isEmpty {
            worker = Task { [weak self] in
                guard let self else { return }
                await self.drain(session: session)
            }
        }
    }
    private func drain(session: UUID) async {
        let clock = ContinuousClock()
        while handle == session, !Task.isCancelled, !queue.isEmpty {
            let segment = queue.removeFirst()
            let began = clock.now
            let wait = segment.enqueued.duration(to: began).milliseconds
            do {
                let text = try await translate(segment.text, provider, languages)
                guard handle == session, !Task.isCancelled else { break }
                await diagnostics?.record(stage: .subtitleQueueToOutput, milliseconds: segment.enqueued.duration(to: clock.now).milliseconds, outcome: .success)
                guard handle == session, !Task.isCancelled else { break }
                completed += 1
                emit(.translated(session: session, ordinal: segment.ordinal, text: text,
                                 apiMilliseconds: began.duration(to: clock.now).milliseconds, queueMilliseconds: wait))
            } catch {
                guard handle == session, !Task.isCancelled else { break }
                failed += 1
                let error = AIUtilityError.sanitized(error)
                emit(.failed(session: session, ordinal: segment.ordinal, error: error))
                if error == .cancelled {
                    queue.removeAll(); handle = nil
                    emit(.stopped(session: session)); break
                }
            }
        }
        // A concurrent stop/start owns worker clearing while waiting for cancellation acknowledgement.
        if handle == session { worker = nil }
    }
    private func emit(_ event: SubtitleEvent) { observers.values.forEach { $0.yield(event) } }
}

extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
