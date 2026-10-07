import Foundation
import Observation
import PowerCore
import SwiftUI

/// Giao tiếp với PowerHelper (root) qua XPC, và cài đặt/gỡ helper.
@MainActor
@Observable
final class HelperClient {
    enum InstallState: Equatable {
        case unknown, notInstalled, outdated(String), installed
    }

    private(set) var status: HelperStatus?
    private(set) var installState: InstallState = .unknown
    private(set) var config = PowerConfig()
    private(set) var isBusy = false
    var errorMessage: String?

    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var applyTask: Task<Void, Never>?

    var isReady: Bool { installState == .installed }

    // MARK: Trạng thái

    func refresh() async {
        do {
            let version: String = try await call { proxy, reply in proxy.version(reply: reply) }
            guard version == AppVersion.current else {
                installState = .outdated(version)
                return
            }
            let data: Data? = try await call { proxy, reply in proxy.status(reply: reply) }
            guard let data, let status = try? JSONDecoder().decode(HelperStatus.self, from: data) else { return }
            self.status = status
            installState = .installed
            // Không ghi đè khi người dùng đang chỉnh và chưa gửi xong.
            if applyTask == nil { config = status.config }
        } catch {
            status = nil
            installState = .notInstalled
        }
    }

    // MARK: Cấu hình

    /// Binding cho UI: mỗi thay đổi được gửi tới helper sau một khoảng debounce ngắn.
    func binding<Value>(_ keyPath: WritableKeyPath<PowerConfig, Value>) -> Binding<Value> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { newValue in
                self.config[keyPath: keyPath] = newValue
                self.scheduleApply()
            }
        )
    }

    func update(_ change: (inout PowerConfig) -> Void) {
        change(&config)
        scheduleApply(delay: .zero)
    }

    private func scheduleApply(delay: Duration = .milliseconds(400)) {
        applyTask?.cancel()
        applyTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await apply(config)
            applyTask = nil
        }
    }

    private func apply(_ config: PowerConfig) async {
        guard let data = try? JSONEncoder().encode(config) else { return }
        do {
            let error: String? = try await call { proxy, reply in proxy.apply(config: data, reply: reply) }
            errorMessage = error
        } catch {
            errorMessage = "Không gửi được cấu hình tới helper: \(error.localizedDescription)"
        }
        await refresh()
    }

    // MARK: Cài đặt / gỡ

    func install() async {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "PowerHelper"),
              let plist = Bundle.main.url(forResource: PowerConstants.helperLabel, withExtension: "plist"),
              let script = Bundle.main.url(forResource: "helper-install", withExtension: "sh") else {
            errorMessage = "Không tìm thấy helper trong app bundle. Hãy build bằng `make app`."
            return
        }
        await runPrivileged(script: script, arguments: ["install", helper.path, plist.path])
        resetConnection()
        try? await Task.sleep(for: .seconds(1))
        await refresh()
    }

    func uninstall() async {
        guard let script = Bundle.main.url(forResource: "helper-install", withExtension: "sh") else { return }
        // Khôi phục sạc/adapter trước, phòng khi helper không nhận được SIGTERM.
        _ = try? await call { (proxy: PowerHelperProtocol, reply: @escaping (Bool) -> Void) in
            proxy.restoreDefaults { reply(true) }
        }
        // Truyền helper đi kèm app để script dùng nó khôi phục (helper đang cài có thể là bản cũ).
        let bundledHelper = Bundle.main.url(forAuxiliaryExecutable: "PowerHelper")?.path
        let output = await runPrivileged(script: script, arguments: ["uninstall"] + [bundledHelper].compactMap { $0 })
        if output.contains("MPM-E3") {
            errorMessage = "Đã gỡ helper nhưng chưa xác minh được việc khôi phục sạc. Hãy khởi động lại máy để SMC trở về mặc định."
        }
        resetConnection()
        status = nil
        await refresh()
    }

    /// Chạy script bằng quyền admin qua hộp thoại xác thực của macOS. Trả về stderr khi lỗi.
    @discardableResult
    private func runPrivileged(script: URL, arguments: [String]) async -> String {
        isBusy = true
        defer { isBusy = false }
        let command = (["/bin/sh", script.path] + arguments).map(Self.shellQuote).joined(separator: " ")
        let appleScript = "do shell script \"\(Self.appleScriptEscape(command))\" with administrator privileges"

        let result = await Task.detached { () -> (Int32, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            let pipe = Pipe()
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return (-1, error.localizedDescription)
            }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        }.value

        if result.0 != 0 {
            errorMessage = result.1.contains("-128") ? "Đã hủy xác thực." : "Lỗi: \(result.1)"
        } else {
            errorMessage = nil
        }
        return result.1
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: XPC

    private func proxyConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: PowerConstants.helperMachService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PowerHelperProtocol.self)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func resetConnection() {
        connection?.invalidate()
        connection = nil
    }

    private func call<T>(_ body: @escaping (PowerHelperProtocol, @escaping (T) -> Void) -> Void) async throws -> T {
        let connection = proxyConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(with: .failure(error))
            }
            guard let helper = proxy as? PowerHelperProtocol else {
                once.resume(with: .failure(CocoaError(.featureUnsupported)))
                return
            }
            body(helper) { value in once.resume(with: .success(value)) }
        }
    }
}

/// Đảm bảo continuation chỉ được resume một lần (reply và error handler có thể cùng gọi).
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}
