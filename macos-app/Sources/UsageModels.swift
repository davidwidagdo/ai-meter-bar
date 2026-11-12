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

// empty: the tool answered with no numbers, as after a sign-out. unavailable: no answer at all.
enum LiveRead<Value> {
    case reading(Value), empty, unavailable

    func next(keeping last: Value?) -> Value? {
        switch self {
        case .reading(let value): return value
        case .empty:              return nil
        case .unavailable:        return last
        }
    }
}

enum TokenFormat {
    static func short(_ tokens: Int) -> String {
        // From 999,950 the K form would round up to "1000.0K".
        if tokens >= 999_950 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
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
    var notReported = false

    static let unknown = QuotaCell(text: "—", fraction: 0, level: .normal, isStale: false, isUnknown: true)
    static let noFiveHour = QuotaCell(text: "No 5h", fraction: 0, level: .normal, isStale: false, isUnknown: true, notReported: true)

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
    var sameAccountAs: String?
    let fiveHour: QuotaCell
    let week: QuotaCell
    let action: ProfileAction

    static func make(name: String, usage: ClaudeUsageResult, running: Bool, showLeft: Bool, now: Date, sameAccountAs: String? = nil) -> ProfileRowModel {
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
            // The row it matches already shows this age, and the width only fits the name.
            status = sameAccountAs.map { "Same as \($0)" } ?? "\(running ? "Running" : "Closed") · \(LastActive.ago(r.date, now: now))"
            hasUsage = true
        }
        return ProfileRowModel(name: name, status: status, isRunning: running, hasUsage: hasUsage, sameAccountAs: sameAccountAs,
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

    static func newest(_ first: CodexReading?, _ second: CodexReading?) -> CodexReading? {
        guard let first = first else { return second }
        guard let second = second else { return first }
        return (second.date ?? .distantPast) > (first.date ?? .distantPast) ? second : first
    }
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
        let age = reading.date.map { now.timeIntervalSince($0) }
        func cell(_ window: CodexWindow?, _ freshness: Freshness) -> QuotaCell {
            guard let window = window else { return .unknown }
            // A passed reset stays true however old the reading is, so it never expires.
            if window.resetsAt.map({ $0 <= now }) ?? false {
                return .make(used: 0, freshness: freshness == .fresh ? .fresh : .stale, showLeft: showLeft)
            }
            return .make(used: window.usedPercent, freshness: freshness, showLeft: showLeft)
        }
        let windows = columns(reading)
        var parts: [String] = []
        let window = windows.short.map { ("5h", $0) } ?? windows.long.map { ("Week", $0) }
        if let (name, window) = window, let reset = window.resetsAt {
            parts.append(reset <= now ? "\(name) reset" : "\(name) resets in \(RelativeAge.short(reset.timeIntervalSince(now)))")
        }
        // A fresh reading needs no age; an older one says how old it is.
        if let date = reading.date, RelativeAge.short(now.timeIntervalSince(date)) != "now" {
            parts.append(LastActive.ago(date, now: now))
        }
        return CodexRowModel(detail: parts.isEmpty ? "Current account" : parts.joined(separator: " · "),
                             fiveHour: cell(windows.short, age.map(QuotaMath.fiveHourFreshness) ?? .fresh),
                             week: cell(windows.long, age.map(QuotaMath.weekFreshness) ?? .fresh))
    }
}

struct AntigravityStatus: Equatable {
    let lastActive: Date
    let model: String?
    var live: AntigravityLive?
}

struct AntigravityQuota: Equatable {
    let name: String
    let fullName: String
    let left: Double
    let resetsAt: Date?
}

struct AntigravityLive: Equatable {
    let plan: String?
    let quotas: [AntigravityQuota]
    let date: Date
}

struct AntigravityRowModel: Equatable {
    struct Quota: Equatable {
        let name: String
        let fullName: String
        let reset: String
        let cell: QuotaCell
    }

    let detail: String
    let quotas: [Quota]

    static func make(_ status: AntigravityStatus, showLeft: Bool, now: Date) -> AntigravityRowModel {
        guard let live = status.live else {
            var detail = LastActive.line(status.lastActive, now: now)
            if let model = status.model { detail += " · \(model)" }
            return AntigravityRowModel(detail: detail, quotas: [])
        }
        let age = LastActive.ago(live.date, now: now)
        let freshness = QuotaMath.fiveHourFreshness(age: now.timeIntervalSince(live.date))
        let quotas = live.quotas.map { quota -> Quota in
            let passed = quota.resetsAt.map { $0 <= now } ?? false
            let cell = passed
                ? QuotaCell.make(used: 0, freshness: freshness == .fresh ? .fresh : .stale, showLeft: showLeft)
                : QuotaCell.make(used: (1 - quota.left) * 100, freshness: freshness, showLeft: showLeft)
            let reset = quota.resetsAt.map { passed ? "Reset" : "Resets in \(RelativeAge.short($0.timeIntervalSince(now)))" } ?? ""
            return Quota(name: quota.name, fullName: quota.fullName, reset: reset, cell: cell)
        }
        let plan = live.plan.map { $0.lowercased().hasSuffix("plan") ? $0 : "\($0) plan" }
        let detail = age == "now" ? (plan ?? "Updated now") : plan.map { "\($0) · \(age)" } ?? "Updated \(age)"
        return AntigravityRowModel(detail: detail, quotas: quotas)
    }
}

enum LastActive {
    static func ago(_ date: Date, now: Date) -> String {
        let elapsed = RelativeAge.short(now.timeIntervalSince(date))
        return elapsed == "now" ? "now" : "\(elapsed) ago"
    }

    static func line(_ date: Date, now: Date) -> String {
        "Last active \(ago(date, now: now))"
    }
}

enum AITooltip {
    private static func windows(fiveHour: QuotaCell, week: QuotaCell) -> String? {
        var parts: [String] = []
        if !fiveHour.isUnknown { parts.append("5h \(fiveHour.text) left") }
        if !week.isUnknown { parts.append("week \(week.text) left") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func lines(profile: ProfileRowModel?, codex: CodexRowModel?) -> [String] {
        var lines: [String] = []
        if let profile = profile, let text = windows(fiveHour: profile.fiveHour, week: profile.week) { lines.append("\(profile.name): \(text)") }
        if let codex = codex, let text = windows(fiveHour: codex.fiveHour, week: codex.week) { lines.append("Codex: \(text)") }
        return lines
    }
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
        // Logs and IDE locks change whenever Copilot merely starts, so they say nothing about use.
        case .copilot:  return [".copilot/session-state", "Library/Application Support/Code/User/globalStorage/github.copilot-chat"]
        case .cursor:   return ["Library/Application Support/Cursor/User/globalStorage/state.vscdb", ".cursor"]
        }
    }

    // Copilot lives in VS Code, so its row opens VS Code.
    var appBundleID: String {
        switch self {
        case .openCode: return "ai.opencode.desktop"
        case .copilot:  return "com.microsoft.VSCode"
        case .cursor:   return "com.todesktop.230313mzl4w4u92"
        }
    }
}

enum ToolApps {
    static let codex = "com.openai.codex"
    static let antigravity = "com.google.antigravity"
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

    private static let pausedAfter: TimeInterval = 20 * 60

    // Claude checks at least every 15 minutes while it polls, so an older reading means it stopped.
    static func hasPausedProfile(_ profiles: [Profile], now: Date) -> Bool {
        profiles.contains { profile in
            guard profile.isRunning, case .reading(let reading) = profile.usage else { return false }
            return now.timeIntervalSince(reading.date) >= pausedAfter
        }
    }

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
