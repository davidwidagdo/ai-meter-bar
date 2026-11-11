import Foundation

func testMeterSchedule() {
    T.eq(MeterSchedule.interval(setting: 1, lowPower: false), 1, "the setting is used as it is")
    T.eq(MeterSchedule.interval(setting: 1, lowPower: true), 5, "Low Power Mode slows a fast setting to 5 s")
    T.eq(MeterSchedule.interval(setting: 2, lowPower: true), 5, "Low Power Mode slows 2 s to 5 s")
    T.eq(MeterSchedule.interval(setting: 5, lowPower: true), 5, "Low Power Mode never speeds a slow setting up")
    T.eq(MeterSchedule.migrated(speed: 1, system: 2), 1, "the faster old interval is kept")
    T.eq(MeterSchedule.migrated(speed: 5, system: 2), 2, "whichever of the two was faster")
    T.eq(MeterSchedule.migrated(speed: nil, system: 5), 5, "one old value alone is kept")
    T.eq(MeterSchedule.migrated(speed: nil, system: nil), 2, "a fresh install starts at 2 s")
    T.eq(MeterSchedule.migrated(speed: 7, system: nil), 2, "a value outside the offered set falls back to 2 s")
}
