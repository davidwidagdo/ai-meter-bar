import Cocoa
import Network
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = PortalClient()
    private var timer: Timer?
    private var settingsWC: SettingsWindowController?
    private var usageHistoryWC: UsageHistoryWindowController?

    private var newProfileWC: NewProfileWindowController?

    private let statusController = StatusPopoverController()
    private let vpn = VPNController()
    private let usageCoordinator = AIUsageCoordinator()
    private var usageTimer: Timer?
    private static let usageRefreshInterval: TimeInterval = 60
    private let speedMonitor = SpeedMonitor()
    private let systemMonitor = SystemMonitor()
    private lazy var meterClock = MeterClock { [weak self] tick in self?.meterTick(tick) }
    private var meterBase = 1
    private var displayAsleep = false

    private var isBusy = false
    private var pendingManual = false
    private var runningManual = false
    private var sawCaptivity = false
    private var lastRouter: String?
    // One pause per router, so moving between networks never clears the pause on the first one.
    private var throttles: [String: LoginThrottle] = [:]
    private var throttle: LoginThrottle {
        get { throttles[lastRouter ?? ""] ?? LoginThrottle() }
        set { throttles[lastRouter ?? ""] = newValue }
    }

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.davidwidagdo.aimeterbar.path")
    private var lastEventCheck = Date.distantPast
    private var lastSignature: NetworkSignature?
    private var systemAsleep = false

    // Portals often answer the first probes with a bare redirect or no reply; retry soon.
    private static let quickRetryDelay: TimeInterval = 3
    private static let quickRetryLimit = 4
    private var quickRetriesLeft = 0
    private static let captivePopupBundleID = "com.apple.CaptiveNetworkAssistant"

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !anotherInstanceIsRunning() else {
            Log.write("Another copy is already running; quitting this one.")
            NSApp.terminate(nil)
            return
        }
        installMainMenu()
        statusController.delegate = self
        statusController.install()
        usageCoordinator.onUpdate = { [weak self] snapshot in self?.statusController.setSnapshot(snapshot) }
        statusController.vpnRows = { [weak self] in self?.vpn.rows(now: Date()) ?? [] }
        vpn.onChange = { [weak self] in self?.statusController.vpnChanged() }
        vpn.refresh()
        if AppMode.isDemo {
            showDemoData()
            return
        }
        Log.write("App started.")
        setUpMeters()
        startMonitoring()
        startEventTriggers()
        usageCoordinator.refresh(live: true)
        syncUsageTimer()
    }

    // Two copies would both poll the portal and post credentials.
    private func anotherInstanceIsRunning() -> Bool {
        guard !AppMode.isDemo, let bundleID = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    private func showDemoData() {
        let now = Date()
        statusController.setStatus(.connected, "Connected")
        statusController.setLastLogin(now.addingTimeInterval(-3600))
        statusController.setSpeed(down: 4_200_000, up: 310_000)
        let memory = MemoryMath.Result(app: 0, wired: 0, compressed: 0, used: 11_000_000_000, cached: 0, free: 5_000_000_000,
                                       total: 16_000_000_000, usedFraction: 0.68, pressure: .normal)
        statusController.setSystem(SystemMonitor.Sample(cpuBusy: 0.12, memory: memory))
        statusController.setSnapshot(DemoData.snapshot(now: now))
        statusController.flushMeters()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !AppMode.isDemo else { return }
        UsageStore.shared.flush()
        Log.write("App quitting.")
    }

    // MARK: - Meters

    private func setUpMeters() {
        speedMonitor.onUpdate = { [weak self] sample in
            self?.statusController.setSpeed(down: sample.down, up: sample.up)
        }
        systemMonitor.onUpdate = { [weak self] sample in
            self?.statusController.setSystem(sample)
        }
        restartMeters()
    }

    // CPU and RAM are sampled only while something shows them.
    private var systemEvery: Int? {
        statusController.isOpen || Settings.shared.menuBarMode.showsSystem ? Settings.shared.systemInterval : nil
    }

    private func restartMeters() {
        speedMonitor.prepare()
        systemMonitor.prepare()
        statusController.flushMeters()
        startMeterClock()
    }

    private func startMeterClock() {
        meterBase = MeterSchedule.baseInterval(speed: Settings.shared.speedInterval, system: systemEvery)
        meterClock.start(interval: meterBase)
    }

    private func meterTick(_ tick: Int) {
        if MeterSchedule.isDue(tick: tick, every: Settings.shared.speedInterval, base: meterBase) {
            speedMonitor.tick()
        }
        // Speed keeps sampling with the screen off, so each day's bytes stay in that day.
        guard !displayAsleep else { return }
        if let every = systemEvery, MeterSchedule.isDue(tick: tick, every: every, base: meterBase) {
            systemMonitor.tick()
        }
        statusController.flushMeters()
    }

    private func resumeDrawing() {
        guard displayAsleep else { return }
        displayAsleep = false
        // A long gap makes the CPU delta meaningless.
        systemMonitor.prepare()
        statusController.flushMeters()
    }

    // MARK: - Event triggers

    private func startEventTriggers() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                if path.status == .satisfied {
                    self?.handlePathUpdate(path)
                } else {
                    // Rejoining the same router must count as a change.
                    self?.lastSignature = nil
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    private func syncUsageTimer() {
        usageTimer?.invalidate()
        usageTimer = nil
        guard Settings.shared.menuBarMode.showsAI else { return }
        let t = Timer(timeInterval: Self.usageRefreshInterval, repeats: true) { [weak self] _ in
            guard let self = self, !self.systemAsleep else { return }
            self.usageCoordinator.refresh()
        }
        t.tolerance = Self.usageRefreshInterval * 0.1
        RunLoop.main.add(t, forMode: .common)
        usageTimer = t
    }

    private func handlePathUpdate(_ path: NWPath) {
        guard !systemAsleep else { return }
        let signature = client.networkSignature(for: path)
        guard signature != lastSignature else { return }
        lastSignature = signature
        sawCaptivity = false
        if let router = signature.router { lastRouter = router }
        triggerCheck(reason: "network changed")
    }

    // Dark wakes run the app for seconds with no network, and no didWake ever marks them.
    @objc private func systemWillSleep() {
        systemAsleep = true
        pendingManual = false
        Log.write("System going to sleep.")
        displayAsleep = true
    }

    @objc private func systemDidWake() {
        wakeUp()
        resumeDrawing()
    }

    @objc private func screensDidSleep() {
        displayAsleep = true
    }

    // Also clears the sleep flag if didWake never arrived, so auto-login cannot stay stuck off.
    @objc private func screensDidWake() {
        if systemAsleep { wakeUp() }
        resumeDrawing()
    }

    private func wakeUp() {
        systemAsleep = false
        lastSignature = nil
        // Events can be missed in sleep, so every VPN's state is read again.
        vpn.refresh()
        triggerCheck(reason: "system woke")
    }

    private func triggerCheck(reason: String) {
        guard Settings.shared.autoLoginEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastEventCheck) > 2 else { return }
        lastEventCheck = now
        quickRetriesLeft = Self.quickRetryLimit
        Log.write("Trigger (\(reason)) — checking session.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.checkAndLogin()
        }
    }

    // MARK: - Main menu (Edit menu keeps copy/paste working in Settings)

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Login cycle

    private func startMonitoring() {
        timer?.invalidate()
        timer = nil
        checkAndLogin()
        guard Settings.shared.autoLoginEnabled else { return }
        let interval = TimeInterval(Settings.shared.pollInterval)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkAndLogin()
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func checkAndLogin() {
        guard !systemAsleep else { return }
        guard Settings.shared.autoLoginEnabled else {
            refreshStatus()
            return
        }
        runCycle(manual: false)
    }

    private func refreshStatus() {
        guard !isBusy else { return }
        client.checkConnectivity { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if state == .connected {
                    self.statusController.setStatus(.connected, "Connected")
                } else {
                    self.statusController.setStatus(.idle, "Offline (auto-login off)")
                }
            }
        }
    }

    private func runCycle(manual: Bool) {
        guard !isBusy else {
            // A click waits out an automatic check; a repeat click during a manual one is dropped.
            if manual, !runningManual { pendingManual = true }
            return
        }
        isBusy = true
        runningManual = manual
        if manual { throttle.reset() }
        client.checkConnectivity { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if state == .connected {
                    self.sessionIsLive()
                    return
                }
                self.client.inspectCaptivePage { [weak self] ours, page in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        // A failed probe alone is no portal; a page that answered in its place is.
                        if page != nil { self.sawCaptivity = true }
                        if ours, page?.isLoggedIn == true {
                            self.sessionIsLive()
                            return
                        }
                        guard ours, let page = page else {
                            self.statusController.setStatus(.idle, "No portal on this network")
                            let detail = page.map { "not our portal page (\(self.client.describe($0)))" }
                                ?? "no captive page (offline or still joining)"
                            Log.write(manual ? "Manual login: \(detail) — nothing to do." : "No internet, \(detail) — skipping.")
                            self.finishCycle()
                            self.scheduleQuickRetry()
                            return
                        }
                        guard self.throttle.allowsAttempt(now: Date()) else {
                            // A wrong password stays on screen; waiting alone cannot fix it.
                            if self.statusController.portalState != .needsSettings {
                                self.statusController.setStatus(.needsLogin, "Login paused after a rejection")
                            }
                            self.finishCycle()
                            return
                        }
                        // A cycle begun before sleep can finish in a dark wake, when no POST should go out.
                        guard manual || !self.systemAsleep else {
                            self.finishCycle()
                            return
                        }
                        self.quickRetriesLeft = 0
                        self.statusController.setStatus(.working, "Logging in…")
                        Log.write(manual ? "Manual login — submitting." : "Captive portal detected — logging in.")
                        self.performLogin(page: page)
                    }
                }
            }
        }
    }

    private func sessionIsLive() {
        statusController.setStatus(.connected, "Connected")
        quickRetriesLeft = 0
        throttle.reset()
        // The probe can pass over another link while Wi-Fi still waits on its portal popup.
        if sawCaptivity { dismissCaptivePopup() }
        finishCycle()
    }

    private func performLogin(page: CaptivePage) {
        // Started before the POST: a request lost to sleep must count as slept too.
        let wallStart = Date()
        let uptimeStart = ProcessInfo.processInfo.systemUptime
        client.login(page: page) { [weak self] submit in
            DispatchQueue.main.async {
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
        throttle.recordRejected(now: Date())
        statusController.setStatus(.needsSettings, status)
        finishCycle()
    }

    private func confirmLogin(wallStart: Date, uptimeStart: TimeInterval, sendFailed: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.client.confirmLogin { confirmed, portalStillAsking in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    let slept = LoginOutcome.slept(wallElapsed: Date().timeIntervalSince(wallStart),
                                                   uptimeElapsed: ProcessInfo.processInfo.systemUptime - uptimeStart)
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
            statusController.setStatus(.connected, "Connected")
            statusController.setLastLogin(Date())
            throttle.reset()
            Log.write("Login OK.")
            dismissCaptivePopup()
            finishCycle()
        case .rejected:
            throttle.recordRejected(now: Date())
            statusController.setStatus(.needsSettings, "Login failed")
            Log.write("Login FAILED — portal still asks for credentials.")
            finishCycle()
        case .unconfirmed:
            statusController.setStatus(.needsLogin, "Login unconfirmed, rechecking")
            Log.write("Login unconfirmed (slept: \(slept)) — rechecking.")
            // Rechecks continue, but only a nap excuses another POST: portals may not show a readable form.
            if !slept { throttle.recordRejected(now: Date()) }
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
        DispatchQueue.main.async { [weak self] in self?.runCycle(manual: true) }
    }

    private func scheduleQuickRetry() {
        guard quickRetriesLeft > 0 else { return }
        quickRetriesLeft -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quickRetryDelay) { [weak self] in
            self?.checkAndLogin()
        }
    }

    // Only called once the session is confirmed, when the macOS portal popup is stale.
    private func dismissCaptivePopup() {
        sawCaptivity = false
        let popups = NSRunningApplication.runningApplications(withBundleIdentifier: Self.captivePopupBundleID)
        guard !popups.isEmpty else { return }
        popups.forEach { if !$0.terminate() { $0.forceTerminate() } }
        Log.write("Closed the macOS captive-portal popup.")
    }

    // MARK: - Login Items

    private func setLoginItem(_ on: Bool) {
        guard !AppMode.isDemo else { return }
        do {
            if on, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
                Log.write("Added to Login Items.")
            } else if !on, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                Log.write("Removed from Login Items.")
            }
        } catch {
            Log.write("Login Item toggle failed: \(error.localizedDescription)")
        }
    }

    private func openUsageHistory() {
        guard !AppMode.isDemo else { return }
        if usageHistoryWC == nil { usageHistoryWC = UsageHistoryWindowController() }
        usageHistoryWC?.present()
    }

    private func openNewProfile() {
        if newProfileWC == nil { newProfileWC = NewProfileWindowController() }
        newProfileWC?.onProfilesChanged = { [weak self] in self?.profilesChanged() }
        newProfileWC?.onOpenExisting = { [weak self] name in
            let profiles = ClaudeProfiles.listed()
            let renamed = profiles.first { Settings.shared.alias(forFolder: $0.folder).map { ProfileNames.sameName($0, name) } ?? false }
            guard let profile = renamed ?? ClaudeProfiles.find(name: name, in: profiles) else { return }
            self?.popoverOpenProfile(folder: profile.folder)
        }
        newProfileWC?.present()
    }

    private func profilesChanged() {
        usageCoordinator.refresh()
        settingsWC?.refreshProfiles()
    }
}

