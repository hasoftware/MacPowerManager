import ServiceManagement
import SwiftUI

/// Thanh menu: kiểu hiển thị, xem trước trực tiếp (sáng/tối), chú giải biểu tượng, mở cùng macOS.
struct MenuBarPage: View {
    @Environment(AppModel.self) private var model
    @State private var login = LoginItemState()

    var body: some View {
        @Bindable var model = model
        let content = model.menuBarContent
        SettingsPage {
            Section {
                HStack(spacing: Theme.Space.m) {
                    MenuBarStrip(content: content, dark: false)
                    MenuBarStrip(content: content, dark: true)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Xem trước")
            } footer: {
                if MenuBarRenderer.size(for: content).width > MenuBarRenderer.notchWarningWidth {
                    Footnote("Mục rộng có thể bị che bởi notch.")
                } else {
                    Footnote("Vạch dọc trên biểu tượng là mức giới hạn sạc đang áp dụng.")
                }
            }

            Section {
                HStack(spacing: Theme.Space.s) {
                    ForEach(MenuBarStyle.allCases) { style in
                        StyleOption(style: style, selected: model.prefs.menuBarStyle == style,
                                    content: MenuBarContent(percent: content.percent ?? 80, limit: content.limit ?? 80,
                                                            state: content.state, style: style,
                                                            showPercent: model.prefs.showPercentInMenuBar)) {
                            model.prefs.menuBarStyle = style
                        }
                    }
                }
                .padding(.vertical, 4)
                Toggle("Hiện phần trăm", isOn: $model.prefs.showPercentInMenuBar)
                    .disabled(model.prefs.menuBarStyle == .text)
                Toggle("Ẩn phần trăm khi đã đầy và đang cắm sạc", isOn: $model.prefs.hidePercentWhenFull)
                    .disabled(model.prefs.menuBarStyle == .text || !model.prefs.showPercentInMenuBar)
                Toggle(isOn: $model.prefs.menuBarColored) {
                    Text("Tô màu theo trạng thái")
                    Text("Mặc định biểu tượng đơn sắc và tự đổi màu theo thanh menu, giống các biểu tượng hệ thống.")
                }
                .disabled(model.prefs.menuBarStyle == .text)
            } header: {
                Text("Kiểu hiển thị")
            }

            if model.prefs.menuBarStyle == .glyph {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: 10) {
                        ForEach(Self.legend, id: \.self) { state in
                            LegendItem(state: state, percent: Self.legendPercent(state), colored: model.prefs.menuBarColored)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Ý nghĩa biểu tượng")
                }
            }

            Section {
                Toggle("Mở cùng macOS", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                if login.requiresApproval {
                    LabeledContent {
                        Button("Mở Cài đặt hệ thống") { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Text("Cần cho phép trong Cài đặt hệ thống › Mục đăng nhập.")
                    }
                }
                if let error = login.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Khởi động")
            } footer: {
                Footnote("App sống trên thanh menu: đóng cửa sổ này app vẫn chạy. Helper vẫn giữ giới hạn sạc kể cả khi app đã thoát.")
            }
        }
        // Người dùng có thể đổi Mục đăng nhập trong Cài đặt hệ thống, nên đọc lại mỗi khi mở trang.
        .onAppear { login.refresh() }
    }

    private static let legend: [PowerState] = [.charging, .holding, .paused, .heat, .discharging, .topUp, .full, .low]

    private static func legendPercent(_ state: PowerState) -> Int {
        switch state {
        case .low, .critical: 12
        case .discharging: 64
        case .topUp: 90
        case .full: 100
        case .charging: 48
        default: 80
        }
    }
}

/// Một dòng chú giải: biểu tượng của trạng thái và tên của nó.
private struct LegendItem: View {
    let state: PowerState
    let percent: Int
    let colored: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(nsImage: MenuBarRenderer.previewImage(
                for: MenuBarContent(percent: percent, limit: 80, state: state, showPercent: false, colored: colored),
                dark: scheme == .dark))
                .renderingMode(colored ? .original : .template)
                .foregroundStyle(.primary)
                .frame(width: 30, alignment: .leading)
            Text(state.legendTitle)
                .font(.callout)
                .lineLimit(1)
        }
    }
}

/// Dải thanh menu giả để xem trước trên nền sáng hoặc tối.
private struct MenuBarStrip: View {
    let content: MenuBarContent
    let dark: Bool

    var body: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(nsImage: MenuBarRenderer.previewImage(for: content, dark: dark))
            Image(systemName: "wifi")
                .font(.system(size: 13, weight: .medium))
            Text(verbatim: "14:32")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(dark ? Color.white : Color.black.opacity(0.85))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(
            LinearGradient(colors: dark ? [Color(white: 0.16), Color(white: 0.11)] : [Color(white: 0.93), Color(white: 0.86)],
                           startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.cardStroke))
        .environment(\.colorScheme, dark ? .dark : .light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dark ? Text("Xem trước trên thanh menu tối") : Text("Xem trước trên thanh menu sáng"))
    }
}

/// Ô chọn kiểu hiển thị, vẽ bằng chính bộ vẽ thanh menu.
private struct StyleOption: View {
    let style: MenuBarStyle
    let selected: Bool
    let content: MenuBarContent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(nsImage: MenuBarRenderer.previewImage(for: content, dark: false))
                    .renderingMode(.template)
                    .foregroundStyle(.primary)
                    .frame(height: 22)
                Text(style.title)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 74)
            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(Theme.panel),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Theme.cardStroke, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Trạng thái "Mở cùng macOS" qua `SMAppService.mainApp`.
struct LoginItemState {
    var enabled = false
    var requiresApproval = false
    var error: String?

    mutating func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
        requiresApproval = status == .requiresApproval
    }

    mutating func set(_ value: Bool) {
        guard value != enabled else { return }
        do {
            if value {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = String(localized: "Không thể thay đổi: \(error.localizedDescription)")
        }
        refresh()
    }
}
