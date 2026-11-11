import Foundation

// One calendar day's WiFi usage.
struct DayUsage: Equatable {
    let day: String        // "yyyy-MM-dd" (local)
    let rx: UInt64         // download bytes
    let tx: UInt64         // upload bytes
    let peakDown: Double   // peak download bytes/sec
    let peakUp: Double     // peak upload bytes/sec
    var total: UInt64 { rx &+ tx }
}

// Persists daily download/upload totals + peak speeds. Keeps today's bucket in
// memory and flushes to UserDefaults periodically (see SpeedMonitor) to avoid a
// disk write every second. History is pruned to the most recent 30 days.
//
// `defaults` and `dayProvider` are injectable so the logic is unit-testable
// without touching real UserDefaults or the wall clock.
final class UsageStore {
    static let shared = UsageStore()

    private let defaults: UserDefaults
    private let dayProvider: () -> String
    private let key = "usageHistory"
    private let maxDays = 30

    private var day: String
    private var rx: UInt64 = 0
    private var tx: UInt64 = 0
    private var peakDown: Double = 0
    private var peakUp: Double = 0

    init(defaults: UserDefaults = .standard,
         dayProvider: @escaping () -> String = { UsageStore.dayString(Date()) }) {
        self.defaults = defaults
        self.dayProvider = dayProvider
        self.day = dayProvider()
        // Restore today's in-memory bucket if a record already exists (app relaunch).
        if let rec = Self.load(from: defaults, key: key).first(where: { $0.day == day }) {
            rx = rec.rx; tx = rec.tx; peakDown = rec.peakDown; peakUp = rec.peakUp
        }
    }

    // Built once: this is called on every sample tick (via rolloverIfNeeded), and
    // constructing a DateFormatter each time is one of the more expensive things
    // Foundation offers.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // never localize the key
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // Calendar-local day key; the zone is rechecked because the formatter keeps the launch zone.
    static func dayString(_ date: Date) -> String {
        if dayFormatter.timeZone != .current { dayFormatter.timeZone = .current }
        return dayFormatter.string(from: date)
    }

    // Totals for the last `days` calendar days to today, whether or not the app ran on each.
    static func totals(_ rows: [DayUsage], days: Int, today: Date, calendar: Calendar = .current) -> (rx: UInt64, tx: UInt64) {
        guard let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return (0, 0) }
        let cutoff = dayString(first)
        return rows.filter { $0.day >= cutoff }.reduce((0, 0)) { ($0.0 &+ $1.rx, $0.1 &+ $1.tx) }
    }

    func add(rx: UInt64, tx: UInt64, downRate: Double, upRate: Double) {
        rolloverIfNeeded()
        self.rx &+= rx
        self.tx &+= tx
        peakDown = max(peakDown, downRate)
        peakUp = max(peakUp, upRate)
    }

    var today: DayUsage {
        DayUsage(day: day, rx: rx, tx: tx, peakDown: peakDown, peakUp: peakUp)
    }

    // Persisted history merged with the live today bucket, newest first, <= 30.
    func history() -> [DayUsage] {
        var records = Self.load(from: defaults, key: key).filter { $0.day != day }
        records.append(today)
        return Array(records.sorted { $0.day > $1.day }.prefix(maxDays))
    }

    func resetToday() {
        // Roll over first so a day boundary crossed since the last tick persists
        // the finished day's real totals before we zero the (now current) bucket.
        rolloverIfNeeded()
        rx = 0; tx = 0; peakDown = 0; peakUp = 0
        flush()
    }

    func flush() {
        rolloverIfNeeded()
        persist(today)
    }

    // If the calendar day changed, persist the finished day and start fresh.
    private func rolloverIfNeeded() {
        let current = dayProvider()
        guard current != day else { return }
        persist(DayUsage(day: day, rx: rx, tx: tx, peakDown: peakDown, peakUp: peakUp))
        day = current; rx = 0; tx = 0; peakDown = 0; peakUp = 0
        if let rec = Self.load(from: defaults, key: key).first(where: { $0.day == current }) {
            rx = rec.rx; tx = rec.tx; peakDown = rec.peakDown; peakUp = rec.peakUp
        }
    }

    // Upsert one day into the stored array, keeping the newest 30.
    private func persist(_ record: DayUsage) {
        var records = Self.load(from: defaults, key: key).filter { $0.day != record.day }
        records.append(record)
        records.sort { $0.day > $1.day }
        defaults.set(Array(records.prefix(maxDays)).map(Self.encode), forKey: key)
    }

    private static func encode(_ d: DayUsage) -> [String: Any] {
        ["day": d.day,
         "rx": NSNumber(value: d.rx), "tx": NSNumber(value: d.tx),
         "peakDown": d.peakDown, "peakUp": d.peakUp]
    }

    private static func load(from defaults: UserDefaults, key: String) -> [DayUsage] {
        guard let arr = defaults.array(forKey: key) as? [[String: Any]] else { return [] }
        return arr.compactMap { dict in
            guard let day = dict["day"] as? String else { return nil }
            return DayUsage(
                day: day,
                rx: (dict["rx"] as? NSNumber)?.uint64Value ?? 0,
                tx: (dict["tx"] as? NSNumber)?.uint64Value ?? 0,
                peakDown: (dict["peakDown"] as? NSNumber)?.doubleValue ?? 0,
                peakUp: (dict["peakUp"] as? NSNumber)?.doubleValue ?? 0
            )
        }
    }
}
