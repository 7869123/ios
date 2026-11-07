import Foundation

public struct BudgetSnapshot: Sendable, Equatable {
    public let attempts: Int
    public let reservedOutputTokens: Int
}

/// Session-wide conservative limits, including failed calls and validation calls.
/// Reservations are never refunded: cancellation/timeout may still incur provider charges.
public actor CallBudget {
    private let maxAttempts: Int
    private let maxReservedOutputTokens: Int
    private var attempts = 0
    private var reserved = 0
    public init(maxAttempts: Int = 100, maxReservedOutputTokens: Int = 65_536) {
        self.maxAttempts = max(0, maxAttempts)
        self.maxReservedOutputTokens = max(0, maxReservedOutputTokens)
    }
    func reserve(outputTokens: Int) throws {
        guard outputTokens >= 0, attempts < maxAttempts,
              outputTokens <= maxReservedOutputTokens - reserved else { throw AIUtilityError.budgetExceeded }
        attempts += 1; reserved += outputTokens
    }
    public func snapshot() -> BudgetSnapshot { BudgetSnapshot(attempts: attempts, reservedOutputTokens: reserved) }
}

public struct RetryPolicy: Sendable {
    public let maxRetries: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public init(maxRetries: Int = 1, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 10) {
        self.maxRetries = min(2, max(0, maxRetries))
        self.baseDelay = baseDelay.isFinite ? min(10, max(0, baseDelay)) : 0.5
        self.maxDelay = maxDelay.isFinite ? min(60, max(0, maxDelay)) : 10
    }
    func delay(for error: AIUtilityError, retry: Int) -> TimeInterval? {
        guard retry < maxRetries else { return nil }
        switch error {
        case .rateLimited(let retryAfter):
            // Don't retry earlier than Retry-After. A longer wait ends this request.
            if let retryAfter, retryAfter > maxDelay { return nil }
            return max(retryAfter ?? 0, min(maxDelay, baseDelay * pow(2, Double(retry))))
        case .overloaded: return min(maxDelay, baseDelay * pow(2, Double(retry)))
        default: return nil // Never auto-retry ambiguous transport/timeouts or authentication failures.
        }
    }
}

public struct ProviderGateway: Sendable {
    private let adapters: [ProviderID: any AIProviderAdapter]
    public let budget: CallBudget
    private let retry: RetryPolicy
    public init(adapters: [any AIProviderAdapter], budget: CallBudget = CallBudget(), retry: RetryPolicy = RetryPolicy()) {
        self.adapters = adapters.reduce(into: [:]) { $0[$1.provider] = $1 }
        self.budget = budget; self.retry = retry
    }
    public static func official(budget: CallBudget = CallBudget()) -> ProviderGateway {
        ProviderGateway(adapters: ProviderID.allCases.map { OfficialAPIAdapter(provider: $0) }, budget: budget)
    }

    public func listModels(provider: ProviderID, key: APIKey, timeout: TimeInterval = 20) async throws -> [AIModel] {
        guard let adapter = adapters[provider] else { throw AIUtilityError.notConfigured }
        // One overall deadline covers pagination, retries and backoff.
        return try await withDeadline(timeout) {
            try await perform(outputTokens: nil) {
                try await adapter.listModels(key: key, timeout: timeout) { try await budget.reserve(outputTokens: 0) }
            }
        }
    }
    public func generate(provider: ProviderID, key: APIKey, request: GenerationRequest,
                         timeout: TimeInterval = 30) async throws -> GenerationResult {
        guard let adapter = adapters[provider] else { throw AIUtilityError.notConfigured }
        return try await withDeadline(timeout) {
            try await perform(outputTokens: request.maxOutputTokens) {
                try await adapter.generate(request, key: key, timeout: timeout)
            }
        }
    }
    private func perform<T: Sendable>(outputTokens: Int?,
                                     operation: @escaping @Sendable () async throws -> T) async throws -> T {
        var retryIndex = 0
        while true {
            do {
                try Task.checkCancellation()
                if let outputTokens { try await budget.reserve(outputTokens: outputTokens) }
                try Task.checkCancellation()
                return try await operation()
            } catch {
                let failure = AIUtilityError.sanitized(error)
                guard let delay = retry.delay(for: failure, retry: retryIndex) else { throw failure }
                retryIndex += 1
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { throw AIUtilityError.cancelled }
            }
        }
    }
}
