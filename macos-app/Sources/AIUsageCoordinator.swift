import Foundation

// Collects local usage off the main thread; never writes to or calls anything outside this Mac.
final class AIUsageCoordinator {
    var onUpdate: ((AISnapshot) -> Void)?

    private let queue = DispatchQueue(label: "com.davidwidagdo.aimeterbar.ai-usage", qos: .utility)
    private let cache = ClaudeUsageCache()
    private var inFlight = false

    func refresh() {
        guard !inFlight, !AppMode.isDemo else { return }
        inFlight = true
        queue.async { [weak self] in
            guard let self = self else { return }
            let snapshot = Self.collect(cache: self.cache)
            DispatchQueue.main.async {
                self.inFlight = false
                self.onUpdate?(snapshot)
            }
        }
    }

    static func collect(cache: ClaudeUsageCache) -> AISnapshot {
        let running = Set(ClaudeInstances.running().map(\.folder))
        let profiles = ClaudeProfiles.scan().map {
            AISnapshot.Profile(folder: $0.folder, name: $0.name, usage: cache.read(profile: $0), isRunning: running.contains($0.folder))
        }
        return AISnapshot(profiles: profiles, codex: CodexProvider.read(), antigravity: AntigravityProvider.read())
    }
}

enum DumpStatus {
    // Read-only check: names are masked and neither the Keychain nor the portal is touched.
    static func run() {
        let snapshot = AIUsageCoordinator.collect(cache: ClaudeUsageCache())
        let now = Date()
        let profiles: [[String: Any]] = snapshot.profiles.enumerated().map { index, profile in
            let model = ProfileRowModel.make(name: "Profile \(index + 1)", usage: profile.usage, running: profile.isRunning, showLeft: true, now: now)
            return ["profile": model.name, "status": model.status, "fiveHourLeft": model.fiveHour.text, "weekLeft": model.week.text]
        }
        var output: [String: Any] = ["profiles": profiles, "wifiInterface": NetworkInterface.wifiName() ?? "none"]
        if let codex = snapshot.codex {
            let model = CodexRowModel.make(codex, showLeft: true, now: now)
            output["codex"] = ["fiveHourLeft": model.fiveHour.text, "weekLeft": model.week.text, "detail": model.detail]
        }
        if let antigravity = snapshot.antigravity {
            output["antigravity"] = ["lastActive": RelativeAge.short(now.timeIntervalSince(antigravity.lastActive)), "modelKnown": antigravity.model != nil]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) else { return }
        print(String(decoding: data, as: UTF8.self))
    }
}
