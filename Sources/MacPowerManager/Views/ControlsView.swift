import PowerCore
import SwiftUI

struct ControlsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let helper = model.helper
        Form {
            if !helper.isReady {
                Section { HelperBanner() }
            }

            Section {
                Toggle("Bật giới hạn sạc", isOn: helper.binding(\.chargeLimitEnabled))
                LabeledContent("Mức tối đa: \(helper.config.chargeLimit)%") {
                    Slider(value: helper.intBinding(\.chargeLimit), in: 50...100, step: 1)
                }
                .disabled(!helper.config.chargeLimitEnabled)
                Stepper("Sạc lại khi giảm \(helper.config.sailingGap)% dưới mức tối đa",
                        value: helper.binding(\.sailingGap), in: 1...20)
                    .disabled(!helper.config.chargeLimitEnabled)
            } header: {
                Text("Giới hạn sạc")
            } footer: {
                Text("Giữ pin ở khoảng 20–80% giúp giảm chai pin lithium-ion. Khi đạt giới hạn, máy dùng điện trực tiếp từ adapter.")
            }

            Section {
                Toggle("Tạm dừng sạc", isOn: helper.binding(\.pauseCharging))
            } header: {
                Text("Chỉ dùng adapter")
            } footer: {
                Text("Pin giữ nguyên mức hiện tại, máy chạy hoàn toàn bằng adapter.")
            }

            Section {
                LabeledContent("Xả về: \(helper.config.dischargeTarget)%") {
                    Slider(value: helper.intBinding(\.dischargeTarget), in: 20...95, step: 1)
                }
                HStack {
                    if helper.config.dischargeEnabled {
                        ProgressView().controlSize(.small)
                        Text("Đang xả… (\(model.battery?.percent ?? 0)% → \(helper.config.dischargeTarget)%)")
                        Spacer()
                        Button("Dừng xả") { helper.update { $0.dischargeEnabled = false } }
                    } else {
                        Spacer()
                        Button("Bắt đầu xả") { helper.update { $0.dischargeEnabled = true } }
                            .disabled((model.battery?.percent ?? 0) <= helper.config.dischargeTarget)
                    }
                }
            } header: {
                Text("Xả pin")
            } footer: {
                Text("Ngắt adapter bằng phần mềm để máy chạy bằng pin dù vẫn cắm sạc. Tự dừng khi đạt mục tiêu, khi pin dưới \(PowerConstants.criticalPercent)%, khi máy ngủ hoặc khi helper khởi động lại.")
            }

            Section {
                Toggle("Bật bảo vệ nhiệt", isOn: helper.binding(\.thermalProtectionEnabled))
                LabeledContent("Dừng sạc khi ≥ \(Int(helper.config.thermalPauseAbove))°C") {
                    Slider(value: helper.binding(\.thermalPauseAbove), in: 32...50, step: 1)
                }
                LabeledContent("Sạc lại khi ≤ \(Int(helper.config.thermalResumeBelow))°C") {
                    Slider(value: helper.binding(\.thermalResumeBelow), in: 25...(helper.config.thermalPauseAbove - 1), step: 1)
                }
                LabeledContent("Nhiệt độ pin hiện tại", value: Format.temperature(model.temperature))
            } header: {
                Text("Bảo vệ nhiệt")
            } footer: {
                Text("Apple Silicon không cho phần mềm chỉnh dòng sạc, nên app hạ nhiệt bằng cách tạm ngắt sạc khi pin nóng và sạc lại khi đã nguội. Cách này giảm công suất sạc trung bình và nhiệt độ pin.")
            }

            Section("Khi máy ngủ") {
                Toggle("Tắt sạc trước khi ngủ (tránh sạc vượt giới hạn)", isOn: helper.binding(\.disableChargingBeforeSleep))
            }

            if let error = helper.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .disabled(!helper.isReady)
    }
}
