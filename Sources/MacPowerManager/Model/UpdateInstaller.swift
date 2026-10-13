import AppKit
import Foundation
import Observation
import PowerCore

/// Tải và cài bản cập nhật ngay trong app: tải `.zip` và chữ ký, xác minh chữ ký Ed25519 (khóa công khai của
/// HASOFTWARE), giải nén, kiểm tra đúng app/đúng version/chữ ký code, rồi thay app và mở lại.
/// File tải bằng URLSession không bị macOS gắn cờ quarantine, nên bản mới mở được ngay, không cần "Open Anyway".
@MainActor
@Observable
final class UpdateInstaller {
    enum Phase: Equatable {
        case idle
        case downloading(Double)       // 0…1
        case verifying
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    var isBusy: Bool {
        switch phase {
        case .downloading, .verifying, .installing: true
        case .idle, .failed: false
        }
    }

    /// Sau khi mở lại bằng bản mới: nhắc cài lại helper (bản app mới có cdhash khác nên helper cũ không nhận lệnh).
    static let pendingHelperReinstallKey = "update.pendingHelperReinstall"

    @ObservationIgnored private var task: Task<Void, Never>?

    func install(_ release: ReleaseInfo) {
        guard !isBusy, let archive = release.updateArchive, let signature = release.updateSignature else { return }
        task = Task { await run(release: release, archive: archive, signature: signature) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    private func run(release: ReleaseInfo, archive: ReleaseInfo.Asset, signature: ReleaseInfo.Asset) async {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MacPowerManager-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            // 1. Tải chữ ký rồi file .zip (có tiến độ).
            phase = .downloading(0)
            let signatureText = try await String(decoding: Self.fetch(signature.downloadURL), as: UTF8.self)
            let zipURL = work.appendingPathComponent(archive.name)
            try await download(archive.downloadURL, to: zipURL, expectedSize: archive.size)
            try Task.checkCancellation()

            // 2. Xác minh chữ ký trước khi giải nén bất cứ thứ gì.
            phase = .verifying
            let zipData = try Data(contentsOf: zipURL, options: .mappedIfSafe)
            guard UpdateSignature.isValid(zipData, signature: signatureText) else {
                throw UpdateError.message(String(localized: "Chữ ký bản cập nhật không hợp lệ. Đã hủy để bảo vệ máy của bạn."))
            }

            // 3. Giải nén và kiểm tra app bên trong.
            let unpacked = work.appendingPathComponent("unpacked")
            try await Self.runTool("/usr/bin/ditto", ["-x", "-k", zipURL.path, unpacked.path])
            let newApp = unpacked.appendingPathComponent("MacPowerManager.app")
            let bundle = Bundle(url: newApp)
            if let failure = UpdatePlan.validate(bundleIdentifier: bundle?.bundleIdentifier,
                                                 version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                                                 expectedIdentifier: PowerConstants.appBundleID,
                                                 currentVersion: AppVersion.current) {
                throw UpdateError.message(Self.describe(failure))
            }
            try await Self.runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])

            // 4. Thay app sau khi thoát, rồi mở bản mới.
            phase = .installing
            let current = Bundle.main.bundleURL
            let readOnly = (try? current.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
            let destination = UpdatePlan.installLocation(runningBundlePath: current.path, isOnReadOnlyVolume: readOnly)
            let parent = URL(fileURLWithPath: destination).deletingLastPathComponent().path
            guard FileManager.default.isWritableFile(atPath: parent) else {
                throw UpdateError.message(String(localized: "Không ghi được vào \(parent). Hãy tải bản cập nhật thủ công."))
            }
            // Đặt bản mới cạnh đích để lệnh `mv` trong script là đổi tên trên cùng ổ đĩa (nhanh, nguyên tử).
            let staged = URL(fileURLWithPath: parent).appendingPathComponent(".MacPowerManager-\(release.tagName)-\(UUID().uuidString).app")
            try FileManager.default.moveItem(at: newApp, to: staged)
            let script = work.appendingPathComponent("relaunch.sh")
            try UpdatePlan.relaunchScript(pid: ProcessInfo.processInfo.processIdentifier, newApp: staged.path,
                                          destination: destination).write(to: script, atomically: true, encoding: .utf8)
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = [script.path]
            relaunch.standardOutput = FileHandle.nullDevice
            relaunch.standardError = FileHandle.nullDevice
            try relaunch.run()
            UserDefaults.standard.set(true, forKey: Self.pendingHelperReinstallKey)
            NSApp.terminate(nil)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: work)
            phase = .idle
        } catch {
            try? FileManager.default.removeItem(at: work)
            phase = .failed((error as? UpdateError)?.text ?? error.localizedDescription)
        }
    }

    /// Lý do bản tải về không cài được, bằng lời dễ hiểu.
    static func describe(_ failure: UpdatePlan.Failure) -> String {
        switch failure {
        case .wrongBundle:
            String(localized: "Bản tải về không phải MacPowerManager. Đã hủy để bảo vệ máy của bạn.")
        case .notNewer(let version):
            String(localized: "Bản tải về (\(version ?? "?")) không mới hơn bản đang dùng (\(AppVersion.current)).")
        case .badSignature:
            String(localized: "Chữ ký bản cập nhật không hợp lệ. Đã hủy để bảo vệ máy của bạn.")
        case .unsupportedLocation:
            String(localized: "Không cài được bản cập nhật vào vị trí hiện tại của app. Hãy tải bản cập nhật thủ công.")
        }
    }

    private func download(_ url: URL, to destination: URL, expectedSize: Int) async throws {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("MacPowerManager/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let total = max(Int(response.expectedContentLength), expectedSize, 1)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var written = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
                phase = .downloading(min(Double(written) / Double(total), 1))
                try Task.checkCancellation()
            }
        }
        try handle.write(contentsOf: buffer)
        phase = .downloading(1)
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("MacPowerManager/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private static func runTool(_ path: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw UpdateError.message(String(localized: "Kiểm tra bản cập nhật thất bại (\(URL(fileURLWithPath: path).lastPathComponent))."))
            }
        }.value
    }

    private enum UpdateError: Error {
        case message(String)
        var text: String { if case .message(let m) = self { m } else { "" } }
    }
}
