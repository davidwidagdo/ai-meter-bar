import Foundation

// Collects local usage off the main thread; never writes to or calls anything outside this Mac.
final class AIUsageCoordinator {
    var onUpdate: ((AISnapshot) -> Void)?

    private let queue = DispatchQueue(label: "com.davidwidagdo.aimeterbar.ai-usage", qos: .utility)
    private let cache = ClaudeUsageCache()
    private var inFlight = false
    private var liveRequested = false
    private var liveUsage = LiveUsage()
    private var lastLiveCheck = Date.distantPast
    private static let liveInterval: TimeInterval = 30

    // Live numbers are asked for only when someone looks, so nothing polls in the background.
    func refresh(live: Bool = false) {
        guard !AppMode.isDemo else { return }
        guard !inFlight else {
            liveRequested = liveRequested || live
            return
        }
        inFlight = true
        queue.async { [weak self] in
            guard let self = self else { return }
            self.deliver(Self.collect(cache: self.cache, live: self.liveUsage))
            if live, Date().timeIntervalSince(self.lastLiveCheck) >= Self.liveInterval {
                self.lastLiveCheck = Date()
                self.liveUsage.update()
                self.deliver(Self.collect(cache: self.cache, live: self.liveUsage))
            }
            DispatchQueue.main.async {
                self.inFlight = false
                if self.liveRequested {
                    self.liveRequested = false
                    self.refresh(live: true)
                }
            }
        }
    }

    private func deliver(_ snapshot: AISnapshot) {
        DispatchQueue.main.async { self.onUpdate?(snapshot) }
    }

    static func collect(cache: ClaudeUsageCache, live: LiveUsage = LiveUsage()) -> AISnapshot {
        let running = Set(ClaudeInstances.running().map(\.folder))
        let found = ClaudeProfiles.scan()
        let usages = AccountUsage.merged(found.map { cache.read(profile: $0) })
        let profiles = zip(found, usages).map { profile, usage in
            AISnapshot.Profile(folder: profile.folder, name: profile.name, usage: usage, isRunning: running.contains(profile.folder))
        }
        var antigravity = AntigravityProvider.read()
        antigravity?.live = live.antigravity
        return AISnapshot(profiles: profiles, codex: CodexReading.newest(CodexProvider.read(), live.codex),
                          antigravity: antigravity, tools: LocalTools.read())
    }
}

enum DumpStatus {
    // Read-only check: names are masked and neither the Keychain nor the portal is touched.
    static func run() {
        var live = LiveUsage()
        live.update()
        let snapshot = AIUsageCoordinator.collect(cache: ClaudeUsageCache(), live: live)
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
            let model = AntigravityRowModel.make(antigravity, showLeft: true, now: now)
            output["antigravity"] = ["detail": model.detail, "quotas": model.quotas.map { ["name": $0.name, "left": $0.cell.text, "reset": $0.reset] }]
        }
        output["tools"] = snapshot.tools.map {
            ["name": $0.tool.displayName, "lastActive": RelativeAge.short(now.timeIntervalSince($0.lastActive)), "shown": $0.isRecent(now: now)] as [String: Any]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) else { return }
        print(String(decoding: data, as: UTF8.self))
    }
}
