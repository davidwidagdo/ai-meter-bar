import Foundation

func testUsageStore() {
    let suite = "wifiautologin.tests.\(ProcessInfo.processInfo.globallyUniqueString)"
    let d = UserDefaults(suiteName: suite)!
    defer { removeTestDefaults(d, suite: suite) }

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
    let suite2 = "wifiautologin.tests.\(ProcessInfo.processInfo.globallyUniqueString)"
    let d2 = UserDefaults(suiteName: suite2)!
    defer { removeTestDefaults(d2, suite: suite2) }
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
    let suite3 = "wifiautologin.tests.\(ProcessInfo.processInfo.globallyUniqueString)"
    let d3 = UserDefaults(suiteName: suite3)!
    defer { removeTestDefaults(d3, suite: suite3) }
    var day3 = "2026-08-01"
    let store5 = UsageStore(defaults: d3, dayProvider: { day3 })
    store5.add(rx: 1000, tx: 500, downRate: 10, upRate: 5)
    day3 = "2026-08-02"                       // clock rolled over, no tick yet
    store5.resetToday()                       // user clicks "Reset today's usage"
    T.expect(store5.history().contains { $0.day == "2026-08-01" && $0.rx == 1000 },
             "resetToday preserves prior day after rollover")
    T.eq(store5.today.rx, UInt64(0), "resetToday zeroes the current day")
}
