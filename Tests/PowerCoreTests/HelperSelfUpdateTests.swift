import CryptoKit
import XCTest
@testable import PowerCore

/// Chạy thật toàn bộ quy trình helper tự cập nhật trên thư mục tạm, với một app giả được ký code và ký Ed25519.
final class HelperSelfUpdateTests: XCTestCase {
    private var dir: URL!
    private let key = Curve25519.Signing.PrivateKey()
    private var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("selfupdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Tạo `MacPowerManager.app` giả, ký code ad-hoc, nén `.zip`. Trả về (đường dẫn zip, dữ liệu zip).
    private func makeRelease(version: String, identifier: String = "com.hasoftware.MacPowerManager",
                             helperMarker: String = "new-helper") throws -> URL {
        let fm = FileManager.default
        let root = dir.appendingPathComponent("build-\(UUID().uuidString)")
        let app = root.appendingPathComponent("MacPowerManager.app")
        let macos = app.appendingPathComponent("Contents/MacOS"), res = app.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: res, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                    "CFBundleExecutable": "MacPowerManager", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try fm.copyItem(atPath: "/usr/bin/true", toPath: macos.appendingPathComponent("MacPowerManager").path)
        // Helper giả: script có dấu hiệu để kiểm tra đã được cài.
        try "#!/bin/sh\n# \(helperMarker)\n".write(to: macos.appendingPathComponent("PowerHelper"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macos.appendingPathComponent("PowerHelper").path)
        try "<plist/>".write(to: res.appendingPathComponent("\(PowerConstants.helperLabel).plist"), atomically: true, encoding: .utf8)
        XCTAssertEqual(HelperSelfUpdate.run("/usr/bin/codesign", ["--force", "--deep", "-s", "-", app.path]).status, 0)
        let zip = root.appendingPathComponent("MacPowerManager-\(version).zip")
        XCTAssertEqual(HelperSelfUpdate.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path]).status, 0)
        return zip
    }

    private func sign(_ zip: URL) throws -> String {
        try key.signature(for: Data(contentsOf: zip)).base64EncodedString()
    }

    private func updater(current: String = "0.6.0") -> HelperSelfUpdate {
        HelperSelfUpdate(paths: .init(workDirectory: dir.appendingPathComponent("work"),
                                      helperDestination: dir.appendingPathComponent("helper"),
                                      plistDestination: dir.appendingPathComponent("helper.plist"),
                                      trustFile: dir.appendingPathComponent("trusted-clients.json")),
                         publicKey: publicKey, currentVersion: current)
    }

    private func installOldHelper() throws {
        try "#!/bin/sh\n# old-helper\n".write(to: dir.appendingPathComponent("helper"), atomically: true, encoding: .utf8)
        try "<plist/>".write(to: dir.appendingPathComponent("helper.plist"), atomically: true, encoding: .utf8)
        let old = TrustedClients.File(cdhashes: [String(repeating: "a", count: 40), String(repeating: "b", count: 40)])
        try JSONEncoder().encode(old).write(to: dir.appendingPathComponent("trusted-clients.json"))
    }

    private var installedHelper: String { (try? String(contentsOf: dir.appendingPathComponent("helper"), encoding: .utf8)) ?? "" }

