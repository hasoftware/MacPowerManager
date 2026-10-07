import PowerCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmUninstall = false

    var body: some View {
        @Bindable var model = model
        let helper = model.helper
        Form {
            Section("Chung") {
                Toggle("Hiện % pin trên thanh menu", isOn: $model.prefs.showPercentInMenuBar)
                Toggle("Mở cùng macOS", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Thông báo") {
                Toggle("Khi đạt giới hạn sạc / sạc đầy", isOn: $model.prefs.notifyLimitReached)
                Toggle("Khi tạm dừng sạc do pin nóng", isOn: $model.prefs.notifyThermal)
                Toggle("Khi xả pin xong", isOn: $model.prefs.notifyDischargeDone)
                Toggle("Khi pin yếu", isOn: $model.prefs.notifyLowBattery)
                Stepper("Ngưỡng pin yếu: \(model.prefs.lowBatteryThreshold)%",
                        value: $model.prefs.lowBatteryThreshold, in: 5...50, step: 5)
                    .disabled(!model.prefs.notifyLowBattery)
            }

            if Platform.isAppleSilicon {
                Section {
                    LabeledContent("Trạng thái") {
                        switch helper.installState {
                        case .installed: Text("Đã cài (v\(AppVersion.current))").foregroundStyle(.green)
                        case .outdated(let v): Text("Phiên bản cũ (v\(v))").foregroundStyle(.orange)
                        case .notInstalled: Text("Chưa cài").foregroundStyle(.secondary)
                        case .unknown: Text("Đang kiểm tra…").foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button(helper.isReady ? "Cài lại helper" : "Cài helper") {
                            Task { await helper.install() }
                        }
                        Button("Gỡ helper", role: .destructive) { confirmUninstall = true }
                            .disabled(helper.installState == .notInstalled)
                        if helper.isBusy { ProgressView().controlSize(.small) }
                    }
                    if let error = helper.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Helper điều khiển sạc")
                } footer: {
                    Text("Helper chạy nền với quyền root (\(PowerConstants.helperInstallPath)) để ghi SMC. Gỡ helper sẽ trả việc sạc về mặc định của macOS.")
                }
            }

            Section("Dữ liệu") {
                LabeledContent("Phiên bản", value: AppVersion.current)
                LabeledContent("Số mẫu lịch sử", value: "\(model.history.samples.count)")
                Button("Xóa lịch sử") { model.history.clear() }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Gỡ helper điều khiển sạc?", isPresented: $confirmUninstall) {
            Button("Gỡ", role: .destructive) { Task { await helper.uninstall() } }
        } message: {
            Text("Giới hạn sạc và các chế độ khác sẽ ngừng hoạt động. Sạc sẽ trở về mặc định của macOS.")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Không thể thay đổi: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
