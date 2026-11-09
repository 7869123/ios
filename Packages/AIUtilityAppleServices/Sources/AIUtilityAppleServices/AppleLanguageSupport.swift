import AIUtilityCore
import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage

/// Text detection only. This does not claim automatic language selection for streaming Speech.
public struct AppleTextLanguageDetector: TextLanguageDetector {
    public init() {}
    public func detect(_ text: String) async throws -> SupportedLanguage {
        guard !Task.isCancelled else { throw AIUtilityError.cancelled }
        guard !text.isEmpty, text.utf8.count <= 24_576 else { throw AIUtilityError.invalidRequest }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let language = recognizer.dominantLanguage, (hypotheses[language] ?? 0) >= 0.6 else {
            throw AIUtilityError.invalidRequest // Uncertain/unsupported detection requires a manual source choice.
        }
        switch language {
        case .simplifiedChinese, .traditionalChinese: return .simplifiedChinese
        case .english: return .english
        case .japanese: return .japanese
        default: throw AIUtilityError.invalidRequest
        }
    }
}
#endif

#if os(iOS) && canImport(Speech)
@preconcurrency import Speech

public struct SpeechLanguageCapability: Sendable {
    public let language: SupportedLanguage
    public let localeIdentifier: String
    public let supportedLocale: Bool
    public let available: Bool
    public let onDeviceRecognition: Bool
}

@MainActor public enum AppleSpeechLanguageSupport {
    /// No permission prompt or capture starts here. Check again after language packs/settings change.
    public static func capabilities() -> [SpeechLanguageCapability] {
        let supported = SFSpeechRecognizer.supportedLocales()
        return SupportedLanguage.allCases.map { language in
            let locale = Locale(identifier: language.speechLocaleIdentifier)
            let recognizer = SFSpeechRecognizer(locale: locale)
            return SpeechLanguageCapability(language: language, localeIdentifier: locale.identifier,
                supportedLocale: supported.contains(locale), available: recognizer?.isAvailable == true,
                onDeviceRecognition: recognizer?.supportsOnDeviceRecognition == true)
        }
    }
}
#endif
