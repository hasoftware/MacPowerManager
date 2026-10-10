import AppKit
import PowerCore
import SwiftUI

/// Hệ thống & helper: trạng thái helper, khả năng của máy, ứng dụng điều khiển sạc khác, ghi từ bên ngoài,
/// cài đặt/gỡ helper.
struct SystemPage: View {
    @Environment(AppModel.self) private var model
    @State private var confirmUninstall = false
    @State private var confirmIntel = false
    @State private var copied = false

    /// Đọc một lần: chuỗi firmware không đổi khi app đang chạy.
    private static let localFirmware = SystemInfo.firmwareVersion

    var body: some View {
        let helper = model.helper
        let status = helper.status
        SettingsPage {
            Section {
                HelperHeader(state: helper.installState, busy: helper.isBusy)
                LabeledContent("Phiên bản helper", value: helperVersion)
                LabeledContent("Phương thức", value: status?.methodText ?? "—")
                LabeledContent("Xác minh") { EffectLabel(effect: status?.effect) }
                if case .ineffective(let detail)? = status?.effect {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pin vẫn nhận dòng sạc sau khi đã chặn sạc. Có thể macOS hoặc ứng dụng khác đang can thiệp.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if !detail.isEmpty {
                            DiagnosticsLine(text: detail)
                        }
                    }
                }
                LabeledContent("Lý do hiện tại", value: status?.reason.label ?? "—")
                LabeledContent("Nắp máy", value: lidText(status?.lidClosed))
                LabeledContent("Firmware", value: status?.firmware ?? Self.localFirmware ?? "—")
                if model.isIntel {
                    LabeledContent("Giới hạn trong firmware (BCLM)", value: status?.firmwareLimit.map { "\($0)%" } ?? "—")
                }
                if let error = status?.lastError, !error.isEmpty {
                    LabeledContent {
                        Text("Helper báo lỗi").foregroundStyle(.red)
                    } label: {
                        Text("Lỗi gần nhất")
                        DiagnosticsLine(text: error)
                    }
                }
                HStack(spacing: Theme.Space.s) {
                    Button(installTitle) {
                        if Platform.isAppleSilicon || helper.installState != .notInstalled {
                            Task { await helper.install() }
                        } else {
                            confirmIntel = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(helper.isReady ? .secondary : .accentColor)
                    Button("Gỡ helper…", role: .destructive) { confirmUninstall = true }
                        .disabled(helper.installState == .notInstalled)
                    if helper.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                .disabled(helper.isBusy)
            } header: {
                Text("Helper")
            } footer: {
                Footnote("Helper chạy nền với quyền root (\(PowerConstants.helperInstallPath)) để ghi SMC, và vẫn giữ giới hạn sạc khi app đã thoát. Sau khi cập nhật app cần cài lại helper. Gỡ helper sẽ trả việc sạc về mặc định của macOS.")
            }

            HelperErrorSection()

            Section {
                if let keys = status?.capabilities?.keys, !keys.isEmpty {
                    CapabilityTable(keys: keys, chargeMethod: status?.capabilities?.chargeMethod,
                                    adapterMethod: status?.capabilities?.adapterMethod)
                } else {
                    Text(helper.isReady ? "Helper đang cài chưa báo cáo khả năng của máy." : "Cần helper để kiểm tra các key điều khiển.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Key điều khiển")
            } footer: {
                Footnote("\"Bị khóa\": firmware từ chối ghi dù helper chạy bằng root. Khi đó helper tự chuyển sang phương thức khác nếu còn.")
            }

            Section {
                if model.conflicts.isEmpty {
                    Label("Không tìm thấy ứng dụng điều khiển sạc khác", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.conflicts) { ConflictRow(finding: $0) }
                }
                LabeledContent {
                    Button("Quét lại") { model.scanConflicts() }
                } label: {
                    Text("Tìm theo đường dẫn cài đặt và tiến trình đang chạy.")
                }
            } header: {
                Text("Ứng dụng điều khiển sạc khác")
            } footer: {
                Footnote("Chỉ cảnh báo khi ứng dụng kia đang chạy. Hai ứng dụng cùng ghi vào SMC có thể khiến sạc bật/tắt liên tục: hãy thoát một bên hoặc đặt giới hạn của bên kia về 100%.")
            }

            Section {
                let writes = (status?.foreignWrites ?? []).suffix(6).reversed()
                if writes.isEmpty {
                    Text("Không phát hiện").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(writes.enumerated()), id: \.offset) { _, write in
                        LabeledContent {
                            Text(verbatim: "\(write.expected) → \(write.found)")
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        } label: {
                            Text(verbatim: write.key).font(.body.monospaced())
                            Text(Format.dateTime(write.at))
                        }
                    }
                }
            } header: {
                Text("Ghi từ bên ngoài")
            } footer: {
                Footnote("Các key điều khiển mà helper phát hiện bị tiến trình khác thay đổi so với giá trị nó đã ghi.")
            }

            Section {
                LabeledContent("Máy", value: SystemInfo.model)
                LabeledContent("macOS", value: SystemInfo.osVersion)
                LabeledContent("Chip", value: Platform.isAppleSilicon ? "Apple Silicon" : "Intel")
                LabeledContent("Phiên bản app", value: AppVersion.current)
                LabeledContent {
                    Button(copied ? "Đã sao chép" : "Sao chép") { copyDiagnostics() }
                } label: {
                    Text("Thông tin chẩn đoán")
                    Text("Dán vào GitHub Issues khi báo lỗi. Không gồm số sê-ri.")
                }
            } header: {
                Text("Máy này")
            }
        }
        .intelInstallConfirmation(isPresented: $confirmIntel, helper: helper)
        .confirmationDialog("Gỡ helper điều khiển sạc?", isPresented: $confirmUninstall) {
            Button("Gỡ helper", role: .destructive) { Task { await helper.uninstall() } }
        } message: {
            if model.isIntel {
                Text("Giới hạn sạc trong firmware sẽ được trả về 100%. Sạc sẽ trở về mặc định của macOS.")
            } else {
                Text("Giới hạn sạc và các chế độ khác sẽ ngừng hoạt động. Sạc sẽ trở về mặc định của macOS.")
            }
        }
    }

    private var installTitle: LocalizedStringKey {
        switch model.helper.installState {
        case .installed: "Cài lại helper…"
        case .outdated("?"): "Cài lại helper…"
        case .outdated: "Cập nhật helper…"
        case .notInstalled, .unknown: Platform.isAppleSilicon ? "Cài helper…" : "Cài helper (thử nghiệm)…"
        }
    }

    private var helperVersion: String {
        switch model.helper.installState {
        case .installed: model.helper.status?.version ?? AppVersion.current
        case .outdated("?"): String(localized: "Không xác định (không nhận kết nối)")
        case .outdated(let version): version
        case .notInstalled: String(localized: "Chưa cài")
        case .unknown: "—"
        }
    }

    private func lidText(_ closed: Bool?) -> String {
        switch closed {
        case true?: String(localized: "Đang đóng")
        case false?: String(localized: "Đang mở")
        case nil: "—"
        }
    }

    private func copyDiagnostics() {
        let status = model.helper.status
        var lines = [
            "MacPowerManager \(AppVersion.current)",
            "Model: \(SystemInfo.model), macOS \(SystemInfo.osVersion), \(Platform.isAppleSilicon ? "Apple Silicon" : "Intel")",
            "Firmware: \(status?.firmware ?? Self.localFirmware ?? "?")",
            "Helper: \(installText(model.helper.installState)), method \(status?.methodText ?? "-")",
            "Reason: \(status?.reason.rawValue ?? "-"), effect: \(status?.effect.map { "\($0)" } ?? "-")",
        ]
        for key in status?.capabilities?.keys ?? [] {
            lines.append("  \(key.name): present=\(key.present) writable=\(key.writable) locked=\(key.locked)")
        }
        for finding in model.conflicts {
            lines.append("Conflict: \(finding.name) running=\(finding.running) paths=\(finding.installedPaths.joined(separator: ","))")
        }
        for write in status?.foreignWrites ?? [] {
            lines.append("Foreign write: \(write.key) \(write.expected) -> \(write.found) at \(write.at)")
        }
        if let battery = model.battery {
            lines.append("Battery: \(battery.percent)%, cycles \(battery.cycleCount), health \(Int(model.healthPercent(battery)))% (measured \(Int(battery.health))%), plugged \(battery.externalConnected)")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// Dòng đầu của nhóm Helper: biểu tượng trạng thái và tên trạng thái.
private struct HelperHeader: View {
    let state: HelperClient.InstallState
    let busy: Bool

    private var tint: Color {
        switch state {
        case .installed: .green
        case .outdated, .notInstalled: .orange
        case .unknown: .secondary
        }
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: state == .installed ? "checkmark.shield.fill" : "lock.shield")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Helper điều khiển sạc").font(.headline)
                Text(installText(state)).font(.callout).foregroundStyle(tint)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

/// Bảng khả năng của các key điều khiển: có mặt / ghi được / bị khóa.
private struct CapabilityTable: View {
    let keys: [KeyCapability]
    let chargeMethod: String?
    let adapterMethod: String?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: 8) {
            GridRow {
                Text("Key")
                Text("Có mặt").gridColumnAlignment(.center)
                Text("Ghi được").gridColumnAlignment(.center)
                Text("Trạng thái")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(keys, id: \.name) { key in
                GridRow {
                    Text(verbatim: key.name).font(.callout.monospaced())
                    mark(key.present)
                    mark(key.writable && !key.locked)
                    status(key)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func mark(_ ok: Bool) -> some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(ok ? Color.green : Color.secondary)
            .accessibilityLabel(ok ? Text("Có") : Text("Không"))
    }

    @ViewBuilder
    private func status(_ key: KeyCapability) -> some View {
        let inUse = chargeMethod?.contains(key.name) == true || adapterMethod?.contains(key.name) == true
        if key.locked {
            Label("Bị khóa", systemImage: "lock.fill").foregroundStyle(.orange)
        } else if inUse {
            Label("Đang dùng", systemImage: "bolt.fill").foregroundStyle(.green)
        } else if key.present {
            Text("Dự phòng").foregroundStyle(.secondary)
        } else {
            Text("Không có").foregroundStyle(.tertiary)
        }
    }
}

/// Một ứng dụng điều khiển sạc khác: tên, đang chạy hay chỉ cài sẵn, giới hạn của nó, đường dẫn.
private struct ConflictRow: View {
    let finding: ConflictFinding

    var body: some View {
        LabeledContent {
            if finding.running {
                Label("Đang chạy", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text("Đã cài, không chạy").foregroundStyle(.secondary)
            }
        } label: {
            Text(verbatim: finding.name)
            if let limit = finding.chargeLimit {
                Text("Giới hạn trong cài đặt của nó: \(limit)%")
            }
            if let path = (finding.processes.first ?? finding.installedPaths.first) {
                Text(verbatim: path).truncationMode(.middle).lineLimit(1).help(Text(verbatim: path))
            }
        }
    }
}
