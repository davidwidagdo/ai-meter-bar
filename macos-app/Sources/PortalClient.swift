import Foundation
import Network
import SystemConfiguration

enum ConnState {
    case connected   // real internet access
    case captured    // behind the portal / offline
}

enum LoginSubmit: Equatable {
    case sent, refused, noPassword, failed
}

struct NetworkSignature: Equatable {
    let wifiInterface: String?
    let router: String?
}

// Connectivity detection + captive-portal login.
final class PortalClient {
    private static let maxRedirectHops = 3
    private let probeURL: URL
    private let successMarker = "<TITLE>Success</TITLE>"
    private let wifiPath = NWPathMonitor(requiredInterfaceType: .wifi)
    private let wifiQueue = DispatchQueue(label: "com.davidwidagdo.aimeterbar.wifi-path")
    private var wifiInterface: String?

    init(probeURL: URL = URL(string: "http://captive.apple.com/hotspot-detect.html")!) {
        self.probeURL = probeURL
        wifiPath.pathUpdateHandler = { [weak self] path in
            self?.wifiInterface = path.availableInterfaces.first { $0.type == .wifi }?.name
        }
        wifiPath.start(queue: wifiQueue)
    }

    // NWPath.gateways reports the VPN's gateway; the Wi-Fi router comes from the per-service state.
    private var wifiGateway: String? {
        wifiQueue.sync(execute: { wifiInterface }).flatMap(router(forInterface:))
    }

    private func router(forInterface name: String) -> String? {
        guard let store = SCDynamicStoreCreate(nil, "AIMeterBar" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String]
        else { return nil }
        for key in keys {
            guard let state = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  state["InterfaceName"] as? String == name else { continue }
            return (state["Router"] as? String).flatMap { LoopbackHost.matches($0) ? nil : $0 }
        }
        return nil
    }

    private var portalURL: URL? { URL(string: Settings.shared.loginURL) }
    private var portalHost: String? { portalURL?.host }

    private var ownAddresses: [String] {
        [probeURL.absoluteString] + (wifiGateway.map { ["http://\($0)/login"] } ?? [])
    }

    // VPN changes reach the plain path monitor too; only this pair decides a portal re-check.
    func networkSignature(for path: NWPath) -> NetworkSignature {
        let name = path.availableInterfaces.first { $0.type == .wifi }?.name
        return NetworkSignature(wifiInterface: name, router: name.flatMap(router(forInterface:)))
    }

    func describe(_ page: CaptivePage) -> String {
        let marker = Settings.shared.portalMarker.trimmingCharacters(in: .whitespaces)
        let ignored = !marker.isEmpty && !PortalMarker.isUsable(marker, ownAddresses: ownAddresses)
        return page.summary(hostKind: PostGuard.hostKind(page.url, portalHost: portalHost, gateway: wifiGateway))
            + (ignored ? ", marker ignored: it matches this app's own addresses" : "")
    }

