import Foundation

enum PortalDiagnostics {
    private static let chapMarkers = ["chap-id", "chap-challenge", "hexmd5("]

    static func usesChap(html: String) -> Bool {
        let lower = html.lowercased()
        return chapMarkers.contains { lower.contains($0) }
    }

    static func report(connected: Bool, page: CaptivePage?, marker: String, hostKind: String, ownAddresses: [String]) -> [String] {
        var lines = [connected ? "Internet: reachable." : "Internet: not reachable."]
        guard let page = page else {
            lines.append("Portal page: no answer.")
            return lines
        }
        if page.status == 511 {
            lines.append("Portal page: HTTP 511, the network requires sign-in.")
        } else {
            lines.append("Portal page: HTTP \(page.status.map(String.init) ?? "?"), \(page.hops) redirect(s), host is \(hostKind).")
        }
        if page.overWiFi == false {
            lines.append("Link: this page did not arrive over Wi-Fi, so the app will not sign in to it.")
        }
        lines.append(page.form == nil ? "Login form: not found." : "Login form: found.")
        let trimmed = marker.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            lines.append("Portal marker: not set.")
        } else if !PortalMarker.isUsable(trimmed, ownAddresses: ownAddresses) {
            lines.append("Portal marker: ignored, it matches this app's own addresses. Use text only your portal's page shows.")
        } else {
            let found = PortalMarker.matches(page: page, marker: trimmed, ownAddresses: ownAddresses)
            lines.append(found ? "Portal marker: found." : "Portal marker: not found on this page.")
        }
        if usesChap(html: page.html) {
            lines.append("CHAP: this portal may hash the password, which is not supported.")
        }
        return lines
    }
}

struct PortalDetection: Equatable {
    enum Outcome: Equatable { case found, online, noPage, noForm, notWiFi, ownAddress }

    let outcome: Outcome
    var loginURL: String?
    var marker: String?
    var host: String?

    var message: String {
        switch outcome {
        case .found:   return "Found the login page at \(host ?? "this network"). Check the address, type your sign-in, then Save."
        case .online:  return "This network is online, so no login page shows. Run Detect while signed out of the Wi-Fi."
        case .noPage:  return "No login page answered on this network. Nothing was changed."
        case .noForm:  return "A page answered, but it has no login form this app can read. Nothing was changed."
        case .notWiFi: return "That page did not come over Wi-Fi, so it is not this Wi-Fi's login page. Nothing was changed."
        case .ownAddress: return "The form posts to the router or Apple's check page, which any network can answer. Set a portal marker instead."
        }
    }
}

// Read-only setup help: it names where the form posts and never sends or reads a password.
enum PortalDetect {
    static func result(connected: Bool, page: CaptivePage?, ownAddresses: [String]) -> PortalDetection {
        if connected { return PortalDetection(outcome: .online) }
        guard let page = page else { return PortalDetection(outcome: .noPage) }
        guard page.overWiFi != false else { return PortalDetection(outcome: .notWiFi) }
        guard let form = page.form, let target = PortalClient.resolve(action: form.action, base: page.url),
              RedirectPolicy.allows(target), let host = target.host else { return PortalDetection(outcome: .noForm) }
        // Any network can answer on these names, so they would send the password to whoever is there.
        let ownHosts = ownAddresses.compactMap { URL(string: $0)?.host?.lowercased() }
        guard !ownHosts.contains(host.lowercased()) else { return PortalDetection(outcome: .ownAddress) }
        return PortalDetection(outcome: .found, loginURL: target.absoluteString, marker: marker(for: page, ownAddresses: ownAddresses), host: host)
    }

    // Only a name the portal redirected to; an address or one of the app's own names proves nothing.
    static func marker(for page: CaptivePage, ownAddresses: [String]) -> String? {
        guard page.hops > 0, let host = page.url?.host?.lowercased(), host.contains(where: \.isLetter), !host.contains(":"),
              !LoopbackHost.matches(host), PortalMarker.isUsable(host, ownAddresses: ownAddresses) else { return nil }
        return host
    }
}
