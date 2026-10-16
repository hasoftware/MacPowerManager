import Foundation

/// Kết quả chạy một lệnh ngoài.
public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 }
    /// Các dòng stdout (bỏ phần rỗng sau `\n` cuối).
    public var lines: [String] {
        var parts = stdout.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    public static let notFound = CommandResult(status: 127, stderr: "not found")
    public static let timedOut = CommandResult(status: 124, stderr: "timeout")
}

/// Seam cho mọi lệnh hệ thống (launchctl, pkgutil, sqlite3, security, lsregister, socketfilterfw,
/// systemextensionsctl, tccutil...). Chạy KHÔNG qua shell (không nội suy). Test dùng bản giả trả output cố định.
/// Quy ước của các bộ quét: lệnh lỗi hoặc không có → coi như output rỗng (zsh luôn `2>/dev/null`).
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult

    /// Đọc stdout THEO DÒNG (byte thô, không gồm `\n`) trong lúc lệnh còn chạy. `onLine` trả false để dừng sớm:
    /// tiến trình bị kết thúc (như SIGPIPE của `| head`). Hủy qua `cancellation` cũng kết thúc tiến trình ngay.
    /// Mặc định: chạy `run` rồi tách dòng (đủ cho runner giả của test).
    func streamLines(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                     cancellation: CancellationToken?, onLine: (ArraySlice<UInt8>) -> Bool) -> StreamResult
}

/// Kết quả `streamLines`.
public struct StreamResult: Sendable, Equatable {
    /// Mã thoát; dừng sớm theo yêu cầu của `onLine` → 0.
    public var status: Int32
    public var cancelled: Bool
    public var timedOut: Bool

    public init(status: Int32, cancelled: Bool = false, timedOut: Bool = false) {
        self.status = status
        self.cancelled = cancelled
        self.timedOut = timedOut
    }

    public var succeeded: Bool { status == 0 && !cancelled && !timedOut }
}

extension CommandRunner {
    public func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        run(executable, arguments, timeout: 60)
    }

    public func streamLines(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                            cancellation: CancellationToken?, onLine: (ArraySlice<UInt8>) -> Bool) -> StreamResult {
        let r = run(executable, arguments, timeout: timeout)
        if r.status == CommandResult.timedOut.status { return StreamResult(status: r.status, timedOut: true) }
        for line in r.lines {
            if cancellation?.isCancelled == true { return StreamResult(status: r.status, cancelled: true) }
            if !onLine(ArraySlice(Array(line.utf8))) { return StreamResult(status: 0) }
        }
        return StreamResult(status: r.status)
    }

    /// `cmd | head -n` thật: chỉ đọc `maxLines` dòng đầu rồi dừng lệnh (không đọc hết output khổng lồ).
    public func runHead(_ executable: String, _ arguments: [String], maxLines: Int,
                        timeout: TimeInterval = 60) -> CommandResult {
        var lines: [String] = []
        guard maxLines > 0 else { return CommandResult(status: 0) }
        let r = streamLines(executable, arguments, timeout: timeout, cancellation: nil) { line in
            lines.append(String(decoding: line, as: UTF8.self))
            return lines.count < maxLines
        }
        let out = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        return CommandResult(status: r.timedOut ? CommandResult.timedOut.status : r.status, stdout: out)
    }
}

/// Đường dẫn tuyệt đối của các lệnh dùng tới (không phụ thuộc PATH của app GUI).
public enum Tool {
    public static let launchctl = "/bin/launchctl"
    public static let pkgutil = "/usr/sbin/pkgutil"
    public static let sqlite3 = "/usr/bin/sqlite3"
    public static let security = "/usr/bin/security"
    public static let tccutil = "/usr/bin/tccutil"
    public static let xcrun = "/usr/bin/xcrun"
    public static let tmutil = "/usr/bin/tmutil"
    public static let swVers = "/usr/bin/sw_vers"
    public static let sfltool = "/usr/bin/sfltool"
    public static let systemextensionsctl = "/usr/bin/systemextensionsctl"
    public static let kmutil = "/usr/bin/kmutil"
    public static let plutil = "/usr/bin/plutil"
    public static let dscl = "/usr/bin/dscl"
    public static let mdfind = "/usr/bin/mdfind"
    public static let socketfilterfw = "/usr/libexec/ApplicationFirewall/socketfilterfw"
    public static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister"
}

