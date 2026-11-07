import Foundation
import Testing
@testable import AIUtilityCore

@Test(arguments: ProviderID.allCases)
func truncationAndRefusalNeverCountAsValidation(_ provider: ProviderID) async throws {
    let payloads: [String]
    switch provider {
    case .openAI:
        payloads = [
            #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#,
            #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"no"}]}]}"#
        ]
    case .anthropic:
        payloads = [
            #"{"stop_reason":"max_tokens","content":[{"type":"text","text":"partial"}]}"#,
            #"{"stop_reason":"refusal","content":[{"type":"text","text":"no"}]}"#,
            #"{"stop_reason":"end_turn","content":[{"type":"refusal"},{"type":"text","text":"no"}]}"#
        ]
    case .deepSeek:
        payloads = [
            #"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#,
            #"{"choices":[{"message":{"content":"no"},"finish_reason":"content_filter"}]}"#,
            #"{"choices":[{"message":{"content":"no","refusal":"refused"},"finish_reason":"stop"}]}"#
        ]
    }
    for (index, payload) in payloads.enumerated() {
        let store = TestCredentialStore()
        try store.replace(provider: provider, configuration: ProviderConfiguration(key: APIKey("old-key"),
            models: [.discordScreenshot: "old", .videoSubtitle: "old"]))
        let transport = ScriptedTransport([response(payload)])
        let coordinator = ConfigurationCoordinator(store: store, gateway: gateway(provider, transport))
        let expected: AIUtilityError = index == 0 ? .outputTruncated : .contentRejected
        await #expect(throws: expected) {
            try await coordinator.saveKey(provider: provider, key: APIKey("candidate-key"), models: [.videoSubtitle: "new"])
        }
        let savedRecord = try store.load(provider: provider)
        let saved = try #require(savedRecord)
        #expect(saved.key.withValue { $0 == "old-key" })
        #expect(saved.models == [.discordScreenshot: "old", .videoSubtitle: "old"])
    }
}

@Test func openAIContentFilterAndUnknownIncompleteReasonsAreDistinct() async throws {
    for (reason, expected) in [("content_filter", AIUtilityError.contentRejected), ("future_reason", .malformedResponse)] {
        let payload = "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"" + reason + "\"},\"output\":[]}"
        let transport = ScriptedTransport([response(payload)])
        await #expect(throws: expected) {
            try await gateway(.openAI, transport).generate(provider: .openAI, key: APIKey("test-key"), request: sampleRequest())
        }
    }
}

