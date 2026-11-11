import Foundation

// The password with the destination it was saved for; no other process can read or forge it.
struct PortalSecret: Equatable {
    let password: String
    // nil for an item saved before bindings existed, which is accepted until the next save.
    let binding: String?

    static func binding(loginURL: String, marker: String) -> String {
        loginURL.trimmingCharacters(in: .whitespaces) + "\n" + marker.trimmingCharacters(in: .whitespaces)
    }

    func allows(loginURL: String, marker: String) -> Bool {
        binding == nil || binding == Self.binding(loginURL: loginURL, marker: marker)
    }

    // What a Settings save must write. A typed password always writes, so the item is made anew.
    static func forSave(typed: String?, stored: PortalSecret?, loginURL: String, marker: String) -> PortalSecret? {
        guard let password = typed ?? stored?.password, typed != nil || !password.isEmpty else { return nil }
        let next = PortalSecret(password: password, binding: binding(loginURL: loginURL, marker: marker))
        return typed == nil && next == stored ? nil : next
    }

    func encoded() -> Data {
        guard let binding = binding else { return Data(password.utf8) }
        let object: [String: Any] = ["v": 1, "password": password, "binding": binding]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(password.utf8)
    }

    static func decode(_ data: Data) -> PortalSecret? {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           object.count == 3, (object["v"] as? NSNumber)?.intValue == 1,
           let password = object["password"] as? String, let binding = object["binding"] as? String {
            return PortalSecret(password: password, binding: binding)
        }
        return String(data: data, encoding: .utf8).map { PortalSecret(password: $0, binding: nil) }
    }
}
