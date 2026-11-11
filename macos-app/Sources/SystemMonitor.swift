import Foundation

// MeterClock calls tick once per update interval, so that is the CPU window.
final class SystemMonitor {
    struct Sample {
        let cpuBusy: Double            // 0...1, NaN when no recent window exists
        let memory: MemoryMath.Result
    }

    var onUpdate: ((Sample) -> Void)?

    // Intervals go up to 5 s, so a longer gap means sampling paused and the delta spans it.
    private static let staleAfter: TimeInterval = 10
    private var lastTicks: CPUMath.Ticks?
    private var lastTickAt: Date?
    private var lastBusy: (value: Double, at: Date)?
    private var followUpPending = false

    func prepare() {
        lastTicks = nil
        tick()
    }

    func tick() {
        guard let pages = SystemStats.memoryPages() else { return }

        let now = Date()
        if let at = lastTickAt, now.timeIntervalSince(at) > Self.staleAfter { lastTicks = nil }
        lastTickAt = now

        var busy = Double.nan
        if let ticks = SystemStats.cpuTicks() {
            let result = CPUMath.usage(prev: lastTicks, current: ticks)
            lastTicks = ticks
            if !result.didReset {
                busy = result.busy
                lastBusy = (busy, now)
            }
        }
        // A reset has no window: a recent value stands in, otherwise the dash.
        if busy.isNaN, let last = lastBusy, now.timeIntervalSince(last.at) <= Self.staleAfter { busy = last.value }
        // A dash stays only half a second: one more sample gives the first real window.
        if busy.isNaN, !followUpPending {
            followUpPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.followUpPending = false
                self?.tick()
            }
        }

        let memory = MemoryMath.compute(pages: pages,
                                        pageSize: SystemStats.pageSize,
                                        total: SystemStats.totalRAM,
                                        pressureRaw: SystemStats.pressureLevel())
        emit(Sample(cpuBusy: busy, memory: memory))
    }

    private func emit(_ sample: Sample) {
        if Thread.isMainThread { onUpdate?(sample) }
        else { DispatchQueue.main.async { [weak self] in self?.onUpdate?(sample) } }
    }
}
