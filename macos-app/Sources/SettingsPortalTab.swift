import Cocoa

struct PortalSave {
    let typedPassword: String?
    // The Login URL and marker are on this tab, so they changed only if it was shown.
    let shown: Bool
    let loginURL: String
    let marker: String
}

// The password loads only when this tab shows, so opening Settings costs no Keychain prompt.
final class SettingsPortalTab: NSObject, NSTextFieldDelegate {
    var onResize: (() -> Void)?
    var runDiagnostics: ((_ loginURL: String, _ marker: String, @escaping ([String]) -> Void) -> Void)?
    var runDetect: ((@escaping (PortalDetection) -> Void) -> Void)?

    private let autoLoginCheck = SettingsUI.check("Auto-Login")
    private let usernameField = SettingsUI.field("username")
    private let passwordField = SettingsUI.small(NSSecureTextField())
    private let passwordPlainField = SettingsUI.small(NSTextField())
    private let revealButton = NSButton()
    private var passwordRevealed = false
    private var passwordEdited = false
    private(set) var passwordLoaded = false
    private let loginURLField = SettingsUI.field("http://<portal-host>/login")
    private lazy var detectButton = SettingsUI.button("Detect") { [weak self] in self?.detect() }
    private let detectResult = SettingsUI.note(width: SettingsUI.fieldWidth + 60)
    private let pollPopup = SettingsUI.popup([])
    private let pollNote = UI.label("", size: 11, color: .secondaryLabelColor)
    private let extraField = SettingsUI.field("e.g. dst=, popup=true")
    private let markerField = SettingsUI.field("text only your portal's page shows")
    private let advancedToggle = SettingsUI.check("Show advanced portal options (rarely needed)")
    private var advancedBox = NSView()
    private let diagnoseResult = SettingsUI.note()
    private var pollOptions: [Int] = []
    private var detectRow: NSGridRow?
    private(set) lazy var view: NSView = build()

