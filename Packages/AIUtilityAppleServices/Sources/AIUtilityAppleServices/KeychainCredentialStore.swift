import AIUtilityCore
import Foundation
#if canImport(Security)
import Security

public final class KeychainCredentialStore: CredentialStore, Sendable {
    private let service: String
    public init(service: String = "com.aiutility.credentials.v1") { self.service = service }
    private func query(_ provider: ProviderID) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: provider.rawValue,
                                   kSecAttrSynchronizable as String: false]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
    public func load(provider: ProviderID) throws -> ProviderConfiguration? {
        var request = query(provider)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AIUtilityError.storageFailure }
        do { return try JSONDecoder().decode(ProviderConfiguration.self, from: data) }
        catch { throw AIUtilityError.storageFailure }
    }
    public func replace(provider: ProviderID, configuration: ProviderConfiguration) throws {
        let data: Data
        do { data = try JSONEncoder().encode(configuration) }
        catch { throw AIUtilityError.storageFailure }
        let attributes: [String: Any] = [kSecValueData as String: data,
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        // Never delete first. SecItemUpdate atomically replaces key AND model bindings.
        var status = SecItemUpdate(query(provider) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(provider)
            item.merge(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AIUtilityError.storageFailure }
    }
    public func remove(provider: ProviderID) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIUtilityError.storageFailure }
    }
}
#endif
