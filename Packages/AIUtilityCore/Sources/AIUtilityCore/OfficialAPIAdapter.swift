import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Only official origins are supported. Test through HTTPTransport rather than replacing the origin.
public struct OfficialAPIAdapter: AIProviderAdapter {
    public let provider: ProviderID
    private let transport: any HTTPTransport
    public init(provider: ProviderID, transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.provider = provider; self.transport = transport
    }

    private var origin: String {
        switch provider {
        case .deepSeek: "https://api.deepseek.com"
        case .anthropic: "https://api.anthropic.com/v1"
        case .openAI: "https://api.openai.com/v1"
        }
    }

    private func send(path: String, key: APIKey, timeout: TimeInterval,
                      body: [String: Any]? = nil) async throws -> Data {
        guard timeout.isFinite, timeout > 0, timeout <= 300 else { throw AIUtilityError.invalidRequest }
        guard let url = URL(string: origin + path) else { throw AIUtilityError.invalidRequest }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        key.withValue { request.setValue("Bearer " + $0, forHTTPHeaderField: "Authorization") }
        if provider == .anthropic {
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
            catch { throw AIUtilityError.invalidRequest }
        }
        let immutableRequest = request
        let response = try await withDeadline(timeout) { try await transport.send(immutableRequest) }
        guard (200..<300).contains(response.status) else {
            throw Self.classify(response, isGeneration: body != nil)
        }
        guard response.body.count <= 4_194_304 else { throw AIUtilityError.malformedResponse }
        return response.body
    }

    public func listModels(key: APIKey, timeout: TimeInterval = 20,
                           beforeRequest: @escaping @Sendable () async throws -> Void = {}) async throws -> [AIModel] {
        var result: [AIModel] = []
        var cursor: String?
        var seen = Set<String>()
        // Bound pagination, including servers returning repeated cursors.
        for _ in 0..<100 {
            try Task.checkCancellation()
            var path = "/models"
            if provider == .anthropic {
                var components = URLComponents()
                components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
                if let cursor { components.queryItems?.append(URLQueryItem(name: "after_id", value: cursor)) }
                path += "?" + (components.percentEncodedQuery ?? "")
            }
            try await beforeRequest()
            let data = try await send(path: path, key: key, timeout: timeout)
            let page: ModelPage
            do { page = try JSONDecoder().decode(ModelPage.self, from: data) }
            catch { throw AIUtilityError.malformedResponse }
            guard page.data.allSatisfy({ !$0.id.isEmpty }) else { throw AIUtilityError.malformedResponse }
            result += page.data.map { AIModel(id: $0.id, displayName: $0.display_name ?? $0.name) }
            guard provider == .anthropic, page.has_more == true else {
                var ids = Set<String>()
                return result.filter { ids.insert($0.id).inserted }
            }
            guard let next = page.last_id, !next.isEmpty, seen.insert(next).inserted else {
                throw AIUtilityError.malformedResponse
            }
            cursor = next
        }
        throw AIUtilityError.malformedResponse
    }

