import Foundation
import SwiftUI

/// Kiểu hiển thị trên thanh menu.
enum MenuBarStyle: String, Codable, CaseIterable, Identifiable {
    /// Số % nằm bên trong viên pin, kiểu thanh trạng thái iPhone (mặc định).
    case inside
    /// Biểu tượng pin riêng của app (có vạch giới hạn và huy hiệu trạng thái).
    case glyph
    /// Biểu tượng pin SF Symbol của hệ thống.
    case symbol
    /// Chỉ hiện phần trăm.
    case text

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .inside: "Phần trăm trong pin (kiểu iPhone)"
        case .glyph: "Biểu tượng có vạch giới hạn"
        case .symbol: "Biểu tượng pin của hệ thống"
        case .text: "Chỉ phần trăm"
        }
    }
}

/// Tùy chọn của app (không phải cấu hình helper), lưu trong UserDefaults.
struct Preferences: Codable, Equatable {
    var showPercentInMenuBar = true
    var menuBarStyle: MenuBarStyle = .inside
    /// Tô màu huy hiệu theo trạng thái thay vì ảnh template đơn sắc.
    var menuBarColored = false
    var hidePercentWhenFull = false

    var notifyLimitReached = true
    var notifyLowBattery = true
    var lowBatteryThreshold = 20
    var notifyThermal = true
    var notifyDischargeDone = true
    var notifyTopUpEnded = true
    var notifyIneffective = true
    var notifyForeignController = true
    /// Thông báo khi có phiên bản mới (một lần cho mỗi phiên bản).
    var notifyUpdate = true
    /// Thông báo các bước của hiệu chuẩn pin (cần rút sạc, đã xong) và nhắc hiệu chuẩn định kỳ.
    var notifyCalibration = true
    var calibrationReminder = true

    /// Tự kiểm tra bản mới trên GitHub lúc mở app và mỗi 24 giờ.
    var autoCheckUpdates = true

    /// Thời hạn mặc định của "Sạc đầy một lần".
    var topUpHours = 24

    private static let key = "preferences"

    init() {}

    /// Trường thiếu (từ bản cũ) hoặc sai kiểu dùng giá trị mặc định thay vì reset toàn bộ cài đặt.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        showPercentInMenuBar = value(.showPercentInMenuBar, d.showPercentInMenuBar)
        menuBarStyle = value(.menuBarStyle, d.menuBarStyle)
        menuBarColored = value(.menuBarColored, d.menuBarColored)
        hidePercentWhenFull = value(.hidePercentWhenFull, d.hidePercentWhenFull)
        notifyLimitReached = value(.notifyLimitReached, d.notifyLimitReached)
        notifyLowBattery = value(.notifyLowBattery, d.notifyLowBattery)
        lowBatteryThreshold = value(.lowBatteryThreshold, d.lowBatteryThreshold)
        notifyThermal = value(.notifyThermal, d.notifyThermal)
        notifyDischargeDone = value(.notifyDischargeDone, d.notifyDischargeDone)
        notifyTopUpEnded = value(.notifyTopUpEnded, d.notifyTopUpEnded)
        notifyIneffective = value(.notifyIneffective, d.notifyIneffective)
        notifyForeignController = value(.notifyForeignController, d.notifyForeignController)
        notifyUpdate = value(.notifyUpdate, d.notifyUpdate)
        notifyCalibration = value(.notifyCalibration, d.notifyCalibration)
        calibrationReminder = value(.calibrationReminder, d.calibrationReminder)
        autoCheckUpdates = value(.autoCheckUpdates, d.autoCheckUpdates)
        topUpHours = value(.topUpHours, d.topUpHours)
    }

    private static let insideMigrationKey = "preferences.menuBarStyle.insideMigrated"

    static func load() -> Preferences {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: key),
              var prefs = try? JSONDecoder().decode(Preferences.self, from: data) else {
            defaults.set(true, forKey: insideMigrationKey)
            return Preferences()
        }
        // v0.6.0: kiểu "số % trong pin" thành mặc định. Ai đang dùng kiểu mặc định cũ (`glyph`) được chuyển một lần;
        // người đã chọn kiểu khác giữ nguyên, và đổi lại `glyph` sau đó cũng được giữ.
        if !defaults.bool(forKey: insideMigrationKey) {
            defaults.set(true, forKey: insideMigrationKey)
            if prefs.menuBarStyle == .glyph {
                prefs.menuBarStyle = .inside
                prefs.save()
            }
        }
        return prefs
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}
