import SwiftUI

/// Thẻ trên các trang theo dõi: tiêu đề nhỏ có biểu tượng, phụ kiện bên phải, nội dung.
struct Card<Content: View, Accessory: View>: View {
    let title: Text
    let symbol: String
    var tint: Color = .secondary
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(title: Text, symbol: String, tint: Color = .secondary,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.accessory = accessory()
        self.content = content()
    }

    init(title: LocalizedStringKey, symbol: String, tint: Color = .secondary,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.init(title: Text(title), symbol: symbol, tint: tint, accessory: accessory, content: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .imageScale(.small)
                    .frame(width: 16)
                title
                    .font(Theme.cardTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                accessory
            }
            content
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }
}

extension Card where Accessory == EmptyView {
    init(title: Text, symbol: String, tint: Color = .secondary, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, tint: tint, accessory: { EmptyView() }, content: content)
    }

    init(title: LocalizedStringKey, symbol: String, tint: Color = .secondary, @ViewBuilder content: () -> Content) {
        self.init(title: Text(title), symbol: symbol, tint: tint, content: content)
    }
}

extension Text {
    /// Tiêu đề thẻ "Tình trạng pin". Khóa riêng vì "Tình trạng pin" còn là tên trang (bản dịch viết hoa kiểu
    /// tiêu đề), còn tiêu đề thẻ trong bản dịch viết hoa chữ đầu như các thẻ khác.
    static var batteryHealthCardTitle: Text {
        Text(verbatim: String(localized: "Tình trạng pin (tiêu đề thẻ)", defaultValue: "Tình trạng pin"))
    }
}

/// Hàng nhãn – giá trị trong thẻ.
struct InfoRow: View {
    let title: LocalizedStringKey
    let value: String
    var valueColor: Color = .primary

    init(_ title: LocalizedStringKey, _ value: String, valueColor: Color = .primary) {
        self.title = title
        self.value = value
        self.valueColor = valueColor
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

/// Giá trị lớn kèm đơn vị nhỏ: "12,4 W".
struct ValueText: View {
    let value: String
    var unit: String?
    var font: Font = Theme.kpi

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(font)
            if let unit {
                Text(unit).font(.callout).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}