// MARK: - StatusPopoverDelegate

extension AppDelegate: StatusPopoverDelegate {
    func popoverDidOpen() {
        guard !AppMode.isDemo else { return }
        // Someone clicking the menu bar proves the Mac is awake, whatever the sleep flag says.
        if systemAsleep { wakeUp() }
        usageCoordinator.refresh(live: true)
        vpn.refresh()
        if !Settings.shared.autoLoginEnabled { refreshStatus() }
        systemMonitor.tick()
        startMeterClock()
    }

    func popoverDidClose() {
        guard !AppMode.isDemo else { return }
        startMeterClock()
    }

    func popoverRefresh() {
        guard !AppMode.isDemo else { return }
        usageCoordinator.refresh(live: true)
        checkAndLogin()
    }

    func popoverSignIn() {
        guard !AppMode.isDemo else { return }
        Log.write("Manual login requested.")
        runCycle(manual: true)
    }

    func popoverVPNAction(id: String) {
        vpn.perform(id: id)
    }

    func popoverOpenUsageHistory() {
        openUsageHistory()
    }

    func popoverNewProfile() {
        openNewProfile()
    }

    func popoverOpenProfile(folder: String) {
        guard !AppMode.isDemo else { return }
        if let instance = ClaudeInstances.running().first(where: { $0.folder == folder }) {
            ClaudeInstances.bringToFront(instance)
            return
        }
        guard let profile = ClaudeProfiles.scan().first(where: { $0.folder == folder }) else { return }
        ClaudeInstances.open(profile: profile) { [weak self] error in
            if error != nil { Log.write("Claude could not be opened for a profile.") }
            self?.usageCoordinator.refresh()
        }
    }

