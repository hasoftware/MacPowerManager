import Foundation
import Observation
import PowerCore
import SwiftUI

/// Giao tiếp với PowerHelper (root) qua XPC, và cài đặt/gỡ helper.
@MainActor
@Observable
final class HelperClient {
    enum InstallState: Equatable {
        /// `outdated("?")`: helper đã cài nhưng không nhận kết nối (thường do app vừa cập nhật), cần cài lại.
        case unknown, notInstalled, outdated(String), installed
    }

    private(set) var status: HelperStatus?
    private(set) var installState: InstallState = .unknown
    private(set) var config = PowerConfig()
    private(set) var isBusy = false
    /// Đang gửi một lệnh (sạc đầy một lần, sạc tới giới hạn…).
    private(set) var isSending = false
    /// Lỗi gần nhất, bằng chữ của chính app (đã dịch).
    private(set) var errorMessage: String?
    /// Chi tiết kỹ thuật thô của lỗi đó (thông báo của helper, stderr của script cài đặt…), chỉ để hiện ở dòng
    /// chẩn đoán phụ. Helper chạy bằng root, không có bản dịch nên chi tiết này luôn là tiếng Việt.
    private(set) var errorDetail: String?

    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    /// Tăng mỗi lần người dùng chỉnh: chỉ lần gửi mới nhất được kết thúc phiên chỉnh và đồng bộ lại cấu hình.
    @ObservationIgnored private var applyGeneration = 0
    /// Phiên bản helper trả lời lần gần nhất.
    @ObservationIgnored private var helperVersion: String?
    @ObservationIgnored private var failures = 0
    /// Dữ liệu giả (chụp giao diện): không bao giờ liên lạc với helper thật.
    @ObservationIgnored private var isPreview = false

    var isReady: Bool { installState == .installed }

    /// Helper đã cài nhưng không trả lời: app mới cập nhật bị helper (ghim cdhash app lúc cài) từ chối.
    var needsReinstall: Bool { installState == .outdated("?") }

    var topUpActive: Bool { status?.topUp != nil }
    var calibrating: Bool { status?.calibration != nil }

    // MARK: Trạng thái

    func refresh() async {
        guard !isPreview else { return }
        do {
            let version: String = try await call { proxy, reply in proxy.version(reply: reply) }
            failures = 0
            helperVersion = version
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
            failures += 1
            if FileManager.default.fileExists(atPath: PowerConstants.launchDaemonPath) {
                // Một lần lỗi khi đang chạy tốt có thể chỉ là helper đang khởi động lại.
                if installState == .installed && failures < 2 { return }
                // Helper v0.3.0 chỉ nhận app có cdhash được ghi lúc cài: bản app mới bị từ chối tới khi cài lại.
                installState = .outdated("?")
            } else {
                installState = .notInstalled
            }
            status = nil
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
        applyGeneration += 1
        let generation = applyGeneration
        applyTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await apply(config)
            // Lần chỉnh mới hơn đang chờ gửi thì để nó tự đồng bộ.
            guard generation == applyGeneration else { return }
            applyTask = nil
            // Đồng bộ lại từ helper: nếu helper từ chối hoặc kẹp giá trị, giao diện trở về giá trị thật.
            await refresh()
        }
    }

    /// Helper từ 0.3.0 nhận lệnh qua `perform(command:)`. Helper cũ hơn không có hàm này (XPC sẽ không trả lời).
    private var supportsCommands: Bool {
        guard let helperVersion, helperVersion != AppVersion.current else { return true }
        return InstallLocation.version(helperVersion, isAtLeast: "0.3.0")
    }

    /// Gửi cấu hình qua `perform(.setConfig)`; helper cũ chưa có lệnh này thì dùng `apply(config:)`.
    private func apply(_ config: PowerConfig) async {
        guard supportsCommands else {
            await applyLegacy(config)
            return
        }
        switch await send(.setConfig(config)) {
        case .success(let response) where response.error == .unsupported:
            await applyLegacy(config)
        case .success(let response):
            report(response, for: .setConfig(config))
            if let status = response.status { self.status = status }
        case .failure(let error):
            setError(String(localized: "Không gửi được cấu hình tới helper: \(error.localizedDescription)"))
        }
    }

