import Foundation

func testMeterSchedule() {
    T.eq(MeterSchedule.baseInterval(speed: 1, system: 1), 1, "base 1 and 1")
    T.eq(MeterSchedule.baseInterval(speed: 1, system: 5), 1, "base 1 and 5")
    T.eq(MeterSchedule.baseInterval(speed: 2, system: 5), 1, "base 2 and 5")
    T.eq(MeterSchedule.baseInterval(speed: 2, system: 4), 2, "base 2 and 4")
    T.eq(MeterSchedule.baseInterval(speed: 5, system: nil), 5, "base without system metrics")

    T.eq(MeterSchedule.isDue(tick: 0, every: 2, base: 1), true, "tick 0 every 2")
    T.eq(MeterSchedule.isDue(tick: 1, every: 2, base: 1), false, "tick 1 every 2")
    T.eq(MeterSchedule.isDue(tick: 2, every: 2, base: 1), true, "tick 2 every 2")
    T.eq(MeterSchedule.isDue(tick: 1, every: 4, base: 2), false, "tick 1 every 4 base 2")
    T.eq(MeterSchedule.isDue(tick: 2, every: 4, base: 2), true, "tick 2 every 4 base 2")
}
