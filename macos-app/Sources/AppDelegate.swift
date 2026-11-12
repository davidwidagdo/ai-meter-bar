import Cocoa
import Network
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = PortalClient()
    private lazy var signIn = SignInCycle(portal: client)
    private var settingsWC: SettingsWindowController?
    private var usageHistoryWC: UsageHistoryWindowController?

    private var newProfileWC: NewProfileWindowController?

    private let statusController = StatusPopoverController()
    private let vpn = VPNController()
    private let notifier = Notifier()
    private let usageCoordinator = AIUsageCoordinator()
    private var usageTimer: Timer?
    private static let usageRefreshInterval: TimeInterval = 60
    private let speedMonitor = SpeedMonitor()
    private let systemMonitor = SystemMonitor()
    private lazy var meterClock = MeterClock { [weak self] tick in self?.meterTick(tick) }
    private var displayAsleep = false

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.davidwidagdo.aimeterbar.path")
    private var lastSignature: NetworkSignature?
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
        usageCoordinator.onUpdate = { [weak self] snapshot in
            self?.statusController.setSnapshot(snapshot)
            self?.notifier.quotas(StatusPopoverController.quotaWatches(snapshot, settings: .shared, now: Date()))
        }
        usageCoordinator.onBusyChange = { [weak self] busy in self?.statusController.setRefreshing(busy) }
        statusController.vpnRows = { [weak self] in self?.vpn.rows(now: Date()) ?? [] }
        vpn.onChange = { [weak self] in self?.statusController.vpnChanged() }
        vpn.onDropped = { [weak self] service in
            // A VPN hidden from the panel stays quiet here too.
            guard !Settings.shared.hiddenVPNs.contains(service.id) else { return }
            self?.notifier.vpnDropped(name: service.name)
        }
        vpn.refresh()
        if AppMode.isDemo {
            showDemoData()
            return
        }
        Log.write("App started.")
        setUpMeters()
        notifier.start()
        signIn.onStatus = { [weak self] state, text in
            self?.statusController.setStatus(state, text)
            self?.notifier.portal(state, text: text)
        }
        signIn.onLoggedIn = { [weak self] date in self?.statusController.setLastLogin(date) }
        signIn.dismissPopup = { Self.dismissCaptivePopup() }
        signIn.start()
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
    private var showsSystem: Bool {
        statusController.isOpen || Settings.shared.menuBarMode.showsSystem
    }

    private func restartMeters() {
        speedMonitor.prepare()
        systemMonitor.prepare()
        statusController.flushMeters()
        startMeterClock()
    }

    private func startMeterClock() {
        meterClock.start(interval: MeterSchedule.interval(setting: Settings.shared.updateInterval,
                                                          lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled))
    }

    private func meterTick(_ tick: Int) {
        speedMonitor.tick()
        // Speed keeps sampling with the screen off, so each day's bytes stay in that day.
        guard !displayAsleep else { return }
        if showsSystem { systemMonitor.tick() }
        statusController.flushMeters()
    }

    @objc private func powerStateChanged() {
        DispatchQueue.main.async { [weak self] in self?.startMeterClock() }
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
        // Posted on any thread when Low Power Mode turns on or off.
        NotificationCenter.default.addObserver(self, selector: #selector(powerStateChanged),
                                               name: .NSProcessInfoPowerStateDidChange, object: nil)
    }

    private func syncUsageTimer() {
        usageTimer?.invalidate()
        usageTimer = nil
        guard Settings.shared.menuBarMode.showsAI else { return }
        let t = Timer(timeInterval: Self.usageRefreshInterval, repeats: true) { [weak self] _ in
            guard let self = self, !self.signIn.systemAsleep else { return }
            self.usageCoordinator.refresh()
        }
        t.tolerance = Self.usageRefreshInterval * 0.1
        RunLoop.main.add(t, forMode: .common)
        usageTimer = t
    }

    private func handlePathUpdate(_ path: NWPath) {
        guard !signIn.systemAsleep else { return }
        let signature = client.networkSignature(for: path)
        guard signature != lastSignature else { return }
        lastSignature = signature
        signIn.networkChanged(router: signature.router)
    }

    @objc private func systemWillSleep() {
        signIn.sleep()
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
        if signIn.systemAsleep { wakeUp() }
        resumeDrawing()
    }

    private func wakeUp() {
        lastSignature = nil
        // Events can be missed in sleep, so every VPN's state is read again.
        vpn.refresh()
        signIn.wake()
    }

    private static func dismissCaptivePopup() {
        let popups = NSRunningApplication.runningApplications(withBundleIdentifier: captivePopupBundleID)
        guard !popups.isEmpty else { return }
        popups.forEach { if !$0.terminate() { $0.forceTerminate() } }
        Log.write("Closed the macOS captive-portal popup.")
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
        // Released on close, after the close itself has finished.
        usageHistoryWC?.onClose = { [weak self] in DispatchQueue.main.async { self?.usageHistoryWC = nil } }
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
        if signIn.systemAsleep { wakeUp() }
        usageCoordinator.refresh(live: true)
        vpn.refresh()
        if !Settings.shared.autoLoginEnabled { signIn.refreshStatus() }
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
        signIn.check()
    }

    func popoverSignIn() {
        guard !AppMode.isDemo else { return }
        Log.write("Manual login requested.")
        signIn.signIn()
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

    func popoverOpenSettings(tab: SettingsTab?) {
        openSettings(tab: tab, detect: false)
    }

    func popoverSetUpPortal() {
        openSettings(tab: .portal, detect: true)
    }

    private func openSettings(tab: SettingsTab?, detect: Bool) {
        if settingsWC == nil {
            settingsWC = SettingsWindowController()
        }
        settingsWC?.onClose = { [weak self] in DispatchQueue.main.async { self?.settingsWC = nil } }
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
        settingsWC?.runDetect = { [weak self] completion in
            guard !AppMode.isDemo else {
                completion(PortalDetection(outcome: .online))
                return
            }
            self?.client.detect(completion: completion)
        }
        settingsWC?.onNotifyEnabled = { [weak self] in self?.notifier.requestPermission() }
        settingsWC?.onSaveStarted = { [weak self] in self?.signIn.savingSettings = true }
        settingsWC?.onSave = { [weak self] in
            guard let self = self else { return }
            self.signIn.savingSettings = false
            guard !AppMode.isDemo else {
                self.vpn.refresh()
                self.statusController.settingsChanged()
                return
            }
            Log.write("Settings updated.")
            self.vpn.refresh()
            self.signIn.settingsSaved()
            self.restartMeters()
            self.syncUsageTimer()
            self.usageCoordinator.refresh()
            self.statusController.settingsChanged()
        }
        settingsWC?.present(tab: tab, detect: detect)
    }
}
