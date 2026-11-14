import Foundation
import Testing
@testable import AIUtilityCore

@Test(arguments: ProviderID.allCases)
func autoReasoningNeverSendsParameters(_ provider: ProviderID) async throws {
    let transport = ScriptedTransport([success(provider)])
    _ = try await OfficialAPIAdapter(provider: provider, transport: transport).generate(sampleRequest(), key: APIKey("test-key"))
    let request = try #require(await transport.requests.first)
    let requestData = try #require(request.httpBody)
    let requestJSON = try JSONSerialization.jsonObject(with: requestData)
    let body = try #require(requestJSON as? [String: Any])
    #expect(body["reasoning"] == nil)
    #expect(body["reasoning_effort"] == nil)
    #expect(body["thinking"] == nil)
    #expect(body["output_config"] == nil)
}

@Test func reasoningUsesProviderSpecificFieldsAndRejectsUnknownModels() async throws {
    let models: [ProviderID: String] = [.openAI: "gpt-5.4", .anthropic: "claude-opus-5-5", .deepSeek: "deepseek-flash"]
    for provider in ProviderID.allCases {
        let transport = ScriptedTransport([success(provider)])
        let request = try GenerationRequest(model: #require(models[provider]), instructions: "Translate", text: "Hello",
                                            maxOutputTokens: 32_768, reasoning: .high)
        _ = try await OfficialAPIAdapter(provider: provider, transport: transport).generate(request, key: APIKey("test-key"))
        let sent = try #require(await transport.requests.first)
        let requestData = try #require(sent.httpBody)
        let requestJSON = try JSONSerialization.jsonObject(with: requestData)
        let body = try #require(requestJSON as? [String: Any])
        switch provider {
        case .openAI:
            #expect((body["reasoning"] as? [String: String])?["effort"] == "high")
            #expect(body["max_output_tokens"] as? Int == 32_768)
        case .deepSeek:
            #expect(body["reasoning_effort"] as? String == "high")
            #expect(body["thinking"] == nil)
        case .anthropic:
            #expect((body["output_config"] as? [String: String])?["effort"] == "high")
            #expect((body["thinking"] as? [String: String])?["type"] == "adaptive")
            #expect(body["budget_tokens"] == nil)
        }
        let unknown = ScriptedTransport([])
        let invalid = try GenerationRequest(model: "future-unknown", instructions: "Translate", text: "Hello", reasoning: .high)
        await #expect(throws: AIUtilityError.invalidRequest) {
            try await OfficialAPIAdapter(provider: provider, transport: unknown).generate(invalid, key: APIKey("test-key"))
        }
        #expect(await unknown.requests.isEmpty)
    }
    #expect(ReasoningCapabilities.forModel("gpt-5.4-pro", provider: .openAI).efforts == [.auto])
    #expect(ReasoningCapabilities.forModel("gpt-5.4", provider: .openAI).efforts.contains(.xhigh))
    #expect(ReasoningCapabilities.forModel("deepseek-flash", provider: .deepSeek).efforts.contains(.max))
}

@Test func reasoningPreferencesArePerModelPersistedAndBudgetExplicit() async throws {
    let store = TestLocalStore()
    let preferences = TranslationPreferences(store: store)
    try await preferences.saveReasoning(.xhigh, provider: .openAI, model: "gpt-5.4", totalOutputTokens: 32_768)
    try await preferences.saveReasoning(.max, provider: .anthropic, model: "claude-opus-5-5", totalOutputTokens: 65_536)
    let next = TranslationPreferences(store: store)
    #expect(try await next.reasoning(provider: .openAI, model: "gpt-5.4") == .xhigh)
    #expect(try await next.reasoning(provider: .deepSeek, model: "gpt-5.4") == .auto)
    #expect(try await next.outputTokenLimit(provider: .anthropic, model: "claude-opus-5-5") == 65_536)
    await #expect(throws: AIUtilityError.invalidRequest) {
        try await next.saveReasoning(.medium, provider: .deepSeek, model: "deepseek-flash", totalOutputTokens: 1024)
    }
    await #expect(throws: AIUtilityError.invalidRequest) {
        try await next.saveReasoning(.high, provider: .openAI, model: "gpt-5.4", totalOutputTokens: 0)
    }
}

@Test func keyValidationUsesCheapSupportedReasoningWithoutChangingUserPreference() async throws {
    let transport = ScriptedTransport([success(.openAI)])
    let service = gateway(.openAI, transport)
    let coordinator = ConfigurationCoordinator(store: TestCredentialStore(), gateway: service)
    try await coordinator.saveKey(provider: .openAI, key: APIKey("test-key"), models: [.videoSubtitle: "gpt-5.4"])
    let request = try #require(await transport.requests.first)
    let requestData = try #require(request.httpBody)
    let requestJSON = try JSONSerialization.jsonObject(with: requestData)
    let body = try #require(requestJSON as? [String: Any])
    #expect((body["reasoning"] as? [String: String])?["effort"] == "none")
    #expect(body["max_output_tokens"] as? Int == 256)
    #expect(await service.budget.snapshot().reservedOutputTokens == 256)
}

