import XCTest
@testable import PowerCore

/// SMC giả lập máy chỉ có phương thức cũ (không có CHTE/CHIE). macOS dùng CH0B cho Sạc tối ưu.
private final class LegacyFakeSMC: SMCAccess {
    var values: [String: SMCReading] = [:]
    private(set) var writes: [(key: String, bytes: [UInt8])] = []

    init(chte: Bool = false) {
        set("CH0B", [0])
        set("CH0C", [0])
        set("CH0I", [0])
        set("CH0J", [0])
        set("CHIE", [0])
        if chte { set("CHTE", [0, 0, 0, 0]) }
    }

    func set(_ key: String, _ bytes: [UInt8], attributes: UInt8 = 0xd4) {
        values[key] = SMCReading(key: key, type: key == "CHTE" ? "ui32" : "hex_", attributes: attributes, bytes: bytes)
    }

    func bytes(_ key: String) -> [UInt8]? { values[key]?.bytes }
    func wrote(_ key: String) -> Bool { writes.contains { $0.key == key } }

    func read(_ key: String) -> SMCReading? { values[key] }

    func write(_ key: String, _ bytes: [UInt8]) throws {
        guard let old = values[key] else { throw SMCError(key: key, code: kIOReturnNotFound) }
        writes.append((key, bytes))
        values[key] = SMCReading(key: key, type: old.type, attributes: old.attributes, bytes: bytes)
    }
}

final class AdapterKeyAndLegacyTests: XCTestCase {
    private func legacy() -> (LegacyFakeSMC, ChargingControl) {
        let smc = LegacyFakeSMC()
        let control = ChargingControl(smc: smc, isAppleSilicon: true)
        XCTAssertEqual(control.chargingKeys, .ch0bc)
        return (smc, control)
    }

    // MARK: Phương thức cũ chỉ dùng CH0C

    func testLegacyJudgesChargingFromCH0COnly() {
        let (smc, control) = legacy()
        smc.set("CH0B", [0x02])
        XCTAssertEqual(control.isChargingEnabled, true, "CH0B do Sạc tối ưu đặt không phải là helper chặn sạc")
        smc.set("CH0C", [0x02])
        XCTAssertEqual(control.isChargingEnabled, false)
        smc.set("CH0B", [0])
        XCTAssertEqual(control.isChargingEnabled, false)
    }

    func testLegacyInhibitAndEnableWriteCH0COnly() throws {
        let (smc, control) = legacy()
        smc.set("CH0B", [0x02])
        try control.setChargingEnabled(false)
        XCTAssertEqual(smc.bytes("CH0C"), [0x02], "Giữ giá trị 02 như v0.2")
        try control.setChargingEnabled(true)
        XCTAssertEqual(smc.bytes("CH0C"), [0])
        XCTAssertFalse(smc.wrote("CH0B"), "Không tranh chấp CH0B với Sạc tối ưu")
        XCTAssertEqual(smc.bytes("CH0B"), [0x02])
    }

    func testLegacySelectedWithoutUsableCH0B() {
        let smc = LegacyFakeSMC()
        smc.values["CH0B"] = nil
        XCTAssertEqual(ChargingControl(smc: smc, isAppleSilicon: true).chargingKeys, .ch0bc)
        let readOnly = LegacyFakeSMC()
        readOnly.set("CH0B", [0], attributes: 0x84)
        XCTAssertEqual(ChargingControl(smc: readOnly, isAppleSilicon: true).chargingKeys, .ch0bc)
    }

    func testLegacyRestoreLeavesCH0BUnlessWritten() {
        let (smc, control) = legacy()
        smc.set("CH0B", [0x02])
        smc.set("CH0C", [0x02])
        XCTAssertTrue(control.restoreDefaults())
        XCTAssertEqual(smc.bytes("CH0C"), [0], "CH0C luôn được xóa")
        XCTAssertEqual(smc.bytes("CH0B"), [0x02])
        XCTAssertFalse(smc.wrote("CH0B"), "Không ghi CH0B=0 khi helper chưa từng ghi")

        XCTAssertTrue(control.restoreDefaults(clearing: ["CH0B", "CH0C"]))
        XCTAssertEqual(smc.bytes("CH0B"), [0], "Phiên trước (v0.2) đã ghi CH0B thì xóa")
    }

