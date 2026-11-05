import Foundation

enum LoginVerdict: Equatable {
    case loggedIn, rejected, unconfirmed
}

enum LoginOutcome {
    private static let sleepGap: TimeInterval = 5

    // The wall clock keeps running through sleep and uptime does not.
    static func slept(wallElapsed: TimeInterval, uptimeElapsed: TimeInterval) -> Bool {
        wallElapsed - uptimeElapsed > sleepGap
    }

    static func verdict(slept: Bool, confirmed: Bool, portalStillAsking: Bool) -> LoginVerdict {
        if confirmed { return .loggedIn }
        if slept { return .unconfirmed }
        return portalStillAsking ? .rejected : .unconfirmed
    }
}
