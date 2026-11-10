import Foundation

public enum BalanceCurrency: String, Codable, Sendable, CaseIterable { case CNY, USD }
public struct BalanceAmount: Sendable, Equatable {
    public let currency: BalanceCurrency
    public let total: Decimal
    public let granted: Decimal
    public let toppedUp: Decimal
}
public struct DeepSeekBalance: Sendable, Equatable {
    public let isAvailable: Bool
    public let amounts: [BalanceAmount]
}

struct BalanceEnvelope: Decodable {
    struct Amount: Decodable {
        let currency: BalanceCurrency
        let total_balance: String
        let granted_balance: String
        let topped_up_balance: String
        var validated: BalanceAmount? {
            func parse(_ value: String) -> Decimal? {
                guard value.utf8.count <= 48,
                      value.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
                return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
            }
            guard let total = parse(total_balance), let granted = parse(granted_balance), let topped = parse(topped_up_balance) else { return nil }
            return BalanceAmount(currency: currency, total: total, granted: granted, toppedUp: topped)
        }
    }
    let is_available: Bool
    let balance_infos: [Amount]
    func value() throws -> DeepSeekBalance {
        let amounts = balance_infos.compactMap(\.validated)
        guard !amounts.isEmpty, amounts.count == balance_infos.count,
              Set(amounts.map(\.currency)).count == amounts.count else { throw AIUtilityError.malformedResponse }
        return DeepSeekBalance(isAvailable: is_available, amounts: amounts)
    }
}

public enum BalanceQueryStatus: Sendable, Equatable { case idle, checking, success, failed(AIUtilityError) }
public struct BalanceSnapshot: Sendable {
    /// Retains the last successful value through a network failure; status identifies staleness.
    public let balance: DeepSeekBalance?
    public let updatedAt: Date?
    public let status: BalanceQueryStatus
    public let alertPersistenceFailed: Bool
}
public struct LowBalanceEvent: Sendable {
    public let currency: BalanceCurrency
    public let total: Decimal
    public let threshold: Decimal
    public let checkedAt: Date
}
private struct BalancePreferences: Codable {
    var version = 1
    var thresholds: [BalanceCurrency: Decimal] = [:]
    var notified: Set<BalanceCurrency> = []
}

/// Foreground polling only: the caller invokes checkWhileActive while the app is in use.
/// No background task, server, automatic top-up or notification UI is created.
public actor DeepSeekBalanceMonitor {
    private let configurations: ConfigurationCoordinator
    private let adapter: OfficialAPIAdapter
    private let budget: CallBudget
    private let store: any LocalDataStore
    private var preferences: BalancePreferences?
    private var checking = false
    private var lastAttempt: Date?
    private var balance: DeepSeekBalance?
    private var updatedAt: Date?
    private var status = BalanceQueryStatus.idle
    private var alertPersistenceFailed = false
    private var observers: [UUID: AsyncStream<LowBalanceEvent>.Continuation] = [:]

    public init(configurations: ConfigurationCoordinator, budget: CallBudget, store: any LocalDataStore,
                transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.configurations = configurations; self.budget = budget; self.store = store
        self.adapter = OfficialAPIAdapter(provider: .deepSeek, transport: transport)
    }
    deinit { observers.values.forEach { $0.finish() } }
    public func snapshot() -> BalanceSnapshot {
        BalanceSnapshot(balance: balance, updatedAt: updatedAt, status: status, alertPersistenceFailed: alertPersistenceFailed)
    }
    public func threshold(for currency: BalanceCurrency) throws -> Decimal? { try load().thresholds[currency] }
    public func setThreshold(_ threshold: Decimal?, for currency: BalanceCurrency) throws {
        if let threshold { guard !threshold.isNaN, threshold >= 0, threshold <= 1_000_000_000 else { throw AIUtilityError.invalidRequest } }
        var value = try load()
        guard value.thresholds[currency] != threshold else { return }
        value.thresholds[currency] = threshold
        value.notified.remove(currency)
        try save(value)
    }
    public func lowBalanceEvents() throws -> AsyncStream<LowBalanceEvent> {
        guard observers.count < 8 else { throw AIUtilityError.budgetExceeded }
        let id = UUID()
        let pair = AsyncStream<LowBalanceEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        observers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return pair.stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    /// Failures are also throttled. An explicit refresh bypasses the foreground interval.
    @discardableResult
    public func checkWhileActive(now: Date = Date(), interval: TimeInterval = 300) async throws -> BalanceSnapshot {
        guard interval.isFinite, interval >= 60, interval <= 86_400 else { throw AIUtilityError.invalidRequest }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < interval { return snapshot() }
        return try await refresh(now: now)
    }
    @discardableResult
    public func refresh(now: Date = Date(), timeout: TimeInterval = 15) async throws -> BalanceSnapshot {
        guard !checking else { throw AIUtilityError.configurationBusy }
        guard !Task.isCancelled else { throw AIUtilityError.cancelled }
        checking = true; status = .checking; lastAttempt = now
        defer { checking = false }
        do {
            let (config, revision) = try await configurations.savedSnapshot(provider: .deepSeek)
            try await budget.reserve(outputTokens: 0)
            let current = try await adapter.balance(key: config.key, timeout: timeout)
            let currentRevision = await configurations.bindingRevision(provider: .deepSeek)
            guard !Task.isCancelled, currentRevision == revision else {
                throw AIUtilityError.cancelled
            }
            balance = current; updatedAt = now; status = .success
            do { try evaluateAlerts(current, now: now); alertPersistenceFailed = false }
            catch { alertPersistenceFailed = true } // Real balance remains usable even if alert storage fails.
            return snapshot()
        } catch {
            let failure = AIUtilityError.sanitized(error)
            status = .failed(failure)
            throw failure
        }
    }
    private func evaluateAlerts(_ balance: DeepSeekBalance, now: Date) throws {
        var value = try load()
        var events: [LowBalanceEvent] = []
        for amount in balance.amounts {
            guard let threshold = value.thresholds[amount.currency] else { continue }
            if amount.total <= threshold {
                if value.notified.insert(amount.currency).inserted {
                    events.append(LowBalanceEvent(currency: amount.currency, total: amount.total, threshold: threshold, checkedAt: now))
                }
            } else { value.notified.remove(amount.currency) }
        }
        // Only emit after durable suppression state; failure cannot create a stream of duplicate alerts.
        try save(value)
        for event in events { observers.values.forEach { $0.yield(event) } }
    }
    private func load() throws -> BalancePreferences {
        if let preferences { return preferences }
        do {
            let value: BalancePreferences
            if let data = try store.read(.deepSeekBalancePreferences) {
                value = try JSONDecoder().decode(BalancePreferences.self, from: data)
                guard value.version == 1, value.thresholds.values.allSatisfy({ !$0.isNaN && $0 >= 0 && $0 <= 1_000_000_000 }) else {
                    throw AIUtilityError.storageFailure
                }
            } else { value = BalancePreferences() }
            preferences = value; return value
        } catch { throw AIUtilityError.storageFailure }
    }
    private func save(_ value: BalancePreferences) throws {
        do { try store.write(JSONEncoder().encode(value), to: .deepSeekBalancePreferences) }
        catch { throw AIUtilityError.storageFailure }
        preferences = value
    }
}
