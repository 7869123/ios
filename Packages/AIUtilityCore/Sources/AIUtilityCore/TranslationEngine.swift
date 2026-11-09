import Foundation

public struct PrivacyPolicy: Sendable {
    public let redactEmails: Bool
    public init(redactEmails: Bool = true) { self.redactEmails = redactEmails }
}

struct RedactedText: Sendable {
    let text: String
    private let replacements: [String: String]
    private let prefix: String

    init(_ input: String, key: APIKey, policy: PrivacyPolicy) {
        let prefix = "AIU_SECRET_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "_"
        var text = input
        var replacements: [String: String] = [:]
        func replace(_ secret: String) {
            guard !secret.isEmpty, text.contains(secret) else { return }
            let marker = "[" + prefix + String(replacements.count) + "]"
            text = text.replacingOccurrences(of: secret, with: marker)
            replacements[marker] = secret
        }
        key.withValue { replace($0) }
        var patterns = [#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, #"\bsk-[A-Za-z0-9_-]{8,}"#]
        if policy.redactEmails { patterns.append(#"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#) }
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            let secrets = matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            secrets.forEach { replace($0) }
        }
        self.text = text; self.replacements = replacements; self.prefix = prefix
    }

    func restore(_ output: String) throws -> String {
        var result = output
        // Missing/modified markers must not silently destroy protected source data.
        for (marker, secret) in replacements {
            guard result.contains(marker) else { throw AIUtilityError.privacyViolation }
            result = result.replacingOccurrences(of: marker, with: secret)
        }
        guard !result.contains(prefix) else { throw AIUtilityError.privacyViolation }
        return result
    }
}

public struct TranslationEngine: Sendable {
    private let configurations: ConfigurationCoordinator
    private let gateway: ProviderGateway
    private let privacy: PrivacyPolicy
    private let preferences: TranslationPreferences?
    private let detector: (any TextLanguageDetector)?
    public let diagnostics: TranslationDiagnostics
    public init(configurations: ConfigurationCoordinator, gateway: ProviderGateway,
                privacy: PrivacyPolicy = PrivacyPolicy(), preferences: TranslationPreferences? = nil,
                detector: (any TextLanguageDetector)? = nil, diagnostics: TranslationDiagnostics = TranslationDiagnostics()) {
        self.configurations = configurations; self.gateway = gateway; self.privacy = privacy
        self.preferences = preferences; self.detector = detector
        self.diagnostics = diagnostics
    }

    public var supportsAutomaticTextDetection: Bool { detector != nil }

    /// Uses independently persisted feature settings. Supplying languages overrides only this call.
    public func translate(_ text: String, provider: ProviderID, feature: TranslationFeature,
                          languages: TranslationLanguages? = nil, maxOutputTokens: Int? = nil,
                          timeout: TimeInterval = 30) async throws -> String {
        try await translateMeasured(text, provider: provider, feature: feature, languages: languages,
                                    maxOutputTokens: maxOutputTokens, timeout: timeout).text
    }

    public func translateMeasured(_ text: String, provider: ProviderID, feature: TranslationFeature,
                                  languages: TranslationLanguages? = nil, maxOutputTokens: Int? = nil,
                                  timeout: TimeInterval = 30) async throws -> TranslationOutput {
        let clock = ContinuousClock()
        let started = clock.now
        try validateText(text)
        let selected: TranslationLanguages
        if let languages { selected = languages }
        else { selected = try await preferences?.languages(for: feature) ?? TranslationLanguages() }
        guard !Task.isCancelled else { throw AIUtilityError.cancelled }
        let source: SupportedLanguage
        if let language = selected.source.language { source = language }
        else {
            guard let detector else { throw AIUtilityError.unsupportedPlatform }
            source = try await detector.detect(text)
            guard !Task.isCancelled else { throw AIUtilityError.cancelled }
        }
        if source == selected.target {
            return TranslationOutput(text: text, duration: started.duration(to: clock.now), requestedAPI: false)
        }
        let output = try await execute(text, source: source.instructionName, target: selected.target.instructionName,
                                       provider: provider, feature: feature, maxOutputTokens: maxOutputTokens, timeout: timeout)
        return TranslationOutput(text: output, duration: started.duration(to: clock.now), requestedAPI: true)
    }

    /// Send OCR text or finalized speech segments here, never screenshots/audio by default.
    public func translate(_ text: String, targetLanguage: String, provider: ProviderID,
                          feature: TranslationFeature, maxOutputTokens: Int? = nil,
                          timeout: TimeInterval = 30) async throws -> String {
        try validateText(text)
        guard !targetLanguage.isEmpty, targetLanguage.utf8.count <= 80,
              targetLanguage.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || " -()".unicodeScalars.contains($0) })
        else { throw AIUtilityError.invalidRequest }
        // Existing UI also benefits from stored source preferences, prompts and reasoning budgets.
        let selected = try await preferences?.languages(for: feature) ?? TranslationLanguages()
        let knownTarget: SupportedLanguage?
        switch targetLanguage.lowercased() {
        case "zh-cn", "简体中文", "chinese", "simplified chinese": knownTarget = .simplifiedChinese
        case "en", "en-us", "english": knownTarget = .english
        case "ja", "ja-jp", "日本語", "japanese": knownTarget = .japanese
        default: knownTarget = nil
        }
        if let knownTarget {
            return try await translate(text, provider: provider, feature: feature,
                languages: TranslationLanguages(source: selected.source, target: knownTarget),
                maxOutputTokens: maxOutputTokens, timeout: timeout)
        }
        // Preserve older callers' other target languages; the typed API intentionally offers three.
        return try await execute(text, source: "the original language of the source text", target: targetLanguage,
                                 provider: provider, feature: feature, maxOutputTokens: maxOutputTokens, timeout: timeout)
    }

