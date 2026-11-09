#if os(iOS)
import Foundation
import Combine
import CoreMedia
import AudioToolbox
import AIUtilityCore
@preconcurrency import Speech

/// Only the serial ScreenCaptureKit queue calls append. Main actor swaps the request under lock.
final class SpeechAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var sampleRate: Double?
    private var channels: UInt32?
    private var invalidFormat = false
    func install(_ value: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }
        request = value; sampleRate = nil; channels = nil; invalidFormat = false
    }
    func append(_ buffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let request else { return }
        guard CMSampleBufferIsValid(buffer), CMSampleBufferDataIsReady(buffer),
              let description = CMSampleBufferGetFormatDescription(buffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate.isFinite,
              (8000...192000).contains(format.mSampleRate), (1...2).contains(format.mChannelsPerFrame),
              sampleRate == nil || sampleRate == format.mSampleRate,
              channels == nil || channels == format.mChannelsPerFrame else { invalidFormat = true; return }
        sampleRate = format.mSampleRate; channels = format.mChannelsPerFrame
        request.appendAudioSampleBuffer(buffer)
    }
    func hasInvalidFormat() -> Bool { lock.lock(); defer { lock.unlock() }; return invalidFormat }
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
        sink.install(request)
        state = "等待音频；尚未验证"
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let failed = error != nil
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
                if self.sink.hasInvalidFormat() { self.fail(); return }
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
        sink.install(nil); request?.endAudio()
        // No audio replay or parallel recognizers. The bounded drain gap must be measured on device.
        rolloverTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<100 {
                guard !Task.isCancelled, self.revision == revision, self.requestRevision == requestRevision else { return }
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
        stop()
        state = "本地识别已停止：权限、语言包、格式或识别任务错误；请检查后手动重启"
        onFailure?()
    }
    public func stop() {
        revision &+= 1; requestRevision &+= 1
        rotationTask?.cancel(); rotationTask = nil
        rolloverTask?.cancel(); rolloverTask = nil
        sink.install(nil); request?.endAudio(); task?.cancel()
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
