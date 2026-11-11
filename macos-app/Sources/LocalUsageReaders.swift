import Foundation

// Vendor files: regular files only, bounded size, never followed through a link.
enum SafeFile {
    static let maxConfigBytes = 2 * 1024 * 1024
    static let tailBytes = 32 * 1024

    private static func isRegular(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }

    static func read(_ url: URL) -> Data? {
        guard isRegular(url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size <= maxConfigBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    static func tail(_ url: URL, maxBytes: Int = tailBytes) -> (data: Data, truncated: Bool)? {
        guard isRegular(url), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        return (data, start > 0)
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func jsonLines(_ data: Data, dropFirstLine: Bool) -> [[String: Any]] {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if dropFirstLine, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
    }
}

enum ClaudeUsageParser {
    static func parse(_ data: Data) -> ClaudeUsageResult {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]] else { return .unreadable }
        guard let last = samples.last else { return .noData }
        // Claude also writes empty samples: the newest one with a value on the same account counts.
        let account = last["org"] as? String
        let sample = samples.last {
            $0["org"] as? String == account && (usage(in: $0).fiveHour != nil || usage(in: $0).week != nil)
        } ?? last
        guard let millis = (sample["t"] as? NSNumber)?.doubleValue else { return .unreadable }
        let values = usage(in: sample)
        return .reading(ClaudeUsageReading(date: Date(timeIntervalSince1970: millis / 1000),
                                           fiveHourUsed: values.fiveHour,
                                           weekUsed: values.week,
                                           account: (sample["org"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
    }

    private static func usage(in sample: [String: Any]) -> (fiveHour: Double?, week: Double?) {
        let values = sample["u"] as? [String: Any]
        return (percent(values?["fh"]), percent(values?["sd"]))
    }

    private static func percent(_ value: Any?) -> Double? {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite, number >= 0 else { return nil }
        return min(100, number)
    }
}

// Re-parses a usage file only when its modification date or size changes.
final class ClaudeUsageCache {
    private var entries: [String: (date: Date, size: Int, result: ClaudeUsageResult)] = [:]

    func read(profile: ClaudeProfile) -> ClaudeUsageResult {
        let url = profile.url.appendingPathComponent("plan-usage-history.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return .noData }
        let date = attributes[.modificationDate] as? Date ?? .distantPast
        let size = attributes[.size] as? Int ?? 0
        if let hit = entries[url.path], hit.date == date, hit.size == size { return hit.result }
        let result = SafeFile.read(url).map(ClaudeUsageParser.parse) ?? .unreadable
        entries[url.path] = (date, size, result)
        return result
    }
}

enum CodexUsageParser {
    static func lastReading(tail: Data, dropFirstLine: Bool) -> CodexReading? {
        for line in SafeFile.jsonLines(tail, dropFirstLine: dropFirstLine).reversed() {
            guard let limits = (line["payload"] as? [String: Any])?["rate_limits"] as? [String: Any] else { continue }
            let primary = window(limits["primary"]), secondary = window(limits["secondary"])
            guard primary != nil || secondary != nil else { continue }
            // Later lines move the file date, so the event's own time dates the reading.
            return CodexReading(primary: primary, secondary: secondary, date: (line["timestamp"] as? String).flatMap(eventDate))
        }
        return nil
    }

    private static func eventDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func window(_ value: Any?) -> CodexWindow? {
        guard let object = value as? [String: Any],
              let used = (object["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        return CodexWindow(usedPercent: used,
                           windowMinutes: (object["window_minutes"] as? NSNumber)?.intValue,
                           resetsAt: (object["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
    }
}

enum CodexProvider {
    private static let filesToTry = 5
    static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions") }

    static func read(root: URL = defaultRoot) -> CodexReading? {
        for file in SessionFiles.newest(under: root, limit: filesToTry) {
            guard let tail = SafeFile.tail(file),
                  var reading = CodexUsageParser.lastReading(tail: tail.data, dropFirstLine: tail.truncated) else { continue }
            reading.date = reading.date ?? SafeFile.modificationDate(file)
            return reading
        }
        return nil
    }
}

enum AntigravityParser {
    static func model(from text: String) -> String? {
        guard let range = text.range(of: #"last_selected_agent_model:\s*"?([^"\n]+)"?"#, options: .regularExpression) else { return nil }
        let value = text[range].dropFirst("last_selected_agent_model:".count)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
        // Antigravity writes a placeholder id here for some models, which means nothing to a person.
        return value.isEmpty || value.hasPrefix("MODEL_PLACEHOLDER_") ? nil : value
    }
}

enum CodexAppServerParser {
    static let requestID = 2

    // An error reply ends the wait at once instead of after the timeout.
    static func isReply(_ line: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any])?["id"] as? NSNumber == NSNumber(value: requestID)
    }

    static func reading(fromLine line: Data, now: Date) -> CodexReading? {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              (root["id"] as? NSNumber)?.intValue == requestID,
              let limits = (root["result"] as? [String: Any])?["rateLimits"] as? [String: Any] else { return nil }
        let primary = window(limits["primary"]), secondary = window(limits["secondary"])
        guard primary != nil || secondary != nil else { return nil }
        return CodexReading(primary: primary, secondary: secondary, date: now)
    }

    private static func window(_ value: Any?) -> CodexWindow? {
        guard let object = value as? [String: Any],
              let used = (object["usedPercent"] as? NSNumber)?.doubleValue, used.isFinite else { return nil }
        return CodexWindow(usedPercent: used,
                           windowMinutes: (object["windowDurationMins"] as? NSNumber)?.intValue,
                           resetsAt: (object["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
    }
}

enum AntigravityStatusParser {
    private static let maxRows = 4
    private static let maxText = 48
    private static let maxModels = 64
    private static let maxLabelBytes = 512

    // The reply also holds the account's email and name, which are never read.
    static func live(from data: Data, now: Date) -> AntigravityLive? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = root["userStatus"] as? [String: Any] else { return nil }
        let plan = ((status["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String
        let models = (status["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]] ?? []
        var groups: [(left: Double, reset: String?, names: [String])] = []
        for model in models.prefix(maxModels) {
            guard let quota = model["quotaInfo"] as? [String: Any],
                  let name = baseName(model["label"] as? String) else { continue }
            // This JSON leaves out zeros, so a quota with no fraction has nothing left.
            let raw = (quota["remainingFraction"] as? NSNumber)?.doubleValue ?? 0
            let left = raw.isFinite ? min(1, max(0, raw)) : 0
            let reset = quota["resetTime"] as? String
            if let index = groups.firstIndex(where: { $0.left == left && $0.reset == reset }) {
                if !groups[index].names.contains(name) { groups[index].names.append(name) }
            } else {
                groups.append((left, reset, [name]))
            }
        }
        let quotas = groups.prefix(maxRows).map { group in
            AntigravityQuota(name: group.names.count > 1 ? "\(group.names[0]) +\(group.names.count - 1)" : group.names[0],
                             fullName: group.names.joined(separator: ", "),
                             left: group.left,
                             resetsAt: group.reset.flatMap(date))
        }
        return AntigravityLive(plan: plan.map { String($0.prefix(maxText)) }, quotas: quotas, date: now)
    }

    private static func baseName(_ label: String?) -> String? {
        guard let label = label else { return nil }
        // The regex is quadratic on some text, so its input is bounded before it runs.
        let bounded = String(decoding: label.utf8.prefix(maxLabelBytes), as: UTF8.self)
        let base = bounded.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        return base.isEmpty ? nil : String(base.prefix(maxText))
    }

    private static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let value = plain.date(from: text) { return value }
        plain.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text)
    }
}

enum LoopbackPorts {
    // Reads lsof -Fn output and keeps only ports bound to this Mac's loopback address.
    static func parse(_ output: String) -> [Int] {
        output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("n127.0.0.1:"), let port = Int(line.dropFirst("n127.0.0.1:".count)),
                  (1...65535).contains(port) else { return nil }
            return port
        }
    }
}

enum LocalTools {
    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [LocalToolStatus] {
        AITool.allCases.compactMap { tool in
            let dates = tool.activityPaths.compactMap { SafeFile.modificationDate(home.appendingPathComponent($0)) }
            return dates.max().map { LocalToolStatus(tool: tool, lastActive: $0) }
        }
    }

    static func listed() -> [LocalToolStatus] {
        AppMode.isDemo ? DemoData.tools(now: Date()) : read()
    }
}

enum AntigravityProvider {
    static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity") }

    static func read(root: URL = defaultRoot) -> AntigravityStatus? {
        let state = root.appendingPathComponent("antigravity_state.pbtxt")
        let locks = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("presence"), includingPropertiesForKeys: nil)) ?? []
        let activity = ["conversation_summaries.db", "conversations", "brain"].map { root.appendingPathComponent($0) }
        let dates = ([state] + activity + locks.filter { $0.pathExtension == "lock" }).compactMap(SafeFile.modificationDate)
        guard let last = dates.max() else { return nil }
        let model = SafeFile.read(state).flatMap { String(data: $0, encoding: .utf8) }.flatMap(AntigravityParser.model)
        return AntigravityStatus(lastActive: last, model: model)
    }
}

enum SessionFiles {
    static func newest(under root: URL, limit: Int) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var found: [(URL, Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            found.append((url, values.contentModificationDate ?? .distantPast))
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}

enum SessionTail {
    static func claude(_ data: Data, dropFirstLine: Bool) -> (project: String?, tokens: Int?) {
        var project: String?, tokens: Int?
        for line in SafeFile.jsonLines(data, dropFirstLine: dropFirstLine) {
            if let cwd = line["cwd"] as? String { project = URL(fileURLWithPath: cwd).lastPathComponent }
            if let usage = (line["message"] as? [String: Any])?["usage"] as? [String: Any] {
                tokens = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"]
                    .compactMap { (usage[$0] as? NSNumber)?.intValue }
                    .reduce(0) { let sum = $0.addingReportingOverflow($1); return sum.overflow ? Int.max : sum.partialValue }
            }
        }
        return (project, tokens)
    }

    static func codex(_ data: Data, dropFirstLine: Bool) -> (project: String?, tokens: Int?) {
        var project: String?, tokens: Int?
        for line in SafeFile.jsonLines(data, dropFirstLine: dropFirstLine) {
            guard let payload = line["payload"] as? [String: Any] else { continue }
            if let cwd = payload["cwd"] as? String { project = URL(fileURLWithPath: cwd).lastPathComponent }
            if let total = ((payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber {
                tokens = total.intValue
            }
        }
        return (project, tokens)
    }
}

enum LocalSessionScanner {
    static func recent(limit: Int = 3) -> [RecentSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var sessions: [RecentSession] = []
        for file in SessionFiles.newest(under: home.appendingPathComponent(".claude/projects"), limit: limit) {
            guard let tail = SafeFile.tail(file), let date = SafeFile.modificationDate(file) else { continue }
            let parsed = SessionTail.claude(tail.data, dropFirstLine: tail.truncated)
            sessions.append(RecentSession(provider: "Claude", project: parsed.project ?? "Session", date: date, tokens: parsed.tokens))
        }
        for file in SessionFiles.newest(under: CodexProvider.defaultRoot, limit: limit) {
            guard let tail = SafeFile.tail(file), let date = SafeFile.modificationDate(file) else { continue }
            let parsed = SessionTail.codex(tail.data, dropFirstLine: tail.truncated)
            sessions.append(RecentSession(provider: "Codex", project: parsed.project ?? "Session", date: date, tokens: parsed.tokens))
        }
        return Array(sessions.sorted { $0.date > $1.date }.prefix(limit))
    }
}