    private func validateText(_ text: String) throws {
        guard !Task.isCancelled else { throw AIUtilityError.cancelled }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 24_576 else { throw AIUtilityError.invalidRequest }
    }

    private func execute(_ text: String, source: String, target: String, provider: ProviderID,
                         feature: TranslationFeature, maxOutputTokens: Int?, timeout: TimeInterval) async throws -> String {
        let (config, revision) = try await configurations.snapshot(provider: provider, feature: feature)
        guard let model = config.models[feature] else { throw AIUtilityError.notConfigured }
        let redacted = RedactedText(text, key: config.key, policy: privacy)
        let prompt = try await preferences?.prompt(for: feature) ?? TranslationPrompts.defaults(for: feature)
        // Do not send a credential if it was accidentally pasted into an editable prompt.
        let safePrompt = config.key.withValue { prompt.replacingOccurrences(of: $0, with: "<redacted credential>") }
        let reasoning = try await preferences?.reasoningSettings(provider: provider, model: model)
        let request = try GenerationRequest(model: model,
            instructions: TranslationPrompts.instructions(prompt: safePrompt, source: source, target: target),
            text: redacted.text, maxOutputTokens: maxOutputTokens ?? reasoning?.totalOutputTokens ?? 1024, reasoning: reasoning?.effort ?? .auto)
        let (observer, changes) = try await configurations.revisionEvents()
        let started = ContinuousClock().now
        let result: GenerationResult
        do {
            guard await configurations.bindingRevision(provider: provider) == revision else { throw AIUtilityError.cancelled }
            result = try await withThrowingTaskGroup(of: GenerationResult.self) { group in
                group.addTask { try await gateway.generate(provider: provider, key: config.key, request: request, timeout: timeout) }
                group.addTask {
                    for await changed in changes {
                        if changed[provider, default: 0] != revision { throw AIUtilityError.cancelled }
                    }
                    throw AIUtilityError.cancelled
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw AIUtilityError.cancelled }
                return value
            }
            await configurations.removeRevisionObserver(observer)
            await diagnostics.record(stage: .translationAPI, milliseconds: started.duration(to: ContinuousClock().now).milliseconds, outcome: .success)
        } catch {
            await configurations.removeRevisionObserver(observer)
            let failure = AIUtilityError.sanitized(error)
            await diagnostics.record(stage: .translationAPI, milliseconds: started.duration(to: ContinuousClock().now).milliseconds, outcome: .failure(failure))
            throw failure
        }
        let currentRevision = await configurations.bindingRevision(provider: provider)
        guard !Task.isCancelled, currentRevision == revision else { throw AIUtilityError.cancelled }
        return try redacted.restore(result.text)
    }
}

public struct TranslationOutput: Sendable, CustomStringConvertible, CustomReflectable {
    public let text: String
    public let duration: Duration
    public let requestedAPI: Bool
    public var description: String { "<TranslationOutput: redacted>" }
    public var customMirror: Mirror { Mirror(self, children: ["output": "<redacted>"]) }
}
