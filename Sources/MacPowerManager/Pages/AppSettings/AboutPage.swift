import AppKit
import PowerCore
import SwiftUI

/// Giới thiệu: phiên bản, mã nguồn, giấy phép.
struct AboutPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPage {
            Section {
                VStack(spacing: Theme.Space.m) {
                    AppLogo(size: 88)
                    VStack(spacing: 4) {
                        Text(verbatim: "MacPowerManager")
                            .font(.title.weight(.semibold))
                        Text("Phiên bản \(AppVersion.current)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text("Giữ pin khỏe lâu hơn bằng một vạch giới hạn: sạc tới mức bạn chọn, rồi để máy chạy bằng bộ sạc.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.l)
            }

            Section {
                LinkRow(title: "Mã nguồn trên GitHub", symbol: "chevron.left.forwardslash.chevron.right", url: Links.repository)
                LinkRow(title: "Báo lỗi hoặc góp ý", symbol: "ladybug", url: Links.issues)
                LinkRow(title: "Giấy phép GNU GPL v3", symbol: "doc.text", url: Links.license)
            } header: {
                Text("Liên kết")
            } footer: {
                Footnote("MacPowerManager là phần mềm mã nguồn mở, độc lập và miễn phí, phát hành theo giấy phép GPL-3.0. Không liên kết với Apple hay nhà phát triển ứng dụng quản lý pin nào khác.")
            }

            Section {
                LabeledContent("Lịch sử pin", value: String(localized: "\(model.history.samples.count) mẫu"))
                LabeledContent("Giữ trong", value: String(localized: "7 ngày"))
            } header: {
                Text("Dữ liệu trên máy")
            } footer: {
                Footnote("Mọi dữ liệu nằm trên máy này; app không gửi gì ra ngoài.")
            }
        }
    }
}

private struct LinkRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
