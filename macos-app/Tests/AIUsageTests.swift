import Foundation

private func data(_ s: String) -> Data { Data(s.utf8) }

func testQuotaMath() {
    T.eq(QuotaMath.fiveHourFreshness(age: 59 * 60), .fresh, "5h fresh under an hour")
    T.eq(QuotaMath.fiveHourFreshness(age: 3600), .stale, "5h stale at an hour")
    T.eq(QuotaMath.fiveHourFreshness(age: 5 * 3600 - 1), .stale, "5h stale before five hours")
    T.eq(QuotaMath.fiveHourFreshness(age: 5 * 3600), .expired, "5h expired at five hours")
    T.eq(QuotaMath.fiveHourFreshness(age: -60), .fresh, "small clock difference is fine")
    T.eq(QuotaMath.fiveHourFreshness(age: -3600), .expired, "reading from the future is not trusted")
    T.eq(QuotaMath.weekFreshness(age: -3600), .expired, "future week reading is not trusted")
    T.eq(QuotaMath.weekFreshness(age: 23 * 3600), .fresh, "week fresh under a day")
    T.eq(QuotaMath.weekFreshness(age: 86400), .stale, "week stale at a day")
    T.eq(QuotaMath.weekFreshness(age: 7 * 86400), .expired, "week expired at seven days")

    T.eq(QuotaMath.text(used: 38, freshness: .fresh, showLeft: true), "62%", "left when fresh")
    T.eq(QuotaMath.text(used: 38, freshness: .fresh, showLeft: false), "38%", "used when fresh")
    T.eq(QuotaMath.text(used: 60, freshness: .stale, showLeft: true), "~40%", "stale gets a tilde")
    T.eq(QuotaMath.text(used: 60, freshness: .expired, showLeft: true), "—", "expired shows a dash")
    T.eq(QuotaMath.text(used: nil, freshness: .fresh, showLeft: true), "—", "missing shows a dash")
    T.eq(QuotaMath.text(used: .nan, freshness: .fresh, showLeft: true), "—", "never NaN")
    T.eq(QuotaMath.text(used: 130, freshness: .fresh, showLeft: true), "0%", "clamped high")

    T.eq(QuotaMath.level(left: 62), .normal, "normal level")
    T.eq(QuotaMath.level(left: 29), .low, "low level")
    T.eq(QuotaMath.level(left: 14), .critical, "critical level")

    T.eq(RelativeAge.short(30), "now", "age now")
    T.eq(RelativeAge.short(12 * 60), "12m", "age minutes")
    T.eq(RelativeAge.short(3 * 3600), "3h", "age hours")
    T.eq(RelativeAge.short(22 * 86400), "22d", "age days")
    T.eq(RelativeAge.short(1e300), "365000d", "huge age is clamped")
    T.eq(RelativeAge.short(.infinity), "365000d", "infinite age is clamped")
    T.eq(RelativeAge.short(-1e300), "now", "huge negative age")
}

