import Foundation

// Formats byte counts and byte-rates with automatic unit selection and
// locale-aware decimals (so id_ID shows "17,82 GB"). Decimal (1000) by default;
// binary (1024) when requested. Single-threaded use (main thread) is assumed.
enum ByteFormatter {
    // Overridable so tests can pin decimal separators; the app uses the user's locale.
    static var locale: Locale = .current

    private static let totalUnits = ["B", "KB", "MB", "GB", "TB"]
    private static let binaryUnits = ["B", "KiB", "MiB", "GiB", "TiB"]

    private static let number: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0       // trailing zeros trimmed: 1.50 -> "1.5"
        f.roundingMode = .halfUp
        // Binary units allow 1000-1023, and "1.023" reads as one in id_ID.
        f.usesGroupingSeparator = false
        return f
    }()

    // Live speed for the menu bar — compact (few decimals).
    static func speed(_ bytesPerSec: Double, binary: Bool = false) -> String {
        format(bytesPerSec, units: (binary ? binaryUnits : totalUnits).map { $0 + "/s" }, binary: binary, compact: true)
    }

    // Cumulative totals for the dropdown / history — a touch more precision.
    static func total(_ bytes: UInt64, binary: Bool = false) -> String {
        format(Double(bytes), units: binary ? binaryUnits : totalUnits, binary: binary, compact: false)
    }

    private static func format(_ value: Double, units: [String], binary: Bool, compact: Bool) -> String {
        let factor = binary ? 1024.0 : 1000.0
        var v = max(0, value)
        var unit = 0
        while v >= factor && unit < units.count - 1 {
            v /= factor
            unit += 1
        }

        func decimals(for x: Double) -> Int {
            if unit == 0 { return 0 }               // whole bytes
            if compact { return x >= 100 ? 0 : 1 }  // menu bar: keep it short
            return x >= 100 ? 1 : 2                  // totals: a bit more precision
        }

        // Rounding to the display decimals can push the value up to `factor`
        // (e.g. 999.96 → 1000), which would print "1000 MB" instead of "1.0 GB".
        // Re-promote to the next unit in that case.
        var dp = decimals(for: v)
        let scale = pow(10.0, Double(dp))
        let rounded = (v * scale).rounded() / scale
        if rounded >= factor && unit < units.count - 1 {
            v = rounded / factor
            unit += 1
            dp = decimals(for: v)
        }

        number.locale = locale
        number.maximumFractionDigits = dp
        let n = number.string(from: NSNumber(value: v)) ?? "\(v)"
        return "\(n) \(units[unit])"
    }
}
