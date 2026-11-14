import AIUtilityCore
import Foundation
#if canImport(Security) && canImport(Vision)

/// Production composition root. No mock credentials, model catalogue or network fallback.
public struct AIUtilityServices: Sendable {
    public let configurations: ConfigurationCoordinator
    public let translation: TranslationEngine
    public let ocr: VisionOCRService
    public let budget: CallBudget
    public let preferences: TranslationPreferences
    public let openAIUsage: OpenAIUsageLedger
    public let deepSeekBalance: DeepSeekBalanceMonitor
    public let screenshots: ScreenshotTranslationWorkflow

    public init(keychainService: String = "com.aiutility.credentials.v1",
                maxAttempts: Int = 100, maxReservedOutputTokens: Int = 65_536,
                localDataDirectory: URL? = nil) {
        let budget = CallBudget(maxAttempts: maxAttempts, maxReservedOutputTokens: maxReservedOutputTokens)
        let directory = localDataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUtility", isDirectory: true).appendingPathComponent("Configuration", isDirectory: true)
        let store = FileLocalDataStore(directory: directory)
        let preferences = TranslationPreferences(store: store)
        let usage = OpenAIUsageLedger(store: store)
        let gateway = ProviderGateway.official(budget: budget, usageLedger: usage)
        let configurations = ConfigurationCoordinator(store: KeychainCredentialStore(service: keychainService), gateway: gateway)
        self.configurations = configurations
        let translation = TranslationEngine(configurations: configurations, gateway: gateway, preferences: preferences,
                                             detector: AppleTextLanguageDetector())
        self.translation = translation
        self.ocr = VisionOCRService()
        self.budget = budget
        self.preferences = preferences
        self.openAIUsage = usage
        self.deepSeekBalance = DeepSeekBalanceMonitor(configurations: configurations, budget: budget, store: store)
        self.screenshots = ScreenshotTranslationWorkflow(ocr: VisionOCRService(), translation: translation)
    }
}
#endif
