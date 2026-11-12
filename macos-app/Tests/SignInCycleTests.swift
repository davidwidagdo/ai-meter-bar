import Foundation

private final class FakePortal: PortalService {
    var connected = false
    var page: CaptivePage?
    var ours = true
    var submit = LoginSubmit.sent
    var confirm = (confirmed: true, asking: false)
    var holdInspect = false
    var heldInspect: (() -> Void)?
    var inspections = 0
    var logins = 0

    func checkConnectivity(completion: @escaping (ConnState) -> Void) {
        completion(connected ? .connected : .captured)
    }

    func inspectCaptivePage(completion: @escaping (Bool, CaptivePage?) -> Void) {
        inspections += 1
        let reply = { [ours, page] in completion(ours, page) }
        if holdInspect { heldInspect = reply } else { reply() }
    }

    func login(page: CaptivePage, completion: @escaping (LoginSubmit) -> Void) {
        logins += 1
        completion(submit)
    }

    func confirmLogin(completion: @escaping (Bool, Bool) -> Void) {
        completion(confirm.confirmed, confirm.asking)
    }

    func describe(_ page: CaptivePage) -> String { "page" }
}

private final class Harness {
    let portal = FakePortal()
    var config = SignInConfig(autoLogin: true, pollInterval: 5, hasUsername: true, hasDestination: true)
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var later: [() -> Void] = []
    var polls: [TimeInterval] = []
    var logs: [String] = []
    var statuses: [(PortalState, String)] = []
    var loggedIn = 0
    var popups = 0
    lazy var cycle: SignInCycle = {
        var env = SignInEnvironment()
        env.now = { [unowned self] in self.now }
        env.uptime = { [unowned self] in self.now.timeIntervalSince1970 }
        env.main = { $0() }
        env.after = { [unowned self] _, work in self.later.append(work) }
        env.every = { [unowned self] interval, _ in
            self.polls.append(interval)
            return {}
        }
        env.log = { [unowned self] in self.logs.append($0) }
        let cycle = SignInCycle(portal: portal, env: env, config: { [unowned self] in self.config })
        cycle.onStatus = { [unowned self] in self.statuses.append(($0, $1)) }
        cycle.onLoggedIn = { [unowned self] _ in self.loggedIn += 1 }
        cycle.dismissPopup = { [unowned self] in self.popups += 1 }
        return cycle
    }()

    func runLater() {
        while !later.isEmpty { later.removeFirst()() }
    }
}

private let loginPage = CaptivePage(url: URL(string: "http://portal.example/login"),
                                    html: #"<form action="/login" method="post"><input type="text" name="u"><input type="password" name="p"></form>"#,
                                    hops: 1, overWiFi: true)

