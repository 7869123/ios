import Foundation

public struct TokenUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    /// Included in outputTokens; never add it to totalTokens a second time.
    public let reasoningTokens: Int?
    public init(inputTokens: Int, outputTokens: Int, totalTokens: Int, reasoningTokens: Int? = nil) throws {
        guard inputTokens >= 0, outputTokens >= 0, totalTokens >= 0,
              inputTokens <= 1_000_000_000, outputTokens <= 1_000_000_000,
              totalTokens == inputTokens + outputTokens,
              reasoningTokens.map({ $0 >= 0 && $0 <= outputTokens }) ?? true else { throw AIUtilityError.malformedResponse }
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.totalTokens = totalTokens; self.reasoningTokens = reasoningTokens
    }
}

public struct ModelTokenTotals: Codable, Sendable, Equatable {
    public private(set) var inputTokens = 0
    public private(set) var outputTokens = 0
    public private(set) var totalTokens = 0
    public private(set) var reasoningTokens = 0
    public private(set) var responsesWithReasoningDetail = 0
    public private(set) var responsesWithActualUsage = 0
    public private(set) var responsesWithoutUsage = 0

    mutating func add(_ usage: TokenUsage?) throws {
        func sum(_ first: Int, _ second: Int) throws -> Int {
            let result = first.addingReportingOverflow(second)
            guard !result.overflow else { throw AIUtilityError.storageFailure }; return result.partialValue
        }
        if let usage {
            inputTokens = try sum(inputTokens, usage.inputTokens)
            outputTokens = try sum(outputTokens, usage.outputTokens)
            totalTokens = try sum(totalTokens, usage.totalTokens)
            reasoningTokens = try sum(reasoningTokens, usage.reasoningTokens ?? 0)
            responsesWithActualUsage = try sum(responsesWithActualUsage, 1)
            if usage.reasoningTokens != nil { responsesWithReasoningDetail = try sum(responsesWithReasoningDetail, 1) }
        } else { responsesWithoutUsage = try sum(responsesWithoutUsage, 1) }
    }
    var valid: Bool {
        inputTokens >= 0 && outputTokens >= 0 && totalTokens >= 0 && reasoningTokens >= 0 &&
        reasoningTokens <= outputTokens && inputTokens <= Int.max - outputTokens &&
        totalTokens == inputTokens + outputTokens && responsesWithActualUsage >= 0 &&
        responsesWithoutUsage >= 0 && responsesWithReasoningDetail >= 0 &&
        responsesWithReasoningDetail <= responsesWithActualUsage
    }
}

public enum UsagePersistenceStatus: String, Sendable {
    case available, writeFailed, unavailable
}
public struct OpenAIUsageSnapshot: Sendable {
    public static let scope = "仅统计 AIUtility 自身收到的 OpenAI API 响应用量，不代表 OpenAI 账户总用量。未收到实际 usage 的请求未估算。"
    public let session: [String: ModelTokenTotals]
    /// nil means historical data could not be loaded, not zero usage.
    public let lifetime: [String: ModelTokenTotals]?
    public let persistence: UsagePersistenceStatus
    public let untrackedResponses: Int
}
private struct UsageDocument: Codable {
    var version = 1
    var models: [String: ModelTokenTotals] = [:]
}

/// Counts actual Responses API usage, including a parsed response later rejected/truncated.
/// No Admin Key, source/translated text, response body, reasoning text or audio is retained.
public actor OpenAIUsageLedger {
    private let store: any LocalDataStore
    private var loaded = false
    private var history: [String: ModelTokenTotals]?
    private var session: [String: ModelTokenTotals] = [:]
    private var status = UsagePersistenceStatus.available
    private var recentAttempts: [UUID] = []
    private var untracked = 0
    public init(store: any LocalDataStore) { self.store = store }

    public func snapshot() -> OpenAIUsageSnapshot {
        load()
        return OpenAIUsageSnapshot(session: session, lifetime: history, persistence: status, untrackedResponses: untracked)
    }
    /// Best effort. Accounting failure must never change the translation result.
    public func record(attempt: UUID, model: String, usage: TokenUsage?) {
        guard !recentAttempts.contains(attempt) else { return }
        recentAttempts.append(attempt)
        if recentAttempts.count > 256 { recentAttempts.removeFirst() }
        load()
        let validated = usage.flatMap { try? TokenUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens,
                                                        totalTokens: $0.totalTokens, reasoningTokens: $0.reasoningTokens) }
        guard Self.validModel(model), session[model] != nil || session.count < 256 else { untracked += 1; return }
        do {
            var current = session[model] ?? ModelTokenTotals()
            try current.add(validated); session[model] = current
            guard var history else { return }
            guard history[model] != nil || history.count < 256 else { status = .writeFailed; untracked += 1; return }
            var cumulative = history[model] ?? ModelTokenTotals()
            try cumulative.add(validated); history[model] = cumulative
            // Retain unsaved aggregate counters in memory for the next write; never roll back session counts.
            self.history = history
            try store.write(JSONEncoder().encode(UsageDocument(models: history)), to: .openAIUsage)
            status = .available
        } catch { status = .writeFailed }
    }
    private func load() {
        guard !loaded else { return }; loaded = true
        do {
            if let data = try store.read(.openAIUsage) {
                let value = try JSONDecoder().decode(UsageDocument.self, from: data)
                guard value.version == 1, value.models.count <= 256,
                      value.models.allSatisfy({ Self.validModel($0.key) && $0.value.valid }) else { throw AIUtilityError.storageFailure }
                history = value.models
            } else { history = [:] }
        } catch { history = nil; status = .unavailable }
    }
    private static func validModel(_ model: String) -> Bool {
        !model.isEmpty && model.utf8.count <= 256 && model.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)
        }
    }
}
