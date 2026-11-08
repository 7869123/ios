import SwiftUI
import AIUtilityCore
import AIUtilityAppleServices

/// Result of checking one provider's saved Key. Checked once per cold start (and again after the
/// user saves or switches in Settings) by listing the provider's model catalogue with the saved Key:
/// a free, non-generating request that proves the Key is accepted. Each check reserves one call
/// in the session budget (no output tokens).
enum KeyStatus: Equatable, Sendable {
    case unknown
    case checking
    case notConfigured
    /// Key accepted; `modelsListed` is false when a bound model no longer appears in the catalogue.
    case available(modelsListed: Bool)
    /// The provider rejected the Key (invalid, revoked or without permission).
    case rejected
    /// Network, timeout, rate limit or provider error: the Key could not be checked right now.
    case unverified

    var title: String {
        switch self {
        case .unknown, .checking: "检测中"
        case .notConfigured: "未配置"
        case .available(let listed): listed ? "可用" : "模型不可用"
        case .rejected: "Key 失效"
        case .unverified: "无法验证"
        }
    }

    var color: Color {
        switch self {
        case .unknown, .checking: UtilityTheme.planned
        case .notConfigured: UtilityTheme.planned
        case .available(let listed): listed ? UtilityTheme.brandStrong : UtilityTheme.poc
        case .rejected: UtilityTheme.danger
        case .unverified: UtilityTheme.poc
        }
    }

    var isUsable: Bool { if case .available(true) = self { true } else { false } }
}

enum KeyHealthChecker {
    /// Checks one provider without touching the stored configuration.
    static func check(_ provider: ProviderID, services: AIUtilityServices) async -> KeyStatus {
        let bindings: [TranslationFeature: String]
        do { bindings = try await services.configurations.models(provider: provider) }
        catch { return .unverified }
        guard !bindings.isEmpty else { return .notConfigured }
        do {
            let catalogue = try await services.configurations.listModels(provider: provider, timeout: 15)
            let ids = Set(catalogue.map(\.id))
            return .available(modelsListed: bindings.values.allSatisfy { ids.contains($0) })
        } catch {
            switch AIUtilityError.sanitized(error) {
            case .notConfigured: return .notConfigured
            case .invalidCredential, .unauthorized, .forbidden: return .rejected
            default: return .unverified
            }
        }
    }
}

extension AppModel {
    /// Cold-start check of every provider, run concurrently; results land on the main actor.
    func checkAllKeys() async {
        for provider in ProviderID.allCases { keyStatus[provider] = .checking }
        let services = self.services
        await withTaskGroup(of: (ProviderID, KeyStatus).self) { group in
            for provider in ProviderID.allCases {
                group.addTask { (provider, await KeyHealthChecker.check(provider, services: services)) }
            }
            for await (provider, status) in group { keyStatus[provider] = status }
        }
    }

    /// Re-check one provider after the user saves a Key or switches a model.
    func recheckKey(_ provider: ProviderID) async {
        keyStatus[provider] = .checking
        keyStatus[provider] = await KeyHealthChecker.check(provider, services: services)
    }

    func status(of provider: ProviderID) -> KeyStatus { keyStatus[provider] ?? .unknown }

    /// True once every provider has a definite result and none is configured.
    var nothingConfigured: Bool {
        ProviderID.allCases.allSatisfy { status(of: $0) == .notConfigured }
    }
}