    private func applyLegacy(_ config: PowerConfig) async {
        guard let data = try? JSONEncoder().encode(config) else { return }
        do {
            let error: String? = try await call { proxy, reply in proxy.apply(config: data, reply: reply) }
            if let error, !error.isEmpty {
                setError(String(localized: "Helper báo lỗi khi áp dụng cấu hình."), detail: error)
            } else {
                setError(nil)
            }
        } catch {
            setError(String(localized: "Không gửi được cấu hình tới helper: \(error.localizedDescription)"))
        }
    }

    // MARK: Lệnh

    func startTopUp(hours: Int? = nil) async {
        await perform(.startTopUp(hours: hours))
    }

    func cancelTopUp() async {
        await perform(.cancelTopUp)
    }

    func chargeToLimitNow() async {
        await perform(.chargeToLimitNow)
    }

    /// Danh sách tiến trình của mọi người dùng từ helper (root). Không báo lỗi lên giao diện; nil nếu không lấy được.
    func processes() async -> [ProcessSample]? {
        guard isReady, let data = try? JSONEncoder().encode(HelperCommand.processes) else { return nil }
        let reply: Data?? = try? await call { proxy, reply in proxy.perform(command: data, reply: reply) }
        return reply?.flatMap { try? JSONDecoder().decode(HelperResponse.self, from: $0) }?.processes
    }

    func startCalibration() async {
        await perform(.startCalibration)
    }

    func cancelCalibration() async {
        await perform(.cancelCalibration)
    }

    /// Nhờ helper đang chạy tự cập nhật từ bản đã tải và đã ký, không cần mật khẩu quản trị.
    /// Trả về false (không báo lỗi lên giao diện) nếu helper cũ chưa hỗ trợ hoặc không cài được: khi đó app dùng cách
    /// cũ là nhắc cài lại helper sau khi mở lại.
    func installUpdate(archivePath: String, signature: String) async -> Bool {
        guard isReady,
              let data = try? JSONEncoder().encode(HelperCommand.installUpdate(archivePath: archivePath, signature: signature))
        else { return false }
        do {
            let reply: Data? = try await call { proxy, reply in proxy.perform(command: data, reply: reply) }
            return reply.flatMap { try? JSONDecoder().decode(HelperResponse.self, from: $0) }?.ok == true
        } catch {
            return false
        }
    }

    /// Gửi `HelperCommand` tới helper. Trả về phản hồi, hoặc nil nếu không liên lạc được.
    @discardableResult
    func perform(_ command: HelperCommand) async -> HelperResponse? {
        guard supportsCommands else {
            setError(Self.message(for: .unsupported, command: command))
            return nil
        }
        isSending = true
        defer { isSending = false }
        let result = await send(command)
        await refresh()
        switch result {
        case .success(let response):
            report(response, for: command)
            return response
        case .failure(let error):
            setError(String(localized: "Không gửi được lệnh tới helper: \(error.localizedDescription)"))
            return nil
        }
    }

    private func send(_ command: HelperCommand) async -> Result<HelperResponse, Error> {
        guard let data = try? JSONEncoder().encode(command) else {
            return .failure(CocoaError(.coderInvalidValue))
        }
        do {
            let reply: Data? = try await call { proxy, reply in proxy.perform(command: data, reply: reply) }
            guard let reply, let response = try? JSONDecoder().decode(HelperResponse.self, from: reply) else {
                return .failure(CocoaError(.coderReadCorrupt))
            }
            return .success(response)
        } catch {
            return .failure(error)
        }
    }

    private func setError(_ message: String?, detail: String? = nil) {
        errorMessage = message
        let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        errorDetail = message == nil || detail?.isEmpty != false ? nil : detail
    }

    /// Lỗi theo mã của helper. `HelperResponse.message` do helper (root, không có bản dịch) viết bằng tiếng Việt,
    /// nên chỉ giữ làm chi tiết chẩn đoán; câu hiển thị là chữ của app theo mã lỗi.
    private func report(_ response: HelperResponse, for command: HelperCommand) {
        if response.ok {
            setError(nil)
        } else {
            setError(Self.message(for: response.error, command: command), detail: response.message)
        }
    }

