import Foundation

enum Freshness: Equatable {
    case fresh, stale, expired
}

enum QuotaLevel: Equatable {
    case normal, low, critical
}

enum QuotaMath {
    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 86400

    // A reading far in the future means a broken clock or file, so it is not trusted as fresh.
    private static let futureLimit: TimeInterval = -300

    static func fiveHourFreshness(age: TimeInterval) -> Freshness {
        age < futureLimit ? .expired : age < hour ? .fresh : age < 5 * hour ? .stale : .expired
    }

    static func weekFreshness(age: TimeInterval) -> Freshness {
        age < futureLimit ? .expired : age < day ? .fresh : age < 7 * day ? .stale : .expired
    }

    static func clamped(_ used: Double) -> Double {
        min(100, max(0, used))
    }

    static func text(used: Double?, freshness: Freshness, showLeft: Bool) -> String {
        guard let used = used, used.isFinite, freshness != .expired else { return "—" }
        let shown = showLeft ? 100 - clamped(used) : clamped(used)
        return (freshness == .stale ? "~" : "") + "\(Int(shown.rounded()))%"
    }

    static func level(left: Double) -> QuotaLevel {
        left < 15 ? .critical : left < 30 ? .low : .normal
    }
}

enum RelativeAge {
    // Vendor files supply these dates, and the clamp keeps the Int conversions in range.
    private static let maxSeconds: TimeInterval = 86400 * 365 * 1000

    static func short(_ seconds: TimeInterval) -> String {
        let s = min(maxSeconds, max(0, seconds))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}

enum TokenFormat {
    static func short(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
        return "\(tokens)"
    }
}

struct ClaudeUsageReading: Equatable {
    let date: Date
    let fiveHourUsed: Double?
    let weekUsed: Double?
    var account: String?
}

enum ClaudeUsageResult: Equatable {
    case noData, unreadable
    case reading(ClaudeUsageReading)
}

enum AccountUsage {
    // Folders signed in to one account share its newest reading; the folder name plays no part.
    static func merged(_ results: [ClaudeUsageResult]) -> [ClaudeUsageResult] {
        var newest: [String: ClaudeUsageReading] = [:]
        for case .reading(let reading) in results {
            guard let account = reading.account else { continue }
            if let current = newest[account], current.date >= reading.date { continue }
            newest[account] = reading
        }
        return results.map { result in
            guard case .reading(let reading) = result, let account = reading.account, let best = newest[account] else { return result }
            return .reading(best)
        }
    }
}

struct QuotaCell: Equatable {
    let text: String
    let fraction: Double
    let level: QuotaLevel
    let isStale: Bool
    let isUnknown: Bool
    var hidesMeter = false

    static let unknown = QuotaCell(text: "—", fraction: 0, level: .normal, isStale: false, isUnknown: true)
    static let noFiveHour = QuotaCell(text: "No 5h", fraction: 0, level: .normal, isStale: false, isUnknown: true, hidesMeter: true)

    static func make(used: Double?, freshness: Freshness, showLeft: Bool) -> QuotaCell {
        guard let used = used, used.isFinite, freshness != .expired else { return unknown }
        let left = 100 - QuotaMath.clamped(used)
        return QuotaCell(text: QuotaMath.text(used: used, freshness: freshness, showLeft: showLeft),
                         fraction: (showLeft ? left : 100 - left) / 100,
                         level: QuotaMath.level(left: left),
                         isStale: freshness == .stale,
                         isUnknown: false)
    }
}

enum ProfileAction: Equatable {
    case open, bringToFront
}

struct ProfileRowModel: Equatable {
    let name: String
    let status: String
    let isRunning: Bool
    let hasUsage: Bool
    let fiveHour: QuotaCell
    let week: QuotaCell
    let action: ProfileAction

    static func make(name: String, usage: ClaudeUsageResult, running: Bool, showLeft: Bool, now: Date) -> ProfileRowModel {
        var fiveHour = QuotaCell.unknown, week = QuotaCell.unknown
        var status = "Usage unavailable"
        var hasUsage = false
        switch usage {
        case .noData:
            status = "No usage yet"
        case .unreadable:
            break
        case .reading(let r):
            let age = now.timeIntervalSince(r.date)
            fiveHour = r.fiveHourUsed == nil && r.weekUsed != nil
                ? .noFiveHour
                : .make(used: r.fiveHourUsed, freshness: QuotaMath.fiveHourFreshness(age: age), showLeft: showLeft)
            week = .make(used: r.weekUsed, freshness: QuotaMath.weekFreshness(age: age), showLeft: showLeft)
            let elapsed = RelativeAge.short(age)
            status = "\(running ? "Running" : "Closed") · \(elapsed == "now" ? "now" : "\(elapsed) ago")"
            hasUsage = true
        }
        return ProfileRowModel(name: name, status: status, isRunning: running, hasUsage: hasUsage,
                               fiveHour: fiveHour, week: week, action: running ? .bringToFront : .open)
    }