func testLiveParsers() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let good = #"{"id":2,"result":{"accountId":"x","rateLimits":{"primary":{"usedPercent":79,"windowDurationMins":300,"resetsAt":1000600},"secondary":{"usedPercent":58,"windowDurationMins":10080}}}}"#
    let codex = CodexAppServerParser.reading(fromLine: data(good), now: now)
    T.eq(codex?.primary?.usedPercent, 79, "codex live 5 hour")
    T.eq(codex?.primary?.windowMinutes, 300, "codex live window")
    T.eq(codex?.primary?.resetsAt, Date(timeIntervalSince1970: 1_000_600), "codex live reset")
    T.eq(codex?.secondary?.usedPercent, 58, "codex live week")
    T.eq(codex?.date, now, "a live reading is dated now")
    T.expect(CodexAppServerParser.reading(fromLine: data(#"{"id":1,"result":{"rateLimits":{"primary":{"usedPercent":1}}}}"#), now: now) == nil, "another reply is ignored")
    T.expect(CodexAppServerParser.reading(fromLine: data(#"{"id":2,"error":{"code":1}}"#), now: now) == nil, "an error is ignored")
    T.expect(CodexAppServerParser.reading(fromLine: data(#"{"id":2,"result":{"rateLimits":{}}}"#), now: now) == nil, "no windows")
    T.expect(CodexAppServerParser.reading(fromLine: data("garbage"), now: now) == nil, "garbage")

    let old = CodexReading(primary: nil, secondary: nil, date: now.addingTimeInterval(-60))
    let fresh = CodexReading(primary: nil, secondary: nil, date: now)
    T.eq(CodexReading.newest(old, fresh), fresh, "newer reading wins")
    T.eq(CodexReading.newest(fresh, old), fresh, "newer reading wins either way")
    T.eq(CodexReading.newest(nil, old), old, "file only")
    T.eq(CodexReading.newest(old, nil), old, "live only")

    let status = #"""
    {"userStatus":{"email":"dummy@example.com","name":"Dummy","planStatus":{"planInfo":{"planName":"Pro"}},"cascadeModelConfigData":{"clientModelConfigs":[
    {"label":"Gemini 4 (High)","quotaInfo":{"remainingFraction":0.25,"resetTime":"1970-01-13T00:00:00Z"}},
    {"label":"Gemini 4 (Low)","quotaInfo":{"remainingFraction":0.25,"resetTime":"1970-01-13T00:00:00Z"}},
    {"label":"Flash (Low)","quotaInfo":{"remainingFraction":1.7,"resetTime":"1970-01-13T00:00:00.500Z"}},
    {"label":"Opus (Low)","quotaInfo":{"resetTime":"1970-01-14T00:00:00Z"}},
    {"label":"Sonnet (Low)","quotaInfo":{"resetTime":"1970-01-14T00:00:00Z"}},
    {"label":"GPT (Low)","quotaInfo":{"resetTime":"1970-01-14T00:00:00Z"}},
    {"label":"No quota (Low)"},
    {"quotaInfo":{"remainingFraction":0.5}}
    ]}}}
    """#
    let live = AntigravityStatusParser.live(from: data(status), now: now)
    T.eq(live?.plan, "Pro", "antigravity plan")
    T.eq(live?.quotas.map(\.name), ["Gemini 4", "Flash", "Opus +2"], "models with one quota are grouped")
    T.eq(live?.quotas.map(\.left), [0.25, 1, 0], "a missing fraction is zero and a big one clamps")
    T.eq(live?.quotas.last?.fullName, "Opus, Sonnet, GPT", "the full list stays for the tooltip")
    T.expect(live?.quotas.first?.resetsAt != nil, "reset date parses")
    T.expect(live?.quotas[1].resetsAt != nil, "reset date with fractions parses")
    T.expect(AntigravityStatusParser.live(from: data(#"{"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[{"label":"A","quotaInfo":{"remainingFraction":0.5,"resetTime":"bad"}}]}}}"#), now: now)?.quotas.first?.resetsAt == nil, "a bad reset is unknown")
    T.expect(AntigravityStatusParser.live(from: data("garbage"), now: now) == nil, "garbage status")
    T.expect(AntigravityStatusParser.live(from: data(#"{"other":1}"#), now: now) == nil, "no user status")

    T.eq(LoopbackPorts.parse("p99\nf1\nn127.0.0.1:54785\nf2\nn127.0.0.1:54786\nn*:80\nn10.0.0.2:81\nn127.0.0.1:99999\nn127.0.0.1:x\n"), [54785, 54786], "only loopback ports")
    T.eq(ProcessArgs.value(of: "--t", in: ["a", "--t", "v", "--u=1"]), "v", "flag then value")
    T.eq(ProcessArgs.value(of: "--u", in: ["a", "--t", "v", "--u=1"]), "1", "flag with equals")
    T.eq(ProcessArgs.value(of: "--t", in: ["a", "--t"]), nil, "flag with no value")
    T.eq(ProcessArgs.value(of: "--z", in: ["a"]), nil, "absent flag")

    let quota = AntigravityQuota(name: "A", fullName: "A", left: 0.2, resetsAt: now.addingTimeInterval(600))
    func model(_ age: TimeInterval, _ item: AntigravityQuota = quota) -> AntigravityRowModel {
        AntigravityRowModel.make(AntigravityStatus(lastActive: now, model: "m", live: AntigravityLive(plan: "Pro", quotas: [item], date: now.addingTimeInterval(-age))), showLeft: true, now: now)
    }
    T.eq(model(0).detail, "Pro · now", "live detail")
    T.eq(model(0).quotas.first?.cell.text, "20%", "live quota left")
    T.eq(model(0).quotas.first?.reset, "Resets 10m", "live quota reset")
    T.eq(model(7200).quotas.first?.cell.text, "~20%", "older live quota is marked")
    T.eq(model(7200).detail, "Pro · 2h ago", "older live detail")
    T.eq(model(6 * 3600).quotas.first?.cell.text, "—", "expired live quota")
    let passed = AntigravityQuota(name: "A", fullName: "A", left: 0.2, resetsAt: now.addingTimeInterval(-60))
    T.eq(model(0, passed).quotas.first?.cell.text, "100%", "a passed reset is full")
    T.eq(model(0, passed).quotas.first?.reset, "Reset", "a passed reset is named")
    T.eq(AntigravityRowModel.make(AntigravityStatus(lastActive: now.addingTimeInterval(-60), model: "m"), showLeft: true, now: now).detail, "Last active 1m ago · m", "no live numbers")

    let stale = CodexReading(primary: CodexWindow(usedPercent: 5, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600)),
                             secondary: CodexWindow(usedPercent: 17, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
                             date: now.addingTimeInterval(-11 * 3600))
    T.eq(CodexRowModel.make(stale, showLeft: true, now: now).fiveHour.text, "—", "an 11 hour old 5h value is not trusted")
    T.eq(CodexRowModel.make(stale, showLeft: true, now: now).week.text, "83%", "a weekly value is fresh for a day")
    let older = CodexReading(primary: stale.primary, secondary: stale.secondary, date: now.addingTimeInterval(-2 * 86400))
    T.eq(CodexRowModel.make(older, showLeft: true, now: now).week.text, "~83%", "an older weekly value is marked")

    func profile(_ running: Bool, _ age: TimeInterval) -> AISnapshot.Profile {
        .init(folder: "F", name: "N", usage: .reading(ClaudeUsageReading(date: now.addingTimeInterval(-age), fiveHourUsed: nil, weekUsed: 1)), isRunning: running)
    }
    T.eq(AISnapshot.hasPausedProfile([profile(true, 3600)], now: now), true, "a running profile with an old reading is paused")
    T.eq(AISnapshot.hasPausedProfile([profile(true, 600)], now: now), false, "a recent reading is not paused")
    T.eq(AISnapshot.hasPausedProfile([profile(false, 3600)], now: now), false, "a closed profile is not paused")
}

func testAccountUsage() {
    func reading(_ seconds: Double, _ account: String?, week: Double) -> ClaudeUsageResult {
        .reading(ClaudeUsageReading(date: Date(timeIntervalSince1970: seconds), fiveHourUsed: nil, weekUsed: week, account: account))
    }
    let merged = AccountUsage.merged([reading(100, "a", week: 1), reading(300, "a", week: 3), reading(200, "b", week: 2),
                                      reading(50, nil, week: 9), .noData, .unreadable, reading(10, nil, week: 8)])
    T.eq(merged[0], reading(300, "a", week: 3), "older folder takes the account's newest reading")
    T.eq(merged[1], reading(300, "a", week: 3), "newest folder keeps its reading")
    T.eq(merged[2], reading(200, "b", week: 2), "another account is untouched")
    T.eq(merged[3], reading(50, nil, week: 9), "no account stays on its own")
    T.eq(merged[4], .noData, "no data stays")
    T.eq(merged[5], .unreadable, "unreadable stays")
    T.eq(merged[6], reading(10, nil, week: 8), "readings with no account never merge")
}

func testLocalTools() {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("ai-meter-tools-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: home) }
    T.eq(LocalTools.read(home: home), [], "no tools on this Mac")
    let db = home.appendingPathComponent(".local/share/opencode/opencode.db")
    try? fm.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data().write(to: db)
    let when = Date(timeIntervalSince1970: 1_000_000)
    try? fm.setAttributes([.modificationDate: when], ofItemAtPath: db.path)
    try? fm.setAttributes([.modificationDate: when], ofItemAtPath: db.deletingLastPathComponent().appendingPathComponent("log").path)
    let found = LocalTools.read(home: home)
    T.eq(found.map(\.tool), [.openCode], "a tool appears only when found")
    T.eq(found.first?.lastActive, when, "last active is the file date")
    let status = LocalToolStatus(tool: .openCode, lastActive: when)
    T.eq(status.isRecent(now: when.addingTimeInterval(29 * 86400)), true, "used within 30 days")
    T.eq(status.isRecent(now: when.addingTimeInterval(31 * 86400)), false, "unused for over 30 days")
}

func testClaudeUsageParser() {
    let good = #"{"version":2,"samples":[{"t":1000,"org":"a","u":{"fh":10,"sd":20}},{"t":2000,"org":"a","u":{"fh":38,"sd":43}}]}"#
    if case .reading(let r) = ClaudeUsageParser.parse(data(good)) {
        T.eq(r.date, Date(timeIntervalSince1970: 2), "milliseconds become seconds")
        T.eq(r.fiveHourUsed, 38, "latest 5h")
        T.eq(r.weekUsed, 43, "latest week")
    } else { T.expect(false, "valid file parses") }

    if case .reading(let r) = ClaudeUsageParser.parse(data(#"{"samples":[{"t":5000,"u":{"sd":12}}]}"#)) {
        T.eq(r.fiveHourUsed, nil, "fh is optional")
        T.eq(r.weekUsed, 12, "sd read without fh")
    } else { T.expect(false, "missing fh still parses") }

    let mixed = #"{"samples":[{"t":1000,"org":"a","u":{"fh":5,"sd":6}},{"t":2000,"org":"b","u":{"sd":7}},{"t":3000,"org":"c","u":{}}]}"#
    if case .reading(let r) = ClaudeUsageParser.parse(data(mixed)) {
        T.eq(r.date, Date(timeIntervalSince1970: 2), "empty sample is skipped")
        T.eq(r.account, "b", "account comes from the same sample")
        T.eq(r.fiveHourUsed, nil, "a weekly-only sample has no 5h")
        T.eq(r.weekUsed, 7, "weekly-only value")
    } else { T.expect(false, "mixed samples parse") }
    if case .reading(let r) = ClaudeUsageParser.parse(data(#"{"samples":[{"t":4000,"u":{}}]}"#)) {
        T.eq(r.date, Date(timeIntervalSince1970: 4), "only empty samples keep the last date")
        T.eq(r.weekUsed, nil, "only empty samples have no value")
    } else { T.expect(false, "only empty samples parse") }

    T.eq(ClaudeUsageParser.parse(data(#"{"samples":[]}"#)), .noData, "empty samples")
    T.eq(ClaudeUsageParser.parse(data(#"[1,2]"#)), .unreadable, "array root is a format change")
    T.eq(ClaudeUsageParser.parse(data(#"{"other":1}"#)), .unreadable, "no samples key")
    T.eq(ClaudeUsageParser.parse(data("not json")), .unreadable, "garbage")
    T.eq(ClaudeUsageParser.parse(data(#"{"samples":[{"t":"x","u":{"fh":1}}]}"#)), .unreadable, "bad timestamp")

    if case .reading(let r) = ClaudeUsageParser.parse(data(#"{"samples":[{"t":1,"u":{"fh":150,"sd":-4}}]}"#)) {
        T.eq(r.fiveHourUsed, 100, "above 100 clamps")
        T.eq(r.weekUsed, nil, "negative is dropped")
    } else { T.expect(false, "out of range still parses") }
}

func testCodexUsageParser() {
    let line = #"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":18.0,"window_minutes":300,"resets_at":1700000000},"secondary":{"used_percent":41.5,"window_minutes":10080,"resets_at":1700100000}}}}"#
    let empty = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":null,"secondary":null}}}"#
    let noise = #"{"type":"response_item","payload":{"text":"rate_limits appears in text"}}"#

    var r = CodexUsageParser.lastReading(tail: data(line + "\n" + noise + "\n"), dropFirstLine: false)
    T.eq(r?.primary?.usedPercent, 18, "primary used")
    T.eq(r?.primary?.windowMinutes, 300, "primary window")
    T.eq(r?.primary?.resetsAt, Date(timeIntervalSince1970: 1_700_000_000), "reset in epoch seconds")
    T.eq(r?.secondary?.usedPercent, 41.5, "secondary used")

    r = CodexUsageParser.lastReading(tail: data(line + "\n" + empty + "\n"), dropFirstLine: false)
    T.eq(r?.primary?.usedPercent, 18, "null limits fall back to the earlier event")

    T.eq(CodexUsageParser.lastReading(tail: data(empty), dropFirstLine: false), nil, "only null limits")
    T.eq(CodexUsageParser.lastReading(tail: data(noise), dropFirstLine: false), nil, "no limits")
    T.eq(CodexUsageParser.lastReading(tail: data(String(line.dropFirst(12)) + "\n"), dropFirstLine: true), nil, "partial first line skipped")
    T.eq(CodexUsageParser.lastReading(tail: data(line + "\n{\"broken"), dropFirstLine: false)?.primary?.usedPercent, 18, "truncated last line skipped")
}

func testCodexFiles() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ai-meter-tests-\(UUID().uuidString)")
    let nested = dir.appendingPathComponent("2026/11/05")
    try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let withLimits = #"{"payload":{"rate_limits":{"primary":{"used_percent":7,"window_minutes":300,"resets_at":1}}}}"# + "\n"
    let older = nested.appendingPathComponent("a.jsonl"), newer = nested.appendingPathComponent("b.jsonl")
    try? Data(withLimits.utf8).write(to: older)
    try? Data("{\"payload\":{}}\n".utf8).write(to: newer)
    try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: older.path)

    T.eq(CodexProvider.read(root: dir)?.primary?.usedPercent, 7, "walks back past a session without limits")
    T.eq(CodexProvider.read(root: dir.appendingPathComponent("missing")), nil, "missing folder")

    let link = nested.appendingPathComponent("c.jsonl")
    try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: older)
    T.expect(SafeFile.tail(link, maxBytes: 100) == nil, "symlink refused")
    T.eq(SafeFile.tail(older, maxBytes: 8)?.data.count, 8, "tail reads the end only")
    T.eq(SafeFile.tail(older, maxBytes: 8)?.truncated, true, "tail reports truncation")
}

func testAntigravityParser() {
    T.eq(AntigravityParser.model(from: "x: 1\nlast_selected_agent_model: MODEL_ONE\ny: 2\n"), "MODEL_ONE", "bare value")
    T.eq(AntigravityParser.model(from: #"last_selected_agent_model: "Model Two""#), "Model Two", "quoted value")
    T.eq(AntigravityParser.model(from: "nothing here"), nil, "absent")
}

func testSessionParser() {
    let tail = #"{"cwd":"/tmp/one"}"# + "\n"
        + #"{"cwd":"/work/two","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30,"output_tokens":40}}}"# + "\n"
        + #"{"broken"#
    let r = SessionTail.claude(data(tail), dropFirstLine: false)
    T.eq(r.project, "two", "last cwd wins")
    T.eq(r.tokens, 100, "last usage summed")
    let codex = #"{"payload":{"cwd":"/work/three"}}"# + "\n" + #"{"payload":{"info":{"total_token_usage":{"total_tokens":55}}}}"# + "\n"
    let c = SessionTail.codex(data(codex), dropFirstLine: false)
    T.eq(c.project, "three", "codex cwd")
    T.eq(c.tokens, 55, "codex total")
    T.eq(SessionTail.claude(data("{}"), dropFirstLine: false).tokens, nil, "tokens optional")
    let overflow = #"{"message":{"usage":{"input_tokens":9223372036854775807,"output_tokens":1}}}"#
    T.eq(SessionTail.claude(data(overflow), dropFirstLine: false).tokens, Int.max, "token sum saturates")

    let hugePast = #"{"samples":[{"t":-1e300,"u":{"fh":10,"sd":20}}]}"#
    let hugeNow = Date(timeIntervalSince1970: 100_000)
    let oldRow = ProfileRowModel.make(name: "Max", usage: ClaudeUsageParser.parse(data(hugePast)), running: false, showLeft: true, now: hugeNow)
    T.expect(oldRow.status.contains("365000d"), "huge past sample builds a clamped row")
    let hugeReset = CodexReading(primary: CodexWindow(usedPercent: 7, windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: 1e300)), secondary: nil)
    T.eq(CodexRowModel.make(hugeReset, showLeft: true, now: hugeNow).detail, "Resets 365000d", "huge reset date builds a clamped row")
}