    private static func message(for error: HelperError?, command: HelperCommand) -> String {
        switch error {
        case .invalidArgument:
            if case .chargeToLimitNow = command { return String(localized: "Giới hạn sạc đang tắt hoặc ở 100%.") }
            if case .startTopUp = command { return String(localized: "Đang hiệu chuẩn pin. Hãy hủy hiệu chuẩn trước.") }
            return String(localized: "Giá trị không hợp lệ.")
        case .notPluggedIn: return String(localized: "Cần cắm sạc để dùng chức năng này.")
        case .unsupported:
            if case .startCalibration = command { return String(localized: "Máy Intel chưa hỗ trợ hiệu chuẩn pin.") }
            return String(localized: "Helper đang cài chưa hỗ trợ lệnh này. Hãy cài lại helper.")
        case .notAuthorized: return String(localized: "Helper từ chối lệnh từ bản app này. Hãy cài lại helper.")
        case .failed, nil: return String(localized: "Helper không thực hiện được lệnh.")
        }
    }

    // MARK: Cài đặt / gỡ

    func install() async {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "PowerHelper"),
              let plist = Bundle.main.url(forResource: PowerConstants.helperLabel, withExtension: "plist"),
              let script = Bundle.main.url(forResource: "helper-install", withExtension: "sh") else {
            setError(String(localized: "Không tìm thấy helper trong app bundle. Hãy build bằng `make app`."))
            return
        }
        // Đối số thứ 4: đường dẫn app, để script ghi cdhash của app vào danh sách client được tin cậy.
        await runPrivileged(script: script, arguments: ["install", helper.path, plist.path, Bundle.main.bundlePath],
                            failure: String(localized: "Không cài được helper."))
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
        let output = await runPrivileged(script: script, arguments: ["uninstall"] + [bundledHelper].compactMap { $0 },
                                         failure: String(localized: "Không gỡ được helper."))
        // Mã MPM-E… của script: thay câu tiếng Việt của script bằng chữ của app.
        if output.contains("MPM-E4") {
            let path = PowerConstants.helperInstallPath
            setError(String(localized: "Đã tắt helper nhưng chưa trả được giới hạn sạc của firmware (BCLM) về 100%. Chạy trong Terminal: sudo \(path) --restore-defaults"))
        } else if output.contains("MPM-E3") {
            setError(String(localized: "Đã gỡ helper nhưng chưa xác minh được việc khôi phục sạc. Hãy khởi động lại máy để SMC trở về mặc định."))
        }
        resetConnection()
        status = nil
        await refresh()
    }

    #if DEBUG
    /// Dữ liệu giả cho chế độ chụp giao diện (`--render-snapshots`).
    func setPreview(status: HelperStatus?, installState: InstallState, error: String? = nil) {
        isPreview = true
        self.status = status
        self.installState = installState
        config = status?.config ?? PowerConfig()
        setError(error)
    }
    #endif

    /// Chạy script bằng quyền admin qua hộp thoại xác thực của macOS. Trả về stderr khi lỗi.
    /// - failure: câu báo lỗi của app khi script thất bại; stderr (tiếng Việt, từ script) chỉ là chi tiết chẩn đoán.
    @discardableResult
    private func runPrivileged(script: URL, arguments: [String], failure: String) async -> String {
        guard !isPreview else { return "" }
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
            if result.1.contains("-128") {
                setError(String(localized: "Đã hủy xác thực."))
            } else {
                setError(failure, detail: result.1)
            }
        } else {
            setError(nil)
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

    /// Gọi helper qua XPC. Không có phản hồi sau `timeout` giây thì coi là lỗi (helper treo hoặc đang khởi động lại).
    private func call<T>(timeout: TimeInterval = 8,
                         _ body: @escaping (PowerHelperProtocol, @escaping (T) -> Void) -> Void) async throws -> T {
        guard !isPreview else { throw CocoaError(.featureUnsupported) }
        let connection = proxyConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                once.resume(with: .failure(CocoaError(.xpcConnectionReplyInvalid)))
            }
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
