#if os(iOS)
import Foundation
import Combine
import CoreMedia
@preconcurrency import Speech

/// Only the serial ScreenCaptureKit queue calls append. Main actor swaps the request under lock.
final class SpeechAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func install(_ value: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }; request = value
    }
    func append(_ buffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }; request?.appendAudioSampleBuffer(buffer)
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
    public var onFinalText: ((String) -> Void)?
    public init() {}
    public func start(locale: Locale = Locale(identifier: "en-US")) async throws {
        stop()
        let revision = self.revision
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard self.revision == revision else { throw CancellationError() }
        guard authorization == .authorized,
              let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            state = "本地语音识别不可用（权限、语言包或设备能力）"
            throw ProbeError.speechUnavailable
        }
        self.recognizer = recognizer
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
                guard self.revision == revision else { return }
                if let text, !text.isEmpty { self.caption = text; self.state = "已收到本地识别文本；需人工比对" }
                if isFinal, let text, !text.isEmpty { self.onFinalText?(text) }
                if failed || isFinal {
                    self.sink.install(nil)
                    self.state = "识别会话结束，请停止后重启（需验证时长限制）"
                }
            }
        }
    }
    public func stop() {
        revision += 1
        sink.install(nil); request?.endAudio(); task?.cancel()
        request = nil; task = nil; recognizer = nil; state = "已停止；无真机结论"
    }
}

public enum ProbeError: Error { case speechUnavailable, captureUnavailable, pictureInPictureUnavailable, frameCreationFailed }
#endif
