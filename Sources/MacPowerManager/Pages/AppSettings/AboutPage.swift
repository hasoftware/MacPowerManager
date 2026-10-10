import AppKit
import PowerCore
import SwiftUI

/// Giới thiệu: phiên bản, cập nhật, mã nguồn, giấy phép.
struct AboutPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
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
                    Text(verbatim: "© 2026 HASOFTWARE")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.l)
            }

            Section {
                LabeledContent("Phiên bản hiện tại") {
                    Text(verbatim: AppVersion.current).monospacedDigit()
                }
                UpdateStatusRow()
                Toggle(isOn: $model.prefs.autoCheckUpdates) {
                    Text("Tự động kiểm tra cập nhật")
                    Text("Lúc mở app và mỗi 24 giờ khi app đang chạy.")
                }
            } header: {
                Text("Cập nhật")
            } footer: {
                Footnote("Kiểm tra cập nhật chỉ đọc thông tin bản phát hành mới nhất từ api.github.com, không gửi dữ liệu cá nhân hay dữ liệu pin. App không tự tải hay cài bản mới.")
            }

            Section {
                ContactRow(name: "GitHub", handle: "@hasoftware", symbol: "person.crop.circle", url: Links.authorGitHub)
                ContactRow(name: "Telegram", handle: "@hoanganhdev", symbol: "paperplane", url: Links.authorTelegram)
                ContactRow(name: "Facebook", handle: "HASOFTWARE", symbol: "person.2", url: Links.authorFacebook)
            } header: {
                Text("Tác giả")
            } footer: {
                Footnote("MacPowerManager được phát triển bởi HASOFTWARE. Liên hệ qua Telegram hoặc Facebook để góp ý, hợp tác hoặc ủng hộ dự án.")
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
                LabeledContent("Giữ trong", value: String(localized: "30 ngày"))
            } header: {
                Text("Dữ liệu trên máy")
            } footer: {
                Footnote("Dữ liệu pin chỉ nằm trên máy này. Yêu cầu mạng duy nhất của app là kiểm tra cập nhật tới api.github.com (không kèm dữ liệu cá nhân, tắt được ở mục Cập nhật).")
            }
        }
    }
}

/// Trạng thái kiểm tra cập nhật và nút "Kiểm tra cập nhật".
private struct UpdateStatusRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let updates = model.updates
        LabeledContent {
            HStack(spacing: Theme.Space.s) {
                if updates.available != nil {
                    Button("Xem có gì mới") {
                        openWindow(id: WindowID.whatsNew)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Kiểm tra cập nhật") {
                    Task { await updates.checkNow() }
                }
                .disabled(updates.state == .checking)
            }
            .fixedSize()
        } label: {
            status(updates)
        }
    }

    @ViewBuilder
    private func status(_ updates: UpdateChecker) -> some View {
        switch updates.state {
        case .checking:
            HStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text("Đang kiểm tra cập nhật…")
            }
        case .upToDate:
            label(Text("Bạn đang dùng bản mới nhất"), symbol: "checkmark.circle.fill", tint: .green, detail: lastChecked(updates))
        case .available(let release):
            label(Text("Có bản mới v\(release.version?.description ?? release.tagName)"),
                  symbol: "arrow.down.circle.fill", tint: .blue,
                  detail: release.publishedAt.map { String(localized: "Phát hành \(Format.date($0))") })
        case .failed(let message):
            if let release = updates.available {
                // Vẫn còn bản mới đã biết: không để lỗi kiểm tra lại che mất nó.
                label(Text("Có bản mới v\(release.version?.description ?? release.tagName)"),
                      symbol: "arrow.down.circle.fill", tint: .blue,
                      detail: String(localized: "Không kiểm tra lại được: \(message)"))
            } else {
                label(Text("Không kiểm tra được cập nhật"), symbol: "exclamationmark.triangle.fill", tint: .orange, detail: message)
            }
        case .idle:
            label(Text("Chưa kiểm tra cập nhật"), symbol: "clock", tint: .secondary, detail: lastChecked(updates))
        }
    }

    private func lastChecked(_ updates: UpdateChecker) -> String? {
        updates.lastChecked.map { String(localized: "Kiểm tra lần cuối: \(Format.dateTime($0))") }
    }

    private func label(_ title: Text, symbol: String, tint: Color, detail: String?) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                title
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

/// Kênh liên hệ của tác giả: tên thương hiệu không dịch.
private struct ContactRow: View {
    let name: String
    let handle: String
    let symbol: String
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack {
                Label { Text(verbatim: name) } icon: { Image(systemName: symbol) }
                Spacer()
                Text(verbatim: handle)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
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
