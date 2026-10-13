import Foundation
import PowerCore

/// Lệnh `mpm` (script `Contents/Resources/mpm` gọi chính app với `--cli`). Chạy trước khi giao diện khởi động rồi thoát.
/// Dùng chính file thực thi của app nên helper nhận lệnh như từ app (cùng chữ ký code đã được ghim).
/// Kết quả in bằng tiếng Anh, ổn định để dùng trong script.
enum CommandLineTool {
    static func run(_ arguments: [String]) -> Int32 {
        let action: AutomationAction
        switch Automation.parse(arguments) {
        case .success(let parsed): action = parsed
        case .failure(let error):
            printError("mpm: \(error.description)")
            return 2
        }
        switch action {
        case .help, .open:
            print(Automation.usage)
            return 0
        case .version:
            print("MacPowerManager \(AppVersion.current)")
            return 0
        default:
            break
        }

        let client = Client()
        defer { client.close() }
        guard let status = client.status() else {
            printError("mpm: cannot reach the MacPowerManager helper. Install it from the app (System & Helper).")
            return 1
        }
        if status.version != AppVersion.current {
            printError("mpm: helper \(status.version) differs from app \(AppVersion.current); open the app to update it.")
        }

        if case .status(let json) = action {
            printStatus(status, json: json)
            return 0
        }
        let command: HelperCommand
        if let config = action.applied(to: status.config) {
            command = .setConfig(config)
        } else if let helperCommand = action.helperCommand {
            command = helperCommand
        } else {
            print(Automation.usage)
            return 2
        }
        guard let response = client.perform(command) else {
            printError("mpm: the helper did not answer")
            return 1
        }
        guard response.ok else {
            printError("mpm: \(response.error?.rawValue ?? "failed")\(response.message.map { ": \($0)" } ?? "")")
            return 1
        }
        if let updated = response.status { printStatus(updated, json: false) }
        return 0
    }

    // MARK: Kết quả

    private struct Summary: Codable {
        var percent: Int?
        var pluggedIn: Bool?
        var charging: Bool?
        var reason: String
        var limitEnabled: Bool
        var limit: Int
        var effectiveLimit: Int?
        var paused: Bool
        var discharging: Bool
        var dischargeTarget: Int
        var topUpUntil: Date?
        var calibrationPhase: String?
        var magSafeLight: String
        var temperature: Double?
        var helperVersion: String
    }

    private static func printStatus(_ status: HelperStatus, json: Bool) {
        let battery = BatteryReader.read()
        let c = status.config
        let summary = Summary(percent: battery?.percent, pluggedIn: battery?.externalConnected,
                              charging: battery.map { $0.isCharging }, reason: status.reason.rawValue,
                              limitEnabled: c.chargeLimitEnabled, limit: c.chargeLimit, effectiveLimit: status.effectiveLimit,
                              paused: c.pauseCharging, discharging: c.dischargeEnabled, dischargeTarget: c.dischargeTarget,
                              topUpUntil: status.topUp?.expiresAt, calibrationPhase: status.calibration?.phase.rawValue,
                              magSafeLight: c.magSafeLED.rawValue, temperature: status.temperature,
                              helperVersion: status.version)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(summary) { print(String(decoding: data, as: UTF8.self)) }
            return
        }
        func onOff(_ value: Bool) -> String { value ? "on" : "off" }
        let batteryLine = [summary.percent.map { "\($0)%" }, summary.pluggedIn.map { $0 ? "plugged in" : "on battery" },
                            summary.charging.map { $0 ? "charging" : "not charging" }].compactMap { $0 }
        print("Battery:     \(batteryLine.joined(separator: ", "))")
        print("State:       \(summary.reason)")
        print("Limit:       \(c.chargeLimit)% (\(onOff(c.chargeLimitEnabled)))\(status.effectiveLimit.map { ", effective \($0)%" } ?? "")")
        print("Pause:       \(onOff(c.pauseCharging))")
        print("Discharge:   \(c.dischargeEnabled ? "to \(c.dischargeTarget)%" : "off")")
        if let until = summary.topUpUntil { print("Top up:      until \(until.formatted(date: .abbreviated, time: .shortened))") }
        if let phase = summary.calibrationPhase { print("Calibration: \(phase)") }
        if status.magSafeLED != nil { print("MagSafe:     \(c.magSafeLED.rawValue)") }
        if let t = status.temperature { print(String(format: "Temperature: %.1f °C", t)) }
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    // MARK: XPC đồng bộ

    private final class Client {
        private let connection: NSXPCConnection

        init() {
            connection = NSXPCConnection(machServiceName: PowerConstants.helperMachService, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: PowerHelperProtocol.self)
            connection.resume()
        }

        func close() { connection.invalidate() }

        func status() -> HelperStatus? {
            let data: Data?? = call { proxy, reply in proxy.status(reply: reply) }
            return data?.flatMap { try? JSONDecoder().decode(HelperStatus.self, from: $0) }
        }

        func perform(_ command: HelperCommand) -> HelperResponse? {
            guard let payload = try? JSONEncoder().encode(command) else { return nil }
            let data: Data?? = call { proxy, reply in proxy.perform(command: payload, reply: reply) }
            return data?.flatMap { try? JSONDecoder().decode(HelperResponse.self, from: $0) }
        }

        /// Chờ trả lời tối đa `timeout` giây (phản hồi XPC đến trên hàng đợi riêng nên chặn luồng chính được).
        private func call<T>(timeout: TimeInterval = 8, _ body: (PowerHelperProtocol, @escaping (T) -> Void) -> Void) -> T? {
            let done = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var result: T?
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done.signal() }
            guard let helper = proxy as? PowerHelperProtocol else { return nil }
            body(helper) { value in
                lock.lock()
                result = value
                lock.unlock()
                done.signal()
            }
            guard done.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }
}
