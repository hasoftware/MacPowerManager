import XCTest
@testable import PowerCore

/// SMC giả lập kiểu Intel T2: BCLM ui8 attr 0xD0, BRSC ui16 big-endian.
private final class FakeSMC: SMCAccess {
    var values: [String: SMCReading] = [:]
    var rejectWrites = false
    var ignoreWrites = false
    private(set) var writes: [(String, [UInt8])] = []

    init(bclm: UInt8 = 100, bclmType: String = "ui8 ", attributes: UInt8 = 0xD0, brsc: UInt16? = 72) {
        values["BCLM"] = SMCReading(key: "BCLM", type: bclmType, attributes: attributes, bytes: [bclm])
        if let brsc {
            values["BRSC"] = SMCReading(key: "BRSC", type: "ui16", attributes: 0x80, bytes: [UInt8(brsc >> 8), UInt8(brsc & 0xff)])
        }
    }

    func read(_ key: String) -> SMCReading? { values[key] }

    func write(_ key: String, _ bytes: [UInt8]) throws {
        if rejectWrites { throw SMCError(key: key, code: kIOReturnNotPrivileged) }
        writes.append((key, bytes))
        guard !ignoreWrites, let old = values[key] else { return }
        values[key] = SMCReading(key: key, type: old.type, attributes: old.attributes, bytes: bytes)
    }
}

final class IntelTests: XCTestCase {
    func testDetection() {
        XCTAssertNotNil(IntelChargeLimiter(smc: FakeSMC(), isAppleSilicon: false))
        XCTAssertNil(IntelChargeLimiter(smc: FakeSMC(), isAppleSilicon: true), "Không bao giờ dùng BCLM trên Apple Silicon")
        XCTAssertNil(IntelChargeLimiter(smc: FakeSMC(attributes: 0x90), isAppleSilicon: false), "BCLM không ghi được")
        XCTAssertNil(IntelChargeLimiter(smc: FakeSMC(bclmType: "hex_"), isAppleSilicon: false), "Sai kiểu dữ liệu")
    }

    func testSetLimitClampsAndVerifies() throws {
        let smc = FakeSMC()
        let limiter = try XCTUnwrap(IntelChargeLimiter(smc: smc, isAppleSilicon: false))
        try limiter.setLimit(80)
        XCTAssertEqual(limiter.currentLimit, 80)
        try limiter.setLimit(10)
        XCTAssertEqual(limiter.currentLimit, 50, "Không bao giờ ghi dưới 50")
        try limiter.setLimit(150)
        XCTAssertEqual(limiter.currentLimit, 100)
    }

    func testWriteNotTakingEffectThrows() throws {
        let smc = FakeSMC()
        let limiter = try XCTUnwrap(IntelChargeLimiter(smc: smc, isAppleSilicon: false))
        smc.ignoreWrites = true
        XCTAssertThrowsError(try limiter.setLimit(80), "Đọc lại không khớp thì báo lỗi")
        smc.ignoreWrites = false
        smc.rejectWrites = true
        XCTAssertThrowsError(try limiter.setLimit(80))
        XCTAssertFalse(limiter.restoreDefaults())
    }

    func testHardwarePercentBigEndianAndScaled() throws {
        XCTAssertEqual(IntelChargeLimiter(smc: FakeSMC(brsc: 72), isAppleSilicon: false)?.hardwarePercent, 72)
        XCTAssertEqual(IntelChargeLimiter(smc: FakeSMC(brsc: 72 << 8), isAppleSilicon: false)?.hardwarePercent, 72,
                       "Một số máy lưu BRSC ×256")
        XCTAssertNil(IntelChargeLimiter(smc: FakeSMC(brsc: nil), isAppleSilicon: false)?.hardwarePercent)
    }

    func testFirmwareLimitPolicy() {
        var config = PowerConfig()
        config.chargeLimit = 80
        func target(_ reason: ChargeReason, hw: Int? = 72, percent: Int = 70) -> Int {
            IntelPolicy.firmwareLimit(config: config, reason: reason, hardwarePercent: hw, percent: percent)
        }
        XCTAssertEqual(target(.normal), 80)
        XCTAssertEqual(target(.limitReached), 80)
        XCTAssertEqual(target(.critical), 80, "Pin nguy hiểm: BCLM ≥ 50 nên firmware vẫn sạc")
        XCTAssertEqual(target(.manualPause), 72, "Tạm dừng: giữ ở mức pin phần cứng hiện tại")
        XCTAssertEqual(target(.thermal, hw: nil, percent: 66), 66, "Không đọc được BRSC thì dùng % của macOS")
        XCTAssertEqual(target(.thermal, hw: 30), 50, "Không bao giờ dưới 50")
        XCTAssertEqual(target(.manualPause, hw: 95), 80, "Tạm dừng không được nâng giới hạn")

        config.chargeLimit = 30
        XCTAssertEqual(target(.normal), 50, "Giới hạn dưới 50 bị kẹp về 50 trên Intel")
        config.chargeLimitEnabled = false
        XCTAssertEqual(target(.normal), 100)
        XCTAssertEqual(target(.thermal, hw: 72), 72)
    }

    func testInstallLocation() {
        XCTAssertTrue(InstallLocation.isTemporary(bundlePath: "/private/var/folders/x/T/AppTranslocation/ABC/d/MacPowerManager.app",
                                                  isOnReadOnlyVolume: true))
        XCTAssertTrue(InstallLocation.isTemporary(bundlePath: "/Volumes/MacPowerManager 0.1.1/MacPowerManager.app",
                                                  isOnReadOnlyVolume: true))
        XCTAssertFalse(InstallLocation.isTemporary(bundlePath: "/Volumes/SSD/Applications/MacPowerManager.app",
                                                   isOnReadOnlyVolume: false), "Ổ đĩa ngoài ghi được không phải vị trí tạm")
        XCTAssertFalse(InstallLocation.isTemporary(bundlePath: "/Applications/MacPowerManager.app", isOnReadOnlyVolume: false))
        XCTAssertTrue(InstallLocation.version("0.2.0", isAtLeast: "0.1.1"))
        XCTAssertTrue(InstallLocation.version("0.1.1", isAtLeast: "0.1.1"))
        XCTAssertFalse(InstallLocation.version("0.1.10", isAtLeast: "0.2"))
        XCTAssertTrue(InstallLocation.version("0.10.0", isAtLeast: "0.9.9"))
    }
}
