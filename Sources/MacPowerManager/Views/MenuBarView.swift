import AppKit
import PowerCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let helper = model.helper
        VStack(alignment: .leading, spacing: 12) {
            header

            if !Platform.isAppleSilicon {
                IntelNotice()
            } else if !helper.isReady {
                HelperBanner()
            } else {
                Divider()
                Toggle(isOn: helper.binding(\.chargeLimitEnabled)) {
                    Text("Giới hạn sạc ở \(helper.config.chargeLimit)%")
                }
                if helper.config.chargeLimitEnabled {
                    Slider(value: helper.intBinding(\.chargeLimit), in: 50...100, step: 5)
                }
                Toggle("Tạm dừng sạc (chỉ dùng adapter)", isOn: helper.binding(\.pauseCharging))
                Toggle(isOn: helper.binding(\.dischargeEnabled)) {
                    Text("Xả pin về \(helper.config.dischargeTarget)%")
                }
                Toggle(isOn: helper.binding(\.thermalProtectionEnabled)) {
                    Text("Dừng sạc khi pin > \(Int(helper.config.thermalPauseAbove))°C")
                }
            }

            if let error = helper.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider()
            stats
            Divider()

            HStack {
                Button("Mở chi tiết…") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Thoát") { NSApp.terminate(nil) }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            BatteryGauge(percent: model.battery?.percent ?? 0,
                         limit: model.activeConfig.flatMap { $0.chargeLimitEnabled ? $0.chargeLimit : nil })
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.battery?.percent ?? 0)%")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stats: some View {
        let battery = model.battery
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                StatLabel(title: "Nhiệt độ", value: Format.temperature(model.temperature),
                          warning: (model.temperature ?? 0) >= (model.activeConfig?.thermalPauseAbove ?? 45))
                StatLabel(title: "Sức khỏe", value: battery.map { String(format: "%.0f%%", $0.health) } ?? "—")
            }
            GridRow {
                StatLabel(title: "Công suất pin", value: battery.map { Format.watts($0.batteryPower) } ?? "—")
                StatLabel(title: "Chu kỳ", value: battery.map { "\($0.cycleCount)" } ?? "—")
            }
            if let battery, battery.externalConnected {
                GridRow {
                    StatLabel(title: "Adapter", value: battery.adapterWatts.map { "\($0) W" } ?? "—")
                    StatLabel(title: "Điện vào", value: Format.watts(battery.systemPowerIn))
                }
            }
        }
    }
}

struct StatLabel: View {
    let title: String
    let value: String
    var warning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(warning ? .orange : .primary)
        }
    }
}

/// Vòng tròn % pin, có vạch đánh dấu giới hạn sạc.
struct BatteryGauge: View {
    let percent: Int
    var limit: Int?

    private var color: Color {
        switch percent {
        case ..<15: .red
        case ..<30: .orange
        default: .green
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let limit, limit < 100 {
                Capsule()
                    .fill(.primary)
                    .frame(width: 2, height: 10)
                    .offset(y: -25)
                    .rotationEffect(.degrees(Double(limit) / 100 * 360))
            }
            Image(systemName: "bolt.fill")
                .font(.system(size: 16))
                .foregroundStyle(color)
        }
    }
}

struct HelperBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let helper = model.helper
        VStack(alignment: .leading, spacing: 6) {
            switch helper.installState {
            case .outdated(let version):
                Text("Helper đã cũ (\(version)), cần cập nhật.").font(.callout.weight(.medium))
            default:
                Text("Chưa cài helper điều khiển sạc").font(.callout.weight(.medium))
            }
            Text("Giới hạn sạc, xả pin và bảo vệ nhiệt cần một helper chạy quyền quản trị để ghi vào SMC.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(helper.isBusy ? "Đang cài…" : "Cài helper") {
                Task { await helper.install() }
            }
            .disabled(helper.isBusy)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Máy Intel: chỉ hiển thị thông tin, chưa điều khiển sạc.
struct IntelNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Máy Intel: chế độ chỉ xem").font(.callout.weight(.medium))
            Text("Điều khiển sạc trên Intel đang được phát triển (thử nghiệm). Bạn có thể giúp bằng cách gửi kết quả `make probe` lên GitHub Issues.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Mở GitHub Issues", destination: URL(string: "https://github.com/hasoftware/MacPowerManager/issues")!)
                .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension HelperClient {
    /// Slider làm việc với Double, cấu hình lưu Int.
    func intBinding(_ keyPath: WritableKeyPath<PowerConfig, Int>) -> Binding<Double> {
        let base = binding(keyPath)
        return Binding(get: { Double(base.wrappedValue) }, set: { base.wrappedValue = Int($0.rounded()) })
    }
}
