import Foundation
import XCTest
@testable import MacPowerManager

final class ConflictScannerTests: XCTestCase {
    func testBatteryScriptDetected() {
        XCTAssertTrue(ConflictScanner.isBatteryScript(path: "/usr/local/bin/battery", arguments: nil))
        XCTAssertTrue(ConflictScanner.isBatteryScript(
            path: "/bin/bash", arguments: ["/bin/bash", "/usr/local/bin/battery", "maintain_synchronous", "80"]))
        XCTAssertTrue(ConflictScanner.isBatteryScript(
            path: "/bin/zsh", arguments: ["zsh", "-e", "/opt/homebrew/bin/battery", "maintain", "80"]))
    }

    func testRecycledPidRejected() {
        XCTAssertFalse(ConflictScanner.isBatteryScript(
            path: "/System/Applications/Safari.app/Contents/MacOS/Safari", arguments: ["Safari"]))
        XCTAssertFalse(ConflictScanner.isBatteryScript(path: "/bin/bash", arguments: ["/bin/bash", "/tmp/other.sh"]))
        XCTAssertFalse(ConflictScanner.isBatteryScript(path: nil, arguments: nil))
        XCTAssertFalse(ConflictScanner.isBatteryScript(path: nil, arguments: []))
    }

    func testParseProcArgs() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { bytes += $0 }
        bytes += Array("/bin/bash".utf8) + [0, 0, 0, 0]
        for arg in ["/bin/bash", "/usr/local/bin/battery", "maintain"] { bytes += Array(arg.utf8) + [0] }
        bytes += Array("PATH=/usr/bin".utf8) + [0]
        XCTAssertEqual(ConflictScanner.parseProcArgs(bytes), ["/bin/bash", "/usr/local/bin/battery", "maintain"])
        XCTAssertNil(ConflictScanner.parseProcArgs([1, 0]))
    }

    func testCurrentProcessArgumentsReadable() {
        // Tiến trình test không phải script battery.
        XCTAssertFalse(ConflictScanner.isBatteryScript(path: CommandLine.arguments.first, arguments: CommandLine.arguments))
    }
}
