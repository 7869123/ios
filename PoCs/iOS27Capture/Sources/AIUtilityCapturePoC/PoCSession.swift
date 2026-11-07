#if os(iOS) && canImport(ScreenCaptureKit)
import Foundation
import Combine
import AIUtilityCore

@available(iOS 27.0, *)
@MainActor public final class PoCSession: ObservableObject {
    public let speech = LocalSpeechProbe()
    public let pip = SubtitlePiPProbe()
    public let capture: ScreenAudioProbe
    @Published public private(set) var translationState = "未启用 API 翻译"
    private var translationTask: Task<Void, Never>?
    private var revision = 0
    private var running = false
    /// Supply a real TranslationEngine built with the shared Keychain coordinator to test translation.
    /// Nil means local ASR-only diagnostics, clearly marked in the host.
    public init(engine: TranslationEngine? = nil, provider: ProviderID = .openAI, targetLanguage: String = "简体中文") {
        capture = ScreenAudioProbe(speech: speech)
        capture.onTermination = { [weak self] in await self?.stop() }
        if engine != nil { translationState = "等待 final 语音段" }
        speech.onFinalText = { [weak self] text in
            guard let self, let engine else { return }
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
        guard !running else { return }
        running = true
        do {
            try await speech.start()
            guard running else { speech.stop(); return }
            try pip.prepare(); capture.presentPicker()
        }
        catch { running = false; speech.stop(); pip.stop(); throw error }
    }
    public func stop() async {
        running = false
        revision += 1; translationTask?.cancel(); translationTask = nil
        await capture.stop(); speech.stop(); pip.stop()
    }
}
#endif
