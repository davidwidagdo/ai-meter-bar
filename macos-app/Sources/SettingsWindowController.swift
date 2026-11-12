import Cocoa

enum SettingsTab: String, CaseIterable {
    case claude, display, portal, general

    var title: String { rawValue.capitalized }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    private let claude = SettingsClaudeTab()
    private let display = SettingsDisplayTab()
    private let portal = SettingsPortalTab()
    private let general = SettingsGeneralTab()
    private let tabView = NSTabView()
    private static let padding: CGFloat = 12

    var onSave: (() -> Void)?
    var onSaveStarted: (() -> Void)?
    var onClose: (() -> Void)?
    var setLoginItem: (Bool) -> Void = { _ in }
    var onNotifyEnabled: (() -> Void)?
    var isLoginItemEnabled: () -> Bool {
        get { general.isLoginItemEnabled }
        set { general.isLoginItemEnabled = newValue }
    }
    var onNewProfile: (() -> Void)? {
        get { claude.onNewProfile }
        set { claude.onNewProfile = newValue }
    }
    var onProfilesChanged: (() -> Void)? {
        get { claude.onProfilesChanged }
        set { claude.onProfilesChanged = newValue }
    }
    var onOpenUsageHistory: (() -> Void)? {
        get { general.onOpenUsageHistory }
        set { general.onOpenUsageHistory = newValue }
    }
    var vpnServices: () -> [VPNService] {
        get { display.vpnServices }
        set { display.vpnServices = newValue }
    }
    var runDiagnostics: ((_ loginURL: String, _ marker: String, @escaping ([String]) -> Void) -> Void)? {
        get { portal.runDiagnostics }
        set { portal.runDiagnostics = newValue }
    }
    var runDetect: ((@escaping (PortalDetection) -> Void) -> Void)? {
        get { portal.runDetect }
        set { portal.runDetect = newValue }
    }

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AI Meter Bar Settings"
        self.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        buildUI()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let resize = { [weak self] in
            guard self?.window?.isVisible == true else { return }
            self?.fitWindowToCurrentContent()
        }
        claude.onResize = resize
        portal.onResize = resize

        tabView.delegate = self
        tabView.controlSize = .small
        tabView.font = .systemFont(ofSize: SettingsUI.textSize)
        tabView.translatesAutoresizingMaskIntoConstraints = false
        let views: [SettingsTab: NSView] = [.claude: claude.view, .display: display.view, .portal: portal.view, .general: general.view]
        for tab in SettingsTab.allCases {
            if let view = views[tab] { tabView.addTabViewItem(item(tab, view: view)) }
        }

        let cancel = SettingsUI.button("Cancel") { [weak self] in self?.window?.close() }
        cancel.keyEquivalent = "\u{1b}"
        let save = SettingsUI.button("Save") { [weak self] in self?.save() }
        save.keyEquivalent = "\r"
        let buttons = UI.row([cancel, save], spacing: 8)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let actionBar = GlassPanel.wrap(buttons, cornerRadius: 12, padding: 5)

        content.addSubview(tabView)
        content.addSubview(actionBar)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            actionBar.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 8),
            actionBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            actionBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    // Every tab has the same fixed width, so the window only changes height between tabs.
    private func item(_ tab: SettingsTab, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: tab.rawValue)
        item.label = tab.title
        let container = NSView()
        container.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.padding),
            view.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -Self.padding),
            view.widthAnchor.constraint(equalToConstant: SettingsUI.width),
        ])
        item.view = container
        return item
    }

    // NSTabView lays out only the selected tab, so the window fits it, keeping its top edge.
    private func fitWindowToCurrentContent(animate: Bool = true) {
        guard let window = window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard size.height > 0, abs(size.height - content.frame.height) > 0.5 || abs(size.width - content.frame.width) > 0.5 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        fitWindowToCurrentContent()
        if tabViewItem?.identifier as? String == SettingsTab.portal.rawValue { portal.loadPasswordAsync() }
    }

    private func load() {
        claude.load()
        display.load()
        portal.load()
        general.load()
        fitWindowToCurrentContent(animate: false)
        if tabView.selectedTabViewItem?.identifier as? String == SettingsTab.portal.rawValue { portal.loadPasswordAsync() }
    }

    private func save() {
        // Clicking Save with the mouse doesn't end editing on the focused field, so commit it first.
        window?.makeFirstResponder(nil)
        // Until the Keychain item is rewritten below, the new values and its binding disagree.
        onSaveStarted?()
        let s = Settings.shared
        let notifyWasOn = s.notifyAttention
        claude.save(to: s)
        display.save(to: s)
        general.save(to: s)
        let portalSave = portal.save(to: s)
        setLoginItem(general.startAtLogin)
        if s.notifyAttention, !notifyWasOn { onNotifyEnabled?() }

        // Keychain work runs off main; onSave is held since closing meanwhile releases this window.
        let onSave = self.onSave
        let finish = { [weak self] in
            onSave?()
            self?.window?.close()
        }
        guard !AppMode.isDemo, portalSave.typedPassword != nil || portalSave.shown else {
            finish()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // Rewritten when the password or its destination changed, so the two stay bound.
            if let next = PortalSecret.forSave(typed: portalSave.typedPassword, stored: Keychain.secret(),
                                               loginURL: portalSave.loginURL, marker: portalSave.marker) {
                Keychain.save(next)
            }
            DispatchQueue.main.async(execute: finish)
        }
    }

    func windowWillClose(_ notification: Notification) {
        portal.clearPassword()
        onClose?()
    }

    func present(tab: SettingsTab? = nil, detect: Bool = false) {
        // Bringing an open window forward must keep what was typed but not saved yet.
        if window?.isVisible != true {
            load()
            window?.center()
        }
        if let tab = tab { tabView.selectTabViewItem(withIdentifier: tab.rawValue) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if detect { portal.detect() }
    }

    func refreshProfiles() {
        guard window?.isVisible == true else { return }
        claude.rebuild()
    }
}