    static func menuBarValue(fiveHour: QuotaCell, week: QuotaCell) -> String {
        fiveHour.isUnknown || fiveHour.isStale ? (week.isUnknown ? fiveHour.text : week.text) : fiveHour.text
    }
}

struct CodexWindow: Equatable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?
}

struct CodexReading: Equatable {
    let primary: CodexWindow?
    let secondary: CodexWindow?
    var date: Date?
}

struct CodexRowModel: Equatable {
    private static let dayMinutes = 1440

    let detail: String
    let fiveHour: QuotaCell
    let week: QuotaCell

    // Codex names its windows primary and secondary, so their length decides the column.
    private static func columns(_ reading: CodexReading) -> (short: CodexWindow?, long: CodexWindow?) {
        let all = [reading.primary, reading.secondary].compactMap { $0 }
        guard all.allSatisfy({ $0.windowMinutes != nil }) else { return (reading.primary, reading.secondary) }
        return (all.first { ($0.windowMinutes ?? 0) <= dayMinutes }, all.first { ($0.windowMinutes ?? 0) > dayMinutes })
    }

    static func make(_ reading: CodexReading, showLeft: Bool, now: Date) -> CodexRowModel {
        func cell(_ window: CodexWindow?) -> QuotaCell {
            guard let window = window else { return .unknown }
            let passed = window.resetsAt.map { $0 <= now } ?? false
            return .make(used: passed ? 0 : window.usedPercent, freshness: .fresh, showLeft: showLeft)
        }
        let windows = columns(reading)
        var parts: [String] = []
        if let reset = (windows.short ?? windows.long)?.resetsAt {
            parts.append(reset <= now ? "Reset" : "Resets \(RelativeAge.short(reset.timeIntervalSince(now)))")
        }
        if let date = reading.date {
            let elapsed = RelativeAge.short(now.timeIntervalSince(date))
            parts.append(elapsed == "now" ? "now" : "\(elapsed) ago")
        }
        return CodexRowModel(detail: parts.isEmpty ? "Current account" : parts.joined(separator: " · "),
                             fiveHour: cell(windows.short), week: cell(windows.long))
    }
}

struct AntigravityStatus: Equatable {
    let lastActive: Date
    let model: String?
}

struct RecentSession: Equatable {
    let provider: String
    let project: String
    let date: Date
    let tokens: Int?
}

enum AITool: String, CaseIterable {
    case openCode = "opencode", copilot, cursor

    var displayName: String {
        switch self {
        case .openCode: return "OpenCode"
        case .copilot:  return "GitHub Copilot"
        case .cursor:   return "Cursor"
        }
    }

    // Relative to home; only modification dates are read, never contents.
    var activityPaths: [String] {
        switch self {
        case .openCode: return [".local/share/opencode/opencode.db-wal", ".local/share/opencode/opencode.db", ".local/share/opencode/log"]
        case .copilot:  return [".copilot/session-state", ".copilot/logs", ".copilot"]
        case .cursor:   return ["Library/Application Support/Cursor/User/globalStorage/state.vscdb", ".cursor"]
        }
    }
}

struct LocalToolStatus: Equatable {
    let tool: AITool
    let lastActive: Date

    private static let recentWindow: TimeInterval = 30 * 86400

    func isRecent(now: Date) -> Bool {
        now.timeIntervalSince(lastActive) < Self.recentWindow
    }
}

struct AISnapshot: Equatable {
    struct Profile: Equatable {
        let folder: String
        let name: String
        let usage: ClaudeUsageResult
        let isRunning: Bool
    }

    var profiles: [Profile] = []
    var codex: CodexReading?
    var antigravity: AntigravityStatus?
    var tools: [LocalToolStatus] = []

    // A running profile with the newest reading, else the newest reading at all.
    static func active(_ profiles: [Profile]) -> Profile? {
        func date(_ profile: Profile) -> Date {
            if case .reading(let r) = profile.usage { return r.date }
            return .distantPast
        }
        let withData = profiles.filter { date($0) != .distantPast }
        let pool = withData.contains { $0.isRunning } ? withData.filter { $0.isRunning } : withData
        return pool.max { date($0) < date($1) }
    }
}
