import XCTest
@testable import MacPowerManager

/// Tùy chọn Giám sát hệ thống: tắt mặc định, kể cả với cài đặt lưu từ bản cũ chưa có trường này.
final class SystemMonitoringSettingTests: XCTestCase {
    func testOffByDefault() {
        XCTAssertFalse(Preferences().systemMonitoring)
    }

    func testOldSettingsWithoutFieldDecodeAsOff() throws {
        let old = #"{"showPercentInMenuBar":true,"menuBarStyle":"inside","autoCheckUpdates":false}"#
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(old.utf8))
        XCTAssertFalse(prefs.systemMonitoring)
        XCTAssertFalse(prefs.autoCheckUpdates, "các trường khác vẫn được đọc")
    }

    func testRoundTrip() throws {
        var prefs = Preferences()
        prefs.systemMonitoring = true
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertTrue(decoded.systemMonitoring)
    }

    func testOnlyMonitorPagesAreGated() {
        XCTAssertTrue(Page.cpu.isSystemMonitor)
        XCTAssertTrue(Page.processes.isSystemMonitor)
        XCTAssertFalse(Page.aboutMac.isSystemMonitor, "Giới thiệu máy này là thông tin tĩnh")
        XCTAssertFalse(Page.overview.isSystemMonitor)
        XCTAssertFalse(Page.limit.isSystemMonitor)
    }
}
