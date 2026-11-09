#if os(iOS)
import Foundation
import Combine
import CoreMedia
import AudioToolbox
import AIUtilityCore
@preconcurrency import Speech

/// The queued sample owns a deep copy of PCM bytes, not a pointer into the capture pool.
/// No code mutates it after construction; the sink serializes all Speech access.
private struct OwnedAudioSample: @unchecked Sendable {
    let sample: CMSampleBuffer
    static func copy(_ source: CMSampleBuffer, block: CMBlockBuffer, format: CMFormatDescription,
                     bytes: Int) throws -> OwnedAudioSample {
        var copiedBlock: CMBlockBuffer?
        guard CMBlockBufferCreateContiguous(allocator: kCFAllocatorDefault, sourceBuffer: block,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes,
            flags: kCMBlockBufferAlwaysCopyDataFlag, blockBufferOut: &copiedBlock) == noErr,
              let copiedBlock else { throw AudioBufferFailure.copyFailed }
        var copiedSample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: copiedBlock, formatDescription: format, sampleCount: CMSampleBufferGetNumSamples(source),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source), packetDescriptions: nil,
            sampleBufferOut: &copiedSample) == noErr, let copiedSample else { throw AudioBufferFailure.copyFailed }
        return OwnedAudioSample(sample: copiedSample)
    }
}

/// One bounded queue for normal delivery and rollover. A single worker submits FIFO audio.
/// The lock covers one Speech append, not the entire backlog, so stop can detach between packets.
final class SpeechAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private let delivery = DispatchQueue(label: "com.aiutility.poc.speech-delivery")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var requestToken: UUID?
    private var buffer = AudioRolloverBuffer<OwnedAudioSample>()
    private var format: CMFormatDescription?
    private var worker: UUID?

    func install(_ value: SFSpeechAudioBufferRecognitionRequest) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        if buffer.phase == .stopped { buffer.start(); format = nil }
        else {
            guard let session = buffer.session, buffer.resume(session: session) else { return nil }
        }
        let token = UUID(); requestToken = token
        request = value; scheduleLocked(); return token
    }
    @discardableResult func beginRollover(requestToken expected: UUID? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return beginRolloverLocked(requestToken: expected)
    }
    /// Speech may invoke a result handler during append; never wait on its delivery lock there.
    /// If the lock is occupied, the revision-checked main-actor callback performs the transition.
    func sealFromCallback(requestToken: UUID) {
        guard lock.try() else { return }
        defer { lock.unlock() }
        _ = beginRolloverLocked(requestToken: requestToken)
    }
    private func beginRolloverLocked(requestToken expected: UUID?) -> Bool {
        guard let requestToken, expected == nil || requestToken == expected else { return false }
        if buffer.phase == .buffering { return true }
        guard let session = buffer.session, buffer.beginRollover(session: session) else { return false }
        request = nil; return true
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        request = nil; requestToken = nil; format = nil
        if let session = buffer.session { buffer.stop(session: session) }
    }
    func snapshot() -> AudioRolloverSnapshot {
        lock.lock(); defer { lock.unlock() }; return buffer.snapshot()
    }
    func append(_ buffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let session = self.buffer.session,
              self.buffer.phase == .live || self.buffer.phase == .buffering else { return }
        guard CMSampleBufferIsValid(buffer), CMSampleBufferDataIsReady(buffer),
              let description = CMSampleBufferGetFormatDescription(buffer),
              let audio = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              audio.mFormatID == kAudioFormatLinearPCM, audio.mSampleRate.isFinite,
              (8000...192000).contains(audio.mSampleRate), (1...2).contains(audio.mChannelsPerFrame),
              CMSampleBufferGetNumSamples(buffer) > 0,
              let block = CMSampleBufferGetDataBuffer(buffer) else {
            self.buffer.reject(.invalidPacket, session: session); request = nil; return
        }
        if let format, !CMFormatDescriptionEqual(description, otherFormatDescription: format) {
            self.buffer.reject(.formatChanged, session: session); request = nil; return
        }
        do {
            try self.buffer.enqueue(session: session, byteCount: CMBlockBufferGetDataLength(block),
                presentationTime: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer)),
                duration: Double(CMSampleBufferGetNumSamples(buffer)) / audio.mSampleRate, formatID: 1) {
                    try OwnedAudioSample.copy(buffer, block: block, format: description, bytes: CMBlockBufferGetDataLength(block))
                }
            self.format = description
            scheduleLocked()
        } catch { request = nil } // The bounded queue retains a safe failure code, never raw audio/errors.
    }
    private func scheduleLocked() {
        guard worker == nil, request != nil, let session = buffer.session, buffer.phase == .live,
              buffer.snapshot().queuedPackets > 0 else { return }
        let id = UUID(); worker = id
        delivery.async { [weak self] in
            guard let self else { return }
            self.drain(worker: id, session: session)
        }
    }
    private func drain(worker id: UUID, session: UUID) {
        while true {
            let again = autoreleasepool { () -> Bool in
                lock.lock(); defer { lock.unlock() }
                guard worker == id else { return false }
                guard buffer.session == session, buffer.phase == .live, let request else {
                    worker = nil
                    scheduleLocked() // A queued old worker may wake after a newer session starts.
                    return false
                }
                guard let packet = buffer.takeNext(session: session) else {
                    worker = nil; return false
                }
                request.appendAudioSampleBuffer(packet.payload.sample)
                return true
            }
            if !again { return }
        }
    }
}

