import AppKit
import PowerCore
import SwiftUI
import UserNotifications

/// Thông báo: một công tắc cho mỗi loại sự kiện, ngưỡng pin yếu, quyền thông báo của hệ thống.
struct NotificationsPage: View {
    @Environment(AppModel.self) private var model
    @State private var authorization: UNAuthorizationStatus?

    var body: some View {
        @Bindable var model = model
        SettingsPage {
            Section {
                Toggle("Khi đạt giới hạn sạc hoặc sạc đầy", isOn: $model.prefs.notifyLimitReached)
                Toggle("Khi tạm dừng sạc do pin nóng", isOn: $model.prefs.notifyThermal)
                if !model.isIntel {
                    Toggle("Khi xả pin xong", isOn: $model.prefs.notifyDischargeDone)
                }
                Toggle("Khi kết thúc sạc đầy một lần", isOn: $model.prefs.notifyTopUpEnded)
            } header: {
                Text("Sạc pin")
            }

            Section {
                Toggle("Khi pin yếu", isOn: $model.prefs.notifyLowBattery)
                Stepper(value: $model.prefs.lowBatteryThreshold, in: 5...50, step: 5) {
                    Text("Ngưỡng pin yếu: \(model.prefs.lowBatteryThreshold)%").monospacedDigit()
                }
            } header: {
                Text("Pin yếu")
            } footer: {
                Footnote("Ngưỡng này cũng dùng cho trạng thái \"Pin yếu\" và banner nhắc cắm sạc.")
            }

            Section {
                Toggle(isOn: $model.prefs.notifyIneffective) {
                    Text("Khi lệnh dừng sạc chưa có hiệu lực")
                    Text("Pin vẫn nhận dòng sạc sau \(Int(PowerConstants.effectVerifySeconds)) giây kể từ khi chặn sạc.")
                }
                Toggle(isOn: $model.prefs.notifyForeignController) {
                    Text("Khi có ứng dụng khác điều khiển sạc")
                    Text("Một ứng dụng quản lý pin khác đang chạy, hoặc key điều khiển bị tiến trình khác thay đổi.")
                }
            } header: {
                Text("Cảnh báo")
            } footer: {
                Footnote("Mỗi loại sự kiện chỉ báo một lần cho tới khi tình trạng đó kết thúc; thông báo mới thay cho thông báo cũ cùng loại.")
            }

            Section {
                LabeledContent("Quyền thông báo") {
                    Text(authorizationText).foregroundStyle(authorization == .denied ? .orange : .secondary)
                }
                LabeledContent {
                    Button("Mở cài đặt Thông báo…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } label: {
                    Text("Đổi kiểu hiển thị, âm thanh hoặc tắt hẳn thông báo của app trong Cài đặt hệ thống.")
                }
            } header: {
                Text("Hệ thống")
            }
        }
        .task { authorization = await model.notifier.authorizationStatus() }
    }

    private var authorizationText: String {
        switch authorization {
        case .authorized, .provisional: String(localized: "Đã cho phép")
        case .denied: String(localized: "Đã tắt trong Cài đặt hệ thống")
        case .notDetermined: String(localized: "Chưa hỏi")
        default: "—"
        }
    }
}
