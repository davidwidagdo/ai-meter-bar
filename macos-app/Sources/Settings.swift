import Foundation

enum MenuBarMode: String, CaseIterable {
    case aiAndSpeed, speedAndSystem, aiOnly, speedOnly, iconOnly

    var title: String {
        switch self {
        case .aiAndSpeed:     return "AI quota and speed"
        case .speedAndSystem: return "Speed, CPU and RAM"
        case .aiOnly:         return "AI quota only"
        case .speedOnly:      return "Speed only"
        case .iconOnly:       return "Icon only"
        }
    }

    var showsSpeed: Bool { self == .aiAndSpeed || self == .speedAndSystem || self == .speedOnly }
    var showsSystem: Bool { self == .speedAndSystem }
    var showsAI: Bool { self == .aiAndSpeed || self == .aiOnly }
}

enum ProfileTint {
    static let all: [(name: String, hex: String)] = [
        ("Blue", "#0062CC"), ("Purple", "#6B3FD4"), ("Teal", "#0B7A75"),
        ("Orange", "#B3500A"), ("Pink", "#C2185B"), ("Graphite", "#5A5F6A"),
    ]

    static func fallback(forFolder folder: String) -> String {
        all[folder.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF } % all.count].hex
    }
}

// Non-secret values live in UserDefaults; the password lives in the Keychain.
final class Settings {
    static let shared = Settings()
    // Demo mode reads and writes its own domain, so a screenshot run cannot touch real preferences.
    private let defaults = AppMode.isDemo ? (UserDefaults(suiteName: "com.davidwidagdo.aimeterbar.demo") ?? .standard) : .standard

    private enum Key {
        static let loginURL = "loginURL"
        static let username = "username"
        static let pollInterval = "pollInterval"
        static let extraFields = "extraFields"
        static let portalMarker = "portalMarker"
        static let autoLogin = "autoLoginEnabled"
        static let showSpeedMeter = "showSpeedMeter"
        static let speedInterval = "speedInterval"
        static let useBinaryUnits = "useBinaryUnits"
        static let interfaceOverride = "wifiInterfaceOverride"
        static let showCPUMeter = "showCPUMeter"
        static let showRAMMeter = "showRAMMeter"
        static let systemInterval = "systemInterval"
        static let initialized = "didInitDefaults"
        static let menuBarMode = "menuBarMode"
        static let usageShowLeft = "usageShowLeft"
        static let showCodex = "showCodex"
        static let showAntigravity = "showAntigravity"
        static let profileAliases = "claudeProfileAliases"
        static let profileTints = "claudeProfileTints"
        static let hiddenProfiles = "hiddenClaudeProfiles"
    }

    private init() {
        guard !defaults.bool(forKey: Key.initialized) else { return }
        defaults.set("", forKey: Key.loginURL)
        defaults.set("", forKey: Key.username)
        defaults.set(15, forKey: Key.pollInterval)
        defaults.set("dst=\npopup=true", forKey: Key.extraFields)
        defaults.set("", forKey: Key.portalMarker)
        defaults.set(true, forKey: Key.autoLogin)
        defaults.set(true, forKey: Key.initialized)
    }

    var loginURL: String {
        get { defaults.string(forKey: Key.loginURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.loginURL) }
    }

    var username: String {
        get { defaults.string(forKey: Key.username) ?? "" }
        set { defaults.set(newValue, forKey: Key.username) }
    }

    var password: String {
        get { AppMode.isDemo ? "" : Keychain.password() }
        set { if !AppMode.isDemo { Keychain.setPassword(newValue) } }
    }

    var pollInterval: Int {
        get { max(5, defaults.integer(forKey: Key.pollInterval)) }
        set { defaults.set(max(5, newValue), forKey: Key.pollInterval) }
    }

    // One "name=value" per line; blank values (e.g. "dst=") are allowed.
    var extraFields: String {
        get { defaults.string(forKey: Key.extraFields) ?? "" }
        set { defaults.set(newValue, forKey: Key.extraFields) }
    }

    // Must appear on the portal page or its address; empty means any page with a login form.
    var portalMarker: String {
        get { defaults.string(forKey: Key.portalMarker) ?? "" }
        set { defaults.set(newValue, forKey: Key.portalMarker) }
    }

    var autoLoginEnabled: Bool {
        get { defaults.bool(forKey: Key.autoLogin) }
        set { defaults.set(newValue, forKey: Key.autoLogin) }
    }

    // Stored choice first; an upgrade keeps what the old speed, CPU and RAM toggles showed.
    var menuBarMode: MenuBarMode {
        get {
            if let raw = defaults.string(forKey: Key.menuBarMode), let mode = MenuBarMode(rawValue: raw) { return mode }
            let showed = { (key: String, fallback: Bool) in self.defaults.object(forKey: key) as? Bool ?? fallback }
            if showed(Key.showCPUMeter, false) || showed(Key.showRAMMeter, false) { return .speedAndSystem }
            return showed(Key.showSpeedMeter, true) ? .speedOnly : .iconOnly
        }
        set { defaults.set(newValue.rawValue, forKey: Key.menuBarMode) }
    }

    var usageShowLeft: Bool {
        get { defaults.object(forKey: Key.usageShowLeft) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.usageShowLeft) }
    }

    var showCodex: Bool {
        get { defaults.object(forKey: Key.showCodex) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showCodex) }
    }

    var showAntigravity: Bool {
        get { defaults.object(forKey: Key.showAntigravity) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showAntigravity) }
    }

    var hiddenProfiles: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.hiddenProfiles) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.hiddenProfiles) }
    }

    func alias(forFolder folder: String) -> String? {
        (defaults.dictionary(forKey: Key.profileAliases) as? [String: String])?[folder]
    }

    func setAlias(_ alias: String?, forFolder folder: String) {
        var all = defaults.dictionary(forKey: Key.profileAliases) as? [String: String] ?? [:]
        all[folder] = alias
        defaults.set(all, forKey: Key.profileAliases)
    }

    func tint(forFolder folder: String) -> String {
        (defaults.dictionary(forKey: Key.profileTints) as? [String: String])?[folder] ?? ProfileTint.fallback(forFolder: folder)
    }

    func setTint(_ hex: String, forFolder folder: String) {
        var all = defaults.dictionary(forKey: Key.profileTints) as? [String: String] ?? [:]
        all[folder] = hex
        defaults.set(all, forKey: Key.profileTints)
    }

    // The sampling periods offered for both meters, in seconds.
    static let intervalOptions = [1, 2, 5]

    // Seconds between speed samples.
    var speedInterval: Int {
        get {
            let v = defaults.object(forKey: Key.speedInterval) as? Int ?? 2
            return Settings.intervalOptions.contains(v) ? v : 2
        }
        set { defaults.set(newValue, forKey: Key.speedInterval) }
    }

    var useBinaryUnits: Bool {
        get { defaults.object(forKey: Key.useBinaryUnits) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.useBinaryUnits) }
    }

    // Empty means "auto" (use the Wi-Fi interface).
    var wifiInterfaceOverride: String {
        get { defaults.string(forKey: Key.interfaceOverride) ?? "" }
        set { defaults.set(newValue, forKey: Key.interfaceOverride) }
    }

    // Seconds between system samples. 1s reads as jittery at 9pt, so default to 2.
    var systemInterval: Int {
        get {
            let v = defaults.object(forKey: Key.systemInterval) as? Int ?? 2
            return Settings.intervalOptions.contains(v) ? v : 2
        }
        set { defaults.set(newValue, forKey: Key.systemInterval) }
    }
}
