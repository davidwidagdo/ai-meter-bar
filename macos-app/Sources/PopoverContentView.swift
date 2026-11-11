import Cocoa

final class ProfileRowView: NSStackView {
    let folder: String
    private let tile: TileView
    private let name = UI.label("", weight: .semibold)
    private let status = UI.label("", size: 11.5, color: .secondaryLabelColor)
    private let dot = StatusDot(filled: false)
    private let five = QuotaColumn(), week = QuotaColumn()
    private let action: ClosureButton

    init(folder: String, model: ProfileRowModel, letter: String, hex: String, showLeft: Bool, onAction: @escaping () -> Void) {
        self.folder = folder
        tile = TileView(letter: letter, hex: hex)
        action = ClosureButton(symbol: "play", label: "", onClick: onAction)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        distribution = .fill
        spacing = 10
        edgeInsets = UI.insets()
        UI.fix(self, height: UI.rowHeight)
        status.lineBreakMode = .byTruncatingTail
        let names = UI.column([name, UI.row([dot, status], spacing: 5)], spacing: 1)
        UI.flexible(names)
        for view in [tile, names, five, week, action] as [NSView] {
            addArrangedSubview(view)
        }
        update(model: model, letter: letter, hex: hex, showLeft: showLeft)
    }

    required init?(coder: NSCoder) { nil }

    // In place, so a refresh neither flickers nor takes keyboard focus off the row's button.
    func update(model: ProfileRowModel, letter: String, hex: String, showLeft: Bool) {
        tile.set(letter: letter, hex: hex)
        name.stringValue = model.name
        name.toolTip = model.name
        status.stringValue = model.status
        status.toolTip = model.sameAccountAs.map { "Same account as \($0)" }
        dot.filled = model.isRunning
        five.set(model.fiveHour, spoken: QuotaColumn.spoken(owner: model.name, window: "5 hour", cell: model.fiveHour, showLeft: showLeft))
        week.set(model.week, spoken: QuotaColumn.spoken(owner: model.name, window: "weekly", cell: model.week, showLeft: showLeft))
        let running = model.action == .bringToFront
        let label = running ? "Bring \(model.name) to front" : "Open \(model.name)"
        action.image = UI.symbol(running ? "arrow.up.forward" : "play", description: label)
        action.toolTip = label
        action.setAccessibilityLabel(label)
    }
}

// The button shows the action and the line under the name shows the state.
final class VPNRowView: NSStackView {
    let id: String
    private let name = UI.label("", weight: .semibold)
    private let status = UI.label("", size: 11.5, color: .secondaryLabelColor)
    private let dot = StatusDot(filled: false)
    private let button = ClosureButton(symbol: "play", label: "")

    init(_ row: VPNPanelRow, onAction: @escaping (String) -> Void) {
        id = row.id
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        distribution = .fill
        spacing = 10
        edgeInsets = UI.insets()
        UI.fix(self, height: UI.rowHeight)
        name.lineBreakMode = .byTruncatingTail
        status.lineBreakMode = .byTruncatingTail
        let names = UI.column([name, UI.row([dot, status], spacing: 5)], spacing: 1)
        UI.flexible(names)
        let id = row.id
        button.onClick = { onAction(id) }
        for view in [TileView(symbol: "lock.shield", hex: ProfileTint.graphite), names, button] as [NSView] {
            addArrangedSubview(view)
        }
        update(row)
    }

    required init?(coder: NSCoder) { nil }

    func update(_ row: VPNPanelRow) {
        name.stringValue = row.name
        name.toolTip = row.name
        status.stringValue = row.model.detail
        status.textColor = row.model.warns ? UI.warn : .secondaryLabelColor
        dot.filled = row.model.isUp
        let symbol: String, label: String
        switch row.model.action {
        case .connect:    (symbol, label) = ("play", "Connect \(row.name)")
        case .disconnect: (symbol, label) = ("stop", "Disconnect \(row.name)")
        case .wait:       (symbol, label) = ("ellipsis", "\(row.name) is changing, please wait")
        case .openApp:    (symbol, label) = ("arrow.up.forward.app", "Open the VPN app for \(row.name)")
        }
        button.image = UI.symbol(symbol, description: label)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isEnabled = row.model.action != .wait
    }
}

// The stack is the scroll view's document, so the panel can grow up to its limit and then scroll.
final class PopoverContentView: NSStackView {
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    var onUsageHistory: (() -> Void)?
    var onActivityMonitor: (() -> Void)?
    var onSignIn: (() -> Void)?
    var onNewProfile: (() -> Void)?
    var onOpenProfile: ((String) -> Void)?
    var onShowSessions: (() -> Void)?
    var onVPNAction: ((String) -> Void)?
    var onHeightChange: (() -> Void)?