@Test func translationUsesSavedReasoningBudgetAndSourceWithoutExtraRequests() async throws {
    let preferences = TranslationPreferences(store: TestLocalStore())
    try await preferences.saveReasoning(.high, provider: .openAI, model: "gpt-5.4", totalOutputTokens: 32_768)
    try await preferences.saveLanguages(TranslationLanguages(source: .japanese, target: .english), for: .videoSubtitle)
    let credentials = TestCredentialStore()
    try credentials.replace(provider: .openAI, configuration: ProviderConfiguration(key: APIKey("test-key"), models: [.videoSubtitle: "gpt-5.4"]))
    let transport = ScriptedTransport([success(.openAI)])
    let service = gateway(.openAI, transport)
    let engine = TranslationEngine(configurations: ConfigurationCoordinator(store: credentials, gateway: service), gateway: service, preferences: preferences)
    let result = try await engine.translate("こんにちは", targetLanguage: "English", provider: .openAI, feature: .videoSubtitle)
    #expect(result == "你好")
    let requests = await transport.requests
    #expect(requests.count == 1)
    let requestData = try #require(requests.first?.httpBody)
    let requestJSON = try JSONSerialization.jsonObject(with: requestData)
    let body = try #require(requestJSON as? [String: Any])
    #expect(body["max_output_tokens"] as? Int == 32_768)
    #expect((body["reasoning"] as? [String: String])?["effort"] == "high")
    #expect((body["instructions"] as? String)?.contains("Japanese (ja)") == true)
}

private let meteredSuccess = #"{"model":"gpt-5.4","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"translated"}]}],"usage":{"input_tokens":12,"output_tokens":20,"total_tokens":32,"output_tokens_details":{"reasoning_tokens":15}}}"#

@Test func openAIActualUsageIsPersistentPerModelAndSessionScoped() async throws {
    let store = TestLocalStore()
    let ledger = OpenAIUsageLedger(store: store)
    let transport = ScriptedTransport([response(meteredSuccess)])
    let result = try await OfficialAPIAdapter(provider: .openAI, transport: transport, usageLedger: ledger)
        .generate(sampleRequest(), key: APIKey("test-key"))
    #expect(result.usage?.inputTokens == 12)
    #expect(result.usage?.reasoningTokens == 15)
    let snapshot = await ledger.snapshot()
    #expect(snapshot.session["gpt-5.4"]?.totalTokens == 32)
    #expect(snapshot.session["gpt-5.4"]?.reasoningTokens == 15)
    let restarted = await OpenAIUsageLedger(store: store).snapshot()
    #expect(restarted.session.isEmpty)
    #expect(restarted.lifetime?["gpt-5.4"]?.totalTokens == 32)
    let persistedUsage = try store.read(.openAIUsage)
    let data = String(decoding: try #require(persistedUsage), as: UTF8.self)
    #expect(!data.contains("translated"))
    #expect(!data.contains("test-key"))
    #expect(!data.contains("Hello"))
}

@Test func openAITruncationStillCountsActualUsageButNeverReturnsTranslation() async throws {
    let ledger = OpenAIUsageLedger(store: TestLocalStore())
    let json = #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[],"usage":{"input_tokens":2,"output_tokens":50,"total_tokens":52,"output_tokens_details":{"reasoning_tokens":50}}}"#
    let transport = ScriptedTransport([response(json)])
    await #expect(throws: AIUtilityError.outputTruncated) {
        try await OfficialAPIAdapter(provider: .openAI, transport: transport, usageLedger: ledger).generate(sampleRequest(), key: APIKey("test-key"))
    }
    let state = await ledger.snapshot()
    #expect(state.session["chosen-model"]?.totalTokens == 52)
}

@Test func absentMalformedUsageAndFailedStatisticsDoNotBreakTranslation() async throws {
    for usage in ["null", #""invalid""#, #"{"input_tokens":-1,"output_tokens":2,"total_tokens":1}"#] {
        let store = TestLocalStore(); store.failWrites()
        let ledger = OpenAIUsageLedger(store: store)
        let json = #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}],"usage":REPLACE}"#.replacingOccurrences(of: "REPLACE", with: usage)
        let transport = ScriptedTransport([response(json)])
        let result = try await OfficialAPIAdapter(provider: .openAI, transport: transport, usageLedger: ledger).generate(sampleRequest(), key: APIKey("test-key"))
        #expect(result.text == "ok")
        #expect(result.usage == nil)
        let state = await ledger.snapshot()
        #expect(state.session["chosen-model"]?.responsesWithoutUsage == 1)
        #expect(state.session["chosen-model"]?.totalTokens == 0)
        #expect(state.persistence == .writeFailed)
    }
}

