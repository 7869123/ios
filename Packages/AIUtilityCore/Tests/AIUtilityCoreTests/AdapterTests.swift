import Foundation
import Testing
@testable import AIUtilityCore

@Test(arguments: ProviderID.allCases)
func officialWireFormat(_ provider: ProviderID) async throws {
    let transport = ScriptedTransport([success(provider)])
    let key = try APIKey("test-key-only")
    let result = try await gateway(provider, transport).generate(provider: provider, key: key, request: sampleRequest())
    #expect(result.text == "你好")
    #expect(result.outputTokens == 8)
    let requests = await transport.requests
    let request = try #require(requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-only")
    let body = try #require(JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any])
    #expect(body["model"] as? String == "chosen-model")
    switch provider {
    case .openAI:
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(body["store"] as? Bool == false)
        #expect(body["max_output_tokens"] as? Int == 64)
        #expect(body["input"] as? String == "Hello")
    case .anthropic:
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(body["system"] as? String == "Translate to Chinese")
        #expect(body["max_tokens"] as? Int == 64)
    case .deepSeek:
        #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(body["max_tokens"] as? Int == 64)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] ?? "" } == ["system", "user"])
    }
}

@Test(arguments: ProviderID.allCases)
func wrongKeyNeverRetries(_ provider: ProviderID) async throws {
    let transport = ScriptedTransport([response(#"{"error":{"type":"authentication_error","message":"secret-user-content"}}"#, status: 401)])
    let service = gateway(provider, transport, retry: RetryPolicy(maxRetries: 2, baseDelay: 0))
    await #expect(throws: AIUtilityError.unauthorized) {
        try await service.generate(provider: provider, key: APIKey("wrong-key"), request: sampleRequest())
    }
    #expect(await transport.requests.count == 1)
}

@Test(arguments: ProviderID.allCases)
func wrongModelIsClassified(_ provider: ProviderID) async throws {
    let transport = ScriptedTransport([response(#"{"error":{"type":"not_found_error","code":"model_not_found"}}"#, status: 404)])
    await #expect(throws: AIUtilityError.modelUnavailable) {
        try await gateway(provider, transport).generate(provider: provider, key: APIKey("test-key"), request: sampleRequest("missing"))
    }
}

@Test(arguments: ProviderID.allCases)
func modelDiscovery(_ provider: ProviderID) async throws {
    let transport = ScriptedTransport([response(#"{"data":[{"id":"model-a","display_name":"Model A"},{"id":"model-b"}]}"#)])
    let models = try await gateway(provider, transport).listModels(provider: provider, key: APIKey("test-key"))
    #expect(models.map(\.id) == ["model-a", "model-b"])
    let request = try #require(await transport.requests.first)
    #expect(request.httpBody == nil)
    #expect(request.url?.path.hasSuffix("/models") == true)
}

@Test func anthropicPaginationUsesBudgetAndEscapedCursor() async throws {
    let transport = ScriptedTransport([
        response(#"{"data":[{"id":"a"}],"has_more":true,"last_id":"a&secret=value"}"#),
        response(#"{"data":[{"id":"b"}],"has_more":false}"#)
    ])
    let service = gateway(.anthropic, transport)
    let models = try await service.listModels(provider: .anthropic, key: APIKey("test-key"))
    #expect(models.map(\.id) == ["a", "b"])
    let requests = await transport.requests
    let items = URLComponents(url: try #require(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
    #expect(items?.first(where: { $0.name == "after_id" })?.value == "a&secret=value")
    #expect(await service.budget.snapshot().attempts == 2)
}

@Test func malformedAndTruncatedResultsAreRejected() async throws {
    for step in [response("not json"), response(#"{"status":"completed","output":[]}"#)] {
        let transport = ScriptedTransport([step])
        await #expect(throws: AIUtilityError.malformedResponse) {
            try await gateway(.openAI, transport).generate(provider: .openAI, key: APIKey("test-key"), request: sampleRequest())
        }
    }
    let transport = ScriptedTransport([response(#"{"status":"incomplete","output":[]}"#)])
    await #expect(throws: AIUtilityError.outputTruncated) {
        try await gateway(.openAI, transport).generate(provider: .openAI, key: APIKey("test-key"), request: sampleRequest())
    }
}

@Test func errorClassificationDiscardsVendorMessage() {
    let body = Data(#"{"error":{"code":"insufficient_quota","message":"sk-sensitive-secret / private text"}}"#.utf8)
    let error = OfficialAPIAdapter.classify(HTTPResponse(status: 429, body: body), isGeneration: true)
    #expect(error == .quotaExceeded)
    #expect(!String(describing: error).contains("sensitive"))
    #expect(OfficialAPIAdapter.classify(HTTPResponse(status: 403, body: Data()), isGeneration: true) == .forbidden)
}

@Test func timeoutCancelsTransportAndNeverRetries() async throws {
    let transport = ScriptedTransport([.waitForCancellation])
    let service = gateway(.openAI, transport, retry: RetryPolicy(maxRetries: 2))
    await #expect(throws: AIUtilityError.timeout) {
        try await service.generate(provider: .openAI, key: APIKey("test-key"), request: sampleRequest(), timeout: 0.03)
    }
    #expect(await transport.requests.count == 1)
}

@Test func callerCancellationReachesTransport() async throws {
    let transport = ScriptedTransport([.waitForCancellation])
    let task = Task {
        try await gateway(.openAI, transport).generate(provider: .openAI, key: APIKey("test-key"), request: sampleRequest())
    }
    await transport.waitForFirstCall()
    task.cancel()
    await #expect(throws: AIUtilityError.cancelled) { try await task.value }
    #expect(await transport.requests.count == 1)
}

@Test func retryIsFiniteAndEveryAttemptReservesBudget() async throws {
    let transport = ScriptedTransport([response("{}", status: 429), success(.openAI)])
    let service = gateway(.openAI, transport, retry: RetryPolicy(maxRetries: 1, baseDelay: 0))
    _ = try await service.generate(provider: .openAI, key: APIKey("test-key"), request: sampleRequest())
    #expect(await service.budget.snapshot() == BudgetSnapshot(attempts: 2, reservedOutputTokens: 128))
    let limited = ScriptedTransport([response("{}", status: 529), response("{}", status: 529), success(.openAI)])
    let limitedGateway = gateway(.openAI, limited, retry: RetryPolicy(maxRetries: 1, baseDelay: 0))
    await #expect(throws: AIUtilityError.overloaded) {
        try await limitedGateway.generate(provider: .openAI, key: APIKey("test-key"), request: sampleRequest())
    }
    #expect(await limited.requests.count == 2)
}

@Test func retryAfterIsNotShortened() async throws {
    let transport = ScriptedTransport([response("{}", status: 429, headers: ["Retry-After": "120"])])
    let service = gateway(.openAI, transport, retry: RetryPolicy(maxRetries: 2, maxDelay: 1))
    await #expect(throws: AIUtilityError.rateLimited(retryAfter: 120)) {
        try await service.generate(provider: .openAI, key: APIKey("test-key"), request: sampleRequest())
    }
    #expect(await transport.requests.count == 1)
}

@Test func budgetPreventsSecondNetworkCall() async throws {
    let transport = ScriptedTransport([success(.openAI), success(.openAI)])
    let service = gateway(.openAI, transport, budget: CallBudget(maxAttempts: 1, maxReservedOutputTokens: 64))
    _ = try await service.generate(provider: .openAI, key: APIKey("test-key"), request: sampleRequest())
    await #expect(throws: AIUtilityError.budgetExceeded) {
        try await service.generate(provider: .openAI, key: APIKey("test-key"), request: sampleRequest())
    }
    #expect(await transport.requests.count == 1)
}
