import PowerCore
import SwiftUI

/// Khung cho các trang theo dõi: cuộn, lề 24 pt, nội dung tối đa 1120 pt và căn giữa.
/// Nội dung nhận độ rộng khả dụng (đo từ khung trang, không phụ thuộc chính nội dung) để chọn số cột.
struct MonitorPage<Content: View>: View {
    @ViewBuilder var content: (_ width: CGFloat) -> Content

    static var maxContentWidth: CGFloat { 1120 }

    var body: some View {
        GeometryReader { geo in
            let width = max(min(geo.size.width - Theme.Space.xl * 2, Self.maxContentWidth), 0)
            ScrollView {
                content(width)
                    .frame(width: width)
                    .padding(.vertical, Theme.Space.xl)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.canvas)
    }
}

/// Khung cho các trang cài đặt: Form kiểu nhóm như System Settings.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
    }
}

/// Chú thích dưới mỗi nhóm cài đặt (căn trái, tự xuống dòng).
struct Footnote: View {
    let text: Text

    init(_ key: LocalizedStringKey) { text = Text(key) }
    init(verbatim: String) { text = Text(verbatim) }

    var body: some View {
        text
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Thông báo trong Form khi chưa điều khiển được sạc (chưa có helper hoặc máy không hỗ trợ).
struct ControlUnavailableSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let banner = model.banners.first(where: { [.helperMissing, .unsupported].contains($0) || $0.id == "helperOutdated" }) {
            Section {
                BannerView(banner: banner)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
    }
}

/// Dòng lỗi gần nhất từ helper.
struct HelperErrorSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.helper.errorMessage {
            Section {
                Label {
                    Text(error).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                .foregroundStyle(.red)
            }
        }
    }
}

extension HelperStatus {
    /// "CHTE · CHIE": phương thức chặn sạc và ngắt adapter đang dùng.
    var methodText: String {
        let charge = capabilities?.chargeMethod ?? chargingKeys
        let adapter = capabilities?.adapterMethod ?? adapterKeys
        let parts = [charge, adapter].compactMap { $0 }
        return parts.isEmpty ? String(localized: "Không có") : parts.joined(separator: " · ")
    }
}

extension EffectState {
    var label: String {
        switch self {
        case .notApplicable: String(localized: "Không cần xác minh")
        case .pending: String(localized: "Đang xác minh…")
        case .verified: String(localized: "Đã xác minh")
        case .ineffective: String(localized: "Chưa có hiệu lực")
        }
    }

    var symbol: String {
        switch self {
        case .notApplicable: "minus.circle"
        case .pending: "clock"
        case .verified: "checkmark.seal.fill"
        case .ineffective: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notApplicable: .secondary
        case .pending: .blue
        case .verified: .green
        case .ineffective: .orange
        }
    }
}

/// Nhãn trạng thái hiệu lực có biểu tượng.
struct EffectLabel: View {
    let effect: EffectState?

    var body: some View {
        if let effect {
            Label {
                Text(effect.label)
            } icon: {
                Image(systemName: effect.symbol).foregroundStyle(effect.tint)
            }
        } else {
            Text("Helper chưa báo cáo").foregroundStyle(.secondary)
        }
    }
}