    func popoverShowSessions() {
        guard !AppMode.isDemo else {
            statusController.setSessions(DemoData.sessions(now: Date()))
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sessions = LocalSessionScanner.recent()
            DispatchQueue.main.async { self?.statusController.setSessions(sessions) }
        }
    }

    func popoverOpenSettings() {
        if settingsWC == nil {
            settingsWC = SettingsWindowController()
        }
        settingsWC?.isLoginItemEnabled = { SMAppService.mainApp.status == .enabled }
        settingsWC?.setLoginItem = { [weak self] on in self?.setLoginItem(on) }
        settingsWC?.onNewProfile = { [weak self] in self?.openNewProfile() }
        settingsWC?.onProfilesChanged = { [weak self] in self?.usageCoordinator.refresh() }
        settingsWC?.onOpenUsageHistory = { [weak self] in self?.openUsageHistory() }
        settingsWC?.vpnServices = { [weak self] in self?.vpn.services ?? [] }
        settingsWC?.runDiagnostics = { [weak self] loginURL, marker, completion in
            guard !AppMode.isDemo else {
                completion(["Demo mode: the portal is not checked."])
                return
            }
            self?.client.diagnose(loginURL: loginURL, marker: marker, completion: completion)
        }
        settingsWC?.onSave = { [weak self] in
            guard let self = self else { return }
            guard !AppMode.isDemo else {
                self.vpn.refresh()
                self.statusController.settingsChanged()
                return
            }
            Log.write("Settings updated.")
            self.vpn.refresh()
            self.throttles.removeAll()
            self.startMonitoring()
            self.restartMeters()
            self.syncUsageTimer()
            self.usageCoordinator.refresh()
            self.statusController.settingsChanged()
        }
        settingsWC?.present()
    }
}
