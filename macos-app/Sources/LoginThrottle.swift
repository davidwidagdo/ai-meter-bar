import Foundation

// A wrong password must not reach the portal every poll: that can lock the account.
struct LoginThrottle {
    private static let delays: [TimeInterval] = [60, 300, 900]
    private var rejections = 0
    private var nextAttempt: Date?

    mutating func recordRejected(now: Date) {
        nextAttempt = now.addingTimeInterval(Self.delays[min(rejections, Self.delays.count - 1)])
        rejections += 1
    }

    mutating func reset() {
        rejections = 0
        nextAttempt = nil
    }

    func allowsAttempt(now: Date) -> Bool {
        guard let nextAttempt else { return true }
        return now >= nextAttempt
    }
}
