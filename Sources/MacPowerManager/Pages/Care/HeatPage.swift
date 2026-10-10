import PowerCore
import SwiftUI

/// Chống nóng: tạm ngắt sạc khi pin nóng, sạc lại khi đã nguội.
struct HeatPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let helper = model.helper
        let config = helper.config
        SettingsPage {
            ControlUnavailableSection()

            Group {
                Section {
                    Toggle("Bật chống nóng", isOn: helper.binding(\.thermalProtectionEnabled))
                    Group {
                        ThermalScale(pause: config.thermalPauseAbove, resume: config.thermalResumeBelow,
                                     current: model.temperature) { pause, resume in
                            helper.update {
                                $0.thermalPauseAbove = pause
                                $0.thermalResumeBelow = resume
                            }
                        }
                        .padding(.vertical, 6)
                        Stepper(value: helper.binding(\.thermalPauseAbove), in: 30...55, step: 1) {
                            Text("Dừng sạc khi pin từ \(Int(config.thermalPauseAbove))°C").monospacedDigit()
                        }
                        Stepper(value: helper.binding(\.thermalResumeBelow), in: 25...(config.thermalPauseAbove - 1), step: 1) {
                            Text("Sạc lại khi pin từ \(Int(config.thermalResumeBelow))°C trở xuống").monospacedDigit()
                        }
                    }
                    .disabled(!config.thermalProtectionEnabled)
                } header: {
                    Text("Chống nóng")
                } footer: {
                    if model.isIntel {
                        Footnote("macOS không cho phần mềm chỉnh dòng sạc, nên app hạ nhiệt bằng cách tạm ngắt sạc khi pin nóng và sạc lại khi đã nguội. Trên Intel, firmware chỉ dừng sạc được khi pin từ 50% trở lên.")
                    } else {
                        Footnote("macOS không cho phần mềm chỉnh dòng sạc, nên app hạ nhiệt bằng cách tạm ngắt sạc khi pin nóng và sạc lại khi đã nguội. Dưới \(PowerConstants.thermalFloorPercent)% pin luôn được sạc dù đang nóng.")
                    }
                }

                Section {
                    LabeledContent("Nhiệt độ pin") {
                        HStack(spacing: 6) {
                            if model.summary.state == .heat {
                                Image(systemName: "flame.fill").foregroundStyle(.orange)
                            }
                            Text(Format.temperature(model.temperature)).monospacedDigit()
                        }
                    }
                    LabeledContent("Trạng thái") {
                        Text(heatStatus).foregroundStyle(model.summary.state == .heat ? .orange : .secondary)
                    }
                    Sparkline(series: model.history.samples(within: 3600).series { $0.temperature }, tint: .orange,
                              threshold: config.thermalProtectionEnabled ? config.thermalPauseAbove : nil)
                        .frame(height: 56)
                        .padding(.vertical, 4)
                } header: {
                    Text("Một giờ qua")
                } footer: {
                    Footnote("Nhiệt độ đọc từ cảm biến pin của SMC (dự phòng bằng IOKit). Đường nét đứt là ngưỡng dừng sạc.")
                }
            }
            .disabled(!model.canControl)

            HelperErrorSection()
        }
    }

    private var heatStatus: String {
        guard model.canControl else { return String(localized: "Chưa điều khiển được sạc") }
        if model.summary.state == .heat {
            return String(localized: "Đang tạm dừng sạc, chờ pin nguội")
        }
        return model.helper.config.thermalProtectionEnabled
            ? String(localized: "Bình thường") : String(localized: "Đã tắt chống nóng")
    }
}
