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

// Portal replies are read as they come; a followed redirect would lose the hop.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
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

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        // A page that never ends must not keep growing in memory.
        cfg.timeoutIntervalForResource = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: cfg, delegate: NoRedirects(), delegateQueue: nil)
    }()

    // Apple's probe returns "Success" only with real internet; otherwise the portal intercepts it.
    func checkConnectivity(completion: @escaping (ConnState) -> Void) {
        let task = session.dataTask(with: probeURL) { data, _, _ in
            if let data = data,
               let body = String(data: data, encoding: .utf8),
               body.contains(self.successMarker) {
                completion(.connected)
            } else {
                completion(.captured)
            }
        }
        task.resume()
    }

    // Gate before any POST: the page must hold a login form, or the marker when set.
    func inspectCaptivePage(completion: @escaping (_ isOurPortal: Bool, _ page: CaptivePage?) -> Void) {
        fetchCaptivePage { [weak self] page in
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
            let form = page.form
            let action = form.flatMap { Self.resolve(action: $0.action, base: page.url) }
            let markerSet = !page.marker.isEmpty
            if form != nil, !PostGuard.allows(target: action, portal: self.portalURL, gateway: page.gateway, markerSet: markerSet) {
                Log.write("Refused to send credentials: the form posts to another address. Set Login URL to the portal address.")
                completion(.refused)
                return
            }
            let endpoint = Self.configuredEndpoint(settings.loginURL)
            if form == nil, endpoint == nil {
                Log.write("No login form on the page and no usable Login URL — nothing to submit.")
                completion(.refused)
                return
            }
            let password = settings.password
            guard !password.isEmpty else {
                Log.write("No password from the Keychain — re-enter it in Settings.")
                completion(.noPassword)
                return
            }
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
                              completion: completion)
            } else if let endpoint = endpoint {
                self.loginWithConfiguredEndpoint(endpoint, password: password, page: page, completion: completion)
            }
        }
    }

    // Read-only: never posts and never touches the Keychain.
    func diagnose(completion: @escaping ([String]) -> Void) {
        checkConnectivity { [weak self] state in
            guard let self = self else { return }
            self.fetchCaptivePage { page in
                let kind = PostGuard.hostKind(page?.url, portalHost: self.portalHost, gateway: self.wifiGateway)
                completion(PortalDiagnostics.report(connected: state == .connected, page: page,
                                                    marker: Settings.shared.portalMarker, hostKind: kind,
                                                    ownAddresses: self.ownAddresses))
            }
        }
    }

    // The marker gates the gateway page: a router's own admin login must never get the password.
    private func fetchCaptivePage(completion: @escaping (CaptivePage?) -> Void) {
        let marker = Settings.shared.portalMarker.trimmingCharacters(in: .whitespaces)
        guard !marker.isEmpty, let gateway = wifiGateway, let start = URL(string: "http://\(gateway)/login") else {
            fetchPage(probeURL, hops: 0, marker: marker, completion: completion)
            return
        }
        fetchPage(start, hops: 0, marker: marker) { [weak self] page in
            if let page = page, let self = self, Self.isOurPortal(page: page, ownAddresses: self.ownAddresses) {
                completion(page)
            } else if let self = self {
                // The portal may not live on the gateway, so its own page must not hide the probe.
                self.fetchPage(self.probeURL, hops: 0, marker: marker) { completion($0 ?? page) }
            } else {
                completion(page)
            }
        }
    }

    // One marker and gateway for a whole cycle, so the gate and the route cannot disagree.
    private func portalRequest(_ url: URL, marker: String, gateway: String?) -> URLRequest {
        let host = portalHost
        // Only a marker proves this gateway is the portal; without one the name must not reach it.
        let routed = PortalRoute.url(url, portalHost: host, gateway: marker.isEmpty ? nil : gateway)
        var request = URLRequest(url: routed)
        if routed != url { request.setValue(host, forHTTPHeaderField: "Host") }
        return request
    }

    private func fetchPage(_ url: URL, hops: Int, marker: String, completion: @escaping (CaptivePage?) -> Void) {
        let gateway = wifiGateway
        var request = portalRequest(url, marker: marker, gateway: gateway)
        request.timeoutInterval = 6
        let task = session.dataTask(with: request) { [weak self] data, response, _ in
            guard let data = data, data.count <= CaptivePage.maxBytes, let html = String(data: data, encoding: .utf8) else {
                completion(nil)
                return
            }
            let page = CaptivePage(url: url, html: html, hops: hops, status: (response as? HTTPURLResponse)?.statusCode, gateway: gateway, marker: marker)
            let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location")
                .flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
            guard let self = self, hops < Self.maxRedirectHops,
                  let next = location ?? LoginFormParser.redirectURL(html: html, base: page.url),
                  RedirectPolicy.allows(next) else {
                completion(page)
                return
            }
            self.fetchPage(next, hops: hops + 1, marker: marker, completion: completion)
        }
        task.resume()
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
        postForm(url: url, fields: fields, source: "configured", page: page, completion: completion)
    }

    private func postForm(url: URL, fields: [(String, String)], source: String, page: CaptivePage, completion: @escaping (LoginSubmit) -> Void) {
        var request = portalRequest(url, marker: page.marker, gateway: page.gateway)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(fields).data(using: .utf8)
        request.timeoutInterval = 15
        let task = session.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "no response"
            Log.write("Login POST: \(status) (\(source))\(error.map { " (error \(($0 as NSError).code))" } ?? "").")
            // The response body varies by portal; the caller confirms the login separately.
            completion(error == nil ? .sent : .failed)
        }
        task.resume()
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
