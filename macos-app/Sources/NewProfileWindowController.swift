import Cocoa

final class NewProfileWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    private enum Step {
        case form, working, signIn, launcherFailed
        case failed(title: String, message: String)
    }

    var onProfilesChanged: (() -> Void)?
    var onOpenExisting: ((String) -> Void)?

    private let width: CGFloat = 412
    private let nameField = NSTextField()
    private let launcherSwitch = NSSwitch()
    private let errorLabel = UI.label("", size: 12, weight: .medium, color: UI.critical)
    private let folderLabel = UI.label("", size: 11.5, mono: true)
    private let launcherLabel = UI.label("", size: 11.5, mono: true)
    private lazy var launcherLine = UI.row([NSImageView(image: UI.symbol("app") ?? NSImage()), launcherLabel], spacing: 8)
    private lazy var openExistingButton = ClosureButton(title: "") { [weak self] in self?.openExisting() }
    private lazy var errorRow = UI.row([errorLabel, UI.spacer(), openExistingButton])
    private lazy var createButton = ClosureButton(title: "Create & Open", primary: true) { [weak self] in self?.create() }
    private let preview = NSImageView()
    private var swatches: [ClosureButton] = []
    private var tintIndex = 0
    private var existing: [String] = []
    private var tasks: [(label: NSTextField, mark: NSImageView)] = []
    private var profile: ClaudeProfile?
    private var launcherURL: URL?
    private var name = ""
    private var showingResult = false

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "New Claude Profile"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        nameField.delegate = self
        nameField.placeholderString = "Client"
        launcherSwitch.state = .on
        launcherSwitch.target = self
        launcherSwitch.action = #selector(refreshForm)
        UI.fix(preview, width: 52, height: 52)
        preview.setAccessibilityElement(false)
    }

    func present() {
        // An open form or a creation in progress only comes forward; a finished one starts over.
        guard window?.isVisible != true || showingResult else {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            return
        }
        let profiles = ClaudeProfiles.listed()
        existing = profiles.map(\.name) + profiles.compactMap { Settings.shared.alias(forFolder: $0.folder) }
        tintIndex = 0
        nameField.stringValue = ""
        launcherSwitch.state = .on
        show(.form)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nameField)
    }

    // MARK: - Steps

    private func show(_ step: Step) {
        switch step {
        case .form, .working: showingResult = false
        default: showingResult = true
        }
        guard let root = window?.contentView else { return }
        root.subviews.forEach { $0.removeFromSuperview() }
        let body: NSView
        switch step {
        case .form:
            body = formView()
        case .working:
            body = workingView()
        case .signIn:
            body = resultView(title: "Sign in on the new window",
                              subtitle: "Claude opened a fresh window for \(name).",
                              lines: [("checkmark", UI.ok, "\(name) is now in your bar."),
                                      ("clock", .secondaryLabelColor, "Usage appears after Claude saves its first reading.")],
                              extra: launcherURL == nil ? nil : ClosureButton(title: "Show in Finder") { [weak self] in self?.revealLauncher() })
        case .launcherFailed:
            body = resultView(title: "\(name) is ready, launcher failed",
                              subtitle: "You can still open this profile from the bar.",
                              lines: [("exclamationmark.triangle", UI.warn, "The launcher could not be saved in Applications.")],
                              extra: ClosureButton(title: "Try Again") { [weak self] in self?.retryLauncher() })
        case .failed(let title, let message):
            body = resultView(title: title, subtitle: name,
                              lines: [("exclamationmark.triangle", UI.warn, message)], extra: nil)
        }
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
            body.widthAnchor.constraint(equalToConstant: width),
        ])
        root.layoutSubtreeIfNeeded()
        window?.setContentSize(NSSize(width: width + 48, height: root.fittingSize.height))
    }

    private func heading(_ title: String, _ subtitle: String?) -> NSView {
        preview.image = Monogram.image(letter: Monogram.letter(for: name), hex: ProfileTint.all[tintIndex].hex, size: 52)
        let titleLabel = UI.label(title, size: 17, weight: .semibold)
        var parts: [NSView] = [titleLabel]
        if let subtitle = subtitle { parts.append(UI.label(subtitle, color: .secondaryLabelColor)) }
        return UI.row([preview, UI.column(parts)], spacing: 14)
    }

    private func stretch(_ views: [NSView], in stack: NSStackView) {
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func buttons(_ views: [NSView]) -> NSView {
        UI.row([UI.spacer()] + views, spacing: 8)
    }

    private func formView() -> NSView {
        name = nameField.stringValue
        let head = heading("New Claude Profile", "A separate Claude for another account.")
        let fieldLabel = UI.label("Name", weight: .semibold)
        fieldLabel.setAccessibilityTitleUIElement(nameField)
        let field = UI.column([fieldLabel, nameField, errorRow], spacing: 6)
        for view in [nameField, errorRow] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: field.widthAnchor).isActive = true
        }

        swatches = ProfileTint.all.enumerated().map { index, tint in
            let button = ClosureButton(symbol: "circle.fill", label: tint.name, tint: UI.color(hex: tint.hex)) { [weak self] in
                self?.tintIndex = index
                self?.refreshForm()
            }
            button.image = UI.symbol("circle.fill", size: 20)
            return button
        }
        let colors = UI.row([UI.label("Color", weight: .semibold)] + swatches, spacing: 2)

        let created = UI.label("Will be created", size: 12, weight: .semibold, color: .secondaryLabelColor)
        let folderLine = UI.row([NSImageView(image: UI.symbol("folder") ?? NSImage()), folderLabel], spacing: 8)
        let plan = CardView(UI.column([created, folderLine, launcherLine], spacing: 8), padding: 12)

        let toggleTitle = UI.label("Create launcher app", weight: .semibold)
        let toggleNote = UI.label("Find it in Spotlight or keep it in the Dock.", size: 12, color: .secondaryLabelColor)
        launcherSwitch.setAccessibilityLabel("Create launcher app")
        let toggle = UI.row([UI.column([toggleTitle, toggleNote]), UI.spacer(), launcherSwitch])

        let cancel = ClosureButton(title: "Cancel") { [weak self] in self?.close() }
        let stack = UI.column([head, field, colors, plan, toggle, buttons([cancel, createButton])], spacing: 16)
        stretch([field, plan, toggle], in: stack)
        stack.arrangedSubviews.last.map { stretch([$0], in: stack) }
        refreshForm()
        return stack
    }

    private func workingView() -> NSView {
        var labels = ["Creating folder \(ProfileNames.folderName(name))"]
        if launcherSwitch.state == .on { labels.append("Creating launcher \(ProfileNames.launcherName(name).replacingOccurrences(of: ".app", with: ""))") }
        labels.append("Opening Claude")
        tasks = labels.map { (UI.label($0), NSImageView(image: UI.symbol("circle", size: 8) ?? NSImage())) }
        tasks.forEach { UI.fix($0.mark, width: 16, height: 16) }
        let list = UI.column(tasks.map { UI.row([$0.mark, $0.label], spacing: 8) }, spacing: 10)
        let card = CardView(list, padding: 14)
        let stack = UI.column([heading("Setting up \(name)", nil), card], spacing: 16)
        stretch([card], in: stack)
        return stack
    }

    private func resultView(title: String, subtitle: String, lines: [(String, NSColor, String)], extra: NSView?) -> NSView {
        let rows = lines.map { symbol, tint, text -> NSView in
            let icon = NSImageView(image: UI.symbol(symbol) ?? NSImage())
            icon.contentTintColor = tint
            return UI.row([icon, UI.label(text)], spacing: 8)
        }
        let card = CardView(UI.column(rows, spacing: 10), padding: 14)
        let done = ClosureButton(title: "Done", primary: true) { [weak self] in self?.close() }
        let footer = buttons((extra.map { [$0] } ?? []) + [done])
        let stack = UI.column([heading(title, subtitle), card, footer], spacing: 16)
        stretch([card, footer], in: stack)
        return stack
    }

    // MARK: - Form

    func controlTextDidChange(_ notification: Notification) {
        refreshForm()
    }

    @objc private func refreshForm() {
        name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let shown = name.isEmpty ? "Name" : name
        preview.image = Monogram.image(letter: Monogram.letter(for: name), hex: ProfileTint.all[tintIndex].hex, size: 52)
        for (index, swatch) in swatches.enumerated() {
            swatch.image = UI.symbol(index == tintIndex ? "checkmark.circle.fill" : "circle.fill", size: 20)
            swatch.setAccessibilityValue(index == tintIndex ? "Selected" : nil)
        }
        folderLabel.stringValue = "~/Library/Application Support/\(ProfileNames.folderName(shown))"
        launcherLabel.stringValue = "~/Applications/\(ProfileNames.launcherName(shown))"
        launcherLine.isHidden = launcherSwitch.state != .on

        let check = ProfileNames.check(name, existing: existing)
        errorLabel.stringValue = check == .taken ? "A profile with this name already exists."
            : check == .invalid ? "Use letters, numbers, spaces or hyphens." : ""
        errorRow.isHidden = errorLabel.stringValue.isEmpty
        openExistingButton.isHidden = check != .taken
        openExistingButton.title = "Open \(name)"
        createButton.isEnabled = check == .ok
        fitWindow()
    }

    private func fitWindow() {
        guard let root = window?.contentView else { return }
        root.layoutSubtreeIfNeeded()
        let height = root.fittingSize.height
        if height > 0, abs(height - root.frame.height) > 0.5 {
            window?.setContentSize(NSSize(width: width + 48, height: height))
        }
    }

    private func openExisting() {
        onOpenExisting?(name)
        close()
    }

    // MARK: - Work

    private func markTask(upTo finished: Int) {
        for (index, task) in tasks.enumerated() {
            task.mark.image = UI.symbol(index < finished ? "checkmark" : index == finished ? "ellipsis" : "circle", size: index < finished ? 12 : 8)
            task.mark.contentTintColor = index < finished ? UI.ok : .secondaryLabelColor
        }
    }

    private func create() {
        guard ProfileNames.check(name, existing: existing) == .ok else { return }
        let makeLauncher = launcherSwitch.state == .on
        let hex = ProfileTint.all[tintIndex].hex
        let name = self.name
        launcherURL = nil
        show(.working)
        markTask(upTo: 0)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let created: ClaudeProfile
            do {
                created = try ClaudeProfiles.create(name: name)
            } catch {
                Log.write("Profile folder could not be created.")
                DispatchQueue.main.async { self?.show(.failed(title: "Profile not created", message: "The profile folder could not be created.")) }
                return
            }
            DispatchQueue.main.async {
                self?.markTask(upTo: 1)
                Settings.shared.setTint(hex, forFolder: created.folder)
                self?.profile = created
                self?.onProfilesChanged?()
            }
            var launcherFailed = false
            if makeLauncher {
                do {
                    let url = try Self.buildLauncher(name: name, hex: hex)
                    DispatchQueue.main.async { self?.launcherURL = url }
                } catch {
                    Log.write("Launcher could not be created.")
                    launcherFailed = true
                }
                DispatchQueue.main.async { self?.markTask(upTo: 2) }
            }
            DispatchQueue.main.async {
                ClaudeInstances.open(profile: created) { error in
                    if error != nil {
                        Log.write("Claude could not be opened for a new profile.")
                        self?.show(.failed(title: "Claude could not be opened", message: "The profile is ready in your bar."))
                    } else {
                        self?.show(launcherFailed ? .launcherFailed : .signIn)
                    }
                    self?.onProfilesChanged?()
                }
            }
        }
    }

    private static func buildLauncher(name: String, hex: String) throws -> URL {
        try Monogram.withIcon(letter: Monogram.letter(for: name), hex: hex) { icon in
            try ClaudeLauncher.build(name: name, icon: icon)
        }
    }

    private func retryLauncher() {
        let name = self.name
        let hex = ProfileTint.all[tintIndex].hex
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let url = try? Self.buildLauncher(name: name, hex: hex)
            DispatchQueue.main.async {
                self?.launcherURL = url
                self?.show(url == nil ? .launcherFailed : .signIn)
            }
        }
    }

    private func revealLauncher() {
        if let url = launcherURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
