import Foundation
import Testing
@testable import AIUtilityCore

private func append(_ id: Int, to buffer: inout AudioRolloverBuffer<Int>, session: UUID,
                    time: Double, duration: Double = 0.25, bytes: Int = 4, format: UInt64 = 1) throws {
    try buffer.enqueue(session: session, byteCount: bytes, presentationTime: time, duration: duration, formatID: format) { id }
}

// Keep mutating calls outside assertion macro expansion (Swift 6 / Swift Testing compatibility).
private func expectRollover<T: Sendable>(_ buffer: inout AudioRolloverBuffer<T>, session: UUID) {
    let result = buffer.beginRollover(session: session)
    #expect(result)
}
private func expectResume<T: Sendable>(_ buffer: inout AudioRolloverBuffer<T>, session: UUID, succeeds: Bool = true) {
    let result = buffer.resume(session: session)
    #expect(result == succeeds)
}
private func expectNext(_ expected: Int?, from buffer: inout AudioRolloverBuffer<Int>, session: UUID) {
    let packet = buffer.takeNext(session: session)
    #expect(packet?.payload == expected)
}

@Test func audioRolloverRetainsOnlyUnsubmittedPacketsAndPreservesFIFO() throws {
    var buffer = AudioRolloverBuffer<Int>()
    let session = buffer.start()
    try append(1, to: &buffer, session: session, time: 0)
    expectNext(1, from: &buffer, session: session)
    expectRollover(&buffer, session: session)
    try append(2, to: &buffer, session: session, time: 0.25)
    try append(3, to: &buffer, session: session, time: 0.5)
    expectNext(nil, from: &buffer, session: session)
    #expect(buffer.snapshot().queuedDuration == 0.5)
    expectResume(&buffer, session: session)
    expectNext(2, from: &buffer, session: session)
    // A new live packet arriving during catch-up cannot overtake the queued tail.
    try append(4, to: &buffer, session: session, time: 0.75)
    expectNext(3, from: &buffer, session: session)
    expectNext(4, from: &buffer, session: session)
    expectNext(nil, from: &buffer, session: session)
    #expect(buffer.snapshot().dequeuedPackets == 4)
    #expect(buffer.snapshot().queuedBytes == 0)
}

@Test func audioDurationOverflowFailsBeforeAllocatingAndReleasesBacklog() throws {
    var buffer = AudioRolloverBuffer<Int>(policy: AudioRolloverPolicy(maxDuration: 1))
    let session = buffer.start()
    expectRollover(&buffer, session: session)
    try append(1, to: &buffer, session: session, time: 0, duration: 0.5)
    try append(2, to: &buffer, session: session, time: 0.5, duration: 0.5)
    var allocated = false
    #expect(throws: AudioBufferFailure.capacityExceeded) {
        try buffer.enqueue(session: session, byteCount: 1, presentationTime: 1, duration: 0.1, formatID: 1) { allocated = true; return 3 }
    }
    #expect(!allocated)
    #expect(buffer.snapshot().phase == .failed)
    #expect(buffer.snapshot().queuedPackets == 0)
    #expect(buffer.snapshot().discardedPackets == 3)
    expectResume(&buffer, session: session, succeeds: false)
}

@Test func audioByteAndPacketLimitsApplyDuringNormalDeliveryAsWellAsRollover() throws {
    var bytes = AudioRolloverBuffer<Int>(policy: AudioRolloverPolicy(maxBytes: 5))
    let first = bytes.start()
    try append(1, to: &bytes, session: first, time: 0, bytes: 4)
    #expect(throws: AudioBufferFailure.capacityExceeded) { try append(2, to: &bytes, session: first, time: 0.25, bytes: 2) }
    #expect(bytes.snapshot().peakQueuedBytes == 4)
    #expect(bytes.snapshot().queuedBytes == 0)

    var packets = AudioRolloverBuffer<Int>(policy: AudioRolloverPolicy(maxPackets: 2))
    let second = packets.start()
    expectRollover(&packets, session: second)
    try append(1, to: &packets, session: second, time: 0)
    try append(2, to: &packets, session: second, time: 0.25)
    #expect(throws: AudioBufferFailure.capacityExceeded) { try append(3, to: &packets, session: second, time: 0.5) }
    #expect(packets.snapshot().queuedPackets == 0)
}

