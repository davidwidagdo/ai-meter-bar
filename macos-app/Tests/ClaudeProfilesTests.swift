import Foundation

func testProfileNames() {
    let existing = ["Max", "My-Work"]
    T.eq(ProfileNames.check("Client", existing: existing), .ok, "free name")
    T.eq(ProfileNames.check("max", existing: existing), .taken, "taken ignores case")
    T.eq(ProfileNames.check("my work", existing: existing), .taken, "taken after spaces become hyphens")
    T.eq(ProfileNames.check("Default", existing: existing), .taken, "Default is reserved")
    T.eq(ProfileNames.check("   ", existing: existing), .empty, "blank")
    T.eq(ProfileNames.check("a/b", existing: existing), .invalid, "slash")
    T.eq(ProfileNames.check("Client\n", existing: existing), .invalid, "trailing newline")
    T.eq(ProfileNames.check("../x", existing: existing), .invalid, "path escape")
    T.eq(ProfileNames.check("\"; rm -rf", existing: existing), .invalid, "shell characters")
    T.eq(ProfileNames.check(String(repeating: "a", count: 33), existing: existing), .invalid, "too long")
    T.eq(ProfileNames.check(String(repeating: "a", count: 32), existing: existing), .ok, "longest allowed")

    T.eq(ProfileNames.folderName("My Work"), "Claude-My-Work", "folder name")
    T.eq(ProfileNames.launcherName("My Work"), "Claude - My Work.app", "launcher name")
    T.eq(ProfileNames.displayName(folder: "Claude"), "Default", "default profile")
    T.eq(ProfileNames.displayName(folder: "Claude-Max"), "Max", "named profile")
    T.eq(ProfileNames.displayName(folder: "Claude Code"), nil, "other folder")
    T.eq(ProfileNames.displayName(folder: "Claude-"), nil, "no suffix")

    let url = URL(fileURLWithPath: "/tmp/x")
    T.eq(ProfileNames.canHaveLauncher(ClaudeProfile(folder: "Claude-My-Work", name: "My-Work", url: url)), true, "hyphen folder can have a launcher")
    T.eq(ProfileNames.canHaveLauncher(ClaudeProfile(folder: "Claude-My Work", name: "My Work", url: url)), false, "space folder would map to another folder")
    T.eq(ProfileNames.canHaveLauncher(ClaudeProfile(folder: "Claude-a.b", name: "a.b", url: url)), false, "invalid name")
    let listed = [ClaudeProfile(folder: "Claude", name: "Default", url: url), ClaudeProfile(folder: "Claude-My-Work", name: "My-Work", url: url)]
    T.eq(ClaudeProfiles.find(name: "default", in: listed)?.folder, "Claude", "find the default profile")
    T.eq(ClaudeProfiles.find(name: "my work", in: listed)?.folder, "Claude-My-Work", "find through the folder name")
    T.eq(ClaudeProfiles.find(name: "other", in: listed), nil, "find nothing")

    T.eq(ProcessArgs.userDataDir(["/x/Claude", "--user-data-dir=/h/Library/Application Support/Claude-Max"]),
         "/h/Library/Application Support/Claude-Max", "flag with spaces")
    T.eq(ProcessArgs.userDataDir(["/x/Claude"]), nil, "no flag")

    var raw = Data([3, 0, 0, 0])
    for part in ["/x/Claude\0\0\0", "/x/Claude\0", "--a=1\0", "--user-data-dir=/h/C\0", "KEY=VALUE\0"] {
        raw.append(contentsOf: Array(part.utf8))
    }
    T.eq(ProcessArgs.parse(raw), ["/x/Claude", "--a=1", "--user-data-dir=/h/C"], "procargs layout, environment excluded")
    T.eq(ProcessArgs.parse(Data([9, 0])), [], "short buffer")
}

