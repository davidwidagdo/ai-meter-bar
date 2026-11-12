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

final class SettingsClaudeTab {
    var onNewProfile: (() -> Void)?
    var onProfilesChanged: (() -> Void)?
    var onResize: (() -> Void)?

    private let rows = UI.column([], spacing: 0)
    private var switches: [String: NSSwitch] = [:]
    private(set) lazy var view: NSView = build()

    private func build() -> NSView {
        let add = SettingsUI.button("New Profile") { [weak self] in self?.onNewProfile?() }
        add.image = UI.symbol("plus", size: 10, weight: .semibold, description: "New Profile")
        add.imagePosition = .imageLeading
        let header = UI.row([SettingsUI.title("Claude Profiles"), UI.spacer(), add], spacing: 8)
        UI.fix(header, width: SettingsUI.width)
        let note = SettingsUI.note("Hiding a profile never deletes its folder or sign-in.")
        return SettingsUI.column([header, SettingsUI.list(rows), note])
    }

    func load() {
        switches.removeAll()
        rebuild()
    }

    func save(to settings: Settings) {
        settings.hiddenProfiles = Set(switches.filter { $0.value.state == .off }.keys)
    }

    func rebuild() {
        _ = view
        // Rename, Color and New Profile rebuild the list; unsaved switch changes stay.
        let unsaved = switches.mapValues(\.state)
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switches.removeAll()
        let settings = Settings.shared
        let cache = ClaudeUsageCache()
        let profiles = ClaudeProfiles.listed()
        let usages = AccountUsage.merged(profiles.map { cache.read(profile: $0) })
        var firstOnAccount: [String: String] = [:]
        for (profile, usage) in zip(profiles, usages) {
            let name = settings.alias(forFolder: profile.folder) ?? profile.name
            var lines = [UI.label(name, size: 12, weight: .semibold)]
            if case .reading(let reading) = usage, let account = reading.account {
                if let owner = firstOnAccount[account] {
                    lines.append(SettingsUI.detail("Same account as \(owner)"))
                } else {
                    firstOnAccount[account] = name
                }
            }
            let names = UI.column(lines, spacing: 0)
            names.toolTip = "Folder: \(profile.folder)"
            UI.flexible(names)

            let toggle = SettingsUI.toggle("Show \(name) in the bar")
            toggle.state = unsaved[profile.folder] ?? (settings.hiddenProfiles.contains(profile.folder) ? .off : .on)
            switches[profile.folder] = toggle

            var age = "No usage yet"
            if case .reading(let reading) = usage {
                age = "\(RelativeAge.short(Date().timeIntervalSince(reading.date))) ago"
            }
            let ageLabel = UI.label(age, size: 11, color: .secondaryLabelColor)
            UI.fix(ageLabel, width: 70)

            let launcher = launcherCell(profile)
            UI.fix(launcher, width: 102)

            let more = ClosureButton(symbol: "ellipsis.circle", label: "More for \(name)", size: SettingsUI.actionSize)
            more.onClick = { [weak self, weak more] in
                guard let self = self, let more = more else { return }
                self.menu(profile, name: name).popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
            }

            let tile = TileView(letter: Monogram.letter(for: name), hex: settings.tint(forFolder: profile.folder), size: SettingsUI.tileSize)
            rows.addArrangedSubview(SettingsUI.row([tile, names, launcher, ageLabel, toggle, more]))
        }
        // A new profile or a "Same account" line can make the tab outgrow the window.
        onResize?()
    }

    private func launcherCell(_ profile: ClaudeProfile) -> NSView {
        if profile.folder == ProfileNames.defaultFolder {
            return UI.label("Opens with Claude", size: 11, color: .secondaryLabelColor)
        }
        if AppMode.isDemo || ClaudeLauncher.exists(name: profile.name) {
            return UI.label("Launcher ready", size: 11, weight: .medium, color: UI.ok)
        }
        guard ProfileNames.canHaveLauncher(profile) else {
            return UI.label("Name not supported", size: 11, color: .secondaryLabelColor)
        }
        return SettingsUI.button("Create Launcher") { [weak self] in self?.createLauncher(profile) }
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
                self?.rebuild()
            }
        }
    }

    private func menu(_ profile: ClaudeProfile, name: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MenuAction("Rename…") { [weak self] in self?.rename(profile, current: name) })
        let colors = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for tint in ProfileTint.all {
            colorMenu.addItem(MenuAction(tint.name) { [weak self] in
                Settings.shared.setTint(tint.hex, forFolder: profile.folder)
                self?.changed()
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
        changed()
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
        let others = ClaudeProfiles.listed().filter { $0.folder != profile.folder }
        let taken = others.map(\.name) + others.compactMap { Settings.shared.alias(forFolder: $0.folder) }
        if !value.isEmpty, taken.contains(where: { ProfileNames.sameName($0, value) }) {
            let clash = NSAlert()
            clash.messageText = "Another profile is already called “\(value)”"
            clash.informativeText = "Pick a different name, so each row in the bar stays clear."
            clash.runModal()
            return
        }
        Settings.shared.setAlias(value.isEmpty || value == profile.name ? nil : value, forFolder: profile.folder)
        changed()
    }

    private func changed() {
        rebuild()
        onProfilesChanged?()
    }
}
