import Foundation

struct FormField {
    let name: String
    let type: String
    var value: String
}

// A login form parsed out of a captive-portal page.
struct LoginForm {
    let action: String   // raw action attribute (may be relative or empty)
    var fields: [FormField]

    // Hidden fields (tokens, dst, popup) stay as the portal sent them.
    func filled(username: String, password: String) -> [(String, String)] {
        var result = fields
        for i in result.indices where result[i].type == "password" {
            result[i].value = password
        }
        if let idx = result.firstIndex(where: { ["text", "email", "tel"].contains($0.type) }) {
            result[idx].value = username
        }
        return result.map { ($0.name, $0.value) }
    }
}

// Fetched once and reused for the gating decision and the login submit.
struct CaptivePage {
    static let maxBytes = 1_000_000

    let url: URL?
    let html: String
    let hops: Int
    let status: Int?
    let gateway: String?
    let marker: String
    // Set only with a marker, when the gateway's own page led here, so the POST goes the same way.
    let route: String?
    // false when the page came over another link, such as a VPN; nil when that is unknown.
    let overWiFi: Bool?
    // Parsed where the page is fetched, so a hostile page cannot stall the main thread.
    let form: LoginForm?
    let isLoggedIn: Bool

    init(url: URL?, html: String, hops: Int = 0, status: Int? = nil, gateway: String? = nil, marker: String = "", route: String? = nil,
         overWiFi: Bool? = nil) {
        self.url = url
        self.html = html
        self.hops = hops
        self.status = status
        self.gateway = gateway
        self.marker = marker
        self.route = route
        self.overWiFi = overWiFi
        form = LoginFormParser.parse(html: html)
        isLoggedIn = LoginFormParser.isSessionPage(html: html)
    }

    // Logged on rejection: shape only, never the page body, host or path, which can name a site.
    func summary(hostKind: String) -> String {
        let depth = max(0, (url?.pathComponents.count ?? 1) - 1)
        return "path depth \(depth), \(html.utf8.count) bytes, \(form == nil ? "no form" : "form"), "
            + "\(hops) redirect(s) followed, host=\(hostKind)"
    }
}

// A VPN can own system DNS and hide the portal's name; the Wi-Fi gateway stays on-link.
enum PortalRoute {
    static func url(_ url: URL, portalHost: String?, gateway: String?) -> URL {
        // TLS checks the address in the URL, so only plain http can be sent by way of the gateway.
        guard url.scheme?.lowercased() == "http", let gateway = gateway, let portalHost = portalHost,
              url.host?.caseInsensitiveCompare(portalHost) == .orderedSame,
              let target = URL(string: "http://\(gateway)"),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        parts.host = target.host
        return parts.url ?? url
    }
}

// Judged on the addresses a connection really used, since a name can point anywhere.
enum PageOrigin {
    static func bare(_ address: String) -> String {
        var text = String(address.split(separator: "%").first ?? "").lowercased()
        if text.hasPrefix("::ffff:"), text.dropFirst(7).contains(".") { text = String(text.dropFirst(7)) }
        return text
    }

    // A page this Mac served itself is no portal, whatever name led to it.
    static func isThisMac(remote: String?, ownAddresses: Set<String>) -> Bool {
        guard let remote = remote.map(bare), !remote.isEmpty else { return false }
        return LoopbackHost.matches(remote) || ownAddresses.contains(remote)
    }

    // nil when either side is unknown, which must not block a sign-in.
    static func cameOverWiFi(local: String?, wifiAddresses: Set<String>?) -> Bool? {
        guard let local = local.map(bare), !local.isEmpty, let wifi = wifiAddresses, !wifi.isEmpty else { return nil }
        return wifi.contains(local)
    }
}

// Filters honest networks only: whoever answers chooses the page, so it is not proof.
enum PortalMarker {
    // The app chose these addresses and portals echo them, so a match on them proves nothing.
    static func isUsable(_ marker: String, ownAddresses: [String]) -> Bool {
        !ownAddresses.contains { $0.localizedCaseInsensitiveContains(marker) }
    }

    static func matches(page: CaptivePage, marker: String, ownAddresses: [String]) -> Bool {
        guard isUsable(marker, ownAddresses: ownAddresses) else { return false }
        let host = page.hops > 0 ? (page.url?.host ?? "") : ""
        return host.localizedCaseInsensitiveContains(marker) || page.html.localizedCaseInsensitiveContains(marker)
    }
}

// A page chooses these targets, so local files and this Mac's services stay out of reach.
enum RedirectPolicy {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return !LoopbackHost.matches(host)
    }
}

// Host text only: a name that resolves to this Mac cannot be seen from here.
enum LoopbackHost {
    static func matches(_ host: String) -> Bool {
        var name = host.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" || name.hasSuffix(".localhost") || name.contains("%") { return true }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, name, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            guard bytes[0..<10].allSatisfy({ $0 == 0 }) else { return false }
            return (bytes[10] == 0xff && bytes[11] == 0xff) || (bytes[10] == 0 && bytes[11] == 0)
        }
        var address = in_addr()
        guard inet_aton(name, &address) != 0 else { return false }
        let first = UInt32(bigEndian: address.s_addr) >> 24
        return first == 127 || first == 0
    }
}

