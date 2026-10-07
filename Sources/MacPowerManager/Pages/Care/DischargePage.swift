import PowerCore
import SwiftUI

/// Xả pin (chỉ Apple Silicon): ngắt bộ sạc bằng phần mềm để máy chạy bằng pin dù vẫn cắm sạc.
struct DischargePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let helper = model.helper
        let config = helper.config
        let percent = model.battery?.percent ?? 0
        SettingsPage {
            ControlUnavailableSection()

            Group {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        LimitBar(limit: config.dischargeTarget, percent: model.battery?.percent, sailingGap: nil,
                                 range: 20...95, tint: .purple, fillTint: model.summary.state.tint, style: .large) { value in
                            helper.update { $0.dischargeTarget = value }
                        }
                        HStack {
                            Text("Chọn nhanh").foregroundStyle(.secondary)
                            Spacer()
                            LimitPresets(values: [50, 60, 70, 80], current: config.dischargeTarget, tint: .purple) { value in
                                helper.update { $0.dischargeTarget = value }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .disabled(config.dischargeEnabled)

                    if config.dischargeEnabled {
                        LabeledContent {
                            Button("Dừng xả") { helper.update { $0.dischargeEnabled = false } }
                        } label: {
                            Label {
                                Text("Đang xả: \(percent)% → \(config.dischargeTarget)%")
                                if model.summary.state == .dischargeSuspended {
                                    Text("Tạm ngừng vì nắp máy đang đóng, sẽ xả tiếp khi mở nắp.")
                                } else if let battery = model.battery,
                                          let minutes = PowerSummary.dischargeMinutes(battery, to: config.dischargeTarget) {
                                    Text("Còn khoảng \(Format.duration(minutes: minutes))")
                                }
                            } icon: {
                                Image(systemName: model.summary.state == .dischargeSuspended ? "laptopcomputer" : "arrow.down.to.line")
                                    .foregroundStyle(.purple)
                            }
                        }
                    } else {
                        LabeledContent {
                            Button("Bắt đầu xả") { helper.update { $0.dischargeEnabled = true } }
                                .disabled(!model.canDischarge)
                        } label: {
                            Text("Xả về \(config.dischargeTarget)%")
                            if percent <= config.dischargeTarget {
                                Text("Pin đang ở \(percent)%, không cao hơn mục tiêu.")
                            } else if model.battery?.externalConnected != true {
                                Text("Sẽ bắt đầu khi cắm sạc.")
                            }
                        }
                    }
                } header: {
                    Text("Xả pin")
                } footer: {
                    Footnote("Ngắt bộ sạc bằng phần mềm để máy chạy bằng pin dù vẫn cắm sạc. Tự dừng khi đạt mục tiêu, khi pin dưới \(PowerConstants.criticalPercent)%, trước khi máy ngủ hoặc khi helper khởi động lại.")
                }

                Section {
                    LabeledContent("Nắp máy") {
                        Text(lidText).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Khi gập máy")
                } footer: {
                    Footnote("Khi nắp máy đóng, việc xả tạm ngừng để tránh vòng lặp ngủ/thức. Bộ sạc luôn được bật lại trước khi máy ngủ.")
                }
            }
            .disabled(!model.canControl)

            HelperErrorSection()
        }
    }

    private var lidText: String {
        switch model.helper.status?.lidClosed {
        case true?: String(localized: "Đang đóng")
        case false?: String(localized: "Đang mở")
        case nil: "—"
        }
    }
}