func testSignInCycle() {
    // An online Mac needs nothing: no page is read and no password goes out.
    var h = Harness()
    h.portal.connected = true
    h.cycle.start()
    T.eq(h.cycle.state, .connected, "online: the state is connected")
    T.eq(h.portal.inspections + h.portal.logins, 0, "online: no page is read and nothing is sent")
    T.eq(h.polls, [30], "online: the next check comes after 30 s, not the 5 s setting")

    // A portal page with a form signs in once and is confirmed.
    h = Harness()
    h.portal.page = loginPage
    h.cycle.start()
    T.eq(h.portal.logins, 1, "portal: one POST")
    T.eq(h.cycle.state, .working, "portal: logging in until confirmed")
    T.eq(h.polls, [5], "portal: checks at the 5 s setting while not connected")
    h.runLater()
    T.eq(h.cycle.state, .connected, "portal: confirmed means connected")
    T.eq(h.loggedIn, 1, "portal: the login time is recorded")
    T.eq(h.popups, 1, "portal: the stale macOS popup is closed")
    T.eq(h.polls, [5, 30], "portal: the pace drops to 30 s once connected")

    // A rejection pauses further POSTs and asks for the settings.
    h = Harness()
    h.portal.page = loginPage
    h.portal.confirm = (false, true)
    h.cycle.start()
    h.runLater()
    T.eq(h.cycle.state, .needsSettings, "rejected: the settings need a look")
    T.eq(h.statuses.last?.1, "Login failed", "rejected: says the login failed")
    h.cycle.check()
    T.eq(h.portal.logins, 1, "rejected: the next poll sends nothing")
    T.eq(h.cycle.state, .needsSettings, "rejected: the state stays on the settings")
    h.cycle.signIn()
    T.eq(h.portal.logins, 2, "rejected: a click tries again at once")

    h = Harness()
    h.config.hasDestination = false
    h.portal.page = loginPage
    h.cycle.start()
    h.cycle.check()
    T.eq(h.cycle.state, .needsSetup, "setup: a login page with nothing saved asks for setup")
    T.eq(h.portal.logins, 0, "setup: nothing is sent")
    T.eq(h.logs.filter { $0.contains("no sign-in details") }.count, 1, "setup: logged once, not every poll")

    // A page from another link is never this Wi-Fi's portal.
    h = Harness()
    h.portal.page = CaptivePage(url: loginPage.url, html: loginPage.html, hops: 1, overWiFi: false)
    h.cycle.start()
    T.eq(h.statuses.last?.1, "Portal page is not on Wi-Fi", "other link: named")
    T.eq(h.portal.logins, 0, "other link: nothing is sent")

    // A check begun before sleep that ends in a dark wake sends nothing.
    h = Harness()
    h.portal.page = loginPage
    h.portal.holdInspect = true
    h.cycle.start()
    h.cycle.sleep()
    h.portal.heldInspect?()
    T.eq(h.portal.logins, 0, "dark wake: no POST after sleep began")
    h.cycle.check()
    T.eq(h.portal.inspections, 1, "asleep: polls do nothing")

    // A click during a check waits and then runs.
    h = Harness()
    h.portal.page = loginPage
    h.portal.holdInspect = true
    h.config.hasDestination = false
    h.cycle.start()
    h.cycle.signIn()
    h.portal.heldInspect?()
    T.eq(h.portal.inspections, 2, "busy: the click runs once the check ends")

    // No password or a refused form: the settings need a look and the pause applies.
    h = Harness()
    h.portal.page = loginPage
    h.portal.submit = .noPassword
    h.cycle.start()
    T.eq(h.statuses.last?.1, "No password saved", "no password: named")
    h.cycle.check()
    T.eq(h.portal.logins, 1, "no password: no retry inside the pause")

    // Unconfirmed without sleep counts as a rejection but keeps rechecking soon.
    h = Harness()
    h.portal.page = loginPage
    h.portal.confirm = (false, false)
    h.cycle.start()
    let queued = h.later.count
    h.later.removeFirst()()
    T.eq(h.cycle.state, .needsLogin, "unconfirmed: rechecking")
    T.expect(h.later.count >= queued, "unconfirmed: a quick recheck is queued")
    h.runLater()
    T.eq(h.portal.logins, 1, "unconfirmed: the rechecks send nothing inside the pause")

    // Auto-login off: no polling, and a check only reports the state.
    h = Harness()
    h.config.autoLogin = false
    h.cycle.start()
    T.eq(h.polls, [], "auto-login off: no timer")
    T.eq(h.cycle.pollInterval, nil, "auto-login off: no pace")
    T.eq(h.statuses.last?.1, "Offline (auto-login off)", "auto-login off: says so")
    T.eq(h.portal.inspections, 0, "auto-login off: no page is read")

    // A slow setting is never sped up by the connected pace.
    h = Harness()
    h.config.pollInterval = 60
    h.portal.connected = true
    h.cycle.start()
    T.eq(h.cycle.pollInterval, 60, "a 60 s setting stays 60 s while connected")
}

