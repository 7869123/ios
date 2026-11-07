import AIUtilityCore
import Foundation
#if canImport(Security) && canImport(Vision)

/// Production composition root. No mock credentials, model catalogue or network fallback.
public struct AIUtilityServices: Sendable {
    public let configurations: ConfigurationCoordinator
    public let translation: TranslationEngine
    public let ocr: VisionOCRService
    public let budget: CallBudget

    public init(keychainService: String = "com.aiutility.credentials.v1",
                maxAttempts: Int = 100, maxReservedOutputTokens: Int = 65_536) {
        let budget = CallBudget(maxAttempts: maxAttempts, maxReservedOutputTokens: maxReservedOutputTokens)
        let gateway = ProviderGateway.official(budget: budget)
        let configurations = ConfigurationCoordinator(store: KeychainCredentialStore(service: keychainService), gateway: gateway)
        self.configurations = configurations
        self.translation = TranslationEngine(configurations: configurations, gateway: gateway)
        self.ocr = VisionOCRService()
        self.budget = budget
    }
}
#endif
