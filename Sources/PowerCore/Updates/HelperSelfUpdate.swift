import Foundation

/// Helper (root) tự cập nhật từ một bản phát hành đã ký, không cần hỏi mật khẩu quản trị.
///
/// Helper đang chạy đã có quyền root nên tự kiểm tra lại chữ ký Ed25519 của file `.zip`, giải nén vào thư mục chỉ
/// root ghi được, kiểm tra đúng app/mới hơn/chữ ký code, rồi thay file helper và ghim cdhash của app mới.
/// Chỉ bản có chữ ký của HASOFTWARE mới qua được bước đầu, nên app hay tiến trình lạ không thể lợi dụng.
public struct HelperSelfUpdate {
    public struct Paths: Sendable {
        /// Thư mục làm việc (tạo với quyền 0700).
        public var workDirectory: URL
        public var helperDestination: URL
        public var plistDestination: URL
        public var trustFile: URL

        public init(workDirectory: URL, helperDestination: URL, plistDestination: URL, trustFile: URL) {
            self.workDirectory = workDirectory
            self.helperDestination = helperDestination
            self.plistDestination = plistDestination
            self.trustFile = trustFile
        }

        public static let installed = Paths(
            workDirectory: URL(fileURLWithPath: "/Library/Application Support/MacPowerManager/update"),
            helperDestination: URL(fileURLWithPath: PowerConstants.helperInstallPath),
            plistDestination: URL(fileURLWithPath: PowerConstants.launchDaemonPath),
            trustFile: PowerConstants.trustedClientsURL)
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadable
        case tooLarge
        case badSignature
        case invalidBundle(UpdatePlan.Failure)
        case codeSignature
        case missingHelper
        case noCDHash
        case io(String)

        public var description: String {
            switch self {
            case .unreadable: "Không đọc được file cập nhật"
            case .tooLarge: "File cập nhật quá lớn"
            case .badSignature: "Chữ ký bản cập nhật không hợp lệ"
            case .invalidBundle(let f): "Bản cập nhật không hợp lệ: \(f)"
            case .codeSignature: "Chữ ký code của bản cập nhật không hợp lệ"
            case .missingHelper: "Bản cập nhật thiếu helper"
            case .noCDHash: "Không đọc được cdhash của app mới"
            case .io(let m): "Lỗi ghi file: \(m)"
            }
        }
    }

    /// Giữ tối đa chừng này cdhash: app mới (2 kiến trúc) và app đang chạy (để nó vẫn điều khiển được cho tới khi mở lại).
    public static let maxTrustedHashes = 4
    public static let maxArchiveBytes = 200 << 20

    public var paths: Paths
    public var publicKey: String
    public var currentVersion: String
    public var expectedIdentifier: String

    public init(paths: Paths = .installed, publicKey: String = UpdateSignature.publicKey,
                currentVersion: String = AppVersion.current, expectedIdentifier: String = PowerConstants.appBundleID) {
        self.paths = paths
        self.publicKey = publicKey
        self.currentVersion = currentVersion
        self.expectedIdentifier = expectedIdentifier
    }

    /// Cài helper của bản cập nhật. Trả về version mới. Helper gọi xong thì tự thoát để launchd chạy bản mới.
    public func apply(archivePath: String, signature: String) throws -> String {
        let fm = FileManager.default
        // 1. Đọc file một lần duy nhất rồi kiểm tra chữ ký trên chính các byte đó (file nằm ở nơi người dùng ghi được,
        //    nên không đọc lại lần nữa để tránh bị tráo giữa lúc kiểm tra và lúc dùng).
        let source = URL(fileURLWithPath: archivePath)
        guard let size = (try? fm.attributesOfItem(atPath: source.path))?[.size] as? Int else { throw Failure.unreadable }
        guard size <= Self.maxArchiveBytes else { throw Failure.tooLarge }
        guard let data = try? Data(contentsOf: source) else { throw Failure.unreadable }
        guard UpdateSignature.isValid(data, signature: signature, publicKey: publicKey) else { throw Failure.badSignature }

        // 2. Giải nén trong thư mục riêng (0700).
        let work = paths.workDirectory
        try? fm.removeItem(at: work)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure.io("\(error)")
        }
        defer { try? fm.removeItem(at: work) }
        let zip = work.appendingPathComponent("update.zip")
        let unpacked = work.appendingPathComponent("unpacked")
        do {
            try data.write(to: zip)
        } catch {
            throw Failure.io("\(error)")
        }
        guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]).status == 0 else { throw Failure.unreadable }

        // 3. Đúng app, mới hơn, chữ ký code hợp lệ.
        let app = unpacked.appendingPathComponent("MacPowerManager.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let version = info?["CFBundleShortVersionString"] as? String
        if let failure = UpdatePlan.validate(bundleIdentifier: info?["CFBundleIdentifier"] as? String, version: version,
                                             expectedIdentifier: expectedIdentifier, currentVersion: currentVersion) {
            throw Failure.invalidBundle(failure)
        }
        guard Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0 else {
            throw Failure.codeSignature
        }
        let newHelper = app.appendingPathComponent("Contents/MacOS/PowerHelper")
        guard fm.fileExists(atPath: newHelper.path) else { throw Failure.missingHelper }
        let newPlist = app.appendingPathComponent("Contents/Resources/\(PowerConstants.helperLabel).plist")

        // 4. cdhash của app mới (mỗi kiến trúc một giá trị).
        let hashes = ["arm64", "x86_64"].compactMap { Self.cdhash(of: app, arch: $0) }
        guard !hashes.isEmpty else { throw Failure.noCDHash }

        // 5. Thay helper (và plist) bằng cách đổi tên nguyên tử; tiến trình đang chạy vẫn giữ file cũ tới khi thoát.
        do {
            try Self.replace(paths.helperDestination, with: newHelper, permissions: 0o755)
            if fm.fileExists(atPath: newPlist.path) {
                try Self.replace(paths.plistDestination, with: newPlist, permissions: 0o644)
            }
            // 6. Ghim cdhash: app mới đứng trước, giữ app đang chạy để nó vẫn dùng được tới khi mở lại.
            let existing = TrustedClients.hashes(from: try? Data(contentsOf: paths.trustFile))
            let merged = Self.mergeTrust(new: hashes, existing: existing)
            let json = try JSONEncoder().encode(TrustedClients.File(cdhashes: merged))
            try json.write(to: paths.trustFile, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.trustFile.path)
        } catch {
            throw Failure.io("\(error)")
        }
        return version ?? "?"
    }

    /// cdhash mới đứng trước, bỏ trùng, giữ tối đa `maxTrustedHashes`.
    public static func mergeTrust(new: [String], existing: [String]) -> [String] {
        var seen = Set<String>()
        let all = (new + existing).compactMap(TrustedClients.normalizedHash).filter { seen.insert($0).inserted }
        return Array(all.prefix(maxTrustedHashes))
    }

    private static func replace(_ destination: URL, with source: URL, permissions: Int) throws {
        let fm = FileManager.default
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).new-\(UUID().uuidString)")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: source, to: staged)
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: staged.path)
        if rename(staged.path, destination.path) != 0 {
            let error = String(cString: strerror(errno))
            try? fm.removeItem(at: staged)
            throw Failure.io(error)
        }
    }

    private static func cdhash(of app: URL, arch: String) -> String? {
        let output = run("/usr/bin/codesign", ["-dvvv", "--arch", arch, app.path]).output
        for line in output.split(separator: "\n") where line.hasPrefix("CDHash=") {
            return TrustedClients.normalizedHash(String(line.dropFirst("CDHash=".count)))
        }
        return nil
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
