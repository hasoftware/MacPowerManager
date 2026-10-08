import AppKit
import PowerCore
import SwiftUI

/// Banner theo ngữ cảnh. `.full` cho Tổng quan, `.compact` (một dòng) cho bảng nhanh.
struct BannerView: View {
    enum Style { case full, compact }

    let banner: AppBanner
    var style: Style = .full

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Page.storageKey) private var page: Page = .overview
    @State private var confirmIntel = false

    var body: some View {
        Group {
            switch style {
            case .full: full
            case .compact: compact
            }
        }
        .intelInstallConfirmation(isPresented: $confirmIntel, helper: model.helper)
    }

    private var full: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: banner.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(banner.tint)
                .frame(width: 32, height: 32)
                .background(banner.tint.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(banner.title).font(.headline)
                Text(banner.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Theme.Space.m)
            actionButton(short: false)
                .controlSize(.regular)
                .fixedSize()
                .frame(minHeight: 32)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(banner.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(banner.tint.opacity(0.3), lineWidth: 1))
    }

    private var compact: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: banner.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(banner.tint)
                .frame(width: 18)
            Text(banner.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(banner.message)
            Spacer(minLength: 4)
            actionButton(short: true)
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(banner.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }

    @ViewBuilder
    private func actionButton(short: Bool) -> some View {
        if let action = banner.action {
            Button(short ? banner.shortActionTitle : banner.actionTitle) { perform(action) }
                .disabled(model.helper.isBusy && (action == .installHelper || action == .reinstallHelper))
        }
    }

    private func perform(_ action: AppBanner.Action) {
        switch action {
        case .installHelper, .reinstallHelper:
            if Platform.isAppleSilicon || model.helper.installState != .notInstalled {
                Task { await model.helper.install() }
            } else {
                confirmIntel = true
            }
        case .openSystemPage:
            page = .system
            openWindow(id: WindowID.dashboard)
            NSApp.activate(ignoringOtherApps: true)
        case .moveApp:
            AppMover.moveAndRelaunch()
        case .reportIssue:
            NSWorkspace.shared.open(Links.issues)
        case .showWhatsNew:
            openWindow(id: WindowID.whatsNew)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

enum WindowID {
    static let dashboard = "dashboard"
    static let whatsNew = "whats-new"
}

enum Links {
    static let repository = URL(string: "https://github.com/hasoftware/MacPowerManager")!
    static let issues = URL(string: "https://github.com/hasoftware/MacPowerManager/issues")!
    static let license = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
    static let releases = URL(string: "https://github.com/hasoftware/MacPowerManager/releases")!

    // Tác giả: HASOFTWARE
    static let authorGitHub = URL(string: "https://github.com/hasoftware")!
    static let authorTelegram = URL(string: "https://t.me/hoanganhdev")!
    static let authorFacebook = URL(string: "https://www.facebook.com/100007353125377")!
}

extension View {
    /// Hộp thoại xác nhận trước khi cài helper thử nghiệm trên máy Intel.
    func intelInstallConfirmation(isPresented: Binding<Bool>, helper: HelperClient) -> some View {
        alert("Điều khiển sạc trên Intel (thử nghiệm)", isPresented: isPresented) {
            Button("Cài helper") { Task { await helper.install() } }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("App sẽ ghi giới hạn vào firmware (key BCLM, 50–100%). Firmware giữ giới hạn cả khi máy ngủ hoặc tắt, kể cả khi đã xóa app, nên hãy gỡ helper trong app trước khi xóa app (gỡ helper trả giới hạn về 100%). Pin có thể vượt khoảng 3%; không dừng sạc được dưới 50%. Tính năng chưa được kiểm chứng trên mọi máy Intel. Nên tắt \"Optimized Battery Charging\" trong System Settings → Battery.")
        }
    }
}
