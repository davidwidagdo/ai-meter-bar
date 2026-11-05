import Cocoa

final class ProfileRowView: NSStackView {
    init(model: ProfileRowModel, letter: String, hex: String, showLeft: Bool, onAction: @escaping () -> Void) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        distribution = .fill
        spacing = 10
        edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)

        let name = UI.label(model.name, weight: .semibold)
        name.toolTip = model.name
        let status = UI.label(model.status, size: 11.5, color: .secondaryLabelColor)
        let names = UI.column([name, UI.row([StatusDot(filled: model.isRunning), status], spacing: 5)], spacing: 1)
        UI.flexible(names)

        let five = QuotaColumn(), week = QuotaColumn()
        five.set(model.fiveHour, spoken: QuotaColumn.spoken(owner: model.name, window: "5 hour", cell: model.fiveHour, showLeft: showLeft))
        week.set(model.week, spoken: QuotaColumn.spoken(owner: model.name, window: "weekly", cell: model.week, showLeft: showLeft))

        let running = model.action == .bringToFront
        let action = ClosureButton(symbol: running ? "arrow.up.forward" : "play",
                                   label: running ? "Bring \(model.name) to front" : "Open \(model.name)",
                                   onClick: onAction)
        for view in [TileView(letter: letter, hex: hex), names, five, week, action] as [NSView] {
            addArrangedSubview(view)
        }
    }

    required init?(coder: NSCoder) { nil }
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
    private lazy var todayButton = ClosureButton(title: "") { [weak self] in self?.onUsageHistory?() }
    private lazy var alertCard = makeAlertCard()
    private let fiveHeader = UI.label("5h left", size: 11.5, color: .secondaryLabelColor)
    private let weekHeader = UI.label("Week left", size: 11.5, color: .secondaryLabelColor)
    private let profileRows = UI.column([], spacing: 0)
    private lazy var profilesCard: CardView = {
        let header = makeProfilesHeader()
        let column = UI.column([header, profileRows], spacing: 2)
        for view in [header, profileRows] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return CardView(column)
    }()
    private let otherRows = UI.column([], spacing: 0)
    private lazy var otherCard = CardView(otherRows)
    private let emptyLabel = UI.label("No local AI sessions detected yet", color: .secondaryLabelColor)
    private let cpuValue = UI.label("—", weight: .semibold)
    private let ramValue = UI.label("—", weight: .semibold)
    private let pressureValue = UI.label("—", weight: .semibold)
    private lazy var sessionsButton = ClosureButton(title: "Recent Sessions") { [weak self] in self?.toggleSessions() }
    private let sessionRows = UI.column([], spacing: 6)
    private lazy var sessionsCard = CardView(sessionRows, padding: 12)
    private var sessionsOpen = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        translatesAutoresizingMaskIntoConstraints = false

        let parts: [NSView] = [makeHeader(), alertCard, profilesCard, otherCard, emptyLabel, makeSystemCard(), sessionsButton, sessionsCard]
        parts.forEach { addArrangedSubview($0) }
        for part in [alertCard, profilesCard, otherCard, sessionsCard, parts[0], parts[5], sessionsButton] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            part.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        }
        alertCard.isHidden = true
        sessionsCard.isHidden = true
        emptyLabel.isHidden = true
        sessionsButton.image = UI.symbol("chevron.right", size: 10, weight: .semibold)
        sessionsButton.imagePosition = .imageTrailing
        sessionsButton.alignment = .left
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Building

    private func makeHeader() -> NSView {
        statusIcon.contentTintColor = .controlAccentColor
        statusIcon.setAccessibilityElement(false)
        UI.fix(statusIcon, width: 28, height: 28)
        let titles = UI.column([titleLabel, subtitleLabel], spacing: 1)
        UI.flexible(titles)
        let speeds = UI.column([downLabel, upLabel], spacing: 1)
        speeds.alignment = .trailing
        let top = UI.row([statusIcon, titles, speeds])

        todayButton.isBordered = false
        todayButton.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        todayButton.contentTintColor = .secondaryLabelColor
        todayButton.toolTip = "Open Usage History"
        let tools = UI.row([
            ClosureButton(symbol: "arrow.clockwise", label: "Refresh") { [weak self] in self?.onRefresh?() },
            ClosureButton(symbol: "gearshape", label: "Settings") { [weak self] in self?.onSettings?() },
            ClosureButton(symbol: "power", label: "Quit") { NSApp.terminate(nil) },
        ], spacing: 2)
        let bottom = UI.row([todayButton, UI.spacer(), tools], spacing: 8)
        let header = UI.column([top, bottom], spacing: 6)
        for row in [top, bottom] {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        }
        return header
    }

    private func makeAlertCard() -> CardView {
        let icon = NSImageView(image: UI.symbol("exclamationmark.triangle", description: "Warning") ?? NSImage())
        icon.contentTintColor = UI.warn
        let text = UI.label("Captive portal detected", weight: .medium)
        UI.flexible(text)
        let button = ClosureButton(title: "Sign in Now") { [weak self] in self?.onSignIn?() }
        return CardView(UI.row([icon, text, button]), padding: 8)
    }

    private func makeProfilesHeader() -> NSView {
        let title = UI.label("Claude Profiles", size: 12.5, weight: .semibold, color: .secondaryLabelColor)
        UI.flexible(title)
        UI.fix(fiveHeader, width: QuotaColumn.width)
        UI.fix(weekHeader, width: QuotaColumn.width)
        let add = ClosureButton(symbol: "plus.circle.fill", label: "New profile", tint: .controlAccentColor) { [weak self] in self?.onNewProfile?() }
        let row = UI.row([title, fiveHeader, weekHeader, add])
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        return row
    }

    private func makeSystemCard() -> NSView {
        func metric(_ name: String, _ value: NSTextField) -> NSView {
            UI.column([UI.label(name, size: 11.5, color: .secondaryLabelColor), value], spacing: 1)
        }
        let monitor = ClosureButton(symbol: "waveform.path.ecg", label: "Open Activity Monitor") { [weak self] in self?.onActivityMonitor?() }
        let row = UI.row([metric("CPU", cpuValue), metric("RAM", ramValue), metric("Pressure", pressureValue), UI.spacer(), monitor], spacing: 28)
        row.alignment = .centerY
        return CardView(row, padding: 10)
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
        case .needsLogin: symbol = "wifi.exclamationmark"
        }
        statusIcon.image = UI.symbol(symbol, size: 15, weight: .medium)
        let wantsAlert = state == .needsLogin && autoLogin
        if alertCard.isHidden == wantsAlert {
            alertCard.isHidden = !wantsAlert
            onHeightChange?()
        }
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

        profileRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for profile in snapshot.profiles where !settings.hiddenProfiles.contains(profile.folder) {
            let name = settings.alias(forFolder: profile.folder) ?? profile.name
            let model = ProfileRowModel.make(name: name, usage: profile.usage, running: profile.isRunning, showLeft: showLeft, now: now)
            let folder = profile.folder
            let row = ProfileRowView(model: model, letter: Monogram.letter(for: name), hex: settings.tint(forFolder: folder), showLeft: showLeft) { [weak self] in
                self?.onOpenProfile?(folder)
            }
            profileRows.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: profileRows.widthAnchor).isActive = true
        }

        otherRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if settings.showCodex, let codex = snapshot.codex {
            addOtherRow(makeCodexRow(codex, showLeft: showLeft, now: now))
        }
        if settings.showAntigravity, let antigravity = snapshot.antigravity {
            let age = now.timeIntervalSince(antigravity.lastActive)
            let elapsed = RelativeAge.short(age)
            var detail = "Last active \(elapsed == "now" ? "now" : "\(elapsed) ago")"
            if let model = antigravity.model { detail += " · \(model)" }
            let names = UI.column([UI.label("Antigravity", weight: .semibold), UI.label(detail, size: 11.5, color: .secondaryLabelColor)], spacing: 1)
            UI.flexible(names)
            let row = UI.row([TileView(letter: "Ag", hex: ProfileTint.all[5].hex), names])
            row.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
            addOtherRow(row)
        }
        otherCard.isHidden = otherRows.arrangedSubviews.isEmpty
        emptyLabel.isHidden = !(profileRows.arrangedSubviews.isEmpty && otherRows.arrangedSubviews.isEmpty)
        onHeightChange?()
    }

    private func addOtherRow(_ row: NSView) {
        otherRows.addArrangedSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalTo: otherRows.widthAnchor).isActive = true
    }

    private func makeCodexRow(_ reading: CodexReading, showLeft: Bool, now: Date) -> NSView {
        let model = CodexRowModel.make(reading, showLeft: showLeft, now: now)
        let names = UI.column([UI.label("Codex", weight: .semibold), UI.label(model.detail, size: 11.5, color: .secondaryLabelColor)], spacing: 1)
        UI.flexible(names)
        let primary = QuotaColumn(), secondary = QuotaColumn()
        primary.set(model.fiveHour, spoken: QuotaColumn.spoken(owner: "Codex", window: "5 hour", cell: model.fiveHour, showLeft: showLeft))
        secondary.set(model.week, spoken: QuotaColumn.spoken(owner: "Codex", window: "weekly", cell: model.week, showLeft: showLeft))
        let gap = NSView()
        UI.fix(gap, width: 28, height: 1)
        let row = UI.row([TileView(letter: "Cx", hex: ProfileTint.all[5].hex), names, primary, secondary, gap])
        row.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        return row
    }

    private func toggleSessions() {
        sessionsOpen.toggle()
        sessionsButton.image = UI.symbol(sessionsOpen ? "chevron.down" : "chevron.right", size: 10, weight: .semibold)
        sessionsCard.isHidden = !sessionsOpen
        if sessionsOpen { onShowSessions?() }
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