func testProfileScan() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ai-meter-profiles-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    for name in ["Claude", "Claude-Max", "Claude-Alpha", "Claude Code", "Other"] {
        try? fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try? Data().write(to: root.appendingPathComponent("Claude-File"))
    try? fm.createSymbolicLink(at: root.appendingPathComponent("Claude-Link"),
                               withDestinationURL: root.appendingPathComponent("Claude-Max"))
    T.eq(ClaudeProfiles.scan(root: root).map(\.name), ["Default", "Alpha", "Max"], "directories only, Default first")
    T.eq(ClaudeProfiles.scan(root: root.appendingPathComponent("none")).count, 0, "missing root")

    let usageFile = root.appendingPathComponent("Claude-Max/plan-usage-history.json")
    try? Data(#"{"samples":[{"t":60000,"u":{"fh":10,"sd":20}}]}"#.utf8).write(to: usageFile)
    let profiles = ClaudeProfiles.scan(root: root)
    let cache = ClaudeUsageCache()
    let max = profiles.first { $0.name == "Max" }!
    if case .reading(let r) = cache.read(profile: max) { T.eq(r.weekUsed, 20, "reads usage file") } else { T.expect(false, "usage readable") }
    T.eq(cache.read(profile: profiles[0]), .noData, "no usage file means no data yet")
    try? Data(count: SafeFile.maxConfigBytes + 1).write(to: usageFile)
    T.eq(cache.read(profile: max), .unreadable, "oversized file refused")
}

func testProfileRowModel() {
    let now = Date(timeIntervalSince1970: 100_000)
    func model(_ usage: ClaudeUsageResult, running: Bool, left: Bool = true) -> ProfileRowModel {
        ProfileRowModel.make(name: "Max", usage: usage, running: running, showLeft: left, now: now)
    }
    let fresh = ClaudeUsageReading(date: now.addingTimeInterval(-720), fiveHourUsed: 38, weekUsed: 43)
    var m = model(.reading(fresh), running: true)
    T.eq(m.status, "Running · 12m ago", "running status")
    T.eq(m.fiveHour.text, "62%", "five hour text")
    T.eq(m.week.text, "57%", "week text")
    T.eq(m.action, .bringToFront, "running brings to front")
    T.eq(m.fiveHour.fraction, 0.62, "meter fraction follows left")

    m = model(.reading(fresh), running: true, left: false)
    T.eq(m.fiveHour.text, "38%", "used text")
    T.eq(m.fiveHour.fraction, 0.38, "meter fraction follows used")

    let old = ClaudeUsageReading(date: now.addingTimeInterval(-3 * 3600), fiveHourUsed: 60, weekUsed: 29)
    m = model(.reading(old), running: false)
    T.eq(m.status, "Closed · 3h ago", "closed status")
    T.eq(m.fiveHour.text, "~40%", "stale five hour")
    T.eq(m.fiveHour.isStale, true, "stale flag")
    T.eq(m.week.text, "71%", "week still fresh")
    T.eq(m.action, .open, "closed opens")

    let lapsed = ClaudeUsageReading(date: now.addingTimeInterval(-6 * 3600), fiveHourUsed: 91, weekUsed: 80)
    m = model(.reading(lapsed), running: false)
    T.eq(m.fiveHour.text, "—", "expired five hour")
    T.eq(m.fiveHour.fraction, 0, "expired meter empty")
    T.eq(m.week.level, .low, "week level from left")

    T.eq(model(.noData, running: true).status, "No usage yet", "no data status")
    T.eq(model(.unreadable, running: false).status, "Usage unavailable", "format change status")
    T.eq(ProfileRowModel.menuBarValue(fiveHour: m.fiveHour, week: m.week), "20%", "menu bar falls back to week")
    T.eq(ProfileRowModel.menuBarValue(fiveHour: model(.reading(fresh), running: true).fiveHour,
                                      week: model(.reading(fresh), running: true).week), "62%", "menu bar prefers five hour")
}

func testProfileSelection() {
    let reading = { (seconds: Double) in ClaudeUsageResult.reading(ClaudeUsageReading(date: Date(timeIntervalSince1970: seconds), fiveHourUsed: 1, weekUsed: 1)) }
    let a = AISnapshot.Profile(folder: "a", name: "A", usage: reading(100), isRunning: false)
    let b = AISnapshot.Profile(folder: "b", name: "B", usage: reading(50), isRunning: true)
    let c = AISnapshot.Profile(folder: "c", name: "C", usage: .noData, isRunning: true)
    T.eq(AISnapshot.active([a, b, c])?.name, "B", "running profile with data wins")
    T.eq(AISnapshot.active([a, c])?.name, "A", "falls back to newest data")
    T.eq(AISnapshot.active([c]), nil, "no data at all")

    let now = Date(timeIntervalSince1970: 10_000)
    let soon = CodexReading(primary: CodexWindow(usedPercent: 18, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600)),
                            secondary: CodexWindow(usedPercent: 41, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400)))
    var row = CodexRowModel.make(soon, showLeft: true, now: now)
    T.eq(row.detail, "Resets 1h", "codex reset countdown")
    T.eq(row.fiveHour.text, "82%", "codex short window left")
    T.eq(row.week.text, "59%", "codex long window left")
    let weeklyFirst = CodexReading(primary: CodexWindow(usedPercent: 41, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
                                   secondary: CodexWindow(usedPercent: 18, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600)),
                                   date: now.addingTimeInterval(-720))
    row = CodexRowModel.make(weeklyFirst, showLeft: true, now: now)
    T.eq(row.fiveHour.text, "82%", "window length decides the 5 hour column")
    T.eq(row.week.text, "59%", "window length decides the week column")
    T.eq(row.detail, "Resets 1h · 12m ago", "codex shows its age")
    let unknownLength = CodexReading(primary: CodexWindow(usedPercent: 18, windowMinutes: nil, resetsAt: nil), secondary: nil)
    T.eq(CodexRowModel.make(unknownLength, showLeft: true, now: now).fiveHour.text, "82%", "no length falls back to position")
    T.eq(CodexRowModel.make(unknownLength, showLeft: true, now: now).detail, "Current account", "no reset and no age")
    let passed = CodexReading(primary: CodexWindow(usedPercent: 90, windowMinutes: 300, resetsAt: now.addingTimeInterval(-5)), secondary: nil)
    row = CodexRowModel.make(passed, showLeft: true, now: now)
    T.eq(row.detail, "Reset", "codex reset passed")
    T.eq(row.fiveHour.text, "100%", "passed window counts as unused")
    T.eq(row.week.text, "—", "missing window shows a dash")
}

