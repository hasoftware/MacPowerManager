import PowerCore
import SwiftUI

/// Tổng quan: banner, lưới thẻ pin 4 cột (2 cột khi vùng nội dung hẹp hơn 800 pt), rồi phần Hệ thống.
struct OverviewPage: View {
    @Environment(AppModel.self) private var model

    private let gap = Theme.Space.m

    var body: some View {
        MonitorPage { width in
            VStack(spacing: gap) {
                if let banner = model.banner {
                    BannerView(banner: banner)
                }
                // Máy không có pin (Mac mini, iMac…) chỉ có phần Hệ thống.
                if model.battery != nil {
                    grid(width: width)
                }
                SystemOverviewGrid(width: width)
            }
        }
        .toolbar { SystemToolbar(monitor: model.system) }
    }

    private func columns(_ width: CGFloat) -> Int { width < 800 ? 2 : 4 }

    private func span(_ n: Int, width: CGFloat) -> CGFloat {
        let columns = columns(width)
        let column = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        return max(column * CGFloat(n) + gap * CGFloat(n - 1), 0)
    }

    @ViewBuilder
    private func grid(width: CGFloat) -> some View {
        let wide = columns(width) == 4
        VStack(spacing: gap) {
            if wide {
                HStack(spacing: gap) {
                    HeroCard().frame(width: span(2, width: width), height: 220)
                    FlowCard().frame(width: span(2, width: width), height: 220)
                }
                HStack(spacing: gap) { statCards.frame(width: span(1, width: width), height: 128) }
            } else {
                HeroCard().frame(height: 220)
                FlowCard().frame(height: 220)
                Grid(horizontalSpacing: gap, verticalSpacing: gap) {
                    GridRow { TemperatureCard(); BatteryPowerCard() }
                    GridRow { SystemLoadCard(); ChargerCard() }
                }
                .frame(height: 128 * 2 + gap)
            }
            LevelCard().frame(height: 260)
            if wide {
                HStack(spacing: gap) {
                    HealthCard().frame(width: span(2, width: width), height: 180)
                    HelperCard().frame(width: span(2, width: width), height: 180)
                }
            } else {
                HealthCard().frame(height: 180)
                HelperCard().frame(height: 180)
            }
        }
    }

    @ViewBuilder
    private var statCards: some View {
        TemperatureCard()
        BatteryPowerCard()
        SystemLoadCard()
        ChargerCard()
    }
}

// MARK: - Trạng thái pin

private struct HeroCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = model.summary
        Card(title: "Trạng thái pin", symbol: "battery.100percent", tint: summary.state.tint) {
            HStack(alignment: .center, spacing: 20) {
                ChargeRing(percent: summary.percent, limit: summary.limit, sailingFloor: summary.sailingFloor,
                           tint: summary.state.tint, lineWidth: 12) {
                    VStack(spacing: 2) {
                        Image(systemName: summary.state.symbol)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(summary.state.tint)
                        if let limit = summary.limit {
                            Text("Giới hạn \(limit)%")
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 120, height: 120)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(summary.percent)%")
                        .font(Theme.heroPercent)
                        .contentTransition(.numericText(value: Double(summary.percent)))
                        .motion(.snappy, value: summary.percent)
                    StateChip(state: summary.state, title: summary.title)
                    Text(summary.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(summary.detail)
                    Spacer(minLength: 6)
                    HStack(spacing: Theme.Space.s) {
                        QuickTile(title: "Giới hạn", symbol: "battery.75percent", isOn: model.isOn(\.chargeLimitEnabled),
                                  tint: .teal, height: 58, action: model.toggleLimit)
                        QuickTile(title: "Tạm dừng", symbol: "pause.fill", isOn: model.isOn(\.pauseCharging),
                                  tint: .indigo, height: 58, action: model.togglePause)
                        QuickTile(title: "Chống nóng", symbol: "thermometer.medium",
                                  isOn: model.isOn(\.thermalProtectionEnabled), tint: .orange, height: 58,
                                  action: model.toggleThermal)
                    }
                    .disabled(!model.canControl)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Dòng điện năng

private struct FlowCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let b = model.battery ?? BatteryInfo()
        let cut = model.summary.state == .discharging
        Card(title: "Dòng điện năng", symbol: "bolt.horizontal", tint: .green) {
            Text(cut ? "Đang xả pin" : b.externalConnected ? "Đang cắm sạc" : "Đang dùng pin")
                .font(.caption)
                .foregroundStyle(.secondary)
        } content: {
            PowerFlowView(flow: .init(adapterIn: b.systemPowerIn, adapterRated: b.adapterWatts,
                                      system: b.systemLoad, battery: b.batteryPower, percent: b.percent,
                                      pluggedIn: b.externalConnected, adapterCut: cut,
                                      batteryTint: model.summary.state.tint))
        }
    }
}

// MARK: - Thẻ số liệu

/// Thẻ số liệu nhỏ: giá trị lớn + chú thích + biểu đồ 1 giờ.
struct StatCard: View {
    let title: LocalizedStringKey
    let symbol: String
    var tint: Color
    let value: String
    var unit: String?
    var caption: String?
    var series: ChartSeries
    var threshold: Double?
    var signed = false

    var body: some View {
        Card(title: title, symbol: symbol, tint: tint) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    ValueText(value: value, unit: unit)
                    Spacer(minLength: 4)
                    if let caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Sparkline(series: series, tint: tint, threshold: threshold, signed: signed)
            }
        }
    }
}

private extension AppModel {
    var lastHour: [HistorySample] { history.samples(within: 3600) }
}

private struct TemperatureCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let threshold = model.activeConfig.flatMap { $0.thermalProtectionEnabled ? $0.thermalPauseAbove : nil }
        let hot = threshold.map { (model.temperature ?? 0) >= $0 - 2 } ?? false
        StatCard(title: "Nhiệt độ pin", symbol: "thermometer.medium", tint: hot ? .orange : .pink,
                 value: model.temperature.map { Format.number($0) } ?? "—", unit: "°C",
                 caption: threshold.map { String(localized: "Ngưỡng \(Int($0))°C") },
                 series: model.lastHour.series { $0.temperature }, threshold: threshold)
    }
}

