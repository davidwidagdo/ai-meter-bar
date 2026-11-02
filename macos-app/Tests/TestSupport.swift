import Foundation

// Minimal assertion helper for the standalone swiftc test executable.
enum T {
    static var failures = 0

    static func expect(_ cond: Bool, _ msg: String) {
        if cond { print("ok   - \(msg)") } else { failures += 1; print("FAIL - \(msg)") }
    }

    static func eq<V: Equatable>(_ a: V, _ b: V, _ msg: String) {
        expect(a == b, "\(msg)  (got \(a), want \(b))")
    }

    static func finish() -> Never {
        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

// removePersistentDomain leaves an empty plist behind, so the file goes too.
func removeTestDefaults(_ defaults: UserDefaults, suite: String) {
    defaults.removePersistentDomain(forName: suite)
    let plist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(suite).plist")
    try? FileManager.default.removeItem(at: plist)
}
