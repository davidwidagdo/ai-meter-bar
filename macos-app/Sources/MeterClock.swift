import Foundation

enum MeterSchedule {
    static let options = [1, 2, 5]
    static let lowPowerInterval = 5

    // Low Power Mode asks apps to do less, so the meters slow down by themselves.
    static func interval(setting: Int, lowPower: Bool) -> Int {
        lowPower ? max(setting, lowPowerInterval) : setting
    }

    // One interval replaced two: the faster of the old pair keeps what the user saw.
    static func migrated(speed: Int?, system: Int?) -> Int {
        let old = [speed, system].compactMap { $0 }.filter(options.contains)
        return old.min() ?? 2
    }
}

// One clock means one menu-bar redraw per tick; two timers drew twice a second.
final class MeterClock {
    private let onTick: (Int) -> Void
    private var timer: Timer?
    private var tick = 0

    init(onTick: @escaping (_ tick: Int) -> Void) {
        self.onTick = onTick
    }

    func start(interval: Int) {
        stop()
        tick = 0
        let seconds = TimeInterval(max(1, interval))
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.tick &+= 1
            self.onTick(self.tick)
        }
        t.tolerance = seconds * 0.2
        // .common keeps the values moving while the popover is open.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
