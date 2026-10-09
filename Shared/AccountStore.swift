import Foundation
import Security

/// A single atomic Keychain item holds both settings and password. Neither is logged.
@MainActor
final class AccountStore {
    private struct StoredAccount: Codable { let account: SIPAccount; let password: String; let turnPassword: String? }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "Javi") + ".sip",
         kSecAttrAccount as String: "primary"]
    }
    func load() throws -> (SIPAccount, String, String)? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw keychainError(status) }
        let saved = try JSONDecoder().decode(StoredAccount.self, from: data)
        return (saved.account, saved.password, saved.turnPassword ?? "")
    }
    func save(account: SIPAccount, password: String, turnPassword: String) throws {
        let data = try JSONEncoder().encode(StoredAccount(account: account, password: password, turnPassword: turnPassword.isEmpty ? nil : turnPassword))
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError(status) }
    }
    func allowCloudBackgroundAccess() throws {
        let status = SecItemUpdate(query as CFDictionary,
            [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        guard status == errSecSuccess else { throw keychainError(status) }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }
    private func keychainError(_ status: OSStatus) -> PhoneError {
        .message("Schlüsselbund nicht verfügbar (\(status)). Bitte das iPhone entsperren und erneut versuchen.")
    }
}
