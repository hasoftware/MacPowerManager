import Foundation
import SwiftUI

/// Kiểu hiển thị trên thanh menu.
enum MenuBarStyle: String, Codable, CaseIterable, Identifiable {
    /// Biểu tượng pin riêng của app (có vạch giới hạn và huy hiệu trạng thái).
    case glyph
    /// Biểu tượng pin SF Symbol của hệ thống.
    case symbol
    /// Chỉ hiện phần trăm.
    case text

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .glyph: "Biểu tượng có vạch giới hạn"
        case .symbol: "Biểu tượng pin của hệ thống"
        case .text: "Chỉ phần trăm"
        }
    }
}

/// Tùy chọn của app (không phải cấu hình helper), lưu trong UserDefaults.
struct Preferences: Codable, Equatable {
    var showPercentInMenuBar = true
    var menuBarStyle: MenuBarStyle = .glyph
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
        topUpHours = value(.topUpHours, d.topUpHours)
    }

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return prefs
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}