    func testValidUpdateInstallsHelperAndPinsNewApp() throws {
        try installOldHelper()
        let zip = try makeRelease(version: "0.6.1")
        let version = try updater().apply(archivePath: zip.path, signature: try sign(zip))
        XCTAssertEqual(version, "0.6.1")
        XCTAssertTrue(installedHelper.contains("new-helper"))
        // Helper mới thuộc về tiến trình cài (root khi chạy thật), không phải uid/gid lưu trong zip; không ai khác ghi được.
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("helper").path)
        XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, geteuid())
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        let trust = TrustedClients.hashes(from: try Data(contentsOf: dir.appendingPathComponent("trusted-clients.json")))
        XCTAssertGreaterThanOrEqual(trust.count, 3, "cdhash app mới + app đang chạy")
        XCTAssertLessThanOrEqual(trust.count, HelperSelfUpdate.maxTrustedHashes)
        XCTAssertNotEqual(trust.first, String(repeating: "a", count: 40), "cdhash app mới đứng trước")
        XCTAssertTrue(trust.contains(String(repeating: "a", count: 40)), "App đang chạy vẫn được tin tới khi mở lại")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("work").path), "Dọn thư mục làm việc")
    }

    func testRejectsBadSignature() throws {
        try installOldHelper()
        let zip = try makeRelease(version: "0.6.1")
        let otherKey = Curve25519.Signing.PrivateKey()
        let forged = try otherKey.signature(for: Data(contentsOf: zip)).base64EncodedString()
        XCTAssertThrowsError(try updater().apply(archivePath: zip.path, signature: forged)) {
            XCTAssertEqual($0 as? HelperSelfUpdate.Failure, .badSignature)
        }
        XCTAssertTrue(installedHelper.contains("old-helper"), "Không đụng vào helper đang cài")
    }

    func testRejectsTamperedArchive() throws {
        try installOldHelper()
        let zip = try makeRelease(version: "0.6.1")
        let signature = try sign(zip)
        var data = try Data(contentsOf: zip)
        data.append(0)
        try data.write(to: zip)
        XCTAssertThrowsError(try updater().apply(archivePath: zip.path, signature: signature))
        XCTAssertTrue(installedHelper.contains("old-helper"))
    }

    func testRejectsDowngradeAndForeignApp() throws {
        try installOldHelper()
        let old = try makeRelease(version: "0.5.9")
        XCTAssertThrowsError(try updater().apply(archivePath: old.path, signature: try sign(old))) {
            XCTAssertEqual($0 as? HelperSelfUpdate.Failure, .invalidBundle(.notNewer("0.5.9")))
        }
        let foreign = try makeRelease(version: "9.0.0", identifier: "com.example.evil")
        XCTAssertThrowsError(try updater().apply(archivePath: foreign.path, signature: try sign(foreign))) {
            XCTAssertEqual($0 as? HelperSelfUpdate.Failure, .invalidBundle(.wrongBundle("com.example.evil")))
        }
        XCTAssertTrue(installedHelper.contains("old-helper"))
    }

    func testChangedLaunchDaemonPlistNeedsReinstall() throws {
        try installOldHelper()
        try "<plist>old</plist>".write(to: dir.appendingPathComponent("helper.plist"), atomically: true, encoding: .utf8)
        let zip = try makeRelease(version: "0.6.1")
        XCTAssertThrowsError(try updater().apply(archivePath: zip.path, signature: try sign(zip))) {
            XCTAssertEqual($0 as? HelperSelfUpdate.Failure, .launchdConfigChanged)
        }
        XCTAssertTrue(installedHelper.contains("old-helper"))
    }

    func testIdentifierOnlyTrustIsLeftAlone() throws {
        try installOldHelper()
        let trustFile = dir.appendingPathComponent("trusted-clients.json")
        try JSONEncoder().encode(TrustedClients.File(cdhashes: [])).write(to: trustFile)
        let zip = try makeRelease(version: "0.6.1")
        _ = try updater().apply(archivePath: zip.path, signature: try sign(zip))
        XCTAssertTrue(installedHelper.contains("new-helper"))
        XCTAssertEqual(TrustedClients.hashes(from: try Data(contentsOf: trustFile)), [])
    }

    func testArchiveReadRejectsSymlinkAndFIFO() throws {
        let real = dir.appendingPathComponent("real.zip")
        try Data([1, 2, 3]).write(to: real)
        XCTAssertEqual(try HelperSelfUpdate.readArchive(at: real.path), Data([1, 2, 3]))
        let link = dir.appendingPathComponent("link.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try HelperSelfUpdate.readArchive(at: link.path)) {
            XCTAssertEqual($0 as? HelperSelfUpdate.Failure, .unreadable)
        }
        let fifo = dir.appendingPathComponent("fifo.zip")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try HelperSelfUpdate.readArchive(at: fifo.path)) {
            XCTAssertEqual($0 as? HelperSelfUpdate.Failure, .unreadable)
        }
        let sparse = dir.appendingPathComponent("big.zip")
        FileManager.default.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: UInt64(HelperSelfUpdate.maxArchiveBytes) + 1)
        try handle.close()
        XCTAssertThrowsError(try HelperSelfUpdate.readArchive(at: sparse.path)) {
            XCTAssertEqual($0 as? HelperSelfUpdate.Failure, .tooLarge)
        }
    }

    func testMissingFileAndTrustMerge() {
        XCTAssertThrowsError(try updater().apply(archivePath: dir.appendingPathComponent("nope.zip").path, signature: "x")) {
            XCTAssertEqual($0 as? HelperSelfUpdate.Failure, .unreadable)
        }
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
        let c = String(repeating: "c", count: 40), d = String(repeating: "d", count: 40), e = String(repeating: "e", count: 40)
        XCTAssertEqual(HelperSelfUpdate.mergeTrust(new: [c, d], existing: [a, b, e]), [c, d, a, b])
        XCTAssertEqual(HelperSelfUpdate.mergeTrust(new: [a, "rác"], existing: [a]), [a])
    }
}
