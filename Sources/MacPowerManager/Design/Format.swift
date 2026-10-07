import Foundation

/// Định dạng số liệu theo tiếng Việt: "12,4 W", "41,2°C", "3 giờ 42 phút".
enum Format {
    /// Giao diện hiện chỉ có tiếng Việt; khi thêm ngôn ngữ khác thì lấy theo ngôn ngữ của app
    /// (và bỏ `.environment(\.locale, Format.locale)` ở các scene).
    static let locale = Locale(identifier: "vi_VN")

    static func duration(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return String(localized: "\(m) phút") }
        if m == 0 { return String(localized: "\(h) giờ") }
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