    func testLegacyRestoreWhenAlreadyClearWritesNothing() {
        let (smc, control) = legacy()
        XCTAssertTrue(control.restoreDefaults())
        XCTAssertFalse(smc.wrote("CH0B"))
    }

    func testCHTEMethodRestoreAlsoClearsCH0C() {
        let smc = LegacyFakeSMC(chte: true)
        let control = ChargingControl(smc: smc, isAppleSilicon: true)
        XCTAssertEqual(control.chargingKeys, .chte)
        smc.set("CH0C", [0x02])
        smc.set("CH0B", [0x02])
        XCTAssertTrue(control.restoreDefaults())
        XCTAssertEqual(smc.bytes("CH0C"), [0])
        XCTAssertEqual(smc.bytes("CH0B"), [0x02])
    }

    // MARK: Mức sàn nguy hiểm xóa mọi key ngắt adapter

    func testClearAdapterKeysClearsForeignCH0IAndCH0J() {
        let smc = LegacyFakeSMC(chte: true)
        let control = ChargingControl(smc: smc, isAppleSilicon: true)
        XCTAssertEqual(control.adapterKeys, .chie)
        smc.set("CH0I", [0x01])
        smc.set("CH0J", [0x20])
        XCTAssertEqual(control.isAdapterEnabled, true, "Phương thức đang dùng (CHIE) không thấy việc ngắt qua CH0I/CH0J")
        XCTAssertEqual(control.clearAdapterKeys(), ["CH0I", "CH0J"])
        XCTAssertEqual(smc.bytes("CH0I"), [0])
        XCTAssertEqual(smc.bytes("CH0J"), [0])
        XCTAssertFalse(smc.wrote("CHIE"), "Key đang bằng 0 thì không ghi")
        XCTAssertEqual(control.clearAdapterKeys(), [], "Không còn gì để xóa")
    }

    // MARK: Ngắt adapter từ bên ngoài

    func testUnownedAdapterCutReportedWhenNotDischarging() {
        let current: [String: [UInt8]] = ["CHIE": [0], "CH0I": [0x01], "CH0J": [0x20]]
        let found = ForeignWriteDetector.detectUnownedAdapterCuts(lastWritten: [:], current: current,
                                                                 discharging: false, now: testEpoch)
        XCTAssertEqual(found, [
            ForeignWrite(key: "CH0I", expected: "00", found: "01", at: testEpoch),
            ForeignWrite(key: "CH0J", expected: "00", found: "20", at: testEpoch),
        ])
    }

    func testUnownedAdapterCutIgnoresOwnKeysAndDischarge() {
        let current: [String: [UInt8]] = ["CHIE": [0x08], "CH0I": [0x01]]
        XCTAssertEqual(ForeignWriteDetector.detectUnownedAdapterCuts(
            lastWritten: ["CHIE": [0x08], "CH0I": [0]], current: current, discharging: false, now: testEpoch), [],
            "Key helper đã ghi do detect() so sánh")
        XCTAssertEqual(ForeignWriteDetector.detectUnownedAdapterCuts(
            lastWritten: [:], current: current, discharging: true, now: testEpoch), [],
            "Đang xả thì adapter bị ngắt là chủ ý")
        XCTAssertEqual(ForeignWriteDetector.detectUnownedAdapterCuts(
            lastWritten: [:], current: ["CHIE": [0], "CHTE": [1, 0, 0, 0]], discharging: false, now: testEpoch), [],
            "Chỉ xét key ngắt adapter, bỏ qua key bằng 0")
    }
}
