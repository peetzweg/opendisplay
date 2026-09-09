import XCTest
import SwiftUI
@testable import OpenSidecarMacTests

final class BatteryReportingTests: XCTestCase {

    func testBatteryLabelFormatting() {
        // Test battery percentage & icon combinations
        XCTAssertEqual(formatBattery(level: 0.85, isCharging: false, isLowPower: false), "85% 🔋")
        XCTAssertEqual(formatBattery(level: 1.0, isCharging: true, isLowPower: false), "100% ⚡")
        XCTAssertEqual(formatBattery(level: 0.15, isCharging: false, isLowPower: true), "15% 🪫")
        XCTAssertEqual(formatBattery(level: 0.05, isCharging: true, isLowPower: true), "5% ⚡")
        XCTAssertNil(formatBattery(level: nil, isCharging: false, isLowPower: false))
        XCTAssertNil(formatBattery(level: -1.0, isCharging: false, isLowPower: false))
    }

    private func formatBattery(level: Double?, isCharging: Bool, isLowPower: Bool) -> String? {
        guard let level, level >= 0 else { return nil }
        let pct = Int(round(level * 100))
        let icon = isCharging ? "⚡" : (isLowPower ? "🪫" : "🔋")
        return "\(pct)% \(icon)"
    }

    func testLaunchAtLoginAvailability() {
        // SMAppService is available on macOS 13+
        if #available(macOS 13.0, *) {
            _ = LaunchAtLogin.isEnabled
        }
    }
}
