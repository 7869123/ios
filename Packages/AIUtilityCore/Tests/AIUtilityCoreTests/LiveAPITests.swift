import Foundation
import Testing
import AIUtilityCore

/// Explicit opt-in only. Every enabled provider incurs real generation charges.
/// No environment values or response contents are printed or included in assertions.
@Test(.enabled(if: ProcessInfo.processInfo.environment["AIUTILITY_LIVE_TESTS"] == "1"), arguments: ProviderID.allCases)
func liveOfficialAPI(_ provider: ProviderID) async throws {
    let prefix: String
    switch provider {
    case .openAI: prefix = "OPENAI"
    case .anthropic: prefix = "ANTHROPIC"
    case .deepSeek: prefix = "DEEPSEEK"
    }
    let environment = ProcessInfo.processInfo.environment
    guard let rawKey = environment[prefix + "_API_KEY"], let model = environment[prefix + "_MODEL"] else {
        // With live tests enabled, missing configuration is a failure, never a false pass.
        throw AIUtilityError.notConfigured
    }
    let key = try APIKey(rawKey)
    let service = ProviderGateway.official(budget: CallBudget(maxAttempts: 110, maxReservedOutputTokens: 2048))
    let models = try await service.listModels(provider: provider, key: key)
    #expect(!models.isEmpty)
    let result = try await service.generate(provider: provider, key: key,
        request: GenerationRequest(model: model, instructions: "Translate to Chinese. Return only the translation.", text: "Hello.", maxOutputTokens: 1024))
    #expect(!result.text.isEmpty)
}