@available(iOS 27.0, *)
@MainActor public final class LocalSpeechProbe: ObservableObject {
    @Published public private(set) var caption = "等待系统音频"
    @Published public private(set) var state = "未验证"
    let sink = SpeechAudioSink()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var revision = 0
    private var requestRevision = 0
    private var draining: SFSpeechRecognitionTask?
    private var rotationTask: Task<Void, Never>?
    private var rolloverTask: Task<Void, Never>?
    private var epoch = UUID()
    private var sequence: UInt64 = 0
    private var lastText = ""
    private var finalSent = false
    private var rolling = false
    private var sessionBegan = ContinuousClock().now
    public var onTranscript: ((SpeechTranscript) -> Void)?
    public var onStableTick: ((TimeInterval) -> Void)?
    public var onFailure: (() -> Void)?
    public var onFinalText: ((String) -> Void)?
    /// Queue counts/durations only; dequeued audio is not proof of successful recognition.
    public var audioBufferSnapshot: AudioRolloverSnapshot { sink.snapshot() }
    public init() {}
    public func start(language: SupportedLanguage) async throws {
        try await start(locale: Locale(identifier: language.speechLocaleIdentifier))
    }
    public func start(locale: Locale = Locale(identifier: "en-US")) async throws {
        stop()
        let revision = self.revision
        guard SupportedLanguage.allCases.contains(where: {
            $0.speechLocaleIdentifier.caseInsensitiveCompare(locale.identifier.replacingOccurrences(of: "_", with: "-")) == .orderedSame
        }) else { throw ProbeError.speechUnavailable }
        let stopped = await waitUntilStopped()
        try Task.checkCancellation()
        guard self.revision == revision else { throw CancellationError() }
        guard stopped else { throw ProbeError.speechUnavailable }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard self.revision == revision else { throw CancellationError() }
        guard authorization == .authorized,
              let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            state = "本地语音识别不可用（权限、语言包或设备能力）"
            throw ProbeError.speechUnavailable
        }
        self.recognizer = recognizer
        sessionBegan = ContinuousClock().now
        try beginRequest(revision: revision)
    }
    private func beginRequest(revision: Int) throws {
        guard self.revision == revision, let recognizer, recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { throw ProbeError.speechUnavailable }
        requestRevision &+= 1
        let requestRevision = self.requestRevision
        epoch = UUID(); sequence = 0; lastText = ""; finalSent = false; rolling = false
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        guard let audioRequest = sink.install(request) else { throw ProbeError.speechUnavailable }
        state = "等待音频；尚未验证"
        let sink = self.sink
        task = recognizer.recognitionTask(with: request) { [weak self, sink] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let failed = error != nil
            // Best-effort sealing before main-actor scheduling, without blocking a Speech callback.
            // A late result from an older request cannot detach a newer recognizer's input.
            if isFinal || failed { sink.sealFromCallback(requestToken: audioRequest) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.revision == revision, self.requestRevision == requestRevision else { return }
                if let text, !text.isEmpty {
                    guard text.count <= 4096, text.utf8.count <= 24_576 else { self.fail(); return }
                    self.lastText = text; self.caption = text
                    self.state = "已收到本地识别文本；需人工比对"
                    self.publish(text, final: isFinal)
                }
                if isFinal { self.rollover(revision: revision, requestRevision: requestRevision) }
                else if failed && !self.rolling { self.fail() }
            }
        }
        let began = ContinuousClock().now
        rotationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, self.revision == revision, self.requestRevision == requestRevision, !self.rolling else { return }
                if self.sink.snapshot().failure != nil { self.fail(); return }
                self.onStableTick?(self.elapsed())
                if began.duration(to: ContinuousClock().now) >= .seconds(50) {
                    self.rollover(revision: revision, requestRevision: requestRevision); return
                }
            }
        }
    }
    private func elapsed() -> TimeInterval {
        let duration = sessionBegan.duration(to: ContinuousClock().now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
    private func publish(_ text: String, final: Bool) {
        guard !finalSent else { return }
        sequence &+= 1
        onTranscript?(SpeechTranscript(utteranceID: epoch, sequence: sequence, text: text, isFinal: final, timestamp: elapsed()))
        if final { finalSent = true; onFinalText?(text) }
    }
    private func rollover(revision: Int, requestRevision: Int) {
        guard self.revision == revision, self.requestRevision == requestRevision, !rolling else { return }
        rolling = true; rotationTask?.cancel(); rotationTask = nil
        guard sink.beginRollover() else { fail(); return }
        request?.endAudio()
        // Capture continues into bounded memory. New Speech consumes only unsubmitted packets.
        rolloverTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<100 {
                guard !Task.isCancelled, self.revision == revision, self.requestRevision == requestRevision else { return }
                if self.sink.snapshot().failure != nil { self.fail(); return }
                if self.task?.state == .completed { break }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
            guard self.revision == revision, self.requestRevision == requestRevision, !Task.isCancelled else { return }
            guard self.task?.state == .completed else { self.fail(); return }
            if !self.lastText.isEmpty { self.publish(self.lastText, final: true) }
            self.request = nil; self.task = nil; self.rolloverTask = nil
            do { try self.beginRequest(revision: revision) } catch { self.fail() }
        }
    }
    private func fail() {
        let bufferFailure = sink.snapshot().failure
        stop()
        if let bufferFailure { state = "音频缓存已停止：" + bufferFailure.rawValue + "；请检查后手动重启" }
        else { state = "本地识别已停止：权限、语言包、格式或识别任务错误；请检查后手动重启" }
        onFailure?()
    }
    public func stop() {
        revision &+= 1; requestRevision &+= 1
        rotationTask?.cancel(); rotationTask = nil
        rolloverTask?.cancel(); rolloverTask = nil
        sink.stop(); request?.endAudio(); task?.cancel()
        if let task { draining = task }
        request = nil; task = nil; recognizer = nil; state = "已停止；无真机结论"
        lastText = ""; finalSent = false; rolling = false
    }
    /// A missing acknowledgement prevents replacement; no unbounded polling or automatic retry.
    public func waitUntilStopped() async -> Bool {
        guard task == nil else { return false }
        let revision = self.revision
        for _ in 0..<100 {
            guard self.revision == revision, !Task.isCancelled else { return false }
            guard let draining else { return true }
            if draining.state == .completed { self.draining = nil; return true }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return false
    }
}

public enum ProbeError: Error { case speechUnavailable, captureUnavailable, pictureInPictureUnavailable, frameCreationFailed, operationInProgress }
#endif
