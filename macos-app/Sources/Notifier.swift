import Foundation
import UserNotifications

struct QuotaWatch: Equatable {
    let key: String
    let title: String
    let cell: QuotaCell
}

struct Attention: Equatable {
    let id: String
    let title: String
    let body: String
}

enum AttentionRules {
    static let lowLeft = 0.10

    // Once per window: a window back above the line, which only a reset does, can alert again.
    static func lowQuota(_ watches: [QuotaWatch], alerted: Set<String>) -> (due: [Attention], alerted: Set<String>) {
        var next = alerted, due: [Attention] = []
        for watch in watches where !watch.cell.isUnknown && !watch.cell.isStale {
            if watch.cell.fraction > lowLeft {
                next.remove(watch.key)
            } else if next.insert(watch.key).inserted {
                due.append(Attention(id: "quota:\(watch.key)", title: "\(watch.title) is almost used up",
                                     body: "\(watch.cell.text) left."))
            }
        }
        return (due, next)
    }

    // Only the step into "needs your settings" alerts; repeated checks in that state stay quiet.
    static func signIn(from previous: PortalState, to next: PortalState, text: String) -> Attention? {
        guard next == .needsSettings, previous != .needsSettings else { return nil }
        return Attention(id: "portal", title: "Wi-Fi sign-in needs you", body: "\(text). Open Settings, Portal to check it.")
    }

    static func vpnDropped(name: String) -> Attention {
        Attention(id: "vpn:\(name)", title: "\(name) disconnected", body: "It was not stopped from AI Meter Bar.")
    }
}

// Off by default; nothing is asked of macOS until the switch is turned on.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var alertedQuota: Set<String> = []
    private var lastPortal = PortalState.idle
    // Test and harness binaries have no bundle, and the notification center needs one.
    private let center: UNUserNotificationCenter? = Bundle.main.bundleURL.pathExtension == "app" && !AppMode.isDemo
        ? UNUserNotificationCenter.current() : nil

    private var enabled: Bool { center != nil && Settings.shared.notifyAttention }

    func requestPermission() {
        center?.delegate = self
        center?.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted { Log.write("Notifications are not allowed in System Settings.") }
        }
    }

    func start() {
        guard enabled else { return }
        center?.delegate = self
    }

    func portal(_ state: PortalState, text: String) {
        defer { lastPortal = state }
        guard enabled, let attention = AttentionRules.signIn(from: lastPortal, to: state, text: text) else { return }
        post(attention)
    }

    // Tracked even while off, so turning the switch on does not alert for an old low quota at once.
    func quotas(_ watches: [QuotaWatch]) {
        let result = AttentionRules.lowQuota(watches, alerted: alertedQuota)
        alertedQuota = result.alerted
        guard enabled else { return }
        result.due.forEach(post)
    }

    func vpnDropped(name: String) {
        guard enabled else { return }
        post(AttentionRules.vpnDropped(name: name))
    }

    private func post(_ attention: Attention) {
        let content = UNMutableNotificationContent()
        content.title = attention.title
        content.body = attention.body
        center?.add(UNNotificationRequest(identifier: attention.id, content: content, trigger: nil))
    }

    // A menu bar app is often frontmost while its panel is open, so banners show then too.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
