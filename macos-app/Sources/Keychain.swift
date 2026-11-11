import Foundation
import Security

// One generic password item. The service is a parameter so a QA run can use its own item.
struct KeychainStore {
    let service: String
    let account: String

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    // Blocks while macOS shows an authorization prompt; never call it on the main thread.
    func read() -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        func add(_ value: Data) -> OSStatus {
            var item = base
            item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(item as CFDictionary, nil)
        }
        let previous = read()
        // A new item gets this app's own access list; an update would keep whatever list was there.
        let removed = SecItemDelete(base as CFDictionary)
        guard removed == errSecSuccess || removed == errSecItemNotFound else {
            Log.write("Keychain: could not replace the password (status \(removed)).")
            return false
        }
        let status = add(data)
        guard status != errSecSuccess else { return true }
        Log.write("Keychain: could not save the password (status \(status)).")
        // A failed save must not lose the stored password.
        if let previous = previous, !previous.isEmpty { _ = add(previous) }
        return false
    }

    @discardableResult
    func delete() -> Bool {
        let status = SecItemDelete(base as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

enum Keychain {
    static let portal = KeychainStore(service: "AIMeterBar", account: "portal")

    static func secret(in store: KeychainStore = portal) -> PortalSecret? {
        store.read().flatMap(PortalSecret.decode)
    }

    @discardableResult
    static func save(_ secret: PortalSecret, in store: KeychainStore = portal) -> Bool {
        store.write(secret.encoded())
    }
}
