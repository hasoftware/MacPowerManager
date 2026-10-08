import PowerCore
import SwiftUI

/// Tình trạng pin: dung lượng, số lần sạc, điện áp, nhiệt độ, thông tin bộ sạc.
struct HealthPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MonitorPage { width in
            if let b = model.battery {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        Card(title: .batteryHealthCardTitle, symbol: "heart.text.square", tint: .pink) {
                            HStack(spacing: Theme.Space.xl) {
                                HealthRing(health: b.health, lineWidth: 12)
                                    .frame(width: 128, height: 128)
                                VStack(alignment: .leading, spacing: 10) {
                                    CapacityBar(title: "Thiết kế", value: b.designCapacity, max: b.designCapacity, tint: .secondary)
                                    CapacityBar(title: "Tối đa", value: b.maxCapacity, max: b.designCapacity, tint: .pink)
                                    CapacityBar(title: "Hiện tại", value: b.currentCapacity, max: b.designCapacity, tint: .green)
                                }
                            }
                        }
                        .frame(height: 210)

                        Card(title: "Số lần sạc", symbol: "arrow.triangle.2.circlepath", tint: .blue) {
                            VStack(alignment: .leading, spacing: 10) {
                                ValueText(value: Format.integer(b.cycleCount), unit: String(localized: "/ \(Format.integer(b.designCycleCount)) lần"))
                                ProgressView(value: Double(min(b.cycleCount, b.designCycleCount)),
                                             total: Double(max(b.designCycleCount, 1)))
                                    .tint(.blue)
                                Text("Pin được thiết kế để giữ khoảng 80% dung lượng sau \(b.designCycleCount) lần sạc.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(width: 300, height: 210)
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.m, alignment: .top),
                                             count: width >= 1000 ? 4 : 2),
                              spacing: Theme.Space.m) {
                        Card(title: "Điện", symbol: "bolt", tint: .yellow) {
                            VStack(spacing: 6) {
                                InfoRow("Điện áp", "\(Format.number(Double(b.voltage) / 1000, digits: 2)) V")
                                InfoRow("Dòng điện", "\(b.amperage) mA")
                                InfoRow("Công suất pin", Format.watts(b.batteryPower, signed: true))
                                InfoRow("Hệ thống tiêu thụ", Format.watts(b.systemLoad))
                            }
                        }
                        Card(title: "Nhiệt độ", symbol: "thermometer.medium", tint: .orange) {
                            VStack(spacing: 6) {
                                InfoRow("Cảm biến pin (SMC)", Format.temperature(model.smcTemperature))
                                InfoRow("Gas gauge (IOKit)", Format.temperature(b.temperature))
                                InfoRow("Ngưỡng dừng sạc", model.activeConfig.map {
                                    $0.thermalProtectionEnabled ? Format.temperature($0.thermalPauseAbove) : String(localized: "Tắt")
                                } ?? "—")
                            }
                        }
                        Card(title: "Bộ sạc", symbol: "powerplug", tint: .mint) {
                            VStack(spacing: 6) {
                                InfoRow("Đang cắm", b.externalConnected ? String(localized: "Có") : String(localized: "Không"))
                                InfoRow("Tên", b.adapterName ?? "—")
                                InfoRow("Công suất", b.adapterWatts.map { "\($0) W" } ?? "—")
                                InfoRow("Điện vào hệ thống", Format.watts(b.systemPowerIn))
                            }
                        }
                        Card(title: "Thông tin", symbol: "info.circle", tint: .secondary) {
                            VStack(spacing: 6) {
                                InfoRow("Số sê-ri", b.serial ?? "—")
                                InfoRow("Đã sạc đầy", b.fullyCharged ? String(localized: "Có") : String(localized: "Không"))
                                InfoRow(b.isCharging ? "Tới khi đầy" : "Còn lại",
                                        b.timeRemaining.map { Format.duration(minutes: $0) } ?? "—")
                            }
                        }
                    }

                    Footnote("Tình trạng pin là dung lượng tối đa hiện tại so với dung lượng thiết kế. Giữ pin trong khoảng 20–80% và tránh nhiệt độ cao giúp pin chai chậm hơn.")
                }
            } else {
                ContentUnavailableView("Không tìm thấy pin", systemImage: "battery.0percent",
                                       description: Text("Máy này có thể không có pin trong."))
            }
        }
    }
}

private struct CapacityBar: View {
    let title: LocalizedStringKey
    let value: Int
    let max: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "\(Format.integer(value)) mAh").font(.callout.monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * CGFloat(Swift.min(Double(value) / Double(Swift.max(max, 1)), 1)))
                }
            }
            .frame(height: 6)
        }
    }
}
