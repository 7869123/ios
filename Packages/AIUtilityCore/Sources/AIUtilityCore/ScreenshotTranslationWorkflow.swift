import Foundation

public struct OCRDraft: Sendable, CustomStringConvertible, CustomReflectable {
    public let id: UUID
    public let text: String
    public let lines: [OCRLine]
    public let recognitionDuration: Duration
    public var description: String { "<OCRDraft: redacted>" }
    public var customMirror: Mirror { Mirror(self, children: ["draft": "<redacted>"]) }
}

/// Manual invocation API for Claude's photo picker, region selector and future App Intent.
/// Recognize once, edit locally, explicitly translate; no image or OCR request goes to an AI API.
public actor ScreenshotTranslationWorkflow {
    private let ocr: any RegionOCRService
    private let translation: TranslationEngine
    private var revision: UInt64 = 0
    private var current: OCRDraft?
    private var recognizing: Task<OCRResult, any Error>?
    private var translating: Task<String, any Error>?
    public init(ocr: any RegionOCRService, translation: TranslationEngine) { self.ocr = ocr; self.translation = translation }
    deinit { recognizing?.cancel(); translating?.cancel() }

    public func recognize(imageData: Data, source: SourceLanguage, region: OCRRegion? = nil,
                          timeout: TimeInterval = 20) async throws -> OCRDraft {
        guard recognizing == nil, translating == nil else { throw AIUtilityError.configurationBusy }
        guard !Task.isCancelled else { throw AIUtilityError.cancelled }
        revision &+= 1
        let expected = revision
        let clock = ContinuousClock(); let started = clock.now
        let languages = source.language.map { [$0.visionLanguageIdentifier] } ?? SupportedLanguage.allCases.map(\.visionLanguageIdentifier)
        let ocr = self.ocr
        let task = Task { try await withDeadline(timeout) { try await ocr.recognize(imageData: imageData, languages: languages, region: region) } }
        recognizing = task
        defer { if revision == expected { recognizing = nil } }
        let result: OCRResult
        do {
            result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch { throw AIUtilityError.sanitized(error) }
        guard revision == expected, !Task.isCancelled else { throw AIUtilityError.cancelled }
        await translation.diagnostics.record(stage: .localOCR, milliseconds: started.duration(to: clock.now).milliseconds, outcome: .success)
        guard revision == expected, !Task.isCancelled else { throw AIUtilityError.cancelled }
        let draft = OCRDraft(id: UUID(), text: result.text, lines: result.lines, recognitionDuration: started.duration(to: clock.now))
        current = draft; return draft
    }
    public func draft() -> OCRDraft? { current }
    @discardableResult
    public func edit(_ text: String, draft id: UUID) throws -> OCRDraft {
        guard recognizing == nil, translating == nil else { throw AIUtilityError.configurationBusy }
        guard let current, current.id == id, text.utf8.count <= 24_576 else { throw AIUtilityError.invalidRequest }
        let draft = OCRDraft(id: UUID(), text: text, lines: [], recognitionDuration: current.recognitionDuration)
        self.current = draft; return draft
    }
    public func translate(draft id: UUID, provider: ProviderID, languages: TranslationLanguages? = nil,
                          timeout: TimeInterval = 30) async throws -> String {
        guard recognizing == nil, translating == nil else { throw AIUtilityError.configurationBusy }
        guard let current, current.id == id else { throw AIUtilityError.invalidRequest }
        let expected = revision
        let translation = self.translation
        let task = Task { try await translation.translate(current.text, provider: provider, feature: .discordScreenshot, languages: languages, timeout: timeout) }
        translating = task
        defer { if revision == expected { translating = nil } }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard revision == expected, !Task.isCancelled else { throw AIUtilityError.cancelled }
            return result
        } catch { throw AIUtilityError.sanitized(error) }
    }
    /// Blocks new work until both producers acknowledge cancellation; preserves editable draft.
    public func cancel() async {
        revision &+= 1
        let expected = revision
        let recognition = recognizing, translation = translating
        recognition?.cancel(); translation?.cancel()
        _ = try? await recognition?.value
        _ = try? await translation?.value
        if revision == expected { recognizing = nil; translating = nil }
    }
    public func clear() async {
        let expected = revision &+ 1
        await cancel()
        if revision == expected { current = nil }
    }
}
