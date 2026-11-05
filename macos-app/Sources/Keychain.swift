import Foundation
import Security

enum Keychain {
    static let service = "AIMeterBar"
    static let account = "portal"

    static func setPassword(_ password: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        func add(_ value: String) -> OSStatus {
            var item = base
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(item as CFDictionary, nil)
        }
        let previous = Self.password()
        // A new item gets this app's own access list; an update would keep whatever list was there.
        let removed = SecItemDelete(base as CFDictionary)
        guard removed == errSecSuccess || removed == errSecItemNotFound else {
            Log.write("Keychain: could not replace the password (status \(removed)).")
            return
        }
        let status = add(password)
        guard status != errSecSuccess else { return }
        Log.write("Keychain: could not save the password (status \(status)).")
        // A failed save must not lose the stored password.
        if !previous.isEmpty { _ = add(previous) }
    }

    // Blocks while macOS shows an authorization prompt; never call it on the main thread.
    static func password() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return ""
        }
        return str
    }
}
