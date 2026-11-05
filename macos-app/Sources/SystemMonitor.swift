import Foundation

// MeterClock calls tick every systemInterval, so the CPU window never follows the speed interval.
final class SystemMonitor {
    struct Sample {
        let cpuBusy: Double            // 0...1
        let memory: MemoryMath.Result
    }

    var onUpdate: ((Sample) -> Void)?

    private var lastTicks: CPUMath.Ticks?

    func prepare() {
        lastTicks = nil
        tick()
    }

    func tick() {
        guard let pages = SystemStats.memoryPages() else { return }

        var busy: Double = 0
        if let ticks = SystemStats.cpuTicks() {
            let result = CPUMath.usage(prev: lastTicks, current: ticks)
            lastTicks = ticks
            if !result.didReset { busy = result.busy }
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
