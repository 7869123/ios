import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AIUtilityCore

actor ScriptedTransport: HTTPTransport {
    enum Step: Sendable {
        case response(HTTPResponse)
        case failure(AIUtilityError)
        case waitForCancellation
        case echoInput
        case delayed(HTTPResponse, nanoseconds: UInt64)
    }
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        waiters.forEach { $0.resume() }; waiters.removeAll()
        guard !steps.isEmpty else { throw AIUtilityError.malformedResponse }
        switch steps.removeFirst() {
        case .response(let response): return response
        case .failure(let error): throw error
        case .delayed(let response, let nanoseconds):
            try await Task.sleep(nanoseconds: nanoseconds)
            return response
        case .waitForCancellation:
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw AIUtilityError.malformedResponse
        case .echoInput:
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let input = body?["input"] as? String ?? ""
            let response: [String: Any] = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": input]]]]]
            return HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: response))
        }
    }
    func waitForFirstCall() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Deterministic barrier for the response/cancel race. Does not resume until released by the test.
actor GatedAdapter: AIProviderAdapter {
    nonisolated let provider = ProviderID.openAI
    private var entered = false
    private var entrance: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<GenerationResult, Never>?
    func listModels(key: APIKey, timeout: TimeInterval,
                    beforeRequest: @escaping @Sendable () async throws -> Void) async throws -> [AIModel] {
        try await beforeRequest()
        return [AIModel(id: "model")]
    }
    func generate(_ request: GenerationRequest, key: APIKey, timeout: TimeInterval) async throws -> GenerationResult {
        entered = true
        entrance?.resume(); entrance = nil
        // Deliberately returns a late success even after cancellation. Gateway must reject it.
        return await withCheckedContinuation { response = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entrance = $0 }
    }
    func release() { response?.resume(returning: GenerationResult(text: "OK")); response = nil }
}

/// Only test code has an in-memory store. Production never falls back to this.
final class TestCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [ProviderID: ProviderConfiguration] = [:]
    private var failing = false
    func failWrites() { lock.lock(); defer { lock.unlock() }; failing = true }
    func load(provider: ProviderID) throws -> ProviderConfiguration? {
        lock.lock(); defer { lock.unlock() }; return records[provider]
    }
    func replace(provider: ProviderID, configuration: ProviderConfiguration) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { throw AIUtilityError.storageFailure }
        records[provider] = configuration
    }
}

func response(_ json: String, status: Int = 200, headers: [String: String] = [:]) -> ScriptedTransport.Step {
    .response(HTTPResponse(status: status, headers: headers, body: Data(json.utf8)))
}
func success(_ provider: ProviderID) -> ScriptedTransport.Step {
    switch provider {
    case .openAI: response(#"{"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"你好"}]}],"usage":{"output_tokens":8}}"#)
    case .deepSeek: response(#"{"choices":[{"message":{"content":"你好","reasoning_content":"hidden"},"finish_reason":"stop"}],"usage":{"completion_tokens":8}}"#)
    case .anthropic: response(#"{"content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"你好"}],"stop_reason":"end_turn","usage":{"output_tokens":8}}"#)
    }
}
func gateway(_ provider: ProviderID, _ transport: ScriptedTransport,
             budget: CallBudget = CallBudget(), retry: RetryPolicy = RetryPolicy(maxRetries: 0)) -> ProviderGateway {
    ProviderGateway(adapters: [OfficialAPIAdapter(provider: provider, transport: transport)], budget: budget, retry: retry)
}
func sampleRequest(_ model: String = "chosen-model") throws -> GenerationRequest {
    try GenerationRequest(model: model, instructions: "Translate to Chinese", text: "Hello", maxOutputTokens: 64)
}
