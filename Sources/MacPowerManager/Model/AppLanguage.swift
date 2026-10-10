import AppKit
import Foundation
import SwiftUI

/// Ngôn ngữ giao diện của riêng app (ghi đè ngôn ngữ hệ thống qua `AppleLanguages` trong miền cài đặt của app).
/// macOS chỉ đọc giá trị này lúc khởi động, nên đổi xong phải mở lại app.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, vi, en

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .system: "Theo hệ thống"
        case .vi: "Tiếng Việt"
        case .en: "English"
        }
    }

    private static let key = "AppleLanguages"

    /// Ngôn ngữ đã chọn (đọc từ miền cài đặt của app, không lẫn với cài đặt toàn hệ thống).
    static var current: AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String],
              let first = languages.first else { return .system }
        if first.hasPrefix("vi") { return .vi }
        if first.hasPrefix("en") { return .en }
        return .system
    }

    /// Ngôn ngữ đang hiển thị (đã áp dụng lúc mở app).
    static var active: AppLanguage {
        Bundle.main.preferredLocalizations.first == "vi" ? .vi : .en
    }

    func apply() {
        switch self {
        case .system: UserDefaults.standard.removeObject(forKey: Self.key)
        case .vi, .en: UserDefaults.standard.set([rawValue], forKey: Self.key)
        }
    }

    /// Mở lại app để áp dụng ngôn ngữ mới.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if error == nil {
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }
}
