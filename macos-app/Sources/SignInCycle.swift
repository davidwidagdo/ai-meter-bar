import Foundation

protocol PortalService: AnyObject {
    func checkConnectivity(completion: @escaping (ConnState) -> Void)
    func inspectCaptivePage(completion: @escaping (_ isOurPortal: Bool, _ page: CaptivePage?) -> Void)
    func login(page: CaptivePage, completion: @escaping (LoginSubmit) -> Void)
    func confirmLogin(completion: @escaping (_ confirmed: Bool, _ portalStillAsking: Bool) -> Void)
    func describe(_ page: CaptivePage) -> String
}

extension PortalClient: PortalService {}

enum PortalSchedule {
    static let options = [5, 10, 15, 30, 60]
    static let connectedInterval = 30

    // A live session is rechecked slowly; network changes and wakes still check at once.
    static func interval(setting: Int, connected: Bool) -> TimeInterval {
        TimeInterval(connected ? max(setting, connectedInterval) : setting)
    }
}

struct SignInConfig {
    var autoLogin: Bool
    var pollInterval: Int
    var hasUsername: Bool
    // A form can only post to the Login URL, or to the gateway once a marker is set.
    var hasDestination: Bool

    // Access-code portals have no username field, so only a form with one needs a username.
    func needsSetup(for page: CaptivePage) -> Bool {
        !hasDestination || (!hasUsername && page.form?.asksUsername == true)
    }

    static func current() -> SignInConfig {
        let s = Settings.shared
        let filled = { (text: String) in !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return SignInConfig(autoLogin: s.autoLoginEnabled, pollInterval: s.pollInterval, hasUsername: filled(s.username),
                            hasDestination: filled(s.loginURL) || filled(s.portalMarker))
    }
}

// Time, threads and the log come in from outside, so tests drive the cycle with a fake portal.
struct SignInEnvironment {
    var now: () -> Date = Date.init
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var main: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    var every: (TimeInterval, @escaping () -> Void) -> () -> Void = { interval, work in
        let timer = Timer(timeInterval: interval, repeats: true) { _ in work() }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
    var log: (String) -> Void = Log.write
}

// Checks the session and signs in to the Wi-Fi portal; the app only forwards events to it.
final class SignInCycle {
    var onStatus: ((PortalState, String) -> Void)?
    var onLoggedIn: ((Date) -> Void)?
    // Only called once the session is confirmed, when the macOS portal popup is stale.
    var dismissPopup: (() -> Void)?

    private(set) var state = PortalState.idle
    private(set) var pollInterval: TimeInterval?
    private(set) var systemAsleep = false
    var savingSettings = false

    private let portal: PortalService
    private let env: SignInEnvironment
    private let config: () -> SignInConfig

    private var stopPolling: (() -> Void)?
    private var pollsConnected: Bool?
    private var isBusy = false
    private var pendingManual = false
    private var runningManual = false
    private var sawCaptivity = false
    private var lastRouter: String?
    private var lastEventCheck = Date.distantPast
    // One pause per router, so moving between networks never clears the pause on the first one.
    private var throttles: [String: LoginThrottle] = [:]
    private var throttle: LoginThrottle {
        get { throttles[lastRouter ?? ""] ?? LoginThrottle() }
        set { throttles[lastRouter ?? ""] = newValue }
    }

    // Portals often answer the first probes with a bare redirect or no reply; retry soon.
    private static let quickRetryDelay: TimeInterval = 3
    private static let quickRetryLimit = 4
    private static let confirmDelay: TimeInterval = 2
    private var quickRetriesLeft = 0

    init(portal: PortalService, env: SignInEnvironment = SignInEnvironment(), config: @escaping () -> SignInConfig = SignInConfig.current) {
        self.portal = portal
        self.env = env
        self.config = config
    }

    // MARK: - Events from the app

    func start() {
        stopPolling?()
        stopPolling = nil
        pollsConnected = nil
        pollInterval = nil
        check()
        syncPolling()
    }