@Test func audioTimelineSpanCannotRetainStaleAudioAcrossALargeSourceGap() throws {
    var buffer = AudioRolloverBuffer<Int>()
    let session = buffer.start()
    expectRollover(&buffer, session: session)
    try append(1, to: &buffer, session: session, time: 0)
    // Only half a second of data, but more than five seconds of queued source timeline.
    #expect(throws: AudioBufferFailure.capacityExceeded) { try append(2, to: &buffer, session: session, time: 20) }
    #expect(buffer.snapshot().queuedDuration == 0)
}

@Test func audioDuplicateIsNotCopiedOrReplayedAcrossRecognizerRotation() throws {
    var buffer = AudioRolloverBuffer<Int>()
    let session = buffer.start()
    try append(1, to: &buffer, session: session, time: 0)
    expectNext(1, from: &buffer, session: session)
    expectRollover(&buffer, session: session)
    var copied = false
    let result = try buffer.enqueue(session: session, byteCount: 4, presentationTime: 0, duration: 0.25, formatID: 1) { copied = true; return 1 }
    #expect(result == .duplicate)
    #expect(!copied)
    expectResume(&buffer, session: session)
    expectNext(nil, from: &buffer, session: session)
    #expect(buffer.snapshot().duplicatePackets == 1)
}

@Test func partialAudioOverlapFailsInsteadOfGuessingATrimOrRepeatingSpeech() throws {
    var buffer = AudioRolloverBuffer<Int>()
    let session = buffer.start()
    try append(1, to: &buffer, session: session, time: 0, duration: 0.5)
    #expect(throws: AudioBufferFailure.overlappingTime) { try append(2, to: &buffer, session: session, time: 0.25, duration: 0.5) }
    #expect(buffer.snapshot().failure == .overlappingTime)
    #expect(buffer.snapshot().queuedPackets == 0)
}

@Test func audioFormatChangeDuringRolloverCannotBeSilentlyConcatenated() throws {
    var buffer = AudioRolloverBuffer<Int>()
    let session = buffer.start()
    try append(1, to: &buffer, session: session, time: 0)
    expectRollover(&buffer, session: session)
    #expect(throws: AudioBufferFailure.formatChanged) { try append(2, to: &buffer, session: session, time: 0.25, format: 2) }
    #expect(buffer.snapshot().failure == .formatChanged)
    expectResume(&buffer, session: session, succeeds: false)
}

private final class AudioTestPayload: Sendable {
    let bytes = Data([1, 2, 3, 4])
}

@Test func audioStopAndFailureReleaseOwnedPayloadsImmediately() throws {
    var buffer = AudioRolloverBuffer<AudioTestPayload>()
    let session = buffer.start()
    expectRollover(&buffer, session: session)
    weak var held: AudioTestPayload?
    do {
        let payload = AudioTestPayload(); held = payload
        try buffer.enqueue(session: session, byteCount: 4, presentationTime: 0, duration: 0.25, formatID: 1) { payload }
    }
    #expect(held != nil)
    buffer.stop(session: session)
    #expect(held == nil)
    #expect(buffer.snapshot().queuedBytes == 0)
    #expect(buffer.snapshot().phase == .stopped)

    let next = buffer.start()
    do {
        let payload = AudioTestPayload(); held = payload
        try buffer.enqueue(session: next, byteCount: 4, presentationTime: 0, duration: 0.25, formatID: 1) { payload }
    }
    buffer.reject(.copyFailed, session: next)
    #expect(held == nil)
    #expect(buffer.snapshot().failure == .copyFailed)
}

