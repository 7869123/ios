import Foundation
import Testing
@testable import AIUtilityCore

@Test func modelCatalogueDoesNotSaveAnUnvalidatedKey() async throws {
    let store = TestCredentialStore()
    let transport = ScriptedTransport([response(#"{"data":[{"id":"available-model"}]}"#)])
    let coordinator = ConfigurationCoordinator(store: store, gateway: gateway(.openAI, transport))
    let models = try await coordinator.discoverModels(provider: .openAI, candidateKey: APIKey("candidate-only"))
    #expect(models.map(\.id) == ["available-model"])
    #expect(try store.load(provider: .openAI)?.models == nil)
}

@Test(arguments: ProviderID.allCases)
func invalidKeyRollsBackAllBindings(_ provider: ProviderID) async throws {
    let store = TestCredentialStore()
    try store.replace(provider: provider, configuration: ProviderConfiguration(key: APIKey("original-key"),
        models: [.discordScreenshot: "old-image", .videoSubtitle: "old-video"]))
    let transport = ScriptedTransport([response("{}", status: 401)])
    let coordinator = ConfigurationCoordinator(store: store, gateway: gateway(provider, transport))
    await #expect(throws: AIUtilityError.unauthorized) {
        try await coordinator.saveKey(provider: provider, key: APIKey("bad-key"), models: [.discordScreenshot: "new-image"])
    }
    let saved = try #require(store.load(provider: provider))
    #expect(saved.key.withValue { $0 == "original-key" })
    #expect(saved.models == [.discordScreenshot: "old-image", .videoSubtitle: "old-video"])
}

@Test func replacementValidatesEveryExistingModelBeforeCommit() async throws {
    let store = TestCredentialStore()
    try store.replace(provider: .openAI, configuration: ProviderConfiguration(key: APIKey("old-key"),
        models: [.discordScreenshot: "a", .videoSubtitle: "b"]))
    let transport = ScriptedTransport([success(.openAI), response("{}", status: 404)])
    let coordinator = ConfigurationCoordinator(store: store, gateway: gateway(.openAI, transport))
    await #expect(throws: AIUtilityError.modelUnavailable) {
        try await coordinator.saveKey(provider: .openAI, key: APIKey("new-key"), models: [:])
    }
    #expect(try store.load(provider: .openAI)?.key.withValue { $0 == "old-key" } == true)
    #expect(await transport.requests.count == 2)
}

@Test func sharedKeySupportsIndependentModelsAndSwitchWithoutReentry() async throws {
    let store = TestCredentialStore()
    let transport = ScriptedTransport(Array(repeating: success(.openAI), count: 5))
    let service = gateway(.openAI, transport)
    let coordinator = ConfigurationCoordinator(store: store, gateway: service)
    try await coordinator.saveKey(provider: .openAI, key: APIKey("one-shared-key"),
        models: [.discordScreenshot: "screenshot-model", .videoSubtitle: "video-model"])
    try await coordinator.switchModel(provider: .openAI, feature: .videoSubtitle, model: "new-video-model")
    let engine = TranslationEngine(configurations: coordinator, gateway: service)
    _ = try await engine.translate("Hello", targetLanguage: "Chinese", provider: .openAI, feature: .discordScreenshot)
    _ = try await engine.translate("Hello", targetLanguage: "Chinese", provider: .openAI, feature: .videoSubtitle)
    let requests = await transport.requests
    #expect(requests.count == 5) // 2 key validations + 1 switch validation + 2 translations
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer one-shared-key" })
    let models = try requests.suffix(2).map {
        try (JSONSerialization.jsonObject(with: #require($0.httpBody)) as? [String: Any])?["model"] as? String
    }
    #expect(models == ["screenshot-model", "new-video-model"])
    #expect(try store.load(provider: .openAI)?.models == [.discordScreenshot: "screenshot-model", .videoSubtitle: "new-video-model"])
}

@Test func failedModelSwitchLeavesOldConfiguration() async throws {
    let store = TestCredentialStore()
    try store.replace(provider: .deepSeek, configuration: ProviderConfiguration(key: APIKey("shared-key"), models: [.videoSubtitle: "old-model"]))
    let coordinator = ConfigurationCoordinator(store: store, gateway: gateway(.deepSeek, ScriptedTransport([response("{}", status: 404)])))
    await #expect(throws: AIUtilityError.modelUnavailable) {
        try await coordinator.switchModel(provider: .deepSeek, feature: .videoSubtitle, model: "invalid-model")
    }
    #expect(try store.load(provider: .deepSeek)?.models[.videoSubtitle] == "old-model")
}

@Test func cancelledValidationNeverSavesAndReleasesEditLock() async throws {
    let store = TestCredentialStore()
    let transport = ScriptedTransport([.waitForCancellation, success(.openAI)])
    let coordinator = ConfigurationCoordinator(store: store, gateway: gateway(.openAI, transport))
    let task = Task { try await coordinator.saveKey(provider: .openAI, key: APIKey("new-key"), models: [.videoSubtitle: "video"]) }
    await transport.waitForFirstCall()
    await #expect(throws: AIUtilityError.configurationBusy) {
        try await coordinator.saveKey(provider: .openAI, key: APIKey("racing-key"), models: [.videoSubtitle: "other"])
    }
    task.cancel()
    await #expect(throws: AIUtilityError.cancelled) { try await task.value }
    #expect(try store.load(provider: .openAI) == nil)
    try await coordinator.saveKey(provider: .openAI, key: APIKey("new-key"), models: [.videoSubtitle: "video"])
    #expect(try store.load(provider: .openAI) != nil)
}

@Test func timedOutValidationAndStorageFailureNeverReplaceOldRecord() async throws {
    let store = TestCredentialStore()
    try store.replace(provider: .openAI, configuration: ProviderConfiguration(key: APIKey("old-key"), models: [.videoSubtitle: "old"]))
    let transport = ScriptedTransport([.waitForCancellation, success(.openAI)])
    let coordinator = ConfigurationCoordinator(store: store, gateway: gateway(.openAI, transport))
    await #expect(throws: AIUtilityError.timeout) {
        try await coordinator.saveKey(provider: .openAI, key: APIKey("new-key"), models: [.videoSubtitle: "new"], timeout: 0.03)
    }
    store.failWrites()
    await #expect(throws: AIUtilityError.storageFailure) {
        try await coordinator.saveKey(provider: .openAI, key: APIKey("new-key"), models: [.videoSubtitle: "new"])
    }
    let old = try #require(store.load(provider: .openAI))
    #expect(old.key.withValue { $0 == "old-key" })
    #expect(old.models[.videoSubtitle] == "old")
}

@Test func emptyBindingsCannotSaveKeyAndIdenticalModelsValidateOnce() async throws {
    let store = TestCredentialStore()
    let transport = ScriptedTransport([success(.openAI)])
    let coordinator = ConfigurationCoordinator(store: store, gateway: gateway(.openAI, transport))
    await #expect(throws: AIUtilityError.invalidRequest) {
        try await coordinator.saveKey(provider: .openAI, key: APIKey("test-key"), models: [:])
    }
    try await coordinator.saveKey(provider: .openAI, key: APIKey("test-key"), models: [.videoSubtitle: "same", .discordScreenshot: "same"])
    #expect(await transport.requests.count == 1)
}
