import Foundation
import Darwin

// Kernel reads only; every calculation lives in CPUMath and MemoryMath, which are tested.
enum SystemStats {
    // mach_host_self() leaks a send right per call (measured), so take one for the whole process.
    private static let host: host_t = mach_host_self()

    // Neither of these ever changes while the machine is running.
    static let pageSize: UInt64 = UInt64(vm_kernel_page_size)
    static let totalRAM: UInt64 = sysctlUInt64("hw.memsize") ?? 0

    // MARK: - CPU

    static func cpuTicks() -> CPUMath.Ticks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, host_flavor_t(HOST_CPU_LOAD_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // Tuple order is CPU_STATE_USER, SYSTEM, IDLE, NICE.
        return CPUMath.Ticks(user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                             idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    // MARK: - Memory

    static func memoryPages() -> MemoryMath.Pages? {
        // Zero-initialised so a shorter reply from an older kernel reads as 0, not garbage.
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, host_flavor_t(HOST_VM_INFO64), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return MemoryMath.Pages(internalPages: UInt64(stats.internal_page_count),
                                purgeable: UInt64(stats.purgeable_count),
                                wired: UInt64(stats.wire_count),
                                compressed: UInt64(stats.compressor_page_count),
                                external: UInt64(stats.external_page_count),
                                free: UInt64(stats.free_count))
    }

    // The sysctl name is not in a public SDK header, so a missing key falls back to normal.
    static func pressureLevel() -> Int32 {
        sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
