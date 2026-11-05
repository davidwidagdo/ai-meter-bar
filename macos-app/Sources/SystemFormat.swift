import Foundation

// Bytes go through ByteFormatter so every size uses the speed meter's units.
enum SystemFormat {
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        let clamped = min(1, max(0, fraction))
        return "\(Int((clamped * 100).rounded()))%"
    }

    static func pressureLabel(_ pressure: MemoryMath.Pressure) -> String {
        switch pressure {
        case .normal:   return "Normal"
        case .warning:  return "Warning"
        case .critical: return "Critical"
        }
    }
}
