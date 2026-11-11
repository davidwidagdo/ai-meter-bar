import Foundation

final class SpeedMonitor {
    struct Sample { let down: Double; let up: Double }

    var onUpdate: ((Sample) -> Void)?

    private let usage: UsageStore
    private var last: (rx: UInt64, tx: UInt64)?
    private var lastTime = Date()
    private var flushAccum: TimeInterval = 0

    init(usage: UsageStore = .shared) { self.usage = usage }

    func prepare() {
        last = nil
        lastTime = Date()
        flushAccum = 0
        tick()
    }

    func tick() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTime)
        lastTime = now

        // Flush about every 10 s of wall time; it also rolls the day over, counters or not.
        flushAccum += elapsed
        if flushAccum >= 10 {
            flushAccum = 0
            usage.flush()
        }

        guard let name = NetworkInterface.resolved(override: Settings.shared.wifiInterfaceOverride),
              let current = NetworkStats.counters(for: name) else {
            last = nil
            emit(Sample(down: 0, up: 0))
            return
        }

        let r = SpeedMath.compute(prev: last, current: current, elapsed: elapsed)
        last = current
        if !r.didReset {
            usage.add(rx: r.rxDelta, tx: r.txDelta, downRate: r.down, upRate: r.up)
        }
        emit(Sample(down: r.down, up: r.up))
    }

    private func emit(_ s: Sample) {
        if Thread.isMainThread { onUpdate?(s) }
        else { DispatchQueue.main.async { [weak self] in self?.onUpdate?(s) } }
    }
}