    // Portal replies are read as they come: no redirect is followed, and a body stops at its cap.
    private lazy var fetcher: CappedFetcher = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return CappedFetcher(configuration: cfg)
    }()

    // Apple's probe returns "Success" only with real internet; otherwise the portal intercepts it.
    func checkConnectivity(completion: @escaping (ConnState) -> Void) {
        fetcher.fetch(URLRequest(url: probeURL), maxBytes: CaptivePage.maxBytes) { result in
            if let data = result.data,
               let body = String(data: data, encoding: .utf8),
               body.contains(self.successMarker) {
                completion(.connected)
            } else {
                completion(.captured)
            }
        }
    }

    // Gate before any POST: the page must hold a login form, or the marker when set.
    func inspectCaptivePage(completion: @escaping (_ isOurPortal: Bool, _ page: CaptivePage?) -> Void) {
        let marker = Settings.shared.portalMarker.trimmingCharacters(in: .whitespaces)
        fetchCaptivePage(marker: marker, portalHost: portalHost) { [weak self] page in
            guard let page = page, let self = self else { completion(false, page); return }
            completion(Self.isOurPortal(page: page, ownAddresses: self.ownAddresses), page)
        }
    }

    static func isOurPortal(page: CaptivePage, ownAddresses: [String]) -> Bool {
        guard !page.marker.isEmpty else { return page.form != nil }
        return PortalMarker.matches(page: page, marker: page.marker, ownAddresses: ownAddresses)
    }

    // Asks the portal first: internet may lag behind the login while a VPN reconnects.
    func confirmLogin(completion: @escaping (_ confirmed: Bool, _ portalStillAsking: Bool) -> Void) {
        inspectCaptivePage { [weak self] ours, page in
            if ours, page?.isLoggedIn == true {
                completion(true, false)
                return
            }
            let asking = ours && page?.form != nil
            guard let self = self else {
                completion(false, asking)
                return
            }
            self.checkConnectivity { completion($0 == .connected, asking) }
        }
    }

    func login(page: CaptivePage, completion: @escaping (LoginSubmit) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completion(.failed)
                return
            }
            let settings = Settings.shared
            // Read once: every check and the POST below must judge the same Login URL.
            let loginURL = settings.loginURL
            let portal = URL(string: loginURL)
            let form = page.form
            let action = form.flatMap { Self.resolve(action: $0.action, base: page.url) }
            let markerSet = !page.marker.isEmpty
            if form != nil, !PostGuard.allows(target: action, portal: portal, gateway: page.gateway, markerSet: markerSet) {
                Log.write("Refused to send credentials: the form posts to another address. Set Login URL to the portal address.")
                completion(.refused)
                return
            }
            let endpoint = Self.configuredEndpoint(loginURL)
            guard page.overWiFi != false else {
                Log.write("Refused to send credentials: the portal page did not arrive over Wi-Fi.")
                completion(.refused)
                return
            }
            if form == nil, endpoint == nil {
                Log.write("No login form on the page and no usable Login URL — nothing to submit.")
                completion(.refused)
                return
            }
            guard let secret = settings.portalSecret, !secret.password.isEmpty else {
                Log.write("No password from the Keychain — re-enter it in Settings.")
                completion(.noPassword)
                return
            }
            guard secret.allows(loginURL: loginURL, marker: page.marker) else {
                Log.write("Refused to send credentials: Login URL or marker changed outside Settings. Save them in Settings again.")
                completion(.refused)
                return
            }
            let password = secret.password
            guard PostGuard.gatewayHolds(proven: page.gateway, current: self.wifiGateway, markerSet: markerSet) else {
                Log.write("Refused to send credentials: the network changed during sign-in.")
                completion(.refused)
                return
            }
            if let form = form, let action = action {
                self.postForm(url: action,
                              fields: form.filled(username: settings.username, password: password),
                              source: "form",
                              page: page,
                              portalHost: portal?.host,
                              completion: completion)
            } else if let endpoint = endpoint {
                self.loginWithConfiguredEndpoint(endpoint, password: password, page: page, completion: completion)
            }
        }
    }

    // Read-only: never posts and never touches the Keychain. Takes the values typed in Settings.
    func diagnose(loginURL: String, marker: String, completion: @escaping ([String]) -> Void) {
        let marker = marker.trimmingCharacters(in: .whitespaces)
        let host = URL(string: loginURL.trimmingCharacters(in: .whitespaces))?.host
        checkConnectivity { [weak self] state in
            guard let self = self else { return }
            self.fetchCaptivePage(marker: marker, portalHost: host) { page in
                let kind = PostGuard.hostKind(page?.url, portalHost: host, gateway: self.wifiGateway)
                completion(PortalDiagnostics.report(connected: state == .connected, page: page,
                                                    marker: marker, hostKind: kind,
                                                    ownAddresses: self.ownAddresses))
            }
        }
    }

    // Read-only like diagnose: follows the probe to whatever page answers, without a marker.
    func detect(completion: @escaping (PortalDetection) -> Void) {
        checkConnectivity { [weak self] state in
            guard let self = self else { return }
            guard state != .connected else { return completion(PortalDetect.result(connected: true, page: nil, ownAddresses: [])) }
            self.fetchCaptivePage(marker: "", portalHost: nil) { page in
                completion(PortalDetect.result(connected: false, page: page, ownAddresses: self.ownAddresses))
            }
        }
    }

    // The marker gates the gateway page: a router's own admin login must never get the password.
    private func fetchCaptivePage(marker: String, portalHost: String?, completion: @escaping (CaptivePage?) -> Void) {
        guard !marker.isEmpty, let gateway = wifiGateway, let start = URL(string: "http://\(gateway)/login") else {
            fetchPage(probeURL, hops: 0, marker: marker, portalHost: portalHost, via: nil, completion: completion)
            return
        }
        fetchPage(start, hops: 0, marker: marker, portalHost: portalHost, via: gateway) { [weak self] page in
            if let page = page, let self = self, Self.isOurPortal(page: page, ownAddresses: self.ownAddresses) {
                completion(page)
            } else if let self = self {
                // The portal may not live on the gateway, so its name is tried as it is first.
                self.fetchPage(self.probeURL, hops: 0, marker: marker, portalHost: portalHost, via: nil) { [weak self] direct in
                    guard direct == nil, let self = self else { return completion(direct ?? page) }
                    // A VPN can hide the name, so the chain runs once more by way of the gateway.
                    self.fetchPage(self.probeURL, hops: 0, marker: marker, portalHost: portalHost, via: gateway) { completion($0 ?? page) }
                }
            } else {
                completion(page)
            }
        }
    }

    private static func portalRequest(_ url: URL, portalHost: String?, via gateway: String?) -> URLRequest {
        let routed = PortalRoute.url(url, portalHost: portalHost, gateway: gateway)
        var request = URLRequest(url: routed)
        if routed != url, let host = url.host {
            request.setValue(url.port.map { "\(host):\($0)" } ?? host, forHTTPHeaderField: "Host")
        }
        return request
    }

    private func fetchPage(_ url: URL, hops: Int, marker: String, portalHost: String?, via route: String?,
                           completion: @escaping (CaptivePage?) -> Void) {
        let gateway = wifiGateway
        var request = Self.portalRequest(url, portalHost: portalHost, via: route)
        request.timeoutInterval = 6
        let wifiName = wifiQueue.sync { wifiInterface }
        fetcher.fetch(request, maxBytes: CaptivePage.maxBytes) { [weak self] result in
            // Older portals send Latin-1; every byte sequence decodes as Latin-1.
            guard let data = result.data,
                  let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                completion(nil)
                return
            }
            let addresses = NetworkInterface.addresses()
            // lo0 is left out: it holds fe80::1, which is also a common router address.
            let own = Set(addresses.filter { !$0.key.hasPrefix("lo") }.values.joined())
            // A name that resolves to this Mac would pass a local service's page off as the portal.
            guard !PageOrigin.isThisMac(remote: result.remoteAddress, ownAddresses: own) else {
                Log.write("Ignored a page served by this Mac.")
                completion(nil)
                return
            }
            let overWiFi = PageOrigin.cameOverWiFi(local: result.localAddress, wifiAddresses: wifiName.flatMap { addresses[$0] })
            let page = CaptivePage(url: url, html: html, hops: hops, status: result.status,
                                   gateway: gateway, marker: marker, route: route, overWiFi: overWiFi)
            let location = (result.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location")
                .flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
            guard let self = self, hops < Self.maxRedirectHops,
                  let next = location ?? LoginFormParser.redirectURL(html: html, base: page.url),
                  RedirectPolicy.allows(next) else {
                completion(page)
                return
            }
            self.fetchPage(next, hops: hops + 1, marker: marker, portalHost: portalHost, via: route, completion: completion)
        }
    }

    // A portal never lives on this Mac, so a Login URL pointing here is not one.
    private static func configuredEndpoint(_ loginURL: String) -> URL? {
        guard let url = URL(string: loginURL), let host = url.host, !LoopbackHost.matches(host) else { return nil }
        return url
    }

    private func loginWithConfiguredEndpoint(_ url: URL, password: String, page: CaptivePage, completion: @escaping (LoginSubmit) -> Void) {
        let settings = Settings.shared
        var fields: [(String, String)] = [
            ("username", settings.username),
            ("password", password),
        ]
        fields.append(contentsOf: Self.parseExtraFields(settings.extraFields))
        postForm(url: url, fields: fields, source: "configured", page: page, portalHost: url.host, completion: completion)
    }

    private func postForm(url: URL, fields: [(String, String)], source: String, page: CaptivePage, portalHost: String?,
                          completion: @escaping (LoginSubmit) -> Void) {
        var request = Self.portalRequest(url, portalHost: portalHost, via: page.route)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(fields).data(using: .utf8)
        request.timeoutInterval = 15
        fetcher.fetch(request, maxBytes: CaptivePage.maxBytes) { result in
            let status = result.status.map { "HTTP \($0)" } ?? "no response"
            Log.write("Login POST: \(status) (\(source))\(result.error.map { " (error \(($0 as NSError).code))" } ?? "").")
            // The response body varies by portal; the caller confirms the login separately.
            completion(result.error == nil ? .sent : .failed)
        }
    }

    // MARK: - Helpers

    // Resolves a form action (absolute, relative, or empty) against the page URL.
    static func resolve(action: String, base: URL?) -> URL? {
        let a = action.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return base }
        if let absolute = URL(string: a), absolute.scheme != nil { return absolute }
        return URL(string: a, relativeTo: base)?.absoluteURL
    }

    // Parses configured extra fields: one "name=value" per line or comma.
    static func parseExtraFields(_ raw: String) -> [(String, String)] {
        var fields: [(String, String)] = []
        for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "," }) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            fields.append((name, value))
        }
        return fields
    }

    static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { name, value in
            let n = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(n)=\(v)"
        }.joined(separator: "&")
    }
}
