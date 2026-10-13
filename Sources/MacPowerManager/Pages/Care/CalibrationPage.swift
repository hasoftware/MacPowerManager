import PowerCore
import SwiftUI

/// Hiệu chuẩn pin (chỉ Apple Silicon): sạc đầy, xả xuống thấp, sạc đầy lại để macOS đo lại dung lượng cho đúng.
struct CalibrationPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let helper = model.helper
        let status = helper.status
        SettingsPage {
            ControlUnavailableSection()

            Group {
                Section {
                    if let calibration = status?.calibration {
                        ForEach(CalibrationText.steps, id: \.number) { step in
                            StepRow(step: step, current: calibration.phase.step)
                        }
                        LabeledContent {
                            Button("Hủy hiệu chuẩn") { Task { await helper.cancelCalibration() } }
                                .disabled(helper.isSending)
                        } label: {
                            Text(verbatim: model.battery.map {
                                CalibrationText.detail(calibration, battery: $0, adapterCut: status?.adapterEnabled == false,
                                                       lidClosed: status?.reason == .clamshellSuspended)
                            } ?? "")
                            Text("Bắt đầu lúc \(Format.dateTime(calibration.startedAt)); tự hủy sau \(Int(Calibration.maxSeconds / 3600)) giờ nếu chưa xong.")
                        }
                    } else {
                        LabeledContent {
                            Button("Bắt đầu hiệu chuẩn") { Task { await helper.startCalibration() } }
                                .disabled(helper.isSending || model.battery?.externalConnected != true || model.isIntel)
                        } label: {
                            Text("Hiệu chuẩn pin")
                            if let last = status?.lastCalibrationAt {
                                Text("Lần gần nhất: \(Format.date(last))")
                            } else {
                                Text("Chưa hiệu chuẩn lần nào")
                            }
                            if model.battery?.externalConnected != true {
                                Text("Cần cắm sạc.")
                            }
                        }
                    }
                } header: {
                    Text("Hiệu chuẩn pin")
                } footer: {
                    Footnote("Giữ pin ở 80% lâu ngày khiến bộ đo dung lượng lệch dần (số % và \"Dung lượng tối đa\" kém chính xác). Hiệu chuẩn sạc pin lên 100% và giữ 1 giờ, xả xuống \(Calibration.lowPercent)%, sạc đầy lại rồi trở về giới hạn. Cả quá trình thường mất 6–12 giờ; nên làm khi máy cắm sạc ở nhà, ví dụ cuối tuần.")
                }

                Section {
                    Toggle("Nhắc hiệu chuẩn mỗi 2 tháng", isOn: $model.prefs.calibrationReminder)
                    Toggle("Thông báo khi cần rút sạc hoặc khi xong", isOn: $model.prefs.notifyCalibration)
                } header: {
                    Text("Thông báo")
                }

                Section {
                    Group {
                        Label("Máy được giữ thức trong lúc xả; gập máy sẽ tạm ngừng xả.", systemImage: "laptopcomputer")
                        Label("Tắt \"Tối ưu hóa sạc pin\" (Optimized Battery Charging) trong Cài đặt hệ thống → Pin, nếu không macOS có thể giữ pin ở 80% và hiệu chuẩn không lên được 100%.", systemImage: "exclamationmark.triangle")
                        Label("Pin nóng vẫn tạm dừng sạc như bình thường; hiệu chuẩn tiếp tục khi pin nguội.", systemImage: "thermometer.medium")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Lưu ý")
                }
            }
            .disabled(!model.canControl)

            HelperErrorSection()
        }
    }
}

private struct StepRow: View {
    let step: CalibrationText.Step
    let current: Int

    var body: some View {
        let done = step.number < current, active = step.number == current
        Label {
            Text(step.title)
                .foregroundStyle(done || active ? .primary : .secondary)
                .fontWeight(active ? .semibold : .regular)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : active ? "\(step.number).circle.fill" : "\(step.number).circle")
                .foregroundStyle(done ? Color.green : active ? Color.blue : Color.secondary)
        }
    }
}

/// Chữ mô tả các bước hiệu chuẩn (dùng chung cho trang Hiệu chuẩn, chip trạng thái và bảng nhanh).
enum CalibrationText {
    struct Step {
        let number: Int
        let title: LocalizedStringKey
    }

    static let steps = [
        Step(number: 1, title: "Sạc đầy 100% và giữ 1 giờ"),
        Step(number: 2, title: "Xả xuống \(Calibration.lowPercent)%"),
        Step(number: 3, title: "Sạc đầy lại, giữ 1 giờ rồi trở về giới hạn"),
    ]

    static func detail(_ calibration: CalibrationState, battery: BatteryInfo, adapterCut: Bool,
                       lidClosed: Bool = false, now: Date = Date()) -> String {
        let plugged = battery.externalConnected || adapterCut
        switch calibration.phase {
        case .chargeToFull, .recharge:
            return plugged ? String(localized: "Đang sạc tới 100%") : String(localized: "Cắm sạc để tiếp tục sạc tới 100%")
        case .holdFull, .holdFinal:
            guard plugged else { return String(localized: "Cắm sạc để tiếp tục giữ 100%") }
            let left = max(Int((Calibration.holdSeconds - now.timeIntervalSince(calibration.phaseStartedAt)) / 60), 1)
            return String(localized: "Giữ 100% thêm \(Format.duration(minutes: left))")
        case .discharge:
            let target = Calibration.lowPercent
            if lidClosed { return String(localized: "Tạm ngừng xả vì nắp máy đang đóng") }
            if let rest = calibration.adapterRestUntil, rest > now {
                return String(localized: "Tạm bật lại bộ sạc, sẽ xả tiếp sau ít phút")
            }
            if adapterCut || !battery.externalConnected {
                if let minutes = PowerSummary.dischargeMinutes(battery, to: target) {
                    return String(localized: "Đang xả về \(target)% · còn khoảng \(Format.duration(minutes: minutes))")
                }
                return String(localized: "Đang xả về \(target)%")
            }
            return String(localized: "Rút sạc và dùng máy tới khi pin còn \(target)%")
        }
    }
}