@Test func stoppedAndOldSessionAudioCannotAllocateOrClearTheNewSession() throws {
    var buffer = AudioRolloverBuffer<Int>()
    let old = buffer.start()
    buffer.stop(session: old)
    var allocated = false
    let stopped = try buffer.enqueue(session: old, byteCount: 1, presentationTime: 0, duration: 0.25, formatID: 1) { allocated = true; return 1 }
    #expect(stopped == .ignored)
    let current = buffer.start()
    try append(2, to: &buffer, session: current, time: 0)
    buffer.stop(session: old)
    buffer.reject(.invalidPacket, session: old)
    expectResume(&buffer, session: old, succeeds: false)
    expectNext(nil, from: &buffer, session: old)
    let stale = try buffer.enqueue(session: old, byteCount: 1, presentationTime: 1, duration: 0.25, formatID: 1) { allocated = true; return 3 }
    #expect(stale == .ignored)
    #expect(!allocated)
    expectNext(2, from: &buffer, session: current)
}

@Test func failedAudioCopyDoesNotPartiallyCommitThePacket() throws {
    var buffer = AudioRolloverBuffer<Int>()
    let session = buffer.start()
    try append(1, to: &buffer, session: session, time: 0)
    #expect(throws: AudioBufferFailure.copyFailed) {
        try buffer.enqueue(session: session, byteCount: 4, presentationTime: 0.25, duration: 0.25, formatID: 1) { throw AIUtilityError.storageFailure }
    }
    #expect(buffer.snapshot().acceptedPackets == 1)
    #expect(buffer.snapshot().queuedPackets == 0)
}

@Test func invalidAudioMetadataNeverAllocatesPayload() throws {
    for values in [(Double.nan, 0.25, 4), (0, Double.infinity, 4), (-1, 0.25, 4), (0, 0, 4), (0, 0.25, 0)] {
        var buffer = AudioRolloverBuffer<Int>()
        let session = buffer.start()
        var allocated = false
        #expect(throws: AudioBufferFailure.invalidPacket) {
            try buffer.enqueue(session: session, byteCount: values.2, presentationTime: values.0, duration: values.1, formatID: 1) { allocated = true; return 1 }
        }
        #expect(!allocated)
        #expect(buffer.snapshot().queuedBytes == 0)
    }
}

@Test func manyAudioRotationsRemainBoundedAndDeliverEveryPacketOnce() throws {
    var buffer = AudioRolloverBuffer<Int>()
    let session = buffer.start()
    var received: [Int] = []
    for round in 0..<1000 {
        expectRollover(&buffer, session: session)
        for offset in 0..<3 {
            let id = round * 3 + offset
            try append(id, to: &buffer, session: session, time: Double(id) * 0.25)
        }
        expectResume(&buffer, session: session)
        while let packet = buffer.takeNext(session: session) { received.append(packet.payload) }
        #expect(buffer.snapshot().queuedBytes == 0)
    }
    #expect(received == Array(0..<3000))
    #expect(buffer.snapshot().peakQueuedBytes == 12)
    #expect(buffer.snapshot().dequeuedPackets == 3000)
}

@Test func sourceAudioGapsAreObservableAndDebugOutputDoesNotExposePayload() throws {
    var buffer = AudioRolloverBuffer<String>()
    let session = buffer.start()
    try buffer.enqueue(session: session, byteCount: 4, presentationTime: 0, duration: 0.25, formatID: 1) { "synthetic audio bytes" }
    #expect(!String(reflecting: buffer).contains("synthetic audio bytes"))
    let next = buffer.takeNext(session: session)
    let packet = try #require(next)
    #expect(!String(reflecting: packet).contains("synthetic audio bytes"))
    try buffer.enqueue(session: session, byteCount: 4, presentationTime: 2, duration: 0.25, formatID: 1) { "next" }
    #expect(buffer.snapshot().sourceGapSeconds > 1.74)
}
