import Cocoa
import SystemConfiguration

// Asks macOS to connect or disconnect; each VPN app keeps its own profiles and passwords.
final class VPNController {
    var onChange: (() -> Void)?
    var onDropped: ((VPNService) -> Void)?

    private static let connectTimeout: TimeInterval = 45
    private static let scutil = "/usr/sbin/scutil"
    private static let maxListBytes = 65_536
    private(set) var services: [VPNService] = []
    private var links: [String: VPNLink] = [:]
    private var connectedSince: [String: Date] = [:]
    private var failed: Set<String> = []
    private var stoppedHere: Set<String> = []
    // Seen up since launch, including at the first listing, unlike connectedSince.
    private var seenUp: Set<String> = []
    private var deadlines: [String: DispatchWorkItem] = [:]
    private var listing = false

    func rows(now: Date) -> [VPNPanelRow] {
        VPNServiceList.visible(services, hidden: Settings.shared.hiddenVPNs).map {
            VPNPanelRow(id: $0.id, name: $0.name,
                        model: VPNRowModel.make($0, connectedSince: connectedSince[$0.id], failed: failed.contains($0.id), now: now))
        }
    }

    // At launch, panel open, wake and Save; status changes in between arrive as events.
    func refresh() {
        if AppMode.isDemo {
            services = DemoData.vpnServices
            connectedSince = [services[0].id: Date().addingTimeInterval(-4300)]
            onChange?()
            return
        }
        guard !listing else { return }
        listing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let output = LocalCommand.output(Self.scutil, ["--nc", "list"], timeout: 5)
            let listed = output.map { VPNServiceList.parse(String(decoding: $0.prefix(Self.maxListBytes), as: UTF8.self)) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.listing = false
                // A slow or failed listing, common after a wake, says nothing; the last list stays.
                guard let listed = listed else { return }
                self.apply(listed)
            }
        }
    }

    func perform(id: String) {
        guard !AppMode.isDemo, let index = services.firstIndex(where: { $0.id == id }) else { return }
        let service = services[index]
        switch VPNRowModel.make(service, connectedSince: nil, failed: failed.contains(id), now: Date()).action {
        case .connect:    connect(index)
        case .disconnect: disconnect(index)
        case .openApp:    openApp(for: service)
        case .wait:       break
        }
    }

    // MARK: - Private

    private func apply(_ listed: [VPNService]) {
        let ids = Set(listed.map(\.id))
        // A profile removed from its VPN app while the bar runs stops being watched.
        for (id, link) in links where !ids.contains(id) {
            link.stop()
            links[id] = nil
            deadlines.removeValue(forKey: id)?.cancel()
            connectedSince[id] = nil
            failed.remove(id)
            seenUp.remove(id)
            stoppedHere.remove(id)
        }
        // The listed state is used as is: asking each connection again can block the main thread.
        services = listed
        for service in listed {
            if links[service.id] == nil { links[service.id] = VPNLink(id: service.id, owner: self) }
            if service.status == .connected {
                failed.remove(service.id)
                seenUp.insert(service.id)
            } else {
                connectedSince[service.id] = nil
                seenUp.remove(service.id)
            }
        }
        onChange?()
    }

    fileprivate func statusChanged(id: String, to status: VPNStatus) {
        guard let index = services.firstIndex(where: { $0.id == id }) else { return }
        services[index].status = status
        switch status {
        case .connected:
            // Kept through a reassert, so the age counts from the first connect the bar saw.
            if connectedSince[id] == nil { connectedSince[id] = Date() }
            seenUp.insert(id)
            stoppedHere.remove(id)
            deadlines.removeValue(forKey: id)?.cancel()
            failed.remove(id)
        case .off, .invalid:
            // Up until now and not stopped from the panel: it dropped, or was stopped in its own app.
            let wasUp = seenUp.remove(id) != nil, stoppedByUs = stoppedHere.remove(id) != nil
            if wasUp, !stoppedByUs { onDropped?(services[index]) }
            connectedSince[id] = nil
            // Dropping back during an awaited connect fails it now, not at the timeout.
            if deadlines.removeValue(forKey: id) != nil { fail(id) }
        case .connecting, .disconnecting:
            break
        }
        onChange?()
    }

    private func connect(_ index: Int) {
        let id = services[index].id
        failed.remove(id)
        services[index].status = .connecting
        let started = links[id]?.start() ?? false
        if !started { Self.runScutil(["--nc", "start", id]) }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self = self, self.deadlines.removeValue(forKey: id) != nil,
                  self.services.first(where: { $0.id == id })?.status != .connected else { return }
            self.fail(id)
            self.onChange?()
        }
        deadlines.removeValue(forKey: id)?.cancel()
        deadlines[id] = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout, execute: deadline)
        onChange?()
    }

    private func disconnect(_ index: Int) {
        let id = services[index].id
        deadlines.removeValue(forKey: id)?.cancel()
        stoppedHere.insert(id)
        services[index].status = .disconnecting
        let stopped = links[id]?.disconnect() ?? false
        if !stopped { Self.runScutil(["--nc", "stop", id]) }
        onChange?()
    }

    private func fail(_ id: String) {
        failed.insert(id)
        Log.write("A VPN did not connect; its own app may need a sign-in.")
    }

    private func openApp(for service: VPNService) {
        failed.remove(service.id)
        onChange?()
        if let url = Self.appURL(for: service.provider) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            return
        }
        if let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.openApplication(at: settings, configuration: .init())
        }
    }

    // The VPN app's own name, for the Settings row; a system VPN has none.
    static func appName(for provider: String?) -> String {
        appURL(for: provider).map { $0.deletingPathExtension().lastPathComponent } ?? "macOS VPN"
    }

    // A VPN extension's ID starts with its app's ID, so trimming parts finds the app.
    private static func appURL(for provider: String?) -> URL? {
        var parts = (provider ?? "").split(separator: ".").map(String.init)
        while parts.count >= 2 {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: ".")) { return url }
            parts.removeLast()
        }
        return nil
    }

    private static func runScutil(_ arguments: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = LocalCommand.output(scutil, arguments, timeout: 5)
        }
    }
}

