#if os(iOS) && canImport(ScreenCaptureKit)
import Foundation
import Combine
import AVFoundation
import AIUtilityCore

@available(iOS 27.0, *)
@MainActor public final class PoCSession: ObservableObject {
    public let speech = LocalSpeechProbe()
    public let pip = SubtitlePiPProbe()
    public let capture: ScreenAudioProbe
    @Published public private(set) var translationState = "未启用 API 翻译"
    private var translationTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private enum Input: Sendable { case transcript(SpeechTranscript), tick(TimeInterval) }
    private var input: AsyncStream<Input>.Continuation?
    private let pipeline: SubtitleTranslationSession?
    private let provider: ProviderID
    private let sourceLanguage: SupportedLanguage
    private let languages: TranslationLanguages?
    private var revision = 0
    private let lifecycle = ProbeLifecycle()
    private var audioObservers: [NSObjectProtocol] = []
    /// Supply a real TranslationEngine built with the shared Keychain coordinator to test translation.
    /// Nil means local ASR-only diagnostics, clearly marked in the host.
    public init(engine: TranslationEngine? = nil, provider: ProviderID = .openAI, targetLanguage: String = "简体中文",
                sourceLanguage: SupportedLanguage = .english) {
        self.provider = provider; self.sourceLanguage = sourceLanguage
        let target: SupportedLanguage?
        switch targetLanguage.lowercased() {
        case "zh-cn", "简体中文", "chinese", "simplified chinese": target = .simplifiedChinese
        case "en", "en-us", "english": target = .english
        case "ja", "ja-jp", "日本語", "japanese": target = .japanese
        default: target = nil
        }
        self.languages = target.map { TranslationLanguages(source: SourceLanguage(rawValue: sourceLanguage.rawValue) ?? .english, target: $0) }
        self.pipeline = engine.map { SubtitleTranslationSession(engine: $0) }
        capture = ScreenAudioProbe(speech: speech)
        if engine != nil { translationState = "等待稳定语音段；无真机结论" }
    }
    public func start() async throws {
        guard let session = lifecycle.begin() else { throw ProbeError.operationInProgress }
        do {
            try Task.checkCancellation()
            try await prepareTranslation(session: session)
            guard lifecycle.accepts(session) else { throw CancellationError() }
            speech.onFailure = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.lifecycle.accepts(session) else { return }
                    await self.stop(expected: session)
                    if self.lifecycle.revision == session { self.translationState = "本地 ASR 失败；已停止，请检查权限、语言包和音频格式" }
                }
            }
            try await speech.start(language: sourceLanguage)
            try Task.checkCancellation()
            guard lifecycle.accepts(session) else { throw CancellationError() }
            try pip.prepare()
            observeAudioEvents(session: session)
            capture.onTermination = { [weak self] in await self?.stop(expected: session, captureAlreadyAttempted: true) }
            capture.presentPicker()
            lifecycle.didStart(session)
        }
        catch {
            if lifecycle.accepts(session) { await stop(expected: session) }
            throw error
        }
    }
    public func stop() async {
        await stop(expected: nil)
    }
    private func prepareTranslation(session: UInt64) async throws {
        guard let pipeline else { return }
        guard let languages else { throw AIUtilityError.invalidRequest }
        let events = try await pipeline.events()
        let handle = try await pipeline.start(provider: provider, languages: languages)
        guard lifecycle.accepts(session), !Task.isCancelled else { await pipeline.stop(); throw CancellationError() }
        revision &+= 1
        let revision = self.revision
        let pair = AsyncStream<Input>.makeStream(bufferingPolicy: .bufferingNewest(32))
        input = pair.continuation
        speech.onTranscript = { [weak self] transcript in self?.send(.transcript(transcript), session: session) }
        speech.onStableTick = { [weak self] time in self?.send(.tick(time), session: session) }
        inputTask = Task { @MainActor [weak self] in
            for await value in pair.stream {
                guard let self, self.lifecycle.accepts(session), self.revision == revision, !Task.isCancelled else { return }
                do {
                    switch value {
                    case .transcript(let transcript): try await pipeline.ingest(transcript, session: handle)
                    case .tick(let time): try await pipeline.flushStable(at: time, session: handle)
                    }
                } catch {
                    guard self.lifecycle.accepts(session), self.revision == revision else { return }
                    self.translationState = "识别输入失败：" + AIUtilityError.sanitized(error).description
                    await self.stop(expected: session); return
                }
            }
        }
        translationTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self, self.lifecycle.accepts(session), self.revision == revision, !Task.isCancelled else { return }
                switch event {
                case .translated(let current, _, let text, _, _) where current == handle:
                    self.pip.caption = text
                    self.translationState = "已收到分段译文；需真机核验顺序和延迟"
                case .failed(let current, _, let error) where current == handle:
                    self.translationState = "翻译失败：" + error.description
                    if [.cancelled, .unauthorized, .forbidden, .quotaExceeded, .budgetExceeded, .notConfigured, .modelUnavailable].contains(error) {
                        await self.stop(expected: session); return
                    }
                case .dropped(let current, let count) where current == handle:
                    self.translationState = "字幕队列达到上限，已丢弃 \(count) 段；请降低推理强度或暂停"
                default: break
                }
            }
        }
    }
    private func send(_ value: Input, session: UInt64) {
        guard lifecycle.accepts(session) else { return }
        if let result = input?.yield(value), case .dropped(_) = result {
            translationState = "识别输入队列达到上限，存在丢段；需人工核验"
        }
    }
    private func stop(expected: UInt64?, captureAlreadyAttempted: Bool = false) async {
        await lifecycle.stop(expected: expected) { [self] in
            audioObservers.forEach { NotificationCenter.default.removeObserver($0) }
            audioObservers.removeAll()
            revision &+= 1; translationTask?.cancel(); translationTask = nil
            input?.finish(); input = nil; inputTask?.cancel(); inputTask = nil
            // Detach producers before resource release suspends. Restart stays blocked.
            speech.onTranscript = nil; speech.onStableTick = nil; speech.onFailure = nil
            speech.stop(); pip.stop()
            // Termination has already attempted capture release; only a user stop retries a failure.
            if !captureAlreadyAttempted { await capture.stop() }
            await pipeline?.stop()
            await pipeline?.closeEventStreams()
            let speechStopped = await speech.waitUntilStopped()
            return capture.isStopped && pip.isStopped && speechStopped
        }
    }
    private func observeAudioEvents(session: UInt64) {
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification] {
            let token = NotificationCenter.default.addObserver(forName: name,
                object: nil, queue: .main) { [weak self] notification in
                let interruptionEnded = name == AVAudioSession.interruptionNotification &&
                    (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
                let ownCategoryChange = name == AVAudioSession.routeChangeNotification &&
                    (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.categoryChange.rawValue
                guard !interruptionEnded, !ownCategoryChange else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.lifecycle.accepts(session) else { return }
                    await self.stop(expected: session)
                    // No automatic restart or authorization after interruptions/route changes.
                    if self.lifecycle.revision == session {
                        self.translationState = self.lifecycle.phase == .idle
                            ? "音频中断、路由变化或媒体服务重置；已停止，请手动重新授权"
                            : "系统资源释放返回错误；禁止重新开始，请再次停止或结束 App"
                    }
                }
            }
            audioObservers.append(token)
        }
    }
}
#endif
