import SwiftUI

/// Thẻ trên các trang theo dõi: tiêu đề nhỏ có biểu tượng, phụ kiện bên phải, nội dung.
struct Card<Content: View, Accessory: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    var tint: Color = .secondary
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .imageScale(.small)
                    .frame(width: 16)
                Text(title)
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
    init(title: LocalizedStringKey, symbol: String, tint: Color = .secondary, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.accessory = EmptyView()
        self.content = content()
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
