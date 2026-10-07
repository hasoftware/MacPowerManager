import AppKit
import PowerCore
import SwiftUI

/// Bảng nhanh mở từ thanh menu (rộng 340 pt). Nền là vật liệu menu của hệ thống; các khối dùng nền nhạt.
struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Page.storageKey) private var page: Page = .overview

    static let width: CGFloat = 340

    var body: some View {
        let summary = model.summary
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            PopoverHeader(summary: summary, openDashboard: { openDashboard(nil) })

            if let banner = model.banner {
                BannerView(banner: banner, style: .compact)
            }
            // Giữ banner chuyển vào Applications kể cả khi có banner ưu tiên hơn.
            if model.needsMove && model.banner != .moveApp {
                BannerView(banner: .moveApp, style: .compact)
            }

            LimitPanel(openLimitPage: { openDashboard(.limit) })
            QuickActionsPanel()
            StatsPanel()

            if let error = model.helper.errorMessage {
                Label {
                    Text(error).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            }

            footer
        }
        .padding(14)
        .frame(width: Self.width)
        .onAppear {
            model.refresh()
            Task { await model.helper.refresh() }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                openDashboard(nil)
            } label: {
                Label("Mở bảng điều khiển", systemImage: "macwindow")
            }
            Spacer()
            Button("Thoát") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 2)
    }

    private func openDashboard(_ target: Page?) {
        if let target { page = target }
        openWindow(id: WindowID.dashboard)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct PopoverHeader: View {
    let summary: PowerSummary
    let openDashboard: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            ChargeRing(percent: summary.percent, limit: summary.limit, sailingFloor: summary.sailingFloor,
                       tint: summary.state.tint, lineWidth: 5) {
                Image(systemName: summary.state.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(summary.state.tint)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                // Chip dài (ví dụ "Tạm dừng do pin nóng") xuống dòng riêng thay vì bị cắt chữ.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: Theme.Space.s) {
                        percent
                        StateChip(state: summary.state, title: summary.title).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        percent
                        StateChip(state: summary.state, title: summary.title)
                    }
                }
                Text(summary.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(summary.detail)
            }
            Spacer(minLength: 0)
            Button(action: openDashboard) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
                    .background(Theme.panel, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Mở bảng điều khiển")
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var percent: some View {
        Text("\(summary.percent)%")
            .font(Theme.popoverPercent)
            .contentTransition(.numericText(value: Double(summary.percent)))
            .motion(.snappy, value: summary.percent)
            .fixedSize()
    }
}

/// Khối "Giới hạn sạc": công tắc, thanh giới hạn, nút chọn nhanh.
private struct LimitPanel: View {
    @Environment(AppModel.self) private var model
    let openLimitPage: () -> Void

    var body: some View {
        let helper = model.helper
        let config = helper.config
        let summary = model.summary
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: Theme.Space.s) {
                Text("Giới hạn sạc").font(.callout.weight(.semibold))
                Spacer()
                Text(config.chargeLimitEnabled ? "\(config.chargeLimit)%" : String(localized: "Tắt"))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(config.chargeLimit)))
                    .motion(.snappy, value: config.chargeLimit)
                Toggle("Giới hạn sạc", isOn: helper.binding(\.chargeLimitEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            LimitBar(limit: config.chargeLimit, percent: model.battery?.percent,
                     sailingGap: model.sailingGapForDisplay, range: model.limitRange,
                     fillTint: summary.state.tint, onCommit: model.setLimit)
                .disabled(!config.chargeLimitEnabled)
            HStack(spacing: Theme.Space.s) {
                LimitPresets(current: config.chargeLimit, onSelect: model.setLimit)
                    .disabled(!config.chargeLimitEnabled)
                Spacer(minLength: 4)
                if helper.topUpActive {
                    Label("Đang sạc đầy một lần", systemImage: "arrow.up.to.line")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .layoutPriority(-1)
                } else if let floor = summary.sailingFloor, config.chargeLimitEnabled {
                    Text("Sạc lại dưới \(floor)%")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .layoutPriority(-1)
                } else if model.isIntel {
                    Button("Ghi chú Intel", action: openLimitPage)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .disabled(!model.canControl)
    }
}

/// Bốn ô thao tác nhanh.
private struct QuickActionsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let config = model.helper.config
        HStack(spacing: Theme.Space.s) {
            QuickTile(title: "Tạm dừng", symbol: "pause.fill", isOn: model.isOn(\.pauseCharging), tint: .indigo,
                      action: model.togglePause)
                .help(model.isIntel ? "Firmware giữ pin ở mức hiện tại (từ 50% trở lên)." : "Pin giữ nguyên, máy chạy bằng bộ sạc.")
            if !model.isIntel {
                QuickTile(title: "Xả pin", symbol: "arrow.down.to.line", isOn: model.isOn(\.dischargeEnabled), tint: .purple,
                          action: model.toggleDischarge)
                    .disabled(!model.canDischarge)
                    .help("Xả về \(config.dischargeTarget)% dù vẫn cắm sạc.")
            }
            QuickTile(title: "Sạc đầy", symbol: "arrow.up.to.line", isOn: model.helper.topUpActive, tint: .blue,
                      action: model.toggleTopUp)
                .disabled(!model.canTopUp || model.helper.isSending)
                .help("Sạc đầy một lần tới 100%, giới hạn trở lại khi rút sạc.")
            QuickTile(title: "Chống nóng", symbol: "thermometer.medium", isOn: model.isOn(\.thermalProtectionEnabled),
                      tint: .orange, action: model.toggleThermal)
                .help("Dừng sạc khi pin ≥ \(Int(config.thermalPauseAbove))°C.")
        }
        .disabled(!model.canControl)
    }
}

/// Lưới thông số 3 cột.
private struct StatsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let b = model.battery
        Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: 10) {
            GridRow {
                Stat(title: "Nhiệt độ", value: Format.temperature(model.temperature),
                     warning: (model.temperature ?? 0) >= (model.activeConfig?.thermalPauseAbove ?? 45))
                Stat(title: "Công suất pin", value: b.map { Format.watts($0.batteryPower, signed: true) } ?? "—")
                Stat(title: "Tiêu thụ", value: Format.watts(b?.systemLoad))
            }
            GridRow {
                Stat(title: "Bộ sạc", value: charger(b))
                Stat(title: "Tình trạng", value: b.map { Format.percent($0.health) } ?? "—")
                Stat(title: "Số lần sạc", value: b.map { "\($0.cycleCount)" } ?? "—")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }

    private func charger(_ b: BatteryInfo?) -> String {
        guard let b, b.externalConnected else { return String(localized: "Chưa cắm") }
        return b.adapterWatts.map { "\($0) W" } ?? String(localized: "Đã cắm")
    }
}

private struct Stat: View {
    let title: LocalizedStringKey
    let value: String
    var warning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(warning ? .orange : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
