import Foundation

/// Định dạng số liệu theo ngôn ngữ đang dùng của app: "12,4 W", "41,2°C", "3 giờ 42 phút" (tiếng Việt)
/// hoặc "12.4 W", "41.2°C", "3 hr 42 min" (tiếng Anh).
enum Format {
    /// Locale cho số, ngày giờ và cho `.environment(\.locale, …)` của các scene (SwiftUI dùng nó để chọn bản dịch).
    /// Bản dịch tiếng Việt: luôn định dạng kiểu Việt Nam ("12,4"). Ngôn ngữ khác: theo cài đặt của hệ thống.
    static let locale: Locale = {
        let language = Bundle.main.preferredLocalizations.first ?? "vi"
        if language == "vi" { return Locale(identifier: "vi_VN") }
        let current = Locale.current
        if current.language.languageCode?.identifier == language { return current }
        // Ngôn ngữ hệ thống không có bản dịch (ví dụ tiếng Pháp, app dùng tiếng Anh): giữ vùng của hệ thống nhưng
        // đổi ngôn ngữ, nếu không SwiftUI sẽ tra bản dịch theo ngôn ngữ hệ thống và trộn hai thứ tiếng.
        return Locale(identifier: current.region.map { "\(language)_\($0.identifier)" } ?? language)
    }()

    static func duration(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return String(localized: "\(m) phút") }
        // Khóa riêng để bản dịch dùng dạng viết tắt ("2 hr") như "1 hr 5 min"; "%lld giờ" (dạng đầy đủ, có số
        // nhiều) dành cho bộ chọn thời gian của Sạc đầy một lần.
        if m == 0 { return String(localized: "%lld giờ (ngắn)", defaultValue: "\(h) giờ") }
        return String(localized: "\(h) giờ \(m) phút")
    }

    /// "3:42", dùng trên thanh menu.
    static func shortDuration(minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    static func number(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
    }

    /// Số nguyên có dấu phân cách hàng nghìn kiểu Việt Nam: "1.000".
    static func integer(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    static func temperature(_ value: Double?) -> String {
        value.map { "\(number($0))°C" } ?? "—"
    }

    static func watts(_ value: Double?, signed: Bool = false) -> String {
        guard let value else { return "—" }
        let text = number(abs(value))
        guard signed, abs(value) >= 0.05 else { return "\(text) W" }
        return value > 0 ? "+\(text) W" : "−\(text) W"
    }

    static func percent(_ value: Double, digits: Int = 0) -> String {
        "\(number(value, digits: digits))%"
    }

    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    static func dateTime(_ date: Date) -> String {
        let style = Calendar.current.isDateInToday(date)
            ? Date.FormatStyle(date: .omitted, time: .shortened)
            : Date.FormatStyle(date: .abbreviated, time: .shortened)
        return date.formatted(style.locale(locale))
    }
}