private struct BatteryPowerCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let power = model.battery?.batteryPower ?? 0
        let caption = power > 0.3 ? String(localized: "Đang nạp")
            : power < -0.3 ? String(localized: "Đang cấp điện") : String(localized: "Không sạc")
        StatCard(title: "Công suất pin", symbol: "battery.100percent.bolt", tint: .green,
                 value: model.battery == nil ? "—" : signedNumber(power), unit: "W", caption: caption,
                 series: model.lastHour.series { $0.batteryPower }, signed: true)
    }

    private func signedNumber(_ v: Double) -> String {
        abs(v) < 0.05 ? Format.number(0) : (v > 0 ? "+" : "−") + Format.number(abs(v))
    }
}

private struct SystemLoadCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        StatCard(title: "Hệ thống tiêu thụ", symbol: "laptopcomputer", tint: .blue,
                 value: model.battery?.systemLoad.map { Format.number($0) } ?? "—", unit: "W",
                 caption: nil, series: model.lastHour.series { $0.systemLoad })
    }
}

private struct ChargerCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let b = model.battery
        let plugged = b?.externalConnected == true
        StatCard(title: "Bộ sạc", symbol: "powerplug.fill", tint: .mint,
                 value: plugged ? (b?.adapterWatts.map(String.init) ?? "—") : String(localized: "Chưa cắm"),
                 unit: plugged && b?.adapterWatts != nil ? "W" : nil,
                 caption: plugged ? b?.systemPowerIn.map { String(localized: "Đang cấp \(Format.watts($0))") } : nil,
                 series: model.lastHour.series { $0.powerIn ?? ($0.pluggedIn ? nil : 0) })
    }
}

// MARK: - Mức pin

private struct LevelCard: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Page.storageKey) private var page: Page = .overview

    var body: some View {
        let samples = model.history.samples(within: 24 * 3600)
        Card(title: "Mức pin · 24 giờ", symbol: "chart.xyaxis.line", tint: .green) {
            Button("Xem lịch sử") { page = .history }
                .buttonStyle(.link)
                .font(.caption)
        } content: {
            if samples.count < 2 {
                ContentUnavailableView("Chưa có dữ liệu", systemImage: "chart.xyaxis.line",
                                       description: Text("Lịch sử sẽ xuất hiện sau vài phút."))
            } else {
                BatteryLevelChart(samples: samples, limit: model.summary.limit, tint: .green, showsLegend: true)
            }
        }
    }
}

// MARK: - Tình trạng pin

private struct HealthCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let b = model.battery ?? BatteryInfo()
        Card(title: .batteryHealthCardTitle, symbol: "heart.text.square", tint: .pink) {
            HStack(spacing: 20) {
                HealthRing(health: model.healthPercent(b))
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 8) {
                    InfoRow("Dung lượng tối đa", "\(Format.integer(b.maxCapacity)) mAh")
                    InfoRow("Dung lượng thiết kế", "\(Format.integer(b.designCapacity)) mAh")
                    VStack(alignment: .leading, spacing: 4) {
                        InfoRow("Số lần sạc", "\(Format.integer(b.cycleCount)) / \(Format.integer(b.designCycleCount))")
                        ProgressView(value: Double(min(b.cycleCount, b.designCycleCount)),
                                     total: Double(max(b.designCycleCount, 1)))
                            .progressViewStyle(.linear)
                            .tint(.pink)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// Vòng tình trạng pin (dung lượng tối đa so với thiết kế).
struct HealthRing: View {
    let health: Double
    var lineWidth: CGFloat = 9

    private var tint: Color { health >= 80 ? .green : health >= 70 ? .orange : .red }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(health, 0), 100)) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(Format.percent(health))
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text("Tình trạng")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(lineWidth / 2)
    }
}

// MARK: - Helper

private struct HelperCard: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Page.storageKey) private var page: Page = .overview

    var body: some View {
        let helper = model.helper
        let status = helper.status
        Card(title: "Helper", symbol: "lock.shield", tint: helper.isReady ? .green : .orange) {
            Button("Chi tiết") { page = .system }
                .buttonStyle(.link)
                .font(.caption)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                InfoRow("Trạng thái", installText(helper.installState),
                        valueColor: helper.isReady ? .green : .orange)
                InfoRow("Phương thức", status?.methodText ?? "—")
                HStack {
                    Text("Hiệu lực").foregroundStyle(.secondary)
                    Spacer()
                    EffectLabel(effect: status?.effect)
                }
                .font(.callout)
                InfoRow("Lý do hiện tại", status?.reason.label ?? "—")
            }
        }
    }
}

func installText(_ state: HelperClient.InstallState) -> String {
    switch state {
    case .installed: String(localized: "Đang chạy (v\(AppVersion.current))")
    case .outdated("?"): String(localized: "Cần cài lại")
    case .outdated(let version): String(localized: "Phiên bản cũ (v\(version))")
    case .notInstalled: String(localized: "Chưa cài")
    case .unknown: String(localized: "Đang kiểm tra…")
    }
}
