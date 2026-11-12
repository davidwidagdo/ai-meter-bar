import Cocoa

enum PortalState {
    // needsSettings: a retry cannot help until the password or Login URL changes.
    // needsSetup: a login page showed up while no sign-in details are saved.
    case connected, idle, working, needsLogin, needsSettings, needsSetup
}

protocol StatusPopoverDelegate: AnyObject {
    func popoverDidOpen()
    func popoverDidClose()
    func popoverRefresh()
    func popoverSignIn()
    func popoverOpenSettings(tab: SettingsTab?)
    func popoverSetUpPortal()
    func popoverOpenUsageHistory()
    func popoverNewProfile()
    func popoverOpenProfile(folder: String)
    func popoverShowSessions()
    func popoverVPNAction(id: String)
}

// Owns the status item, its image and the popover; AppDelegate keeps the login cycle.
final class StatusPopoverController: NSObject, NSPopoverDelegate {
    weak var delegate: StatusPopoverDelegate?
    private(set) var isOpen = false
    // Read when shown, so a connection's age is current each time the panel opens.
    var vpnRows: () -> [VPNPanelRow] = { [] }

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let content = PopoverContentView()
    private let scroll = OverlayScrollView(frame: NSRect(x: 0, y: 0, width: PopoverContentView.width, height: 400))
    private static let screenMargin: CGFloat = 40

    private(set) var portalState = PortalState.idle
    private var statusText = "Checking…"
    private var lastLogin: Date?
    private var latestDown: Double = 0
    private var latestUp: Double = 0
    private var latestSystem: SystemMonitor.Sample?
    private var snapshot = AISnapshot()
    private var lastRenderKey: String?
    private var refreshing = false
    private var vpnUp: [String] = []

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.setAccessibilityLabel("AI Meter Bar")
        wireContent()
        renderMenuBar()