    func settingsSaved() {
        throttles.removeAll()
        start()
    }

    func networkChanged(router: String?) {
        sawCaptivity = false
        if let router = router { lastRouter = router }
        trigger(reason: "network changed")
    }

    // Dark wakes run the app for seconds with no network, and no didWake ever marks them.
    func sleep() {
        systemAsleep = true
        pendingManual = false
    }

    func wake() {
        systemAsleep = false
        trigger(reason: "system woke")
    }

    func signIn() {
        runCycle(manual: true)
    }

    func check() {
        guard !systemAsleep, !savingSettings else { return }
        guard config().autoLogin else {
            refreshStatus()
            return
        }
        runCycle(manual: false)
    }

    func refreshStatus() {
        guard !isBusy else { return }
        portal.checkConnectivity { [weak self] state in
            self?.env.main {
                guard let self = self else { return }
                if state == .connected {
                    self.setStatus(.connected, "Connected")
                } else {
                    self.setStatus(.idle, "Offline (auto-login off)")
                }
            }
        }
    }

    private func trigger(reason: String) {
        guard config().autoLogin else { return }
        let now = env.now()
        guard now.timeIntervalSince(lastEventCheck) > 2 else { return }
        lastEventCheck = now
        quickRetriesLeft = Self.quickRetryLimit
        env.log("Trigger (\(reason)) — checking session.")
        env.after(0.4) { [weak self] in self?.check() }
    }

    // MARK: - Status and polling

    private func setStatus(_ next: PortalState, _ text: String) {
        state = next
        onStatus?(next, text)
        syncPolling()
    }

    // Restarted only when the pace changes, so a steady state keeps one timer.
    private func syncPolling() {
        let settings = config()
        guard settings.autoLogin else {
            stopPolling?()
            stopPolling = nil
            pollsConnected = nil
            pollInterval = nil
            return
        }
        let connected = state == .connected
        guard stopPolling == nil || pollsConnected != connected else { return }
        stopPolling?()
        let interval = PortalSchedule.interval(setting: settings.pollInterval, connected: connected)
        pollsConnected = connected
        pollInterval = interval
        stopPolling = env.every(interval) { [weak self] in self?.check() }
    }

    // MARK: - The cycle

    private func runCycle(manual: Bool) {
        guard !isBusy else {
            // A click waits out an automatic check; a repeat click during a manual one is dropped.
            if manual, !runningManual { pendingManual = true }
            return
        }
        isBusy = true
        runningManual = manual
        if manual { throttle.reset() }
        portal.checkConnectivity { [weak self] state in
            self?.env.main {
                guard let self = self else { return }
                if state == .connected {
                    self.sessionIsLive()
                    return
                }
                self.portal.inspectCaptivePage { [weak self] ours, page in
                    self?.env.main { self?.handlePage(ours: ours, page: page, manual: manual) }
                }
            }
        }
    }

    private func handlePage(ours: Bool, page: CaptivePage?, manual: Bool) {
        // A failed probe alone is no portal; a page that answered in its place is.
        if page != nil { sawCaptivity = true }
        if ours, page?.isLoggedIn == true {
            sessionIsLive()
            return
        }
        guard ours, let page = page else {
            setStatus(.idle, "No portal on this network")
            let detail = page.map { "not our portal page (\(portal.describe($0)))" } ?? "no captive page (offline or still joining)"
            env.log(manual ? "Manual login: \(detail) — nothing to do." : "No internet, \(detail) — skipping.")
            finishCycle()
            scheduleQuickRetry()
            return
        }
        // A page that came over a VPN or another link is not this Wi-Fi's portal.
        guard page.overWiFi != false else {
            setStatus(.idle, "Portal page is not on Wi-Fi")
            env.log("Portal page did not arrive over Wi-Fi; nothing sent.")
            finishCycle()
            return
        }
        // Nothing saved yet: the page is offered for setup and no password is looked up.
        guard !config().needsSetup(for: page) else {
            if state != .needsSetup { env.log("Login page found, but no sign-in details are saved; nothing sent.") }
            setStatus(.needsSetup, "Not signed in")
            finishCycle()
            return
        }
        guard throttle.allowsAttempt(now: env.now()) else {
            // A wrong password stays on screen; waiting alone cannot fix it.
            if state != .needsSettings { setStatus(.needsLogin, "Login paused after a rejection") }
            finishCycle()
            return
        }
        // A cycle begun before sleep can finish in a dark wake, when no POST should go out.
        guard manual || !systemAsleep else {
            finishCycle()
            return
        }
        quickRetriesLeft = 0
        setStatus(.working, "Logging in…")
        env.log(manual ? "Manual login — submitting." : "Captive portal detected — logging in.")
        performLogin(page: page)
    }