// One macOS connection per listed service; its events come back on the main run loop.
private final class VPNLink {
    let id: String
    private weak var owner: VPNController?
    private var connection: SCNetworkConnection?

    init(id: String, owner: VPNController) {
        self.id = id
        self.owner = owner
        var context = SCNetworkConnectionContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                                 retain: nil, release: nil, copyDescription: nil)
        connection = SCNetworkConnectionCreateWithServiceID(nil, id as CFString, { _, status, info in
            guard let info = info else { return }
            let link = Unmanaged<VPNLink>.fromOpaque(info).takeUnretainedValue()
            link.owner?.statusChanged(id: link.id, to: VPNLink.status(status))
        }, &context)
        if let connection = connection {
            SCNetworkConnectionScheduleWithRunLoop(connection, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
    }

    // Lingers, so the VPN stays up when the bar quits or stops watching it.
    func start() -> Bool {
        connection.map { SCNetworkConnectionStart($0, nil, true) } ?? false
    }

    // Forced, since the VPN's own app also holds the connection and a click means off.
    func disconnect() -> Bool {
        connection.map { SCNetworkConnectionStop($0, true) } ?? false
    }

    // Unscheduled before release, so no event can reach a link that is gone.
    func stop() {
        if let connection = connection {
            SCNetworkConnectionUnscheduleFromRunLoop(connection, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
        connection = nil
    }

    deinit { stop() }

    static func status(_ status: SCNetworkConnectionStatus) -> VPNStatus {
        switch status {
        case .connected:     return .connected
        case .connecting:    return .connecting
        case .disconnecting: return .disconnecting
        case .invalid:       return .invalid
        default:             return .off
        }
    }
}