    private func build() -> NSView {
        detectButton.toolTip = "Reads this network's login page; sends nothing"
        detectResult.isHidden = true
        pollPopup.target = self
        pollPopup.action = #selector(pollChanged)
        let urlRow = UI.row([loginURLField, detectButton], spacing: 6)
        let primary = SettingsUI.grid([
            [NSGridCell.emptyContentView, autoLoginCheck],
            [SettingsUI.formLabel("Username:"), usernameField],
            [SettingsUI.formLabel("Password:"), passwordCell()],
            [SettingsUI.formLabel("Login URL:"), urlRow],
            [NSGridCell.emptyContentView, detectResult],
            [SettingsUI.formLabel("Check every:"), UI.row([pollPopup, pollNote], spacing: 8)],
        ])

        // A hidden view keeps its grid row, so the row hides until Detect has something to say.
        detectRow = primary.row(at: 4)
        detectRow?.isHidden = true

        let note = SettingsUI.note("Credentials go only to the Login URL's host, or to the Wi-Fi gateway once the marker matches.")

        advancedToggle.target = self
        advancedToggle.action = #selector(toggleAdvanced)
        let caption = SettingsUI.note("Extra fields apply only when the page has no login form the app can read.")
        let advancedGrid = SettingsUI.grid([
            [SettingsUI.formLabel("Extra form fields:"), extraField],
            [SettingsUI.formLabel("Portal marker:"), markerField],
        ])
        let advanced = UI.column([caption, advancedGrid], spacing: 6)
        advanced.isHidden = true
        advancedBox = advanced

        let diagnose = SettingsUI.button("Diagnose") { [weak self] in self?.diagnose() }
        let diagnoseNote = UI.label("Checks the portal without sending anything", size: 11, color: .secondaryLabelColor)
        diagnoseResult.isHidden = true
        return SettingsUI.column([primary, note, advancedToggle, advanced, UI.row([diagnose, diagnoseNote], spacing: 8), diagnoseResult])
    }

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
        revealButton.image = eyeImage(revealed: false)
        revealButton.isBordered = false
        revealButton.imagePosition = .imageOnly
        revealButton.setButtonType(.momentaryChange)
        revealButton.target = self
        revealButton.action = #selector(togglePasswordReveal)
        revealButton.toolTip = "Show or hide password"
        UI.fix(revealButton, width: 18)
        UI.fix(holder, width: SettingsUI.fieldWidth)
        return UI.row([holder, revealButton], spacing: 4)
    }

    private func eyeImage(revealed: Bool) -> NSImage? {
        UI.symbol(revealed ? "eye.slash" : "eye", size: 11, description: revealed ? "Hide password" : "Show password")
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

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === passwordField || field === passwordPlainField else { return }
        passwordEdited = true
    }

    @objc private func toggleAdvanced() {
        advancedBox.isHidden = advancedToggle.state != .on
        onResize?()
    }

    @objc private func pollChanged() {
        let seconds = pollOptions[safe: pollPopup.indexOfSelectedItem] ?? Settings.shared.pollInterval
        let connected = Int(PortalSchedule.interval(setting: seconds, connected: true))
        pollNote.stringValue = connected == seconds ? "Also while connected" : "\(connected) s once connected"
    }

    private func diagnose() {
        diagnoseResult.stringValue = "Checking…"
        diagnoseResult.isHidden = false
        onResize?()
        runDiagnostics?(loginURLField.stringValue, markerField.stringValue) { [weak self] lines in
            DispatchQueue.main.async {
                self?.diagnoseResult.stringValue = lines.joined(separator: "\n")
                self?.onResize?()
            }
        }
    }

    // Fills the fields only; nothing is saved until Save.
    func detect() {
        _ = view
        detectButton.isEnabled = false
        detectResult.textColor = .secondaryLabelColor
        detectResult.stringValue = "Looking for this network's login page…"
        detectResult.isHidden = false
        detectRow?.isHidden = false
        onResize?()
        runDetect? { [weak self] detection in
            DispatchQueue.main.async { self?.showDetection(detection) }
        }
    }

    private func showDetection(_ detection: PortalDetection) {
        detectButton.isEnabled = true
        detectResult.stringValue = detection.message
        detectResult.textColor = detection.outcome == .found ? UI.ok : .secondaryLabelColor
        if detection.outcome == .found, let loginURL = detection.loginURL {
            let saved = URL(string: loginURLField.stringValue.trimmingCharacters(in: .whitespaces))?.host?.lowercased()
            loginURLField.stringValue = loginURL
            // A new portal must never get the old one's password, so it has to be typed again.
            if saved != detection.host?.lowercased() {
                markerField.stringValue = detection.marker ?? ""
                passwordField.stringValue = ""
                passwordPlainField.stringValue = ""
                passwordEdited = true
            }
            if !markerField.stringValue.isEmpty {
                advancedToggle.state = .on
                advancedBox.isHidden = false
            }
            usernameField.window?.makeFirstResponder(usernameField.stringValue.isEmpty ? usernameField : passwordField)
        }
        onResize?()
    }

    func load() {
        _ = view
        let s = Settings.shared
        autoLoginCheck.state = s.autoLoginEnabled ? .on : .off
        pollOptions = Array(Set(PortalSchedule.options + [s.pollInterval])).sorted()
        pollPopup.removeAllItems()
        pollPopup.addItems(withTitles: pollOptions.map { $0 == 1 ? "1 second" : "\($0) seconds" })
        pollPopup.selectItem(at: pollOptions.firstIndex(of: s.pollInterval) ?? 0)
        pollChanged()
        loginURLField.stringValue = s.loginURL
        usernameField.stringValue = s.username
        extraField.stringValue = s.extraFields.replacingOccurrences(of: "\n", with: ", ")
        markerField.stringValue = s.portalMarker
        advancedToggle.state = .off
        advancedBox.isHidden = true
        diagnoseResult.isHidden = true
        detectResult.isHidden = true
        detectRow?.isHidden = true
        detectButton.isEnabled = true
        passwordRevealed = false
        passwordLoaded = false
        passwordField.isHidden = false
        passwordPlainField.isHidden = true
        revealButton.image = eyeImage(revealed: false)
    }

    func loadPasswordAsync() {
        guard !passwordLoaded else { return }
        passwordLoaded = true
        passwordEdited = false
        passwordField.stringValue = ""
        passwordPlainField.stringValue = ""
        passwordField.placeholderString = "Loading…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stored = Settings.shared.portalSecret?.password ?? ""
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

    func save(to s: Settings) -> PortalSave {
        s.autoLoginEnabled = autoLoginCheck.state == .on
        s.pollInterval = pollOptions[safe: pollPopup.indexOfSelectedItem] ?? s.pollInterval
        let loginURL = loginURLField.stringValue.trimmingCharacters(in: .whitespaces)
        let marker = markerField.stringValue.trimmingCharacters(in: .whitespaces)
        s.loginURL = loginURL
        s.username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)
        s.extraFields = extraField.stringValue
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        s.portalMarker = marker
        return PortalSave(typedPassword: passwordEdited ? enteredPassword : nil, shown: passwordLoaded, loginURL: loginURL, marker: marker)
    }

    // Closing must leave no plaintext password in the fields.
    func clearPassword() {
        passwordField.stringValue = ""
        passwordPlainField.stringValue = ""
        passwordEdited = false
        passwordRevealed = false
        passwordLoaded = false
        passwordField.isHidden = false
        passwordPlainField.isHidden = true
        revealButton.image = eyeImage(revealed: false)
    }
}
