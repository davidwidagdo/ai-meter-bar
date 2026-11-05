import Cocoa

private final class MenuAction: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.handler = handler
        target = self
    }

    @objc private func fire() {
        handler?()
    }
}

// The password loads only on the Portal tab, so opening Settings costs no Keychain prompt.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTabViewDelegate {
    // Accounts tab
    private let unitControl = NSSegmentedControl(labels: ["% Left", "% Used"], trackingMode: .selectOne, target: nil, action: nil)
    private let profileRows = UI.column([], spacing: 4)
    private var profileSwitches: [String: NSSwitch] = [:]
    private let codexSwitch = NSSwitch()
    private let antigravitySwitch = NSSwitch()
    private var toolSwitches: [AITool: NSSwitch] = [:]

    // Portal tab
    private let tabView = NSTabView()
    private let portalTabIdentifier = "portal"
    private let autoLoginCheck = NSButton(checkboxWithTitle: "Auto-Login", target: nil, action: nil)
    private let pollField = NSTextField()
    private let loginURLField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let passwordPlainField = NSTextField()
    private let revealButton = NSButton()
    private var passwordRevealed = false
    private var passwordEdited = false
    private var passwordLoaded = false
    private let extraField = NSTextField()
    private let markerField = NSTextField()
    private let advancedToggle = NSButton(checkboxWithTitle: "Show advanced portal options (rarely needed)", target: nil, action: nil)
    private var advancedBox = NSView()
    private let diagnoseResult = UI.wrappingLabel("", width: 520)
    private var baseContentHeight: CGFloat = 0
    private var isMeasuringTabs = false

    // General tab
    private let modePopup = NSPopUpButton()
    private let intervalPopup = NSPopUpButton()
    private let systemIntervalPopup = NSPopUpButton()
    private let binaryCheck = NSButton(checkboxWithTitle: "Use binary units (1024 / KiB)", target: nil, action: nil)
    private let interfacePopup = NSPopUpButton()
    private let startAtLoginCheck = NSButton(checkboxWithTitle: "Start at Login", target: nil, action: nil)

    // Wiring back to AppDelegate.
    var onSave: (() -> Void)?
    var isLoginItemEnabled: () -> Bool = { false }
    var setLoginItem: (Bool) -> Void = { _ in }
    var onNewProfile: (() -> Void)?
    var onProfilesChanged: (() -> Void)?
    var onOpenUsageHistory: (() -> Void)?
    var runDiagnostics: ((@escaping ([String]) -> Void) -> Void)?

    private let intervalOptions = Settings.intervalOptions
    private let modes = MenuBarMode.allCases

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AI Meter Bar — Settings"
        self.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        buildUI()
    }

    // MARK: - UI construction

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        tabView.delegate = self
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(tab("Accounts", identifier: "accounts", view: buildAccountsTab()))
        tabView.addTabViewItem(tab("Portal", identifier: portalTabIdentifier, view: buildPortalTab()))
        tabView.addTabViewItem(tab("General", identifier: "general", view: buildGeneralTab()))

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let actionBar = GlassPanel.wrap(buttons, cornerRadius: 16, padding: 8)

        content.addSubview(tabView)
        content.addSubview(actionBar)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            actionBar.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 12),
            actionBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            actionBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    // NSTabView lays out only the selected tab, so measure every tab or taller ones clip.
    private func sizeWindowToTallestTab() {
        guard let content = window?.contentView else { return }
        let selected = tabView.selectedTabViewItem
        var tallest: CGFloat = 0
        // Selecting the Portal tab just to measure it must not read the Keychain.
        isMeasuringTabs = true
        for item in tabView.tabViewItems {
            tabView.selectTabViewItem(item)
            content.layoutSubtreeIfNeeded()
            tallest = max(tallest, content.fittingSize.height)
        }
        if let selected = selected { tabView.selectTabViewItem(selected) }
        isMeasuringTabs = false
        guard tallest > 0 else { return }
        baseContentHeight = tallest
        window?.setContentSize(NSSize(width: content.frame.width, height: tallest))
    }

    // The advanced section can outgrow the tallest-tab floor; grow instead of clipping it.
    private func fitWindowToCurrentContent() {
        guard let content = window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = max(baseContentHeight, content.fittingSize.height)
        guard abs(height - content.frame.height) > 0.5 else { return }
        window?.setContentSize(NSSize(width: content.frame.width, height: height))
    }

    private func tab(_ title: String, identifier: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: identifier)
        item.label = title
        let container = NSView()
        container.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            view.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])
        item.view = container
        return item
    }

    private func grid(_ rows: [[NSView]]) -> NSGridView {
        let g = NSGridView(views: rows)
        g.translatesAutoresizingMaskIntoConstraints = false
        g.rowSpacing = 10
        g.columnSpacing = 10
        g.column(at: 0).xPlacement = .trailing
        return g
    }

    private func buildAccountsTab() -> NSView {
        let title = UI.label("Claude Profiles", size: 15, weight: .semibold)
        let mark = NSImageView(image: ProviderMark.claude.symbol(size: 16))
        mark.setAccessibilityElement(false)
        UI.fix(mark, width: 16, height: 16)
        unitControl.setAccessibilityLabel("Show usage as")
        let add = ClosureButton(title: "New Profile") { [weak self] in self?.onNewProfile?() }
        let header = UI.row([mark, title, UI.spacer(), unitControl, add])
        UI.fix(header, width: 560)

        let profiles = CardView(profileRows, padding: 8)
        UI.fix(profiles, width: 560)
        let note = UI.label("Hiding a profile never deletes its folder or sign-in.", size: 12, color: .secondaryLabelColor)

        let others = UI.label("Other Tools", size: 15, weight: .semibold)
        codexSwitch.setAccessibilityLabel("Show Codex in the bar")
        antigravitySwitch.setAccessibilityLabel("Show Antigravity in the bar")
        var toolRows = [
            toolRow(.openAI, "Codex", "Current account, read from local sessions", codexSwitch),
            toolRow(.antigravity, "Antigravity", "Last active time only", antigravitySwitch),
        ]
        for status in LocalTools.listed() {
            let toggle = NSSwitch()
            toggle.setAccessibilityLabel("Show \(status.tool.displayName) in the bar")
            toolSwitches[status.tool] = toggle
            toolRows.append(toolRow(status.tool.mark, status.tool.displayName, "Shown when used in the last 30 days", toggle))
        }
        let tools = CardView(UI.column(toolRows, spacing: 4), padding: 8)
        UI.fix(tools, width: 560)

        return UI.column([header, profiles, note, others, tools], spacing: 12)
    }

    private func toolRow(_ mark: ProviderMark, _ name: String, _ detail: String, _ toggle: NSSwitch) -> NSView {
        let names = UI.column([UI.label(name, weight: .semibold), UI.label(detail, size: 11.5, color: .secondaryLabelColor)], spacing: 1)
        let row = UI.row([TileView(mark: mark), names, UI.spacer(), toggle], spacing: 12)
        UI.fix(row, width: 544)
        return row
    }

    private func rebuildProfiles() {
        profileRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        profileSwitches.removeAll()
        let settings = Settings.shared
        let cache = ClaudeUsageCache()
        let profiles = ClaudeProfiles.listed()
        let usages = AccountUsage.merged(profiles.map { cache.read(profile: $0) })
        var firstOnAccount: [String: String] = [:]
        for (profile, usage) in zip(profiles, usages) {
            let name = settings.alias(forFolder: profile.folder) ?? profile.name
            var lines = [UI.label(name, weight: .semibold), UI.label(profile.folder, size: 11.5, color: .secondaryLabelColor, mono: true)]
            if case .reading(let reading) = usage, let account = reading.account {
                if let owner = firstOnAccount[account] {
                    lines.append(UI.label("Same account as \(owner)", size: 11.5, color: .secondaryLabelColor))
                } else {
                    firstOnAccount[account] = name
                }
            }
            let names = UI.column(lines, spacing: 1)
            UI.flexible(names)

            let toggle = NSSwitch()
            toggle.state = settings.hiddenProfiles.contains(profile.folder) ? .off : .on
            toggle.setAccessibilityLabel("Show \(name) in the bar")
            profileSwitches[profile.folder] = toggle

            var age = "No usage yet"
            if case .reading(let reading) = usage {
                age = "\(RelativeAge.short(Date().timeIntervalSince(reading.date))) ago"
            }
            let ageLabel = UI.label(age, size: 12, color: .secondaryLabelColor)
            UI.fix(ageLabel, width: 78)

            let launcher = launcherCell(profile)
            UI.fix(launcher, width: 124)

            let more = ClosureButton(symbol: "ellipsis.circle", label: "More for \(name)")
            more.onClick = { [weak self, weak more] in
                guard let self = self, let more = more else { return }
                self.profileMenu(profile, name: name).popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
            }

            let row = UI.row([TileView(letter: Monogram.letter(for: name), hex: settings.tint(forFolder: profile.folder)), names, launcher, ageLabel, toggle, more], spacing: 12)
            UI.fix(row, width: 544)
            profileRows.addArrangedSubview(row)
        }
    }

    private func launcherCell(_ profile: ClaudeProfile) -> NSView {
        if profile.folder == ProfileNames.defaultFolder {
            return UI.label("Opens with Claude", size: 12, color: .secondaryLabelColor)
        }
        if AppMode.isDemo || ClaudeLauncher.exists(name: profile.name) {
            return UI.label("Launcher ready", size: 12, weight: .medium, color: UI.ok)
        }
        guard ProfileNames.canHaveLauncher(profile) else {
            return UI.label("Name not supported", size: 12, color: .secondaryLabelColor)
        }
        let button = ClosureButton(title: "Create Launcher")
        button.controlSize = .small
        button.onClick = { [weak self] in self?.createLauncher(profile) }
        return button
    }

    private func createLauncher(_ profile: ClaudeProfile) {
        let hex = Settings.shared.tint(forFolder: profile.folder)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try Monogram.withIcon(letter: Monogram.letter(for: profile.name), hex: hex) { icon in
                    try ClaudeLauncher.build(name: profile.name, icon: icon)
                }
            }
            DispatchQueue.main.async {
                if case .failure = result { Log.write("Launcher could not be created.") }
                self?.rebuildProfiles()
            }
        }
    }

    private func profileMenu(_ profile: ClaudeProfile, name: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MenuAction("Rename…") { [weak self] in self?.rename(profile, current: name) })
        let colors = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for tint in ProfileTint.all {
            colorMenu.addItem(MenuAction(tint.name) { [weak self] in
                Settings.shared.setTint(tint.hex, forFolder: profile.folder)
                self?.profilesChanged()
            })
        }
        colors.submenu = colorMenu
        menu.addItem(colors)
        menu.addItem(MenuAction("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([profile.url]) })
        guard profile.folder != ProfileNames.defaultFolder else { return menu }
        menu.autoenablesItems = false
        menu.addItem(.separator())
        let running = ClaudeInstances.running().contains { $0.folder == profile.folder }
        let trash = MenuAction(running ? "Move to Trash… (quit it first)" : "Move to Trash…") { [weak self] in
            self?.confirmTrash(profile, name: name)
        }
        trash.isEnabled = !running
        menu.addItem(trash)
        return menu
    }

    private func confirmTrash(_ profile: ClaudeProfile, name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = Monogram.image(letter: Monogram.letter(for: name), hex: Settings.shared.tint(forFolder: profile.folder), size: 64)
        alert.messageText = "Move “\(name)” to the Trash?"
        alert.informativeText = "Its folder, sign-in and local chats go to the Trash, and so does its launcher. Put it back from the Trash to restore it."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try ClaudeProfiles.moveToTrash(profile, running: Set(ClaudeInstances.running().map(\.folder)))
        } catch {
            let failure = NSAlert()
            failure.messageText = "Could not move “\(name)” to the Trash"
            failure.informativeText = error as? ProfileTrashError == .running
                ? "Quit this profile in Claude, then try again."
                : "Nothing was changed. You can move its folder yourself with Show in Finder."
            failure.runModal()
            return
        }
        if ProfileNames.canHaveLauncher(profile) { ClaudeLauncher.moveToTrash(name: profile.name) }
        Settings.shared.forgetProfile(folder: profile.folder)
        Log.write("A Claude profile was moved to the Trash.")
        profilesChanged()
    }

    private func rename(_ profile: ClaudeProfile, current: String) {
        let alert = NSAlert()
        alert.messageText = "Rename \(current)"
        alert.informativeText = "This changes the name shown here. The folder stays the same."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        Settings.shared.setAlias(value.isEmpty || value == profile.name ? nil : value, forFolder: profile.folder)
        profilesChanged()
    }

    private func profilesChanged() {
        rebuildProfiles()
        onProfilesChanged?()
    }

    private func buildPortalTab() -> NSView {
        let fields = [loginURLField, usernameField, extraField, markerField]
        for field in fields {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        usernameField.placeholderString = "username"
        loginURLField.placeholderString = "http://<portal-host>/login"
        extraField.placeholderString = "e.g. dst=, popup=true"
        markerField.placeholderString = "text only your portal's page shows"
        pollField.translatesAutoresizingMaskIntoConstraints = false
        pollField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        pollField.placeholderString = "15"

        let primary = grid([
            [NSGridCell.emptyContentView, autoLoginCheck],
            [label("Username:"), usernameField],
            [label("Password:"), passwordCell()],
            [label("Login URL:"), loginURLField],
            [label("Check every (s):"), pollField],
        ])

        let note = UI.wrappingLabel("Credentials are sent only to the Login URL's host, or to the Wi-Fi gateway once the Portal marker matches.", width: 520)

        advancedToggle.target = self
        advancedToggle.action = #selector(toggleAdvanced)
        advancedToggle.translatesAutoresizingMaskIntoConstraints = false

        let caption = UI.wrappingLabel("Extra fields apply only when the page has no login form the app can read.", width: 520)
        let advancedGrid = grid([
            [label("Extra form fields:"), extraField],
            [label("Portal marker:"), markerField],
        ])

        let advancedStack = NSStackView(views: [caption, advancedGrid])
        advancedStack.orientation = .vertical
        advancedStack.alignment = .leading
        advancedStack.spacing = 8
        advancedStack.translatesAutoresizingMaskIntoConstraints = false
        advancedStack.isHidden = true
        advancedBox = advancedStack

        let diagnose = ClosureButton(title: "Diagnose") { [weak self] in self?.diagnose() }
        diagnose.toolTip = "Checks the portal without sending anything"
        diagnoseResult.isHidden = true

        let column = NSStackView(views: [primary, note, advancedToggle, advancedStack, diagnose, diagnoseResult])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        return column
    }

    @objc private func toggleAdvanced() {
        advancedBox.isHidden = advancedToggle.state != .on
        fitWindowToCurrentContent()
    }

    private func diagnose() {
        diagnoseResult.stringValue = "Checking…"
        diagnoseResult.isHidden = false
        fitWindowToCurrentContent()
        runDiagnostics? { [weak self] lines in
            DispatchQueue.main.async {
                self?.diagnoseResult.stringValue = lines.joined(separator: "\n")
                self?.fitWindowToCurrentContent()
            }
        }
    }

    private func buildGeneralTab() -> NSView {
        for popup in [modePopup, intervalPopup, systemIntervalPopup, interfacePopup] {
            popup.translatesAutoresizingMaskIntoConstraints = false
        }
        modePopup.removeAllItems()
        modePopup.addItems(withTitles: modes.map(\.title))
        for popup in [intervalPopup, systemIntervalPopup] {
            popup.removeAllItems()
            popup.addItems(withTitles: ["1 second", "2 seconds", "5 seconds"])
        }
        rebuildInterfacePopup()

        let resetButton = NSButton(title: "Reset Today's Usage", target: self, action: #selector(resetUsage))
        let history = ClosureButton(title: "Usage History") { [weak self] in self?.onOpenUsageHistory?() }
        let logButton = ClosureButton(title: "Open Log") {
            if !AppMode.isDemo { NSWorkspace.shared.open(Log.fileURL) }
        }

        return grid([
            [label("Menu bar shows:"), modePopup],
            [label("Speed interval:"), intervalPopup],
            [label("CPU and RAM interval:"), systemIntervalPopup],
            [NSGridCell.emptyContentView, binaryCheck],
            [label("Wi-Fi interface:"), interfacePopup],
            [NSGridCell.emptyContentView, startAtLoginCheck],
            [NSGridCell.emptyContentView, UI.row([resetButton, history, logButton], spacing: 8)],
        ])
    }

    private func rebuildInterfacePopup() {
        interfacePopup.removeAllItems()
        interfacePopup.addItem(withTitle: "Automatic (Wi-Fi)")
        interfacePopup.item(at: 0)?.representedObject = ""
        for name in NetworkInterface.all() {
            interfacePopup.addItem(withTitle: name)
            interfacePopup.lastItem?.representedObject = name
        }
    }

    // MARK: - Password reveal

    private func passwordCell() -> NSView {
        passwordPlainField.isHidden = true
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        for field in [passwordField, passwordPlainField] as [NSTextField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.delegate = self
            holder.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                field.topAnchor.constraint(equalTo: holder.topAnchor),
                field.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            ])
        }
        holder.setContentHuggingPriority(.defaultLow, for: .horizontal)

        revealButton.image = eyeImage(revealed: false)
        revealButton.isBordered = false
        revealButton.imagePosition = .imageOnly
        revealButton.setButtonType(.momentaryChange)
        revealButton.target = self
        revealButton.action = #selector(togglePasswordReveal)
        revealButton.toolTip = "Show or hide password"
        revealButton.translatesAutoresizingMaskIntoConstraints = false
        revealButton.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let cell = NSStackView(views: [holder, revealButton])
        cell.orientation = .horizontal
        cell.spacing = 6
        cell.distribution = .fill
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return cell
    }

    private func eyeImage(revealed: Bool) -> NSImage? {
        NSImage(systemSymbolName: revealed ? "eye.slash" : "eye",
                accessibilityDescription: revealed ? "Hide password" : "Show password")
    }

    @objc private func togglePasswordReveal() {
        passwordRevealed.toggle()
        if passwordRevealed {
            passwordPlainField.stringValue = passwordField.stringValue
        } else {
            passwordField.stringValue = passwordPlainField.stringValue
        }
        passwordField.isHidden = passwordRevealed
        passwordPlainField.isHidden = !passwordRevealed
        revealButton.image = eyeImage(revealed: passwordRevealed)
    }

    private var enteredPassword: String {
        passwordRevealed ? passwordPlainField.stringValue : passwordField.stringValue
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard tabViewItem?.identifier as? String == portalTabIdentifier, !isMeasuringTabs else { return }
        loadPasswordAsync()
    }

    private func loadPasswordAsync() {
        guard !passwordLoaded else { return }
        passwordLoaded = true
        passwordEdited = false
        passwordField.stringValue = ""
        passwordPlainField.stringValue = ""
        passwordField.placeholderString = "Loading…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stored = Settings.shared.password
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.passwordField.placeholderString = nil
                // The user may have typed meanwhile, or closed the window, which must stay clear.
                guard self.passwordLoaded, !self.passwordEdited else { return }
                if self.passwordRevealed {
                    self.passwordPlainField.stringValue = stored
                } else {
                    self.passwordField.stringValue = stored
                }
            }
        }
    }

    // MARK: - Load / Save

    private func load() {
        let s = Settings.shared
        unitControl.selectedSegment = s.usageShowLeft ? 0 : 1
        rebuildProfiles()
        codexSwitch.state = s.showCodex ? .on : .off
        antigravitySwitch.state = s.showAntigravity ? .on : .off
        for (tool, toggle) in toolSwitches { toggle.state = s.hiddenTools.contains(tool.rawValue) ? .off : .on }

        autoLoginCheck.state = s.autoLoginEnabled ? .on : .off
        pollField.stringValue = String(s.pollInterval)
        loginURLField.stringValue = s.loginURL
        usernameField.stringValue = s.username
        extraField.stringValue = s.extraFields.replacingOccurrences(of: "\n", with: ", ")
        markerField.stringValue = s.portalMarker
        advancedToggle.state = .off
        advancedBox.isHidden = true
        diagnoseResult.isHidden = true

        passwordRevealed = false
        passwordLoaded = false
        passwordField.isHidden = false
        passwordPlainField.isHidden = true
        revealButton.image = eyeImage(revealed: false)

        modePopup.selectItem(at: modes.firstIndex(of: s.menuBarMode) ?? 0)
        intervalPopup.selectItem(at: intervalOptions.firstIndex(of: s.speedInterval) ?? 1)
        systemIntervalPopup.selectItem(at: intervalOptions.firstIndex(of: s.systemInterval) ?? 1)
        binaryCheck.state = s.useBinaryUnits ? .on : .off
        rebuildInterfacePopup()
        let override = s.wifiInterfaceOverride
        let idx = (0..<interfacePopup.numberOfItems).first {
            (interfacePopup.item(at: $0)?.representedObject as? String) == override
        }
        interfacePopup.selectItem(at: idx ?? 0)
        startAtLoginCheck.state = isLoginItemEnabled() ? .on : .off

        sizeWindowToTallestTab()
        if tabView.selectedTabViewItem?.identifier as? String == portalTabIdentifier { loadPasswordAsync() }
    }

    @objc private func save() {
        // Clicking Save with the mouse doesn't end editing on the focused field, so commit it first.
        window?.makeFirstResponder(nil)

        let s = Settings.shared
        s.usageShowLeft = unitControl.selectedSegment == 0
        s.hiddenProfiles = Set(profileSwitches.filter { $0.value.state == .off }.keys)
        s.showCodex = codexSwitch.state == .on
        s.showAntigravity = antigravitySwitch.state == .on
        s.hiddenTools = Set(toolSwitches.filter { $0.value.state == .off }.map(\.key.rawValue))

        s.autoLoginEnabled = autoLoginCheck.state == .on
        s.pollInterval = Int(pollField.stringValue) ?? 15
        s.loginURL = loginURLField.stringValue.trimmingCharacters(in: .whitespaces)
        s.username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)
        let newPassword = passwordEdited ? enteredPassword : nil
        s.extraFields = extraField.stringValue
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        s.portalMarker = markerField.stringValue.trimmingCharacters(in: .whitespaces)

        s.menuBarMode = modes[safe: modePopup.indexOfSelectedItem] ?? s.menuBarMode
        s.speedInterval = intervalOptions[safe: intervalPopup.indexOfSelectedItem] ?? 2
        s.systemInterval = intervalOptions[safe: systemIntervalPopup.indexOfSelectedItem] ?? 2
        s.useBinaryUnits = binaryCheck.state == .on
        s.wifiInterfaceOverride = (interfacePopup.selectedItem?.representedObject as? String) ?? ""
        setLoginItem(startAtLoginCheck.state == .on)

        // A Keychain prompt blocks its caller, so the write stays off the main thread.
        let finish = { [weak self] in
            self?.onSave?()
            self?.window?.close()
        }
        guard let password = newPassword else {
            finish()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            Settings.shared.password = password
            DispatchQueue.main.async(execute: finish)
        }
    }

    @objc private func resetUsage() {
        guard !AppMode.isDemo else { return }
        UsageStore.shared.resetToday()
    }

    @objc private func cancel() {
        window?.close()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === passwordField || field === passwordPlainField else { return }
        passwordEdited = true
    }

    // This window lives for days, so the plaintext password must not stay in its fields after closing.
    func windowWillClose(_ notification: Notification) {
        passwordField.stringValue = ""
        passwordPlainField.stringValue = ""
        passwordEdited = false
        passwordRevealed = false
        passwordLoaded = false
        passwordField.isHidden = false
        passwordPlainField.isHidden = true
        revealButton.image = eyeImage(revealed: false)
    }

    func present() {
        load()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshProfiles() {
        guard window?.isVisible == true else { return }
        rebuildProfiles()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