func testProfileCreate() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ai-meter-create-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    do {
        let profile = try ClaudeProfiles.create(name: " My Work ", root: root)
        T.eq(profile.folder, "Claude-My-Work", "folder follows the name")
        T.eq(profile.name, "My Work", "name trimmed")
        let mode = (try fm.attributesOfItem(atPath: profile.url.path))[.posixPermissions] as? Int
        T.eq(mode, 0o700, "folder is private to the user")
    } catch {
        T.expect(false, "profile folder created: \(error)")
    }
    do {
        _ = try ClaudeProfiles.create(name: "My Work", root: root)
        T.expect(false, "existing folder must refuse")
    } catch {
        T.eq(error as? ProfileCreateError, .exists, "existing folder refused")
    }
    do {
        _ = try ClaudeProfiles.create(name: "../evil", root: root)
        T.expect(false, "path escape must refuse")
    } catch {
        T.eq(error as? ProfileCreateError, .invalidName, "path escape refused")
    }
}

func testLauncher() {
    let script = ClaudeLauncher.script(folder: "Claude-My-Work")
    T.expect(script.contains("/usr/bin/open -n -a"), "script opens a new instance")
    T.expect(script.contains("--args"), "script passes arguments")
    T.expect(script.contains("Library/Application Support/Claude-My-Work"), "script names the folder")

    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("ai-meter-launcher-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    do {
        let app = try ClaudeLauncher.build(name: "QA Test", into: dir)
        T.eq(app.lastPathComponent, "Claude - QA Test.app", "launcher name")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        T.eq(info?["LSUIElement"] as? Bool, true, "launcher has no Dock icon")
        T.eq(info?["CFBundleIdentifier"] as? String, "com.davidwidagdo.aimeterbar.launcher.qa-test", "launcher bundle id")
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", app.path]
        verify.standardError = FileHandle.nullDevice
        try verify.run()
        verify.waitUntilExit()
        T.eq(verify.terminationStatus, 0, "launcher signature verifies")
        T.eq(fm.contentsOfDirectory(atPath: dir.path, default: []).count, 1, "no temporary files left")
        do {
            _ = try ClaudeLauncher.build(name: "QA Test", into: dir)
            T.expect(false, "second build must refuse")
        } catch {
            T.eq(error as? LauncherError, .exists, "existing launcher is never replaced")
        }
    } catch {
        T.expect(false, "launcher builds: \(error)")
    }
}

private extension FileManager {
    func contentsOfDirectory(atPath path: String, default fallback: [String]) -> [String] {
        (try? contentsOfDirectory(atPath: path)) ?? fallback
    }
}
