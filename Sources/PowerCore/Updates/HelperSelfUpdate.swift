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
        case launchdConfigChanged
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
            case .launchdConfigChanged: "Cấu hình LaunchDaemon thay đổi, cần cài lại helper"
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
        let data = try Self.readArchive(at: archivePath)
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
        // launchd giữ cấu hình job từ lúc nạp, nên đổi plist chỉ có tác dụng khi cài lại (bootout/bootstrap).
        // Plist khác bản đang cài thì để app nhắc cài lại helper như trước.
        let newPlist = app.appendingPathComponent("Contents/Resources/\(PowerConstants.helperLabel).plist")
        guard let bundledPlist = try? Data(contentsOf: newPlist),
              bundledPlist == (try? Data(contentsOf: paths.plistDestination)) else { throw Failure.launchdConfigChanged }

        // 4. cdhash của app mới (mỗi kiến trúc một giá trị).
        let hashes = ["arm64", "x86_64"].compactMap { Self.cdhash(of: app, arch: $0) }
        guard !hashes.isEmpty else { throw Failure.noCDHash }

        // 5. Thay helper bằng cách đổi tên nguyên tử; tiến trình đang chạy vẫn giữ file cũ tới khi thoát.
        do {
            try Self.replace(paths.helperDestination, with: newHelper, permissions: 0o755)
            // 6. Ghim cdhash: app mới đứng trước, giữ app đang chạy để nó vẫn dùng được tới khi mở lại.
            //    Bản cài chỉ ghim theo bundle id (không có cdhash) thì giữ nguyên: ghim mỗi app mới sẽ khóa app
            //    đang chạy nếu bước thay app thất bại và app cũ được khôi phục.
            let existing = TrustedClients.hashes(from: try? Data(contentsOf: paths.trustFile))
            if !existing.isEmpty {
                let merged = Self.mergeTrust(new: hashes, existing: existing)
                let json = try JSONEncoder().encode(TrustedClients.File(cdhashes: merged))
                try Self.writeOwned(json, to: paths.trustFile, permissions: 0o644)
            }
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

    /// Đọc file cập nhật an toàn khi chạy bằng root với đường dẫn do app gửi: không theo symlink, không chặn ở FIFO,
    /// chỉ nhận file thường trên ổ cục bộ (ổ mạng có thể treo helper), và không đọc quá giới hạn.
    static func readArchive(at path: String) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        var volume = statfs()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              fstatfs(fd, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw Failure.unreadable }
        guard info.st_size <= maxArchiveBytes else { throw Failure.tooLarge }
        guard let data = try? handle.read(upToCount: maxArchiveBytes + 1) else { throw Failure.unreadable }
        guard data.count <= maxArchiveBytes else { throw Failure.tooLarge }
        return data
    }

    /// Thay `destination` bằng nội dung của `source`.
    private static func replace(_ destination: URL, with source: URL, permissions: Int) throws {
        try writeOwned(Data(contentsOf: source), to: destination, permissions: permissions)
    }

    /// Ghi file mới do chính tiến trình này sở hữu (root:wheel khi chạy bằng root), rồi đổi tên nguyên tử vào đích.
    /// Không sao chép file đã giải nén: `ditto` giữ uid/gid ghi trong zip (máy build), và bản sao của root giữ
    /// nguyên chủ sở hữu đó. Helper mà người dùng thường ghi được thì tiến trình nào cũng leo thang lên root được.
    static func writeOwned(_ data: Data, to destination: URL, permissions: Int) throws {
        let fm = FileManager.default
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).new-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged) }
        try data.write(to: staged, options: .withoutOverwriting)
        let owner = geteuid()
        if owner == 0, chown(staged.path, 0, 0) != 0 { throw Failure.io(String(cString: strerror(errno))) }
        guard chmod(staged.path, mode_t(permissions)) == 0 else { throw Failure.io(String(cString: strerror(errno))) }
        var info = stat()
        guard lstat(staged.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner,
              owner != 0 || info.st_gid == 0, info.st_mode & 0o022 == 0 else {
            throw Failure.io("Quyền sở hữu file không đúng: \(destination.path)")
        }
        if rename(staged.path, destination.path) != 0 { throw Failure.io(String(cString: strerror(errno))) }
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
