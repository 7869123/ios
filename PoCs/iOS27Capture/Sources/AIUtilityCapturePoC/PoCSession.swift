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
    private var revision = 0
    private let lifecycle = ProbeLifecycle()
    private var audioObservers: [NSObjectProtocol] = []
    /// Supply a real TranslationEngine built with the shared Keychain coordinator to test translation.
    /// Nil means local ASR-only diagnostics, clearly marked in the host.
    public init(engine: TranslationEngine? = nil, provider: ProviderID = .openAI, targetLanguage: String = "简体中文") {
        capture = ScreenAudioProbe(speech: speech)
        if engine != nil { translationState = "等待 final 语音段" }
        speech.onFinalText = { [weak self] text in
            guard let self, let engine, self.lifecycle.accepts(self.lifecycle.revision) else { return }
            self.revision += 1
            let revision = self.revision
            self.translationTask?.cancel()
            self.translationState = "正在翻译 final 语音段"
            self.translationTask = Task { [weak self] in
                do {
                    let translation = try await engine.translate(text, targetLanguage: targetLanguage,
                        provider: provider, feature: .videoSubtitle)
                    guard !Task.isCancelled, self?.revision == revision else { return }
                    self?.pip.caption = translation
                    self?.translationState = "已收到译文；需人工核验"
                } catch {
                    guard self?.revision == revision else { return }
                    self?.translationState = "翻译失败：" + AIUtilityError.sanitized(error).description
                }
            }
        }
    }
    public func start() async throws {
        guard let session = lifecycle.begin() else { throw ProbeError.operationInProgress }
        do {
            try Task.checkCancellation()
            try await speech.start()
            try Task.checkCancellation()
            guard lifecycle.accepts(session) else { throw CancellationError() }
            try pip.prepare()
            observeAudioEvents(session: session)
            capture.onTermination = { [weak self] in await self?.stop(expected: session) }
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
    private func stop(expected: UInt64?) async {
        await lifecycle.stop(expected: expected) { [self] in
            audioObservers.forEach { NotificationCenter.default.removeObserver($0) }
            audioObservers.removeAll()
            revision += 1; translationTask?.cancel(); translationTask = nil
            // Detach producers before resource release suspends. Restart stays blocked.
            speech.stop(); pip.stop()
            await capture.stop()
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
                        self.translationState = "音频中断、路由变化或媒体服务重置；已停止，请手动重新授权"
                    }
                }
            }
            audioObservers.append(token)
        }
    }
}
#endif
