import PowerCore
import SwiftUI

/// Khi ngủ (chỉ Apple Silicon): giữ nguyên mức pin khi máy ngủ để không sạc vượt giới hạn.
struct SleepPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let helper = model.helper
        SettingsPage {
            ControlUnavailableSection()

            Section {
                Toggle(isOn: helper.binding(\.disableChargingBeforeSleep)) {
                    Text("Giữ nguyên mức pin khi máy ngủ")
                    Text("Tắt sạc trước khi ngủ nếu đang bật giới hạn, tạm dừng sạc hoặc xả pin.")
                }
            } header: {
                Text("Khi máy ngủ")
            } footer: {
                Footnote("Helper không bao giờ đánh thức máy để kiểm tra pin, nên khi máy ngủ helper không theo dõi được mức pin. Muốn pin sạc tiếp khi gập máy cắm sạc thì tắt tùy chọn này: pin có thể vượt giới hạn trong lúc ngủ, helper dừng sạc ở lần máy thức kế tiếp.")
            }
            .disabled(!model.canControl)

            Section {
                GuaranteeRow(symbol: "powerplug.fill", tint: .green,
                             text: "Trước khi ngủ, bộ sạc luôn được bật lại (việc xả pin dừng).")
                GuaranteeRow(symbol: "arrow.up.to.line", tint: .blue,
                             text: "Đang sạc đầy một lần thì máy vẫn sạc trong lúc ngủ.")
                GuaranteeRow(symbol: "exclamationmark.triangle.fill", tint: .red,
                             text: "Dưới \(PowerConstants.criticalPercent)% pin luôn được sạc.")
                GuaranteeRow(symbol: "moon.zzz.fill", tint: .indigo,
                             text: "Khi đang giữ mức pin, lúc máy chuẩn bị ngủ hoặc thức ngầm helper chỉ có thể tắt sạc, không bật lại.")
            } header: {
                Text("Luôn được đảm bảo")
            } footer: {
                Footnote("Máy tắt hẳn khi đang cắm sạc sẽ luôn sạc tới 100% — đây là giới hạn phần cứng của Apple Silicon.")
            }

            HelperErrorSection()
        }
    }
}

private struct GuaranteeRow: View {
    let symbol: String
    let tint: Color
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}
