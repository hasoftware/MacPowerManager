import Observation
import PowerCore
import SwiftUI

/// Thông tin máy: phần cứng, phần mềm, dung lượng lưu trữ.
struct AboutMacPage: View {
    @Environment(AppModel.self) private var model
    @State private var info = MacInfo.shared

    var body: some View {
        let monitor = model.system
        let topology = monitor.topology
        let memory = ProcessInfo.processInfo.physicalMemory
        let gpu = monitor.latest?.gpu
        MonitorPage { width in
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.xl) {
                    Image(systemName: info.isLaptop ? "laptopcomputer" : "desktopcomputer")
                        .font(.system(size: 76, weight: .thin))
                        .foregroundStyle(.blue.gradient)
                        .frame(width: 140)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: info.machineName ?? SystemInfo.model).font(.largeTitle.weight(.semibold))
                        Text(verbatim: "\(topology.brand) · \(Format.bytes(memory))").font(.title3).foregroundStyle(.secondary)
                        HStack(spacing: Theme.Space.s) {
                            Chip(text: "macOS \(info.osVersion) (\(info.osBuild))", tint: .blue)
                            Chip(text: String(localized: "Đã chạy \(Format.uptime(since: monitor.activity.bootTime))"), tint: .green)
                        }
                    }
                    Spacer()
                }
                .padding(Theme.Space.l)
                .cardSurface()

                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Card(title: "Phần cứng", symbol: "cpu", tint: SystemTint.cpu) {
                        VStack(spacing: 8) {
                            InfoRow("Mẫu máy", info.machineName ?? "—")
                            InfoRow("Mã mẫu máy", SystemInfo.model)
                            InfoRow("Chip", topology.brand)
                            InfoRow("Nhân CPU", coresText(topology))
                            InfoRow("Nhân GPU", gpu?.cores.map(String.init) ?? "—")
                            InfoRow("Bộ nhớ", Format.bytes(memory))
                            InfoRow("Kiến trúc", Platform.isAppleSilicon ? "Apple Silicon" : "Intel")
                        }
                    }
                    Card(title: "Phần mềm", symbol: "macwindow", tint: .secondary) {
                        VStack(spacing: 8) {
                            InfoRow("Hệ điều hành", "macOS \(info.osVersion)")
                            InfoRow("Bản dựng", info.osBuild)
                            InfoRow("Nhân hệ thống", info.kernel)
                            InfoRow("Tên máy", info.computerName)
                            InfoRow("Khởi động lúc", monitor.activity.bootTime.map { Format.dateTime($0) } ?? "—")
                            InfoRow("Thời gian chạy", Format.uptime(since: monitor.activity.bootTime))
                            InfoRow("Tiến trình", Format.integer(monitor.activity.processCount))
                        }
                    }
                }

                Card(title: "Lưu trữ", symbol: "internaldrive", tint: SystemTint.disk) {
                    VStack(spacing: 10) {
                        ForEach(monitor.volumes) { volume in
                            VStack(alignment: .leading, spacing: 4) {
                                InfoRow(LocalizedStringKey(volume.name),
                                        String(localized: "còn trống \(Format.bytes(volume.available)) / \(Format.bytes(volume.total))"))
                                MeterBar(value: Double(volume.used) / Double(max(volume.total, 1)), tint: SystemTint.disk)
                            }
                        }
                    }
                }
            }
        }
        .task { await info.load() }
    }

    private func coresText(_ topology: CPUTopology) -> String {
        guard topology.efficiencyCores > 0 else { return "\(topology.logicalCores)" }
        return String(localized: "\(topology.logicalCores) (\(topology.performanceCores) hiệu năng, \(topology.efficiencyCores) tiết kiệm điện)")
    }
}

private struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Circle().fill(tint).frame(width: 6, height: 6)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Thông tin cố định của máy. Tên thương mại ("MacBook Pro") chỉ có từ system_profiler nên đọc một lần ở luồng nền.
@MainActor
@Observable
final class MacInfo {
    static let shared = MacInfo()

    private(set) var machineName: String?
    let osVersion: String
    let osBuild: String
    let kernel: String
    let computerName: String
    @ObservationIgnored private var loaded = false

    var isLaptop: Bool { (machineName ?? SystemInfo.model).contains("Book") }

    private init() {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        osBuild = Sysctl.string("kern.osversion") ?? "—"
        kernel = "Darwin \(Sysctl.string("kern.osrelease") ?? "?")"
        computerName = Host.current().localizedName ?? "—"
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        machineName = await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPHardwareDataType", "-json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return ((root?["SPHardwareDataType"] as? [[String: Any]])?.first?["machine_name"]) as? String
        }.value
    }
}