// Credentials go only to the configured portal, or to the gateway once a marker matched there.
enum PostGuard {
    // A nil target is a form nobody could read, which must not fall back to the Login URL.
    static func allows(target: URL?, portal: URL?, gateway: String?, markerSet: Bool) -> Bool {
        guard let target = target, let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = target.host?.lowercased(), !LoopbackHost.matches(host) else { return false }
        if let portal = portal, portal.host?.lowercased() == host, sameService(target, portal) { return true }
        // TLS cannot validate on a bare gateway address, so an https portal never goes that way.
        if markerSet, host == gateway?.lowercased(), portal?.scheme?.lowercased() != "https" { return true }
        return false
    }

    // A page may upgrade the configured portal to https, but never drop TLS or change the port.
    private static func sameService(_ target: URL, _ portal: URL) -> Bool {
        let scheme = target.scheme?.lowercased(), configured = portal.scheme?.lowercased()
        if scheme == configured { return port(of: target) == port(of: portal) }
        return configured == "http" && scheme == "https" && target.port == nil
    }

    private static func port(of url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }

    // A Keychain prompt can outlast a Wi-Fi change, and the marker matched only on the old gateway.
    static func gatewayHolds(proven: String?, current: String?, markerSet: Bool) -> Bool {
        !markerSet || proven == current
    }

    static func hostKind(_ url: URL?, portalHost: String?, gateway: String?) -> String {
        guard let host = url?.host?.lowercased() else { return "other" }
        if host == portalHost?.lowercased() { return "portal" }
        if host == gateway?.lowercased() { return "gateway" }
        return "other"
    }
}

// Handles plain form markup only; JS-rendered portals fall back to the configured Login URL.
enum LoginFormParser {
    // Returns the first <form> that contains a password input.
    static func parse(html: String) -> LoginForm? {
        guard let closed = upToLast("</form>", in: html) else { return nil }
        for form in regexMatches("(?is)<form\\b.*?</form>", closed) {
            let inputs = parseInputs(form)
            guard inputs.contains(where: { $0.type == "password" }) else { continue }
            let openTag = regexMatches("(?is)<form\\b[^>]*>", form).first ?? ""
            let action = attribute("action", in: openTag) ?? ""
            return LoginForm(action: action, fields: inputs)
        }
        return nil
    }

    // A logged-in client gets the status page: no password form, a logout link.
    static func isSessionPage(html: String) -> Bool {
        parse(html: html) == nil && html.range(of: "/logout", options: .caseInsensitive) != nil
    }

    // A page with no login form may be a redirect page (meta refresh or JS location).
    static func redirectURL(html: String, base: URL?) -> URL? {
        guard parse(html: html) == nil, !isSessionPage(html: html),
              let raw = metaRefreshTarget(html) ?? scriptLocationTarget(html),
              !raw.contains("$(") else { return nil }
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }

    // An opener with no closer rescans to the end, which is quadratic on a hostile page.
    private static func upToLast(_ closer: String, in html: String) -> String? {
        html.range(of: closer, options: [.caseInsensitive, .backwards]).map { String(html[..<$0.upperBound]) }
    }

    private static func metaRefreshTarget(_ html: String) -> String? {
        for tag in regexMatches("(?is)<meta\\b[^>]*>", upToLast(">", in: html) ?? "") {
            guard attribute("http-equiv", in: tag)?.lowercased() == "refresh",
                  let content = attribute("content", in: tag),
                  let url = firstCapture("(?i)url\\s*=\\s*['\"]?([^'\"]+)", content) else { continue }
            return url.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func scriptLocationTarget(_ html: String) -> String? {
        let quoted = "\\s*(?:unescape\\(\\s*)?['\"]([^'\"]+)['\"]"
        guard let raw = firstCapture("(?i)\\blocation(?:\\.href)?\\s*=" + quoted, html)
            ?? firstCapture("(?i)\\blocation\\.replace\\(" + quoted, html) else { return nil }
        // MikroTik writes unescape('http%3A%2F%2F...'), a fully percent-encoded URL.
        return raw.contains("://") ? raw : (raw.removingPercentEncoding ?? raw)
    }

    private static func parseInputs(_ formHTML: String) -> [FormField] {
        var fields: [FormField] = []
        for tag in regexMatches("(?is)<input\\b[^>]*>", formHTML) {
            guard let name = attribute("name", in: tag), !name.isEmpty else { continue }
            let type = (attribute("type", in: tag) ?? "text").lowercased()
            let value = attribute("value", in: tag) ?? ""
            fields.append(FormField(name: name, type: type, value: value))
        }
        return fields
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        // Not after a hyphen, so data-type="x" is never read as type.
        let key = "(?i)(?<![\\w-])\(name)\\s*=\\s*"
        let raw = firstCapture(key + "\"([^\"]*)\"", tag)
            ?? firstCapture(key + "'([^']*)'", tag)
            ?? firstCapture(key + "([^\\s\"'=<>`]+)", tag)
        return raw.map(decodeEntities)
    }

    private static func decodeEntities(_ s: String) -> String {
        var r = s
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x2F;": "/", "&#47;": "/"] {
            r = r.replacingOccurrences(of: k, with: v)
        }
        return r
    }

    private static func regexMatches(_ pattern: String, _ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func firstCapture(_ pattern: String, _ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