    static let width: CGFloat = 380
    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private let statusIcon = NSImageView()
    private let titleLabel = UI.label("Checking…", size: 14, weight: .semibold)
    private let subtitleLabel = UI.label("", size: 11.5, color: .secondaryLabelColor)
    private let downLabel = UI.label("", size: 11.5, weight: .medium, color: .secondaryLabelColor)
    private let upLabel = UI.label("", size: 11.5, weight: .medium, color: .secondaryLabelColor)
    private lazy var refreshButton = ClosureButton(symbol: "arrow.clockwise", label: "Refresh") { [weak self] in self?.onRefresh?() }
    private let refreshSpinner: NSProgressIndicator = {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Refreshing")
        return spinner
    }()
    private lazy var todayButton = ClosureButton(title: "") { [weak self] in self?.onUsageHistory?() }
    private lazy var alertCard = makeAlertCard()
    private let fiveHeader = UI.label("5h left", size: 11.5, color: .secondaryLabelColor)
    private let weekHeader = UI.label("Week left", size: 11.5, color: .secondaryLabelColor)
    private let profileRows = UI.column([], spacing: 0)
    private lazy var pausedHint: NSStackView = {
        let icon = NSImageView(image: UI.symbol("info.circle", size: 12) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)
        let text = "Claude paused updates: open its menu, then Refresh."
        let label = UI.label(text, size: 11.5, color: .secondaryLabelColor)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = text
        UI.flexible(label)
        let row = UI.row([icon, label], spacing: 6)
        row.edgeInsets = NSEdgeInsets(top: 4, left: UI.rowSide, bottom: 2, right: UI.rowSide)
        return row
    }()
    private lazy var profilesCard: CardView = {
        let header = makeProfilesHeader()
        let column = UI.column([header, profileRows, pausedHint], spacing: 2)
        for view in [header, profileRows] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return CardView(column)
    }()
    private let vpnRows = UI.column([], spacing: 0)
    private lazy var vpnCard = Self.sectionCard("VPN", rows: vpnRows)
    private let otherRows = UI.column([], spacing: 0)
    private lazy var otherCard = Self.sectionCard("Other Tools", rows: otherRows)
    private let emptyLabel = UI.label("No local AI sessions detected yet", color: .secondaryLabelColor)
    private let cpuValue = UI.label("—", weight: .semibold)
    private let ramValue = UI.label("—", weight: .semibold)
    private let pressureValue = UI.label("—", weight: .semibold)
    private lazy var sessionsToggle = ClosureButton(symbol: "chevron.right", label: "Recent Sessions") { [weak self] in self?.toggleSessions() }
    private lazy var sessionsHeader: CardView = {
        let title = UI.sectionTitle("Recent Sessions")
        UI.flexible(title)
        let row = UI.row([title, sessionsToggle])
        row.edgeInsets = UI.insets()
        let card = CardView(row)
        card.clickTarget = sessionsToggle
        return card
    }()
    private let sessionRows = UI.column([], spacing: 6)
    private lazy var sessionsCard: CardView = {
        sessionRows.edgeInsets = UI.insets(vertical: 4)
        return CardView(sessionRows)
    }()
    private var sessionsOpen = false
    var sessionsAreOpen: Bool { sessionsOpen }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader(), system = makeSystemCard()
        let parts: [NSView] = [header, alertCard, vpnCard, profilesCard, otherCard, emptyLabel, system, sessionsHeader, sessionsCard]
        parts.forEach { addArrangedSubview($0) }
        for part in [alertCard, vpnCard, profilesCard, otherCard, sessionsCard, header, system, sessionsHeader] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            part.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        }
        alertCard.isHidden = true
        vpnCard.isHidden = true
        sessionsCard.isHidden = true
        emptyLabel.isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Building

    // A titled card whose rows line up under the profile rows.
    private static func sectionCard(_ text: String, rows: NSStackView) -> CardView {
        let title = UI.sectionTitle(text)
        UI.flexible(title)
        let header = UI.row([UI.gap(width: UI.tileSize), title])
        header.edgeInsets = UI.insets()
        let column = UI.column([header, rows], spacing: 2)
        for view in [header, rows] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return CardView(column)
    }

    private func makeHeader() -> NSView {
        statusIcon.contentTintColor = .controlAccentColor
        statusIcon.setAccessibilityElement(false)
        UI.fix(statusIcon, width: UI.tileSize, height: 28)
        let titles = UI.column([titleLabel, subtitleLabel], spacing: 1)
        UI.flexible(titles)
        let speeds = UI.column([downLabel, upLabel], spacing: 1)
        speeds.alignment = .trailing
        let top = UI.row([statusIcon, titles, speeds])
        top.edgeInsets = NSEdgeInsets(top: 0, left: UI.panelInset, bottom: 0, right: UI.panelInset)

        todayButton.isBordered = false
        todayButton.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        todayButton.contentTintColor = .secondaryLabelColor
        todayButton.toolTip = "Open Usage History"
        // The spinner takes the button's place, so the header does not move while a refresh runs.
        let refresh = NSView()
        UI.fix(refresh, width: UI.actionWidth, height: UI.actionWidth)
        for view in [refreshButton, refreshSpinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            refresh.addSubview(view)
            view.centerXAnchor.constraint(equalTo: refresh.centerXAnchor).isActive = true
            view.centerYAnchor.constraint(equalTo: refresh.centerYAnchor).isActive = true
        }
        let tools = UI.row([
            refresh,
            ClosureButton(symbol: "gearshape", label: "Settings") { [weak self] in self?.onSettings?() },
        ], spacing: 2)
        let bottom = UI.row([todayButton, UI.spacer(), tools], spacing: 8)
        // A borderless button keeps 2pt around its title, so its text still starts on the grid.
        bottom.edgeInsets = NSEdgeInsets(top: 0, left: UI.panelInset - 2, bottom: 0, right: UI.panelInset)
        let header = UI.column([top, bottom], spacing: 6)
        for row in [top, bottom] {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        }
        return header
    }

    private let alertText = UI.label("", weight: .medium)
    private var alertOpensSettings = false
    private lazy var alertButton = ClosureButton(title: "Sign in Now") { [weak self] in
        guard let self = self else { return }
        if self.alertOpensSettings { self.onSettings?() } else { self.onSignIn?() }
    }

    private func makeAlertCard() -> CardView {
        let icon = NSImageView(image: UI.symbol("exclamationmark.triangle", description: "Warning") ?? NSImage())
        icon.contentTintColor = UI.warn
        UI.fix(icon, width: UI.tileSize)
        alertText.lineBreakMode = .byTruncatingTail
        UI.flexible(alertText)
        let row = UI.row([icon, alertText, alertButton])
        row.edgeInsets = UI.insets()
        return CardView(row)
    }

    private func makeProfilesHeader() -> NSView {
        let title = UI.sectionTitle("Claude Profiles")
        UI.flexible(title)
        let mark = NSImageView(image: ProviderMark.claude.symbol(size: 16))
        mark.setAccessibilityElement(false)
        UI.fix(mark, width: UI.tileSize, height: 16)
        UI.fix(fiveHeader, width: QuotaColumn.width)
        UI.fix(weekHeader, width: QuotaColumn.width)
        let add = ClosureButton(symbol: "plus.circle.fill", label: "New profile", tint: .controlAccentColor) { [weak self] in self?.onNewProfile?() }
        let row = UI.row([mark, title, fiveHeader, weekHeader, add])
        row.edgeInsets = UI.insets()
        return row
    }

    private func makeSystemCard() -> NSView {
        func metric(_ name: String, _ value: NSTextField) -> NSView {
            UI.column([UI.label(name, size: 11.5, color: .secondaryLabelColor), value], spacing: 1)
        }
        let monitor = ClosureButton(symbol: "waveform.path.ecg", label: "Open Activity Monitor") { [weak self] in self?.onActivityMonitor?() }
        let row = UI.row([metric("CPU", cpuValue), metric("RAM", ramValue), metric("Pressure", pressureValue), UI.spacer(), monitor], spacing: 28)
        row.alignment = .centerY
        row.edgeInsets = UI.insets(vertical: 2)
        return CardView(row)
    }

    // MARK: - Updates

    func setStatus(_ state: PortalState, text: String, lastLogin: Date?, autoLogin: Bool) {
        titleLabel.stringValue = text
        subtitleLabel.stringValue = lastLogin.map { "Last login \(Self.timeFormat.string(from: $0))" } ?? ""
        subtitleLabel.isHidden = lastLogin == nil
        let symbol: String
        switch state {
        case .connected:  symbol = "wifi"
        case .idle:       symbol = "wifi"
        case .working:    symbol = "arrow.triangle.2.circlepath"
        case .needsLogin, .needsSettings: symbol = "wifi.exclamationmark"
        }
        statusIcon.image = UI.symbol(symbol, size: 15, weight: .medium)
        // The header names what happened; the card says what to do, with one button.
        let alert: (text: String, opensSettings: Bool)?
        switch state {
        case .needsLogin:    alert = ("This Wi-Fi needs a sign-in", false)
        case .needsSettings: alert = ("Check your sign-in details", true)
        // With auto-login off nothing else can sign in, so the button stays while the Mac is offline.
        case .idle where !autoLogin: alert = ("Auto-login is off", false)
        default: alert = nil
        }
        let wantsAlert = alert != nil
        if let alert = alert {
            alertText.stringValue = alert.text
            alertText.toolTip = alert.text
            alertOpensSettings = alert.opensSettings
            alertButton.title = alert.opensSettings ? "Open Settings" : "Sign in Now"
        }
        if alertCard.isHidden == wantsAlert {
            alertCard.isHidden = !wantsAlert
            onHeightChange?()
        }
    }

    func setRefreshing(_ refreshing: Bool) {
        refreshButton.isHidden = refreshing
        if refreshing { refreshSpinner.startAnimation(nil) } else { refreshSpinner.stopAnimation(nil) }
    }

    func setSpeed(down: Double, up: Double, today: DayUsage, binary: Bool) {
        downLabel.stringValue = "↓ \(ByteFormatter.speed(down, binary: binary))"
        upLabel.stringValue = "↑ \(ByteFormatter.speed(up, binary: binary))"
        todayButton.title = "Today ↓ \(ByteFormatter.total(today.rx, binary: binary)) ↑ \(ByteFormatter.total(today.tx, binary: binary))"
    }

    func setSystem(cpu: String, ram: String, pressure: String) {
        cpuValue.stringValue = cpu
        ramValue.stringValue = ram
        pressureValue.stringValue = pressure
    }

    func setSnapshot(_ snapshot: AISnapshot, settings: Settings, now: Date) {
        let showLeft = settings.usageShowLeft
        fiveHeader.stringValue = showLeft ? "5h left" : "5h used"
        weekHeader.stringValue = showLeft ? "Week left" : "Week used"

        var entries: [(folder: String, model: ProfileRowModel, letter: String, hex: String)] = []
        var firstOnAccount: [String: String] = [:]
        for profile in snapshot.profiles where !settings.hiddenProfiles.contains(profile.folder) {
            let name = settings.alias(forFolder: profile.folder) ?? profile.name
            var sameAs: String?
            if case .reading(let reading) = profile.usage, let account = reading.account {
                sameAs = firstOnAccount[account]
                if sameAs == nil { firstOnAccount[account] = name }
            }
            let model = ProfileRowModel.make(name: name, usage: profile.usage, running: profile.isRunning, showLeft: showLeft, now: now, sameAccountAs: sameAs)
            entries.append((profile.folder, model, Monogram.letter(for: name), settings.tint(forFolder: profile.folder)))
        }
        let current = profileRows.arrangedSubviews.compactMap { $0 as? ProfileRowView }
        if current.map(\.folder) == entries.map(\.folder) {
            for (row, entry) in zip(current, entries) {
                row.update(model: entry.model, letter: entry.letter, hex: entry.hex, showLeft: showLeft)
            }
        } else {
            profileRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for entry in entries {
                let folder = entry.folder
                let row = ProfileRowView(folder: folder, model: entry.model, letter: entry.letter, hex: entry.hex, showLeft: showLeft) { [weak self] in
                    self?.onOpenProfile?(folder)
                }
                profileRows.addArrangedSubview(row)
                row.translatesAutoresizingMaskIntoConstraints = false
                row.widthAnchor.constraint(equalTo: profileRows.widthAnchor).isActive = true
            }
        }

        let visible = snapshot.profiles.filter { !settings.hiddenProfiles.contains($0.folder) }
        pausedHint.isHidden = !AISnapshot.hasPausedProfile(visible, now: now)

        otherRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if settings.showCodex, let codex = snapshot.codex {
            addOtherRow(makeCodexRow(codex, showLeft: showLeft, now: now))
        }
        if settings.showAntigravity, let antigravity = snapshot.antigravity {
            let model = AntigravityRowModel.make(antigravity, showLeft: showLeft, now: now)
            addOtherRow(makeToolRow(.antigravity, name: "Antigravity", detail: model.detail))
            for quota in model.quotas { addOtherRow(makeQuotaRow(quota, showLeft: showLeft)) }
        }
        for status in snapshot.tools where status.isRecent(now: now) && !settings.hiddenTools.contains(status.tool.rawValue) {
            addOtherRow(makeToolRow(status.tool.mark, name: status.tool.displayName, detail: LastActive.line(status.lastActive, now: now)))
        }
        otherCard.isHidden = otherRows.arrangedSubviews.isEmpty
        emptyLabel.isHidden = !(profileRows.arrangedSubviews.isEmpty && otherRows.arrangedSubviews.isEmpty)
        onHeightChange?()
    }

    private func makeQuotaRow(_ quota: AntigravityRowModel.Quota, showLeft: Bool) -> NSView {
        let name = UI.label(quota.name, size: 12)
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = quota.fullName
        UI.flexible(name)
        let reset = UI.label(quota.reset, size: 10.5, color: .secondaryLabelColor)
        reset.alignment = .right
        UI.fix(reset, width: 78)
        let column = QuotaColumn()
        column.set(quota.cell, spoken: QuotaColumn.spoken(owner: "Antigravity", window: quota.fullName, cell: quota.cell, showLeft: showLeft))
        let row = UI.row([UI.gap(width: UI.tileSize), name, reset, column, UI.gap(width: UI.actionWidth)])
        row.edgeInsets = UI.insets()
        UI.fix(row, height: UI.subRowHeight)
        return row
    }

    private func makeToolRow(_ mark: ProviderMark, name: String, detail: String, quotas: [QuotaColumn] = []) -> NSView {
        let names = UI.column([UI.label(name, weight: .semibold), UI.label(detail, size: 11.5, color: .secondaryLabelColor)], spacing: 1)
        UI.flexible(names)
        var parts: [NSView] = [TileView(mark: mark), names] + quotas
        if !quotas.isEmpty { parts.append(UI.gap(width: UI.actionWidth)) }
        let row = UI.row(parts)
        row.edgeInsets = UI.insets()
        UI.fix(row, height: UI.rowHeight)
        return row
    }

    private func addOtherRow(_ row: NSView) {
        otherRows.addArrangedSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalTo: otherRows.widthAnchor).isActive = true
    }

    private func makeCodexRow(_ reading: CodexReading, showLeft: Bool, now: Date) -> NSView {
        let model = CodexRowModel.make(reading, showLeft: showLeft, now: now)
        let primary = QuotaColumn(), secondary = QuotaColumn()
        primary.set(model.fiveHour, spoken: QuotaColumn.spoken(owner: "Codex", window: "5 hour", cell: model.fiveHour, showLeft: showLeft))
        secondary.set(model.week, spoken: QuotaColumn.spoken(owner: "Codex", window: "weekly", cell: model.week, showLeft: showLeft))
        return makeToolRow(.openAI, name: "Codex", detail: model.detail, quotas: [primary, secondary])
    }

    private func toggleSessions() {
        sessionsOpen.toggle()
        sessionsToggle.image = UI.symbol(sessionsOpen ? "chevron.down" : "chevron.right", description: "Recent Sessions")
        sessionsCard.isHidden = !sessionsOpen
        if sessionsOpen { onShowSessions?() }
        onHeightChange?()
    }

    func setVPN(_ rows: [VPNPanelRow]) {
        let current = vpnRows.arrangedSubviews.compactMap { $0 as? VPNRowView }
        // The same accounts are updated in place, so a focused button keeps its focus.
        if current.map(\.id) == rows.map(\.id) {
            zip(current, rows).forEach { $0.update($1) }
            return
        }
        vpnRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in rows {
            let view = VPNRowView(row) { [weak self] id in self?.onVPNAction?(id) }
            vpnRows.addArrangedSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: vpnRows.widthAnchor).isActive = true
        }
        vpnCard.isHidden = rows.isEmpty
        onHeightChange?()
    }

    func setSessions(_ sessions: [RecentSession], binary: Bool, now: Date) {
        sessionRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if sessions.isEmpty {
            sessionRows.addArrangedSubview(UI.label("No recent sessions", size: 12, color: .secondaryLabelColor))
        }
        for session in sessions {
            var detail = "\(session.provider) · \(RelativeAge.short(now.timeIntervalSince(session.date)))"
            if let tokens = session.tokens { detail += " · \(TokenFormat.short(tokens)) tokens" }
            let project = UI.label(session.project, size: 12, weight: .medium)
            sessionRows.addArrangedSubview(UI.column([project, UI.label(detail, size: 11.5, color: .secondaryLabelColor)], spacing: 1))
        }
        onHeightChange?()
    }
}