/// Chạy lệnh thật bằng `Process`. Đọc stdout/stderr song song (output lsregister -dump vài MB), stdin = /dev/null.
public struct ProcessCommandRunner: CommandRunner {
    public var environment: [String: String]?

    public init(environment: [String: String]? = nil) {
        self.environment = environment
    }

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return .notFound }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = environment }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return .notFound }

        let group = DispatchGroup()
        let box = OutputBox()
        DispatchQueue.global(qos: .utility).async(group: group) {
            box.setOut(out.fileHandleForReading.readDataToEndOfFile())
        }
        DispatchQueue.global(qos: .utility).async(group: group) {
            box.setErr(err.fileHandleForReading.readDataToEndOfFile())
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
            _ = group.wait(timeout: .now() + 2)
            return .timedOut
        }
        _ = group.wait(timeout: .now() + 5)
        let (o, e) = box.get()
        return CommandResult(status: p.terminationStatus,
                             stdout: String(decoding: o, as: UTF8.self),
                             stderr: String(decoding: e, as: UTF8.self))
    }

    public func streamLines(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                            cancellation: CancellationToken?, onLine: (ArraySlice<UInt8>) -> Bool) -> StreamResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return StreamResult(status: 127) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = environment }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return StreamResult(status: 127) }

        // Canh giờ + cờ hủy trên luồng phụ: lệnh im lặng (không ra dòng nào) vẫn bị dừng đúng lúc.
        let flags = StopFlags()
        let deadline = Date().addingTimeInterval(timeout)
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 0.1, repeating: 0.1)
        watchdog.setEventHandler {
            if cancellation?.isCancelled == true {
                flags.set(cancelled: true); p.terminate()
            } else if Date() > deadline {
                flags.set(timedOut: true); p.terminate()
            }
        }
        watchdog.resume()
        defer { watchdog.cancel() }

        let h = out.fileHandleForReading
        var buf: [UInt8] = []
        var stopped = false
        reading: while true {
            let chunk = h.availableData
            if chunk.isEmpty { break }
            buf.append(contentsOf: chunk)
            var start = buf.startIndex
            while let nl = buf[start...].firstIndex(of: 0x0A) {
                if flags.any || !onLine(buf[start..<nl]) {
                    stopped = true
                    break reading
                }
                start = nl + 1
            }
            buf.removeSubrange(..<start)
        }
        if !stopped, !buf.isEmpty, !flags.any { _ = onLine(buf[...]) }
        if stopped || flags.any { p.terminate() }
        if done.wait(timeout: .now() + 5) == .timedOut { return StreamResult(status: 124, timedOut: true) }
        if flags.cancelled { return StreamResult(status: p.terminationStatus, cancelled: true) }
        if flags.timedOut { return StreamResult(status: 124, timedOut: true) }
        return StreamResult(status: stopped ? 0 : p.terminationStatus)
    }

    private final class StopFlags: @unchecked Sendable {
        private let lock = NSLock()
        private var _cancelled = false, _timedOut = false
        func set(cancelled: Bool = false, timedOut: Bool = false) {
            lock.lock(); _cancelled = _cancelled || cancelled; _timedOut = _timedOut || timedOut; lock.unlock()
        }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return _timedOut }
        var any: Bool { cancelled || timedOut }
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        func setOut(_ d: Data) { lock.lock(); out = d; lock.unlock() }
        func setErr(_ d: Data) { lock.lock(); err = d; lock.unlock() }
        func get() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
    }
}
