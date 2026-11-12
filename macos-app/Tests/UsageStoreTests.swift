import Foundation

func testUsageStore() {
    let d = testDefaults("usage")

    var day = "2026-07-17"
    let store = UsageStore(defaults: d, dayProvider: { day })

    store.add(rx: 100, tx: 50, downRate: 500, upRate: 200)
    store.add(rx: 20, tx: 5, downRate: 300, upRate: 100)
    T.eq(store.today.rx, UInt64(120), "accumulate rx")
    T.eq(store.today.tx, UInt64(55), "accumulate tx")
    T.eq(store.today.peakDown, 500, "peak down")
    T.eq(store.today.peakUp, 200, "peak up")

    // Rollover to the next day: the finished day (rx 120) must persist.
    day = "2026-07-18"
    store.add(rx: 10, tx: 5, downRate: 50, upRate: 20)
    T.eq(store.today.day, "2026-07-18", "rolled to new day")
    T.eq(store.today.rx, UInt64(10), "new day rx")
    T.expect(store.history().contains { $0.day == "2026-07-17" && $0.rx == 120 },
             "previous day persisted with its total")

    // Persistence: a fresh store on the same defaults restores today's bucket.
    store.flush()
    let store2 = UsageStore(defaults: d, dayProvider: { "2026-07-18" })
    T.eq(store2.today.rx, UInt64(10), "restored today rx")

    // Reset today zeroes the current bucket.
    store2.resetToday()
    T.eq(store2.today.rx, UInt64(0), "reset today")

    // Prune: seed 35 historical days, then history stays <= 30.
    let d2 = testDefaults("usage-prune")
    var recs: [[String: Any]] = []
    for i in 0..<35 {
        recs.append(["day": String(format: "2026-06-%02d", i + 1),
                     "rx": NSNumber(value: 1), "tx": NSNumber(value: 1),
                     "peakDown": 0.0, "peakUp": 0.0])
    }
    d2.set(recs, forKey: "usageHistory")
    let store3 = UsageStore(defaults: d2, dayProvider: { "2026-07-01" })
    store3.add(rx: 5, tx: 5, downRate: 0, upRate: 0)
    store3.flush()
    T.expect(store3.history().count <= 30, "history pruned to 30")

    // resetToday across a midnight boundary must NOT wipe the prior day.
    let d3 = testDefaults("usage-midnight")
    var day3 = "2026-08-01"
    let store5 = UsageStore(defaults: d3, dayProvider: { day3 })
    store5.add(rx: 1000, tx: 500, downRate: 10, upRate: 5)
    day3 = "2026-08-02"                       // clock rolled over, no tick yet
    store5.resetToday()                       // user clicks "Reset today's usage"
    T.expect(store5.history().contains { $0.day == "2026-08-01" && $0.rx == 1000 },
             "resetToday preserves prior day after rollover")
    T.eq(store5.today.rx, UInt64(0), "resetToday zeroes the current day")

    // Missing days leave no row, so totals follow the calendar.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!
    func row(_ daysAgo: Int, _ rx: UInt64) -> DayUsage {
        DayUsage(day: UsageStore.dayString(calendar.date(byAdding: .day, value: -daysAgo, to: today)!), rx: rx, tx: 1, peakDown: 0, peakUp: 0)
    }
    let rows = [row(0, 1), row(6, 10), row(7, 100), row(12, 1000)]
    T.eq(UsageStore.totals(rows, days: 7, today: today, calendar: calendar).rx, UInt64(11), "7 days counts today back to 6 days ago")
    T.eq(UsageStore.totals(rows, days: 7, today: today, calendar: calendar).tx, UInt64(2), "7 days upload")
    T.eq(UsageStore.totals(rows, days: 30, today: today, calendar: calendar).rx, UInt64(1111), "30 days counts all four")
    T.eq(UsageStore.totals([], days: 7, today: today, calendar: calendar).rx, UInt64(0), "no rows")
}
