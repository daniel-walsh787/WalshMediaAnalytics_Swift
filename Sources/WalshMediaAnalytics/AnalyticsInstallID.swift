import Foundation
import Security

/// Stable UUID per install (not per Apple ID / CloudKit user). Not iCloud-synced.
enum AnalyticsInstallID {
    static func current(appId: String) -> String {
        let service = "com.\(appId).analytics.install"
        let defaultsKey = "\(appId).analytics.deviceID"
        #if os(macOS)
        // The login keychain prompts on every signature change (typical for local Mac builds).
        // This value is not a secret, so UserDefaults keeps the same install ID without a dialog.
        return installIDFromDefaults(defaultsKey)
        #else
        if let keychain = loadFromKeychain(service: service), isValid(keychain) {
            return keychain
        }
        if let defaults = UserDefaults.standard.string(forKey: defaultsKey), isValid(defaults) {
            saveToKeychain(defaults, service: service)
            return defaults
        }
        let id = UUID().uuidString
        saveToKeychain(id, service: service)
        UserDefaults.standard.set(id, forKey: defaultsKey)
        return id
        #endif
    }

    #if os(macOS)
    private static func installIDFromDefaults(_ defaultsKey: String) -> String {
        if let defaults = UserDefaults.standard.string(forKey: defaultsKey), isValid(defaults) {
            return defaults
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: defaultsKey)
        return id
    }
    #endif

    private static func isValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...128).contains(trimmed.count)
    }

    #if !os(macOS)
    private static func loadFromKeychain(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "device_id",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func saveToKeychain(_ value: String, service: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "device_id"
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard let data = value.data(using: .utf8) else { return }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "device_id",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
    #endif
}
