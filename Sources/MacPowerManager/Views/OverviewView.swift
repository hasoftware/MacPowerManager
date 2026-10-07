import PowerCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            if let b = model.battery {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 16) {
                        BatteryGauge(percent: b.percent,
                                     limit: model.activeConfig.flatMap { $0.chargeLimitEnabled ? $0.chargeLimit : nil })
                            .frame(width: 72, height: 72)
                        VStack(alignment: .leading) {
                            Text("\(b.percent)%").font(.system(size: 34, weight: .semibold, design: .rounded))
                            Text(model.statusText).foregroundStyle(.secondary)
                        }
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        InfoCard(title: "Pin", icon: "battery.100percent") {
                            InfoRow("Dung lượng hiện tại", "\(b.currentCapacity) mAh")
                            InfoRow("Dung lượng khi đầy", "\(b.maxCapacity) mAh")
                            InfoRow("Dung lượng thiết kế", "\(b.designCapacity) mAh")
                            InfoRow("Sức khỏe", String(format: "%.1f%%", b.health))
                            InfoRow("Chu kỳ sạc", "\(b.cycleCount) / \(b.designCycleCount)")
                        }
                        InfoCard(title: "Điện", icon: "bolt") {
                            InfoRow("Điện áp", String(format: "%.2f V", Double(b.voltage) / 1000))
                            InfoRow("Dòng điện", "\(b.amperage) mA")
                            InfoRow("Công suất pin", Format.watts(b.batteryPower))
                            InfoRow("Hệ thống tiêu thụ", Format.watts(b.systemLoad))
                            timeRow(b)
                        }
                        InfoCard(title: "Nhiệt độ", icon: "thermometer.medium") {
                            InfoRow("Cảm biến pin (SMC)", Format.temperature(model.smcTemperature))
                            InfoRow("Gas gauge (IOKit)", Format.temperature(b.temperature))
                            InfoRow("Ngưỡng dừng sạc",
                                    model.activeConfig.map {
                                        $0.thermalProtectionEnabled ? Format.temperature($0.thermalPauseAbove) : "Tắt"
                                    } ?? "—")
                        }
                        InfoCard(title: "Adapter", icon: "powerplug") {
                            InfoRow("Đang cắm", b.externalConnected ? "Có" : "Không")
                            InfoRow("Tên", b.adapterName ?? "—")
                            InfoRow("Công suất", b.adapterWatts.map { "\($0) W" } ?? "—")
                            InfoRow("Điện vào hệ thống", Format.watts(b.systemPowerIn))
                        }
                        InfoCard(title: "Điều khiển (SMC)", icon: "cpu") {
                            let s = model.helper.status
                            InfoRow("Helper", s.map { "v\($0.version)" } ?? "Chưa cài")
                            InfoRow("Trạng thái", s?.reason.label ?? "—")
                            InfoRow("Cho phép sạc", s?.chargingEnabled.map { $0 ? "Có" : "Không" } ?? "—")
                            InfoRow("Adapter cấp điện", s?.adapterEnabled.map { $0 ? "Có" : "Không" } ?? "—")
                            InfoRow("Key", [s?.chargingKeys, s?.adapterKeys].compactMap { $0 }.joined(separator: ", "))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView("Không tìm thấy pin", systemImage: "battery.0percent",
                                       description: Text("Máy này có thể không có pin trong."))
            }
        }
    }
}

extension OverviewView {
    /// Khớp với dòng trạng thái: khi có giới hạn, ước tính thời gian tới giới hạn chứ không phải tới 100%.
    @ViewBuilder
    func timeRow(_ b: BatteryInfo) -> some View {
        if b.isCharging, let config = model.activeConfig, config.chargeLimitEnabled, config.chargeLimit < 100 {
            InfoRow("Tới \(config.chargeLimit)%", b.minutesToCharge(to: config.chargeLimit).map { Format.duration(minutes: $0) } ?? "—")
        } else {
            InfoRow(b.isCharging ? "Tới khi đầy" : "Còn lại", b.timeRemaining.map { Format.duration(minutes: $0) } ?? "—")
        }
    }
}

struct InfoCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().textSelection(.enabled)
        }
        .font(.callout)
    }
}