@Test func openAIOnlyReadsCompletedMessageText() async throws {
    let payload = #"{"status":"completed","incomplete_details":{"reason":null},"output":[{"type":"reasoning","content":[{"type":"output_text","text":"hidden"}]},{"type":"message","status":"completed","content":[{"type":"output_text","text":"visible"}]}]}"#
    let transport = ScriptedTransport([response(payload)])
    let result = try await gateway(.openAI, transport).generate(provider: .openAI, key: APIKey("test-key"), request: sampleRequest())
    #expect(result.text == "visible")
    let incomplete = ScriptedTransport([response(#"{"status":"completed","output":[{"type":"message","status":"incomplete","content":[{"type":"output_text","text":"partial"}]}]}"#)])
    await #expect(throws: AIUtilityError.malformedResponse) {
        try await gateway(.openAI, incomplete).generate(provider: .openAI, key: APIKey("test-key"), request: sampleRequest())
    }
}

@Test func machineErrorTypeSurvivesUnknownOrNonStringCode() {
    for code in ["42", "\"future_code\""] {
        let body = Data(("{\"error\":{\"code\":" + code + ",\"type\":\"insufficient_quota\"}}").utf8)
        #expect(OfficialAPIAdapter.classify(HTTPResponse(status: 429, body: body), isGeneration: true) == .quotaExceeded)
    }
    let misleading = Data(#"{"error":{"code":"model_not_found"}}"#.utf8)
    #expect(OfficialAPIAdapter.classify(HTTPResponse(status: 401, body: misleading), isGeneration: true) == .unauthorized)
}

@Test func lateSuccessAfterCancellationCannotReplaceOldKey() async throws {
    let store = TestCredentialStore()
    try store.replace(provider: .openAI, configuration: ProviderConfiguration(key: APIKey("old-key"), models: [.videoSubtitle: "old"]))
    let adapter = GatedAdapter()
    let coordinator = ConfigurationCoordinator(store: store, gateway: ProviderGateway(adapters: [adapter]))
    let task = Task {
        try await coordinator.saveKey(provider: .openAI, key: APIKey("new-key"), models: [.videoSubtitle: "new"])
    }
    await adapter.waitUntilEntered()
    #expect(try store.load(provider: .openAI)?.key.withValue { $0 == "old-key" } == true)
    task.cancel()
    await adapter.release()
    await #expect(throws: AIUtilityError.cancelled) { try await task.value }
    let oldRecord = try store.load(provider: .openAI)
    let old = try #require(oldRecord)
    #expect(old.key.withValue { $0 == "old-key" })
    #expect(old.models[.videoSubtitle] == "old")
}

@Test func simultaneousSwitchCannotOverwritePendingKeyReplacement() async throws {
    let store = TestCredentialStore()
    try store.replace(provider: .openAI, configuration: ProviderConfiguration(key: APIKey("old-key"), models: [.videoSubtitle: "old"]))
    let adapter = GatedAdapter()
    let coordinator = ConfigurationCoordinator(store: store, gateway: ProviderGateway(adapters: [adapter]))
    let replacement = Task {
        try await coordinator.saveKey(provider: .openAI, key: APIKey("new-key"), models: [.videoSubtitle: "new"])
    }
    await adapter.waitUntilEntered()
    await #expect(throws: AIUtilityError.configurationBusy) {
        try await coordinator.switchModel(provider: .openAI, feature: .videoSubtitle, model: "racing-model")
    }
    await adapter.release()
    try await replacement.value
    let savedRecord = try store.load(provider: .openAI)
    let saved = try #require(savedRecord)
    #expect(saved.key.withValue { $0 == "new-key" })
    #expect(saved.models[.videoSubtitle] == "new")
}

@Test func differentProviderEditsAreIndependent() async throws {
    let store = TestCredentialStore()
    let adapter = GatedAdapter()
    let deepSeek = ScriptedTransport([success(.deepSeek)])
    let service = ProviderGateway(adapters: [adapter, OfficialAPIAdapter(provider: .deepSeek, transport: deepSeek)])
    let coordinator = ConfigurationCoordinator(store: store, gateway: service)
    let first = Task {
        try await coordinator.saveKey(provider: .openAI, key: APIKey("openai-key"), models: [.videoSubtitle: "a"])
    }
    await adapter.waitUntilEntered()
    // Collect the second result without throwing before releasing the first operation's barrier.
    var secondFailure: AIUtilityError?
    do { try await coordinator.saveKey(provider: .deepSeek, key: APIKey("deepseek-key"), models: [.videoSubtitle: "b"]) }
    catch { secondFailure = AIUtilityError.sanitized(error) }
    await adapter.release()
    try await first.value
    #expect(secondFailure == nil)
    #expect(try store.load(provider: .openAI)?.key.withValue { $0 == "openai-key" } == true)
    #expect(try store.load(provider: .deepSeek)?.key.withValue { $0 == "deepseek-key" } == true)
}

@Test func keyReplacementHasOneDeadlineAcrossBothModels() async throws {
    let store = TestCredentialStore()
    try store.replace(provider: .openAI, configuration: ProviderConfiguration(key: APIKey("old-key"),
        models: [.discordScreenshot: "a", .videoSubtitle: "b"]))
    let body = Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}"#.utf8)
    let step = ScriptedTransport.Step.delayed(HTTPResponse(status: 200, body: body), nanoseconds: 50_000_000)
    let coordinator = ConfigurationCoordinator(store: store, gateway: gateway(.openAI, ScriptedTransport([step, step])))
    await #expect(throws: AIUtilityError.timeout) {
        try await coordinator.saveKey(provider: .openAI, key: APIKey("new-key"), models: [:], timeout: 0.08)
    }
    #expect(try store.load(provider: .openAI)?.key.withValue { $0 == "old-key" } == true)
}

@Test func cancellationDuringRetryDoesNotSendAnotherRequest() async throws {
    let transport = ScriptedTransport([response("{}", status: 429, headers: ["Retry-After": "5"]), success(.openAI)])
    let service = gateway(.openAI, transport, retry: RetryPolicy(maxRetries: 1, baseDelay: 5))
    let task = Task { try await service.generate(provider: .openAI, key: APIKey("test-key"), request: sampleRequest()) }
    await transport.waitForFirstCall()
    task.cancel()
    await #expect(throws: AIUtilityError.cancelled) { try await task.value }
    #expect(await transport.requests.count == 1)
}

@Test func cancelledBeforeEntryConsumesNoBudgetOrNetwork() async throws {
    let transport = ScriptedTransport([])
    let service = gateway(.openAI, transport)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await service.generate(provider: .openAI, key: APIKey("test-key"), request: sampleRequest())
    }
    await #expect(throws: AIUtilityError.cancelled) { try await task.value }
    #expect(await service.budget.snapshot().attempts == 0)
    #expect(await transport.requests.isEmpty)
}

@Test func paginationExhaustionStopsBeforeAnotherHTTPCall() async throws {
    let transport = ScriptedTransport([response(#"{"data":[{"id":"a"}],"has_more":true,"last_id":"a"}"#)])
    let service = gateway(.anthropic, transport, budget: CallBudget(maxAttempts: 1))
    await #expect(throws: AIUtilityError.budgetExceeded) {
        try await service.listModels(provider: .anthropic, key: APIKey("test-key"))
    }
    #expect(await transport.requests.count == 1)
}