        // The cached image is drawn at this display's scale, so a monitor change must force a redraw.
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func wireContent() {
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = content
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.widthAnchor.constraint(equalToConstant: PopoverContentView.width),
        ])
        let holder = NSViewController()
        holder.view = scroll
        popover.contentViewController = holder
        popover.behavior = .transient
        popover.delegate = self

        content.onRefresh = { [weak self] in self?.delegate?.popoverRefresh() }
        content.onSettings = { [weak self] tab in self?.closeThen { $0.popoverOpenSettings(tab: tab) } }
        content.onSetUp = { [weak self] in self?.closeThen { $0.popoverSetUpPortal() } }
        content.onOpenApp = { [weak self] bundleID in
            self?.popover.performClose(nil)
            Self.openApp(bundleID: bundleID)
        }
        content.onUsageHistory = { [weak self] in self?.closeThen { $0.popoverOpenUsageHistory() } }
        content.onNewProfile = { [weak self] in self?.closeThen { $0.popoverNewProfile() } }
        content.onSignIn = { [weak self] in self?.delegate?.popoverSignIn() }
        content.onOpenProfile = { [weak self] folder in self?.closeThen { $0.popoverOpenProfile(folder: folder) } }
        content.onShowSessions = { [weak self] in self?.delegate?.popoverShowSessions() }
        content.onVPNAction = { [weak self] id in self?.delegate?.popoverVPNAction(id: id) }
        content.onHeightChange = { [weak self] in self?.resizePopover() }
        content.onActivityMonitor = { Self.openActivityMonitor() }
    }

    private func closeThen(_ action: (StatusPopoverDelegate) -> Void) {
        popover.performClose(nil)
        if let delegate = delegate { action(delegate) }
    }

    private static func openActivityMonitor() {
        openApp(bundleID: "com.apple.ActivityMonitor")
    }

    private static func openApp(bundleID: String) {
        guard !AppMode.isDemo, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    @objc private func screenParametersChanged() {
        lastRenderKey = nil
        renderMenuBar()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        isOpen = true
        delegate?.popoverDidOpen()
        syncContent()
        if content.sessionsAreOpen { delegate?.popoverShowSessions() }
        resizePopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        isOpen = false
        // A hidden spinner must not keep animating.
        content.setRefreshing(false)
        delegate?.popoverDidClose()
    }

    private func resizePopover() {
        content.layoutSubtreeIfNeeded()
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let room = (screen?.visibleFrame.height ?? content.fittingSize.height) - Self.screenMargin
        popover.contentSize = NSSize(width: PopoverContentView.width, height: min(content.fittingSize.height, room))
    }

    // MARK: - Inputs from the app

    func setStatus(_ state: PortalState, _ text: String) {
        portalState = state
        statusText = text
        renderMenuBar()
        if isOpen { syncStatus() }
    }

    func setLastLogin(_ date: Date) {
        lastLogin = date
        if isOpen { syncStatus() }
    }

    func setSpeed(down: Double, up: Double) {
        latestDown = down
        latestUp = up
    }

    func setSystem(_ sample: SystemMonitor.Sample) {
        latestSystem = sample
    }

    func flushMeters() {
        renderMenuBar()
        if isOpen {
            syncSpeed()
            syncSystem()
        }
    }

    func setSnapshot(_ snapshot: AISnapshot) {
        self.snapshot = snapshot
        renderMenuBar()
        if isOpen { content.setSnapshot(snapshot, settings: .shared, now: Date()) }
    }

    func setRefreshing(_ refreshing: Bool) {
        self.refreshing = refreshing
        if isOpen { content.setRefreshing(refreshing) }
    }

    // Also feeds the menu bar shield, so it runs on every VPN event, open or not.
    func vpnChanged() {
        let rows = vpnRows()
        let up = rows.filter(\.model.isUp).map(\.name)
        if up != vpnUp {
            vpnUp = up
            renderMenuBar()
        }
        guard isOpen else { return }
        content.setVPN(rows)
        resizePopover()
    }

    func setSessions(_ sessions: [RecentSession]) {
        content.setSessions(sessions, binary: Settings.shared.useBinaryUnits, now: Date())
    }

    func settingsChanged() {
        lastRenderKey = nil
        renderMenuBar()
        if isOpen { syncContent() }
    }

    // MARK: - Popover content

    private func syncContent() {
        syncStatus()
        syncSpeed()
        syncSystem()
        content.setRefreshing(refreshing)
        content.setVPN(vpnRows())
        content.setSnapshot(snapshot, settings: .shared, now: Date())
    }

    private func syncStatus() {
        content.setStatus(portalState, text: statusText, lastLogin: lastLogin, autoLogin: Settings.shared.autoLoginEnabled)
    }

    private func syncSpeed() {
        let today = AppMode.isDemo ? DemoData.today : UsageStore.shared.today
        content.setSpeed(down: latestDown, up: latestUp, today: today, binary: Settings.shared.useBinaryUnits)
    }

    private func syncSystem() {
        guard let sample = latestSystem else { return }
        content.setSystem(cpu: SystemFormat.percent(sample.cpuBusy),
                          ram: SystemFormat.percent(sample.memory.usedFraction),
                          pressure: SystemFormat.pressureLabel(sample.memory.pressure))
    }

    // MARK: - Menu bar

    // The quotas the menu bar shows, always as left, for the low-quota notification.
    static func quotaWatches(_ snapshot: AISnapshot, settings: Settings, now: Date) -> [QuotaWatch] {
        var watches: [QuotaWatch] = []
        let visible = snapshot.profiles.filter { !settings.hiddenProfiles.contains($0.folder) }
        if let active = AISnapshot.active(visible) {
            let name = settings.alias(forFolder: active.folder) ?? active.name
            let model = ProfileRowModel.make(name: name, usage: active.usage, running: active.isRunning, showLeft: true, now: now)
            watches.append(QuotaWatch(key: "claude:\(active.folder):5h", title: "Claude \(name) 5-hour quota", cell: model.fiveHour))
            watches.append(QuotaWatch(key: "claude:\(active.folder):week", title: "Claude \(name) weekly quota", cell: model.week))
        }
        if settings.showCodex, let reading = snapshot.codex {
            let model = CodexRowModel.make(reading, showLeft: true, now: now)
            watches.append(QuotaWatch(key: "codex:5h", title: "Codex 5-hour quota", cell: model.fiveHour))
            watches.append(QuotaWatch(key: "codex:week", title: "Codex weekly quota", cell: model.week))
        }
        return watches
    }

    private func aiCells() -> (claude: (five: QuotaCell, week: QuotaCell)?, codex: QuotaCell?) {
        let settings = Settings.shared
        let now = Date()
        let visible = snapshot.profiles.filter { !settings.hiddenProfiles.contains($0.folder) }
        let claude = AISnapshot.active(visible).map { active -> (QuotaCell, QuotaCell) in
            let model = ProfileRowModel.make(name: active.name, usage: active.usage, running: active.isRunning, showLeft: true, now: now)
            return (model.fiveHour, model.week)
        }
        let codex = settings.showCodex ? snapshot.codex.map { reading -> QuotaCell in
            let model = CodexRowModel.make(reading, showLeft: true, now: now)
            return model.fiveHour.isUnknown ? model.week : model.fiveHour
        } : nil
        return (claude, codex)
    }

    private func renderState() -> MenuBarRenderer.State {
        switch portalState {
        case .working:    return .working
        case .needsLogin, .needsSettings, .needsSetup: return .needsLogin
        default: break
        }
        guard Settings.shared.menuBarMode.showsAI else { return .normal }
        let cells = aiCells()
        let shown = [cells.claude?.five, cells.claude?.week, cells.codex].compactMap { $0 }
        return shown.contains { !$0.isUnknown && $0.level == .critical } ? .lowQuota : .normal
    }

    private func meterColumns() -> [MenuBarRenderer.Column] {
        typealias Column = MenuBarRenderer.Column
        let settings = Settings.shared
        let mode = settings.menuBarMode
        var columns: [Column] = []
        if mode.showsSpeed {
            // Upload on top, download below, so each arrow points toward its own row.
            columns.append(Column(rows: [
                Column.Row(label: "", value: "↑ " + ByteFormatter.speed(latestUp, binary: settings.useBinaryUnits)),
                Column.Row(label: "", value: "↓ " + ByteFormatter.speed(latestDown, binary: settings.useBinaryUnits)),
            ], valueSample: settings.useBinaryUnits ? "↑ 999.9 KiB/s" : "↑ 999.9 KB/s"))
        }
        if mode.showsSystem {
            columns.append(Column(rows: [
                Column.Row(label: "CPU", value: SystemFormat.percent(latestSystem?.cpuBusy ?? 0)),
                Column.Row(label: "RAM", value: SystemFormat.percent(latestSystem?.memory.usedFraction ?? 0)),
            ], valueSample: "100%"))
        }
        if mode.showsAI {
            let cells = aiCells()
            let claude = cells.claude.map { ProfileRowModel.menuBarValue(fiveHour: $0.five, week: $0.week) } ?? "—"
            columns.append(Column(rows: [
                Column.Row(label: "", value: claude, mark: .claude),
                Column.Row(label: "", value: cells.codex?.text ?? "—", mark: .openAI),
            ], valueSample: "~100%"))
        }
        return columns
    }

    private func renderMenuBar() {
        guard let button = statusItem?.button else { return }
        let columns = meterColumns()
        let state = renderState()
        // Rebuilding the image is the costliest idle work, so skip it when nothing visible changed.
        let shield = !vpnUp.isEmpty
        let key = renderKey(state, columns) + (shield ? "\u{4}" : "")
        let tip = tooltip()
        if button.toolTip != tip { button.toolTip = tip }
        guard key != lastRenderKey else { return }
        lastRenderKey = key
        button.image = MenuBarRenderer.image(state: state, columns: columns, shield: shield)
        button.imagePosition = .imageOnly
    }

    private func renderKey(_ state: MenuBarRenderer.State, _ columns: [MenuBarRenderer.Column]) -> String {
        var key = state.symbol
        for column in columns {
            for row in column.rows {
                key += "\u{1}" + row.label + "\u{2}" + row.value
            }
            key += "\u{3}"
        }
        return key
    }

    private func tooltip() -> String {
        let binary = Settings.shared.useBinaryUnits
        let today = AppMode.isDemo ? DemoData.today : UsageStore.shared.today
        let status = "AI Meter Bar — \(statusText) · Today ↓ \(ByteFormatter.total(today.rx, binary: binary)) ↑ \(ByteFormatter.total(today.tx, binary: binary))"
        let settings = Settings.shared, now = Date()
        let visible = snapshot.profiles.filter { !settings.hiddenProfiles.contains($0.folder) }
        let profile = AISnapshot.active(visible).map { active in
            ProfileRowModel.make(name: settings.alias(forFolder: active.folder) ?? active.name, usage: active.usage, running: active.isRunning, showLeft: true, now: now)
        }
        let codex = settings.showCodex ? snapshot.codex.map { CodexRowModel.make($0, showLeft: true, now: now) } : nil
        let vpn = vpnUp.isEmpty ? [] : ["VPN: \(vpnUp.joined(separator: ", ")) connected"]
        return ([status] + vpn + AITooltip.lines(profile: profile, codex: codex)).joined(separator: "\n")
    }
}

// The panel has no room for a 15 pt legacy scroller; it would cover the action column.
private final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}
