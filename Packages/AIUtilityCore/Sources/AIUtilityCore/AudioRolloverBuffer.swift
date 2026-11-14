import Foundation

public struct AudioRolloverPolicy: Sendable, Equatable {
    public let maxDuration: TimeInterval
    public let maxBytes: Int
    public let maxPackets: Int
    public init(maxDuration: TimeInterval = 5, maxBytes: Int = 8 * 1024 * 1024, maxPackets: Int = 512) {
        self.maxDuration = maxDuration.isFinite ? min(10, max(0.1, maxDuration)) : 5
        self.maxBytes = min(16 * 1024 * 1024, max(1, maxBytes))
        self.maxPackets = min(1024, max(1, maxPackets))
    }
}

public enum AudioBufferPhase: String, Equatable, Sendable { case stopped, live, buffering, failed }
public enum AudioBufferFailure: String, Error, Equatable, Sendable {
    case capacityExceeded, invalidPacket, formatChanged, overlappingTime, copyFailed
}
public enum AudioEnqueueResult: Equatable, Sendable { case accepted, duplicate, ignored }

public struct AudioRolloverSnapshot: Sendable {
    public let phase: AudioBufferPhase
    public let failure: AudioBufferFailure?
    public let queuedPackets: Int
    public let queuedBytes: Int
    public let queuedDuration: TimeInterval
    public let acceptedPackets: Int
    /// Submitted to the consumer, not proof that Speech recognized the audio.
    public let dequeuedPackets: Int
    public let duplicatePackets: Int
    public let discardedPackets: Int
    public let peakQueuedBytes: Int
    public let sourceGapSeconds: TimeInterval
}

public struct BufferedAudioPacket<Payload: Sendable>: Sendable, CustomStringConvertible, CustomReflectable {
    public let payload: Payload
    public let byteCount: Int
    public let presentationTime: TimeInterval
    public let duration: TimeInterval
    public var description: String { "<BufferedAudioPacket: audio redacted>" }
    public var customMirror: Mirror { Mirror(self, children: ["audio": "<redacted>"]) }
}

/// Platform-independent ownership/ordering kernel. The owner must serialize access.
/// Retains only not-yet-delivered packets, never a replay history or an overlapping pre-roll.
public struct AudioRolloverBuffer<Payload: Sendable>: Sendable, CustomStringConvertible, CustomReflectable {
    public let policy: AudioRolloverPolicy
    public private(set) var session: UUID?
    public private(set) var phase = AudioBufferPhase.stopped
    public private(set) var failure: AudioBufferFailure?
    private var packets: [BufferedAudioPacket<Payload>] = []
    private var bytes = 0
    private var duration: TimeInterval = 0
    private var formatID: UInt64?
    private var lastEnd: TimeInterval?
    private var accepted = 0
    private var dequeued = 0
    private var duplicates = 0
    private var discarded = 0
    private var peakBytes = 0
    private var sourceGap: TimeInterval = 0
    private let tolerance: TimeInterval = 0.000_001

    public init(policy: AudioRolloverPolicy = AudioRolloverPolicy()) { self.policy = policy }
    public var description: String { "<AudioRolloverBuffer: audio redacted>" }
    public var customMirror: Mirror { Mirror(self, children: ["snapshot": snapshot()]) }

    /// A new authorization/playback epoch; no old packet survives this operation.
    @discardableResult public mutating func start() -> UUID {
        clearPackets()
        let id = UUID(); session = id; phase = .live; failure = nil
        formatID = nil; lastEnd = nil
        accepted = 0; dequeued = 0; duplicates = 0; discarded = 0; peakBytes = 0; sourceGap = 0
        return id
    }
    @discardableResult public mutating func beginRollover(session: UUID) -> Bool {
        guard self.session == session, phase == .live else { return false }
        phase = .buffering; return true
    }
    @discardableResult public mutating func resume(session: UUID) -> Bool {
        guard self.session == session, phase == .buffering else { return false }
        phase = .live; return true
    }
    public mutating func stop(session: UUID) {
        guard self.session == session else { return }
        discarded += packets.count; clearPackets(); phase = .stopped
    }
    public mutating func reject(_ failure: AudioBufferFailure, session: UUID) {
        guard self.session == session, phase == .live || phase == .buffering else { return }
        self.failure = failure; discarded += packets.count + 1
        clearPackets(); phase = .failed
    }

    /// Validates metadata and capacity BEFORE allocating/copying the payload.
    @discardableResult
    public mutating func enqueue(session: UUID, byteCount: Int, presentationTime: TimeInterval,
                                 duration: TimeInterval, formatID: UInt64,
                                 makePayload: () throws -> Payload) throws -> AudioEnqueueResult {
        guard self.session == session, phase == .live || phase == .buffering else { return .ignored }
        guard byteCount > 0, presentationTime.isFinite, presentationTime >= 0,
              duration.isFinite, duration > 0, (presentationTime + duration).isFinite,
              presentationTime + duration > presentationTime else {
            reject(.invalidPacket, session: session); throw AudioBufferFailure.invalidPacket
        }
        guard self.formatID == nil || self.formatID == formatID else {
            reject(.formatChanged, session: session); throw AudioBufferFailure.formatChanged
        }
        let end = presentationTime + duration
        if let lastEnd {
            if end <= lastEnd + tolerance { duplicates += 1; return .duplicate }
            guard presentationTime >= lastEnd - tolerance else {
                reject(.overlappingTime, session: session); throw AudioBufferFailure.overlappingTime
            }
        }
        let span = end - (packets.first?.presentationTime ?? presentationTime)
        guard packets.count < policy.maxPackets, byteCount <= policy.maxBytes - bytes,
              duration <= policy.maxDuration, self.duration + duration <= policy.maxDuration + tolerance,
              span <= policy.maxDuration + tolerance else {
            reject(.capacityExceeded, session: session); throw AudioBufferFailure.capacityExceeded
        }
        let payload: Payload
        do { payload = try makePayload() }
        catch { reject(.copyFailed, session: session); throw AudioBufferFailure.copyFailed }
        if let lastEnd { sourceGap += max(0, presentationTime - lastEnd - tolerance) }
        self.formatID = formatID; self.lastEnd = end
        packets.append(BufferedAudioPacket(payload: payload, byteCount: byteCount, presentationTime: presentationTime, duration: duration))
        bytes += byteCount; self.duration += duration; accepted += 1; peakBytes = max(peakBytes, bytes)
        return .accepted
    }
    /// A stopped, buffering or stale consumer cannot remove any packet.
    public mutating func takeNext(session: UUID) -> BufferedAudioPacket<Payload>? {
        guard self.session == session, phase == .live, !packets.isEmpty else { return nil }
        let packet = packets.removeFirst()
        bytes -= packet.byteCount; duration = max(0, duration - packet.duration); dequeued += 1
        return packet
    }
    public func snapshot() -> AudioRolloverSnapshot {
        AudioRolloverSnapshot(phase: phase, failure: failure, queuedPackets: packets.count, queuedBytes: bytes,
            queuedDuration: duration, acceptedPackets: accepted, dequeuedPackets: dequeued, duplicatePackets: duplicates,
            discardedPackets: discarded, peakQueuedBytes: peakBytes, sourceGapSeconds: sourceGap)
    }
    private mutating func clearPackets() {
        packets.removeAll(keepingCapacity: false); bytes = 0; duration = 0
    }
}