    public func generate(_ request: GenerationRequest, key: APIKey,
                         timeout: TimeInterval = 30) async throws -> GenerationResult {
        let body: [String: Any]
        let path: String
        switch provider {
        case .openAI:
            path = "/responses"
            body = ["model": request.model, "instructions": request.instructions, "input": request.text,
                    "max_output_tokens": request.maxOutputTokens, "store": false, "stream": false]
        case .anthropic:
            path = "/messages"
            body = ["model": request.model, "system": request.instructions,
                    "messages": [["role": "user", "content": request.text]],
                    "max_tokens": request.maxOutputTokens, "stream": false]
        case .deepSeek:
            path = "/chat/completions"
            body = ["model": request.model,
                    "messages": [["role": "system", "content": request.instructions],
                                 ["role": "user", "content": request.text]],
                    "max_tokens": request.maxOutputTokens, "stream": false]
        }
        let data = try await send(path: path, key: key, timeout: timeout, body: body)
        do {
            let text: String
            let tokens: Int?
            switch provider {
            case .openAI:
                let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
                if response.status == "incomplete" {
                    if response.incomplete_details?.reason == "content_filter" { throw AIUtilityError.contentRejected }
                    if response.incomplete_details?.reason == "max_output_tokens" { throw AIUtilityError.outputTruncated }
                    throw AIUtilityError.malformedResponse
                }
                guard response.status == "completed", response.error == nil else { throw AIUtilityError.malformedResponse }
                let messages = response.output.filter { $0.type == "message" }
                guard messages.allSatisfy({ $0.status == nil || $0.status == "completed" }) else {
                    throw AIUtilityError.malformedResponse
                }
                let blocks = messages.flatMap { $0.content ?? [] }
                guard !blocks.contains(where: { $0.type == "refusal" }) else { throw AIUtilityError.contentRejected }
                text = blocks.filter { $0.type == "output_text" }.compactMap(\.text).joined(separator: "\n")
                tokens = response.usage?.output_tokens
            case .anthropic:
                let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
                if response.stop_reason == "max_tokens" { throw AIUtilityError.outputTruncated }
                if response.stop_reason == "refusal" { throw AIUtilityError.contentRejected }
                if response.content.contains(where: { $0.type == "refusal" }) { throw AIUtilityError.contentRejected }
                guard ["end_turn", "stop_sequence"].contains(response.stop_reason) else { throw AIUtilityError.malformedResponse }
                text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
                tokens = response.usage?.output_tokens
            case .deepSeek:
                let response = try JSONDecoder().decode(DeepSeekResponse.self, from: data)
                guard let choice = response.choices.first else { throw AIUtilityError.malformedResponse }
                if choice.finish_reason == "length" { throw AIUtilityError.outputTruncated }
                if choice.finish_reason == "content_filter" { throw AIUtilityError.contentRejected }
                if let refusal = choice.message.refusal, !refusal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw AIUtilityError.contentRejected
                }
                guard choice.finish_reason == "stop" else { throw AIUtilityError.malformedResponse }
                text = choice.message.content ?? ""
                tokens = response.usage?.completion_tokens
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIUtilityError.malformedResponse }
            try Task.checkCancellation()
            return GenerationResult(text: text, outputTokens: tokens)
        } catch { throw error is DecodingError ? AIUtilityError.malformedResponse : AIUtilityError.sanitized(error) }
    }

    static func classify(_ response: HTTPResponse, isGeneration: Bool) -> AIUtilityError {
        if response.status == 401 { return .unauthorized }
        if response.status == 403 { return .forbidden }
        // Only inspect machine codes. Raw vendor messages may echo secrets/user content.
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: response.body)
        let codes = [envelope?.error.code, envelope?.error.type].compactMap { $0 }
        if codes.contains(where: { ["insufficient_quota", "credit_balance_too_low", "billing_error"].contains($0) }) { return .quotaExceeded }
        if codes.contains(where: { ["model_not_found", "invalid_model", "model_not_available"].contains($0) }) { return .modelUnavailable }
        switch response.status {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 402: return .quotaExceeded
        case 404: return isGeneration ? .modelUnavailable : .invalidRequest
        case 408: return .timeout
        case 429:
            let delay = response.header("Retry-After").flatMap { value -> TimeInterval? in
                if let seconds = TimeInterval(value) { return seconds }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
            }
            return .rateLimited(retryAfter: delay.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
        case 503, 529: return .overloaded
        case 500...599: return .server(status: response.status)
        default: return .invalidRequest
        }
    }
}

private struct ModelPage: Decodable {
    struct Model: Decodable { let id: String; let display_name: String?; let name: String? }
    let data: [Model]
    let has_more: Bool?
    let last_id: String?
}
private struct ErrorEnvelope: Decodable {
    struct Detail: Decodable {
        let code: String?
        let type: String?
        private enum CodingKeys: String, CodingKey { case code, type }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // An unexpected code type must not hide a usable error.type or HTTP status.
            code = try? container.decode(String.self, forKey: .code)
            type = try? container.decode(String.self, forKey: .type)
        }
    }
    let error: Detail
}
private struct ContentBlock: Decodable { let type: String; let text: String? }
private struct Usage: Decodable { let output_tokens: Int?; let completion_tokens: Int? }
private struct OpenAIResponse: Decodable {
    struct Output: Decodable { let type: String; let status: String?; let content: [ContentBlock]? }
    struct Failure: Decodable { let code: String? }
    struct Incomplete: Decodable { let reason: String? }
    let status: String
    let error: Failure?
    let incomplete_details: Incomplete?
    let output: [Output]
    let usage: Usage?
}
private struct AnthropicResponse: Decodable {
    let content: [ContentBlock]
    let stop_reason: String
    let usage: Usage?
}
private struct DeepSeekResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String?; let refusal: String? }
        let message: Message
        let finish_reason: String
    }
    let choices: [Choice]
    let usage: Usage?
}