@Test func usageAttemptDedupAndCorruptHistoryNeverPretendZeroLifetime() async throws {
    let store = TestLocalStore()
    try store.write(Data("broken json".utf8), to: .openAIUsage)
    let ledger = OpenAIUsageLedger(store: store)
    let attempt = UUID()
    let usage = try TokenUsage(inputTokens: 1, outputTokens: 2, totalTokens: 3)
    await ledger.record(attempt: attempt, model: "test-model", usage: usage)
    await ledger.record(attempt: attempt, model: "test-model", usage: usage)
    let state = await ledger.snapshot()
    #expect(state.lifetime == nil)
    #expect(state.persistence == .unavailable)
    #expect(state.session["test-model"]?.totalTokens == 3)
    #expect(try store.read(.openAIUsage) == Data("broken json".utf8))
}

private func balanceResponse(_ total: String, available: Bool = true) -> ScriptedTransport.Step {
    response("{\"is_available\":\(available),\"balance_infos\":[{\"currency\":\"CNY\",\"total_balance\":\"\(total)\",\"granted_balance\":\"0.00\",\"topped_up_balance\":\"\(total)\"}]}")
}
private func balanceMonitor(_ transport: ScriptedTransport, store: TestLocalStore = TestLocalStore()) throws -> DeepSeekBalanceMonitor {
    let credentials = TestCredentialStore()
    try credentials.replace(provider: .deepSeek, configuration: ProviderConfiguration(key: APIKey("shared-deepseek-key"),
        models: [.videoSubtitle: "subtitle-model", .discordScreenshot: "screenshot-model"]))
    let service = gateway(.deepSeek, transport)
    return DeepSeekBalanceMonitor(configurations: ConfigurationCoordinator(store: credentials, gateway: service),
        budget: service.budget, store: store, transport: transport)
}

@Test func balanceUsesOfficialEndpointAndSharedCredentialWithoutGeneration() async throws {
    let transport = ScriptedTransport([balanceResponse("0.00", available: false)])
    let monitor = try balanceMonitor(transport)
    let now = Date(timeIntervalSince1970: 100)
    let state = try await monitor.refresh(now: now)
    #expect(state.status == .success)
    #expect(state.balance?.amounts.first?.total == 0)
    #expect(state.balance?.isAvailable == false)
    #expect(state.updatedAt == now)
    let request = try #require(await transport.requests.first)
    #expect(request.url?.absoluteString == "https://api.deepseek.com/user/balance")
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer shared-deepseek-key")
}

@Test func balanceNetworkFailureKeepsPriorValueAndCannotBecomeZero() async throws {
    let transport = ScriptedTransport([balanceResponse("12.34"), .failure(.transport)])
    let monitor = try balanceMonitor(transport)
    _ = try await monitor.refresh(now: Date(timeIntervalSince1970: 100))
    await #expect(throws: AIUtilityError.transport) { try await monitor.refresh(now: Date(timeIntervalSince1970: 110)) }
    let state = await monitor.snapshot()
    #expect(state.status == .failed(.transport))
    #expect(state.balance?.amounts.first?.total == Decimal(string: "12.34"))
    #expect(state.updatedAt == Date(timeIntervalSince1970: 100))
}

@Test func balanceAlertsAreSuppressedAcrossRestartAndRecoverAboveThreshold() async throws {
    let store = TestLocalStore()
    let first = try balanceMonitor(ScriptedTransport([balanceResponse("1.00")]), store: store)
    try await first.setThreshold(2, for: .CNY)
    let events = try await first.lowBalanceEvents()
    _ = try await first.refresh(now: Date(timeIntervalSince1970: 100))
    var iterator = events.makeAsyncIterator()
    let event = await iterator.next()
    #expect(event?.total == 1)
    let next = try balanceMonitor(ScriptedTransport([balanceResponse("1.00"), balanceResponse("3.00"), balanceResponse("0.50")]), store: store)
    let nextEvents = try await next.lowBalanceEvents()
    _ = try await next.refresh(now: Date(timeIntervalSince1970: 200))
    _ = try await next.refresh(now: Date(timeIntervalSince1970: 300))
    _ = try await next.refresh(now: Date(timeIntervalSince1970: 400))
    var nextIterator = nextEvents.makeAsyncIterator()
    let renewed = await nextIterator.next()
    #expect(renewed?.total == Decimal(string: "0.50")) // A repeated low balance did not enqueue a second 1.00 event.
}

@Test func foregroundBalanceChecksAreBoundedAndMalformedAmountsRejected() async throws {
    let transport = ScriptedTransport([balanceResponse("2.00"), balanceResponse("invalid")])
    let monitor = try balanceMonitor(transport)
    _ = try await monitor.checkWhileActive(now: Date(timeIntervalSince1970: 100))
    _ = try await monitor.checkWhileActive(now: Date(timeIntervalSince1970: 200))
    #expect(await transport.requests.count == 1)
    await #expect(throws: AIUtilityError.malformedResponse) {
        try await monitor.refresh(now: Date(timeIntervalSince1970: 500))
    }
    #expect(await monitor.snapshot().balance?.amounts.first?.total == 2)
}