    private func sessionIsLive() {
        setStatus(.connected, "Connected")
        quickRetriesLeft = 0
        throttle.reset()
        // The probe can pass over another link while Wi-Fi still waits on its portal popup.
        if sawCaptivity { closePopup() }
        finishCycle()
    }

    private func performLogin(page: CaptivePage) {
        // Started before the POST: a request lost to sleep must count as slept too.
        let wallStart = env.now()
        let uptimeStart = env.uptime()
        portal.login(page: page) { [weak self] submit in
            self?.env.main {
                guard let self = self else { return }
                switch submit {
                case .sent, .failed:
                    self.confirmLogin(wallStart: wallStart, uptimeStart: uptimeStart, sendFailed: submit == .failed)
                case .refused:
                    self.loginBlocked("Login refused")
                case .noPassword:
                    self.loginBlocked("No password saved")
                }
            }
        }
    }

    private func loginBlocked(_ status: String) {
        throttle.recordRejected(now: env.now())
        setStatus(.needsSettings, status)
        finishCycle()
    }

    private func confirmLogin(wallStart: Date, uptimeStart: TimeInterval, sendFailed: Bool) {
        env.after(Self.confirmDelay) { [weak self] in
            self?.portal.confirmLogin { confirmed, portalStillAsking in
                self?.env.main {
                    guard let self = self else { return }
                    let slept = LoginOutcome.slept(wallElapsed: self.env.now().timeIntervalSince(wallStart),
                                                   uptimeElapsed: self.env.uptime() - uptimeStart)
                    // A portal cannot have rejected credentials it never received.
                    let verdict = LoginOutcome.verdict(slept: slept || sendFailed, confirmed: confirmed, portalStillAsking: portalStillAsking)
                    self.finishLogin(verdict, slept: slept)
                }
            }
        }
    }

    private func finishLogin(_ verdict: LoginVerdict, slept: Bool) {
        switch verdict {
        case .loggedIn:
            setStatus(.connected, "Connected")
            onLoggedIn?(env.now())
            throttle.reset()
            env.log("Login OK.")
            closePopup()
            finishCycle()
        case .rejected:
            throttle.recordRejected(now: env.now())
            setStatus(.needsSettings, "Login failed")
            env.log("Login FAILED — portal still asks for credentials.")
            finishCycle()
        case .unconfirmed:
            setStatus(.needsLogin, "Login unconfirmed, rechecking")
            env.log("Login unconfirmed (slept: \(slept)) — rechecking.")
            // Rechecks continue, but only a nap excuses another POST: portals may not show a readable form.
            if !slept { throttle.recordRejected(now: env.now()) }
            finishCycle()
            quickRetriesLeft = Self.quickRetryLimit
            scheduleQuickRetry()
        }
    }

    private func finishCycle() {
        isBusy = false
        runningManual = false
        guard pendingManual, !systemAsleep else { return }
        pendingManual = false
        env.main { [weak self] in self?.runCycle(manual: true) }
    }

    private func scheduleQuickRetry() {
        guard quickRetriesLeft > 0 else { return }
        quickRetriesLeft -= 1
        env.after(Self.quickRetryDelay) { [weak self] in self?.check() }
    }

    private func closePopup() {
        sawCaptivity = false
        dismissPopup?()
    }
}
