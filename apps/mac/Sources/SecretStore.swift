import Foundation
import Security

enum SecretStore {
    /// MXU_SKIP_KEYCHAIN=1 keeps a Debug copy (a test library, the Settings
    /// layout probe) out of the keychain: the release app's keys answer a
    /// differently signed copy with a password prompt that blocks the
    /// window asking for them.
    #if DEBUG || MXU_PERF_HOOKS
    static let skipped = ProcessInfo.processInfo.environment["MXU_SKIP_KEYCHAIN"] == "1"
    #else
    static let skipped = false
    #endif

    // Keys sync through iCloud Keychain once the app is signed with a provisioning
    // profile; until then, they stay on this Mac.
    /// `localOnly` keeps a key on this Mac: one that identifies the Mac
    /// itself must not follow the person to their other Macs.
    static func load(service: String, account: String, localOnly: Bool = false) -> String? {
        guard !skipped else { return nil }
        for synchronizable in localOnly ? [false] : [true, false] {
            var query = keychainQuery(service: service, account: account, synchronizable: synchronizable)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data,
               let value = String(data: data, encoding: .utf8) {
                return value
            }
        }
        return nil
    }

    static func save(_ value: String, service: String, account: String, localOnly: Bool = false) {
        guard !skipped else { return }
        let synced = keychainQuery(service: service, account: account, synchronizable: true)
        let local = keychainQuery(service: service, account: account, synchronizable: false)
        if localOnly {
            SecItemDelete(local as CFDictionary)
            if !value.isEmpty { _ = upsert(Data(value.utf8), query: local) }
            return
        }
        if value.isEmpty {
            SecItemDelete(synced as CFDictionary)
            SecItemDelete(local as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let status = upsert(data, query: synced)
        if status != errSecSuccess {
            // errSecMissingEntitlement until the app has a provisioning
            // profile; any other failure also keeps the key on this Mac.
            _ = upsert(data, query: local)
        } else {
            // Remove an older fallback so a later load cannot return a stale key.
            SecItemDelete(local as CFDictionary)
        }
    }

    private static func keychainQuery(
        service: String, account: String, synchronizable: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
        ]
        if synchronizable {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private static func upsert(_ data: Data, query: [String: Any]) -> OSStatus {
        let status = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var item = query
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil)
    }
}
