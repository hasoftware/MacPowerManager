import CryptoKit
import XCTest
@testable import PowerCore

final class AutoUpdateTests: XCTestCase {
    func testSignatureVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let data = Data("MacPowerManager-0.5.0.zip".utf8)
        let signature = try key.signature(for: data).base64EncodedString()
        XCTAssertTrue(UpdateSignature.isValid(data, signature: signature, publicKey: publicKey))
        XCTAssertTrue(UpdateSignature.isValid(data, signature: signature + "\n", publicKey: publicKey), "Dòng mới cuối file .sig")
        XCTAssertFalse(UpdateSignature.isValid(data + Data([0]), signature: signature, publicKey: publicKey), "File bị sửa")
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(UpdateSignature.isValid(data, signature: signature, publicKey: other), "Khóa khác")
        XCTAssertFalse(UpdateSignature.isValid(data, signature: "rác", publicKey: publicKey))
        XCTAssertFalse(UpdateSignature.isValid(data, signature: signature), "Không khớp khóa thật của dự án")
        XCTAssertNotNil(Data(base64Encoded: UpdateSignature.publicKey), "Khóa công khai nhúng sẵn hợp lệ")
    }

    func testReleaseAssets() throws {
        let json = """
        {"tag_name":"v0.5.0","html_url":"https://github.com/hasoftware/MacPowerManager/releases/tag/v0.5.0",
         "draft":false,"prerelease":false,"body":"x","assets":[
          {"name":"MacPowerManager-0.5.0.dmg","browser_download_url":"https://example.com/a.dmg","size":1},
          {"name":"MacPowerManager-0.5.0.zip","browser_download_url":"https://example.com/a.zip","size":2},
          {"name":"MacPowerManager-0.5.0.zip.sig","browser_download_url":"https://example.com/a.zip.sig","size":3}]}
        """
        let release = try ReleaseInfo.decode(Data(json.utf8))
        XCTAssertEqual(release.updateArchive?.name, "MacPowerManager-0.5.0.zip")
        XCTAssertEqual(release.updateSignature?.name, "MacPowerManager-0.5.0.zip.sig")
        XCTAssertTrue(release.supportsAutomaticUpdate)

        var unsigned = release
        unsigned.assets.removeAll { $0.name.hasSuffix(".sig") }
        XCTAssertFalse(unsigned.supportsAutomaticUpdate, "Bản cũ chưa có chữ ký: tải thủ công")
    }

    func testValidateExtractedBundle() {
        let id = "com.hasoftware.MacPowerManager"
        XCTAssertNil(UpdatePlan.validate(bundleIdentifier: id, version: "0.5.0", expectedIdentifier: id, currentVersion: "0.4.0"))
        XCTAssertEqual(UpdatePlan.validate(bundleIdentifier: "evil.app", version: "9.0.0", expectedIdentifier: id,
                                           currentVersion: "0.4.0"), .wrongBundle("evil.app"))
        XCTAssertEqual(UpdatePlan.validate(bundleIdentifier: id, version: "0.4.0", expectedIdentifier: id,
                                           currentVersion: "0.4.0"), .notNewer("0.4.0"), "Không cài lại cùng bản")
        XCTAssertNil(UpdatePlan.validate(bundleIdentifier: id, version: "0.4.0", expectedIdentifier: id,
                                         currentVersion: "0.4.0-dev"), "Bản dev được nâng lên bản chính thức")
    }

    func testInstallLocation() {
        XCTAssertEqual(UpdatePlan.installLocation(runningBundlePath: "/Applications/MacPowerManager.app", isOnReadOnlyVolume: false),
                       "/Applications/MacPowerManager.app")
        XCTAssertEqual(UpdatePlan.installLocation(runningBundlePath: "/Users/a/Apps/MacPowerManager.app", isOnReadOnlyVolume: false),
                       "/Users/a/Apps/MacPowerManager.app")
        XCTAssertEqual(UpdatePlan.installLocation(runningBundlePath: "/private/var/folders/x/AppTranslocation/y/d/MacPowerManager.app",
                                                  isOnReadOnlyVolume: true), "/Applications/MacPowerManager.app")
    }

    /// Chạy thật script thay app (bỏ bước `open`) trên thư mục tạm, với đường dẫn có dấu cách và dấu nháy.
    func testRelaunchScriptSwapsAppAndRestoresOnFailure() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("upd test '\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("My App.app"), newApp = dir.appendingPathComponent("new.app")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("v"))
        try fm.createDirectory(at: newApp, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: newApp.appendingPathComponent("v"))

        func run(_ script: String) throws {
            let testable = script.replacingOccurrences(of: "\nopen ", with: "\n: ")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", testable]
            try p.run()
            p.waitUntilExit()
        }
        // pid 999999 không tồn tại: không phải chờ.
        try run(UpdatePlan.relaunchScript(pid: 999_999, newApp: newApp.path, destination: destination.path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("v")), "new")
        XCTAssertFalse(fm.fileExists(atPath: newApp.path))
        let leftovers = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".old-") }
        XCTAssertTrue(leftovers.isEmpty, "Bản cũ được dọn sau khi thay thành công")

        // Bản mới không tồn tại: bản cũ phải được khôi phục.
        try run(UpdatePlan.relaunchScript(pid: 999_999, newApp: dir.appendingPathComponent("missing.app").path,
                                          destination: destination.path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("v")), "new", "Giữ nguyên app khi thay thất bại")
    }
}
