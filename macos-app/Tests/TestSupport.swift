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

// A suite named by a path is stored there, so test preferences never reach ~/Library/Preferences.
func testDefaults(_ name: String) -> UserDefaults {
    guard let work = ProcessInfo.processInfo.environment["AIMETERBAR_TEST_DIR"], work.hasPrefix("/") else {
        preconditionFailure("Run the tests with Tests/run.sh, which owns and removes their work folder.")
    }
    return UserDefaults(suiteName: URL(fileURLWithPath: work).appendingPathComponent(name).path)!
}
