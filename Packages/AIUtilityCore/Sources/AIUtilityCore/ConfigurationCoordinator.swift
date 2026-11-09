import Foundation

/// Use a single coordinator per store namespace. Concurrent edits to the same provider fail busy.
/// Translation can continue with the last committed snapshot while validation is in progress.
public actor ConfigurationCoordinator {
    private let store: any CredentialStore
    private let gateway: ProviderGateway
    private var editing = Set<ProviderID>()
    private var revisions: [ProviderID: UInt64] = [:]
    public init(store: any CredentialStore, gateway: ProviderGateway) { self.store = store; self.gateway = gateway }

    public func models(provider: ProviderID) throws -> [TranslationFeature: String] {
        try load(provider)?.models ?? [:]
    }
    public func configuration(provider: ProviderID, feature: TranslationFeature) throws -> ProviderConfiguration {
        guard let value = try load(provider), value.models[feature] != nil else { throw AIUtilityError.notConfigured }
        return value
    }
    func snapshot(provider: ProviderID, feature: TranslationFeature) throws -> (ProviderConfiguration, UInt64) {
        (try configuration(provider: provider, feature: feature), revisions[provider, default: 0])
    }
    public func bindingRevision(provider: ProviderID) -> UInt64 { revisions[provider, default: 0] }
    func savedConfiguration(provider: ProviderID) throws -> ProviderConfiguration {
        guard let configuration = try load(provider) else { throw AIUtilityError.notConfigured }
        return configuration
    }
    public func listModels(provider: ProviderID, timeout: TimeInterval = 20) async throws -> [AIModel] {
        guard let value = try load(provider) else { throw AIUtilityError.notConfigured }
        return try await gateway.listModels(provider: provider, key: value.key, timeout: timeout)
    }
    /// Lets a first-time user discover models without persisting an unvalidated candidate key.
    public func discoverModels(provider: ProviderID, candidateKey: APIKey,
                               timeout: TimeInterval = 20) async throws -> [AIModel] {
        try await gateway.listModels(provider: provider, key: candidateKey, timeout: timeout)
    }
    /// Listing models does NOT constitute key validation. Calls real generation for every unique binding.
    /// Existing bindings are retained and revalidated with the replacement key.
    public func saveKey(provider: ProviderID, key: APIKey,
                        models updates: [TranslationFeature: String], timeout: TimeInterval = 30) async throws {
        guard editing.insert(provider).inserted else { throw AIUtilityError.configurationBusy }
        defer { editing.remove(provider) }
        var bindings = try load(provider)?.models ?? [:]
        bindings.merge(updates) { _, new in new }
        guard !bindings.isEmpty else { throw AIUtilityError.invalidRequest }
        let validationModels = Set(bindings.values).sorted()
        // One validation deadline for the whole transaction, rather than timeout per binding.
        try await withDeadline(timeout) {
            for model in validationModels {
                try await self.validate(provider: provider, key: key, model: model, timeout: timeout)
            }
        }
        try commit(provider, configuration: ProviderConfiguration(key: key, models: bindings))
    }
    /// Uses the saved shared key; the caller never needs to re-enter it.
    public func switchModel(provider: ProviderID, feature: TranslationFeature, model: String,
                            timeout: TimeInterval = 30) async throws {
        guard editing.insert(provider).inserted else { throw AIUtilityError.configurationBusy }
        defer { editing.remove(provider) }
        guard let old = try load(provider) else { throw AIUtilityError.notConfigured }
        try await validate(provider: provider, key: old.key, model: model, timeout: timeout)
        var bindings = old.models
        bindings[feature] = model
        try commit(provider, configuration: ProviderConfiguration(key: old.key, models: bindings))
    }
    private func validate(provider: ProviderID, key: APIKey, model: String, timeout: TimeInterval) async throws {
        let request = try GenerationRequest(model: model,
            instructions: "Return only the word OK. This is a connectivity test.", text: "Reply OK.", maxOutputTokens: 256)
        let result = try await gateway.generate(provider: provider, key: key, request: request, timeout: timeout)
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIUtilityError.malformedResponse }
    }
    private func load(_ provider: ProviderID) throws -> ProviderConfiguration? {
        do { return try store.load(provider: provider) }
        catch { throw AIUtilityError.storageFailure }
    }
    private func commit(_ provider: ProviderID, configuration: ProviderConfiguration) throws {
        // Linearization point: no await between cancellation check and atomic replacement.
        guard !Task.isCancelled else { throw AIUtilityError.cancelled }
        do { try store.replace(provider: provider, configuration: configuration) }
        catch { throw AIUtilityError.storageFailure }
        revisions[provider, default: 0] &+= 1
    }
}