func testPortalSchedule() {
    T.eq(PortalSchedule.interval(setting: 5, connected: false), 5, "signed out: his interval")
    T.eq(PortalSchedule.interval(setting: 5, connected: true), 30, "connected: 30 s")
    T.eq(PortalSchedule.interval(setting: 60, connected: true), 60, "connected: never faster than his interval")
    let codeOnly = CaptivePage(url: loginPage.url, html: #"<form action="/login"><input type="password" name="code"></form>"#, hops: 1)
    let saved = SignInConfig(autoLogin: true, pollInterval: 5, hasUsername: true, hasDestination: true)
    var noName = saved
    noName.hasUsername = false
    var noDestination = saved
    noDestination.hasDestination = false
    T.expect(!saved.needsSetup(for: loginPage), "setup: done")
    T.expect(noName.needsSetup(for: loginPage), "setup: a form with a username field needs a username")
    T.expect(!noName.needsSetup(for: codeOnly), "setup: an access-code form needs no username")
    T.expect(noDestination.needsSetup(for: codeOnly), "setup: no Login URL and no marker")
}

func testPortalDetect() {
    let own = ["http://captive.apple.com/hotspot-detect.html", "http://192.0.2.1/login"]
    T.eq(PortalDetect.result(connected: true, page: loginPage, ownAddresses: own).outcome, .online, "online: nothing to detect")
    T.eq(PortalDetect.result(connected: false, page: nil, ownAddresses: own).outcome, .noPage, "no page answered")
    let elsewhere = CaptivePage(url: loginPage.url, html: loginPage.html, hops: 1, overWiFi: false)
    T.eq(PortalDetect.result(connected: false, page: elsewhere, ownAddresses: own).outcome, .notWiFi, "a page from another link is refused")
    let plain = CaptivePage(url: loginPage.url, html: "<p>Welcome</p>", hops: 1)
    T.eq(PortalDetect.result(connected: false, page: plain, ownAddresses: own).outcome, .noForm, "no readable form")

    let found = PortalDetect.result(connected: false, page: loginPage, ownAddresses: own)
    T.eq(found.outcome, .found, "a form is found")
    T.eq(found.loginURL, "http://portal.example/login", "the Login URL is where the form posts")
    T.eq(found.marker, "portal.example", "a redirected name becomes the marker")
    T.eq(found.host, "portal.example", "the host is named in the message")

    let byAddress = CaptivePage(url: URL(string: "http://198.51.100.7/login"), html: loginPage.html, hops: 1)
    let addressed = PortalDetect.result(connected: false, page: byAddress, ownAddresses: own)
    T.eq(addressed.outcome, .found, "a portal at a plain address is found")
    T.eq(addressed.marker, nil, "an address is no marker")
    let empty = #"<form action=""><input type="text" name="u"><input type="password" name="p"></form>"#
    let inProbe = CaptivePage(url: URL(string: "http://captive.apple.com/hotspot-detect.html"), html: empty, hops: 0)
    T.eq(PortalDetect.result(connected: false, page: inProbe, ownAddresses: own).outcome, .ownAddress,
         "a form served in place of Apple's probe is never the Login URL")
    let onRouter = CaptivePage(url: URL(string: "http://192.0.2.1/login"), html: loginPage.html, hops: 1)
    T.eq(PortalDetect.result(connected: false, page: onRouter, ownAddresses: own).outcome, .ownAddress,
         "a form on the router is never the Login URL without a marker")
    let local = CaptivePage(url: loginPage.url, html: #"<form action="http://localhost/x"><input type="password" name="p"></form>"#, hops: 1)
    T.eq(PortalDetect.result(connected: false, page: local, ownAddresses: own).outcome, .noForm, "a form posting to this Mac is not used")
}

func testAttentionRules() {
    let low = QuotaCell.make(used: 93, freshness: .fresh, showLeft: true)
    let fine = QuotaCell.make(used: 20, freshness: .fresh, showLeft: true)
    let watch = { (cell: QuotaCell) in [QuotaWatch(key: "codex:5h", title: "Codex 5-hour quota", cell: cell)] }
    var result = AttentionRules.lowQuota(watch(low), alerted: [])
    T.eq(result.due.count, 1, "low quota: one alert")
    T.eq(result.due.first?.body, "7% left.", "low quota: says what is left")
    result = AttentionRules.lowQuota(watch(low), alerted: result.alerted)
    T.eq(result.due.count, 0, "low quota: no repeat in the same window")
    result = AttentionRules.lowQuota(watch(fine), alerted: result.alerted)
    result = AttentionRules.lowQuota(watch(low), alerted: result.alerted)
    T.eq(result.due.count, 1, "low quota: alerts again after a reset")
    T.eq(AttentionRules.lowQuota(watch(.unknown), alerted: []).due.count, 0, "unknown quota: no alert")
    let stale = QuotaCell.make(used: 99, freshness: .stale, showLeft: true)
    T.eq(AttentionRules.lowQuota(watch(stale), alerted: []).due.count, 0, "stale quota: no alert")

    T.expect(AttentionRules.signIn(from: .working, to: .needsSettings, text: "Login failed") != nil, "sign-in: a failure alerts")
    T.expect(AttentionRules.signIn(from: .needsSettings, to: .needsSettings, text: "Login failed") == nil, "sign-in: once per failure")
    T.expect(AttentionRules.signIn(from: .working, to: .connected, text: "Connected") == nil, "sign-in: success is quiet")
}
