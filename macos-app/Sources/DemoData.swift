import Foundation

// Invented numbers for screenshots; nothing here comes from this Mac.
enum DemoData {
    static func snapshot(now: Date) -> AISnapshot {
        func reading(minutesAgo: Double, fiveHour: Double?, week: Double?) -> ClaudeUsageResult {
            .reading(ClaudeUsageReading(date: now.addingTimeInterval(-minutesAgo * 60), fiveHourUsed: fiveHour, weekUsed: week))
        }
        return AISnapshot(
            profiles: [
                .init(folder: "Claude", name: "Default", usage: reading(minutesAgo: 12, fiveHour: 38, week: 43), isRunning: true),
                .init(folder: "Claude-Max", name: "Max", usage: reading(minutesAgo: 180, fiveHour: nil, week: 29), isRunning: true),
                .init(folder: "Claude-Work", name: "Work", usage: reading(minutesAgo: 360, fiveHour: 90, week: 75), isRunning: false),
                .init(folder: "Claude-Studio", name: "Studio", usage: reading(minutesAgo: 12, fiveHour: 38, week: 43), isRunning: false),
            ],
            codex: CodexReading(primary: CodexWindow(usedPercent: 18, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600)),
                                secondary: CodexWindow(usedPercent: 41, windowMinutes: 10080, resetsAt: now.addingTimeInterval(4 * 86400)),
                                date: now.addingTimeInterval(-720)),
            antigravity: AntigravityStatus(lastActive: now.addingTimeInterval(-720), model: nil),
            tools: tools(now: now))
    }

    static func tools(now: Date) -> [LocalToolStatus] {
        [LocalToolStatus(tool: .openCode, lastActive: now.addingTimeInterval(-86400)),
         LocalToolStatus(tool: .copilot, lastActive: now.addingTimeInterval(-8 * 86400))]
    }

    static let profiles = ["Claude", "Claude-Max", "Claude-Work", "Claude-Studio"].map {
        ClaudeProfile(folder: $0, name: ProfileNames.displayName(folder: $0) ?? $0,
                      url: FileManager.default.temporaryDirectory.appendingPathComponent("aimeterbar-demo/\($0)"))
    }

    static func sessions(now: Date) -> [RecentSession] {
        [RecentSession(provider: "Claude", project: "sample-app", date: now.addingTimeInterval(-300), tokens: 182_000),
         RecentSession(provider: "Codex", project: "sample-api", date: now.addingTimeInterval(-3600), tokens: 54_000)]
    }

    static let today = DayUsage(day: "demo", rx: 1_800_000_000, tx: 240_000_000, peakDown: 4_200_000, peakUp: 310_000)
}
