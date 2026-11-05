import Foundation

func testSystemFormat() {
    // Percent: rounds half up, clamps to 0...100.
    T.eq(SystemFormat.percent(0.755), "76%", "percent rounds half up")
    T.eq(SystemFormat.percent(0), "0%", "percent zero")
    T.eq(SystemFormat.percent(1), "100%", "percent one")
    T.eq(SystemFormat.percent(1.4), "100%", "percent clamps high")
    T.eq(SystemFormat.percent(-0.5), "0%", "percent clamps low")
    T.eq(SystemFormat.percent(.nan), "—", "percent nan")

    // Pressure labels.
    T.eq(SystemFormat.pressureLabel(.normal), "Normal", "pressure label normal")
    T.eq(SystemFormat.pressureLabel(.warning), "Warning", "pressure label warning")
    T.eq(SystemFormat.pressureLabel(.critical), "Critical", "pressure label critical")
}
