import Security
import XCTest
@testable import PowerCore

/// SMC giả lập kiểu M2 Pro (macOS 15.5): mọi control key có attr 0xd4.
private final class RuntimeFakeSMC: SMCAccess {
    var values: [String: SMCReading] = [:]
    /// Key ghi bị từ chối với kIOReturnNotPrivileged (firmware khóa).
    var lockedKeys: Set<String> = []
    /// Key ghi "thành công" nhưng giá trị không đổi.
    var ignoredKeys: Set<String> = []
    private(set) var writes: [(key: String, bytes: [UInt8])] = []
    private(set) var attempts: [String] = []

    static func m2Pro() -> RuntimeFakeSMC {
        let smc = RuntimeFakeSMC()
        smc.set("CHTE", type: "ui32", [0, 0, 0, 0])
        smc.set("CH0B", type: "hex_", [0])
        smc.set("CH0C", type: "hex_", [0])
        smc.set("CHIE", type: "hex_", [0])
        smc.set("CH0I", type: "ui8 ", [0])
        smc.set("CH0J", type: "ui8 ", [0])
        smc.set("B0AC", type: "si16", [0x07, 0xff], attributes: 0x84)
        return smc
    }

    func set(_ key: String, type: String, _ bytes: [UInt8], attributes: UInt8 = 0xd4) {
        values[key] = SMCReading(key: key, type: type, attributes: attributes, bytes: bytes)
    }

    func bytes(_ key: String) -> [UInt8]? { values[key]?.bytes }

    func read(_ key: String) -> SMCReading? { values[key] }

    func write(_ key: String, _ bytes: [UInt8]) throws {
        attempts.append(key)
        if lockedKeys.contains(key) { throw SMCError(key: key, code: kIOReturnNotPrivileged) }
        guard let old = values[key] else { throw SMCError(key: key, code: kIOReturnNotFound) }
        writes.append((key, bytes))
        guard !ignoredKeys.contains(key) else { return }
        values[key] = SMCReading(key: key, type: old.type, attributes: old.attributes, bytes: bytes)
    }
}

final class HelperRuntimeTests: XCTestCase {
    // MARK: CapabilityProbe

    func testProbeOnM2Pro() {
        let caps = CapabilityProbe.probe(RuntimeFakeSMC.m2Pro())
        XCTAssertEqual(caps.map(\.name), CapabilityProbe.controlKeys)
        for cap in caps where cap.name != "BCLM" {
            XCTAssertTrue(cap.present && cap.writable && !cap.locked, cap.name)
        }
        XCTAssertEqual(caps.last, KeyCapability(name: "BCLM", present: false, writable: false))
    }

    func testProbeReadOnlyWrongSizeAndEmptyKeys() {
        let smc = RuntimeFakeSMC.m2Pro()
        smc.set("CHTE", type: "ui32", [0, 0, 0, 0], attributes: 0x84)
        smc.set("CHIE", type: "hex_", [0, 0])
        smc.set("CH0J", type: "ui8 ", [])
        let caps = Dictionary(uniqueKeysWithValues: CapabilityProbe.probe(smc, locked: ["CH0B"]).map { ($0.name, $0) })
        XCTAssertEqual(caps["CHTE"], KeyCapability(name: "CHTE", present: true, writable: false), "Không có bit 0x40")
        XCTAssertEqual(caps["CHIE"]?.writable, false, "Sai kích thước thì không ghi")
        XCTAssertEqual(caps["CH0J"]?.present, false, "Key rỗng coi như không có")
        XCTAssertEqual(caps["CH0B"]?.locked, true)
        XCTAssertFalse(CapabilityProbe.isUsable(caps["CH0B"]))
        XCTAssertTrue(CapabilityProbe.isUsable(caps["CH0C"]))
    }

    // MARK: Chọn phương thức

    func testPrefersCHTEAndCHIE() {
        let control = ChargingControl(smc: RuntimeFakeSMC.m2Pro(), isAppleSilicon: true)
        XCTAssertEqual(control.chargingKeys, .chte)
        XCTAssertEqual(control.adapterKeys, .chie)
        XCTAssertEqual(control.capabilities.chargeMethod, "CHTE")
        XCTAssertEqual(control.capabilities.adapterMethod, "CHIE")
        XCTAssertEqual(control.capabilities.keys.count, CapabilityProbe.controlKeys.count)
    }

    func testFallsBackToLegacyKeys() {
        let smc = RuntimeFakeSMC.m2Pro()
        smc.values["CHTE"] = nil
        smc.values["CHIE"] = nil
        let control = ChargingControl(smc: smc, isAppleSilicon: true)
        XCTAssertEqual(control.chargingKeys, .ch0bc)
        XCTAssertEqual(control.adapterKeys, .ch0i)
    }

    func testUnusableKeysAreNotSelected() {
        let smc = RuntimeFakeSMC.m2Pro()
        smc.set("CHTE", type: "ui32", [0, 0, 0, 0], attributes: 0x84)
        smc.values["CH0C"] = nil
        smc.values["CHIE"] = nil
        smc.values["CH0I"] = nil
        let control = ChargingControl(smc: smc, isAppleSilicon: true)
        XCTAssertNil(control.chargingKeys, "CHTE chỉ đọc và thiếu CH0C")
        XCTAssertNil(control.adapterKeys, "CH0J không bao giờ được dùng để ngắt adapter")
        XCTAssertThrowsError(try control.setChargingEnabled(false))
        XCTAssertThrowsError(try control.setAdapterEnabled(false))
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testNoMethodsOnIntel() {
        let smc = RuntimeFakeSMC.m2Pro()
        let control = ChargingControl(smc: smc, isAppleSilicon: false)
        XCTAssertNil(control.chargingKeys)
        XCTAssertNil(control.adapterKeys)
        XCTAssertTrue(control.restoreDefaults())
        XCTAssertTrue(control.clearAdapterKeys().isEmpty)
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testWritesExpectedValues() throws {
        let smc = RuntimeFakeSMC.m2Pro()
        let control = ChargingControl(smc: smc, isAppleSilicon: true)
        try control.setChargingEnabled(false)
        XCTAssertEqual(smc.bytes("CHTE"), [1, 0, 0, 0])
        XCTAssertEqual(control.isChargingEnabled, false)
        try control.setAdapterEnabled(false)
        XCTAssertEqual(smc.bytes("CHIE"), [0x08])
        XCTAssertEqual(control.isAdapterEnabled, false)
        try control.setAdapterEnabled(true)
        try control.setChargingEnabled(true)
        XCTAssertEqual(smc.bytes("CHTE"), [0, 0, 0, 0])
        XCTAssertEqual(smc.bytes("CHIE"), [0])
        XCTAssertEqual(control.batteryCurrentmA, -249, "B0AC si16 little-endian")
    }

    func testReadBackMismatchRetriesOnceThenThrows() {
        let smc = RuntimeFakeSMC.m2Pro()
        smc.ignoredKeys = ["CHTE"]
        let control = ChargingControl(smc: smc, isAppleSilicon: true)
        XCTAssertThrowsError(try control.setChargingEnabled(false))
        XCTAssertEqual(smc.attempts, ["CHTE", "CHTE"])
        XCTAssertEqual(control.chargingKeys, .chte, "Lỗi đọc lại không phải firmware khóa")
    }

    // MARK: Firmware khóa key

    func testNotPrivilegedLocksAndFallsBack() throws {
        let smc = RuntimeFakeSMC.m2Pro()
        smc.lockedKeys = ["CHTE", "CHIE"]
        let control = ChargingControl(smc: smc, isAppleSilicon: true)

        try control.setChargingEnabled(false)
        XCTAssertEqual(control.chargingKeys, .ch0bc)
        XCTAssertEqual(smc.bytes("CH0B"), [0], "Phương thức cũ không đụng tới CH0B (Sạc tối ưu)")
        XCTAssertEqual(smc.bytes("CH0C"), [0x02])
        XCTAssertEqual(control.isChargingEnabled, false)

        try control.setAdapterEnabled(false)
        XCTAssertEqual(control.adapterKeys, .ch0i)
        XCTAssertEqual(smc.bytes("CH0I"), [0x01])

        let caps = control.capabilities
        XCTAssertEqual(caps.chargeMethod, "CH0B/CH0C")
        XCTAssertEqual(caps.adapterMethod, "CH0I")
        XCTAssertEqual(control.lockedKeys, ["CHTE", "CHIE"])
        XCTAssertEqual(caps.keys.first { $0.name == "CHTE" }?.locked, true)

        // Key bị khóa không bao giờ được thử lại.
        let before = smc.attempts.count
        try control.setAdapterEnabled(true)
        try control.setChargingEnabled(true)
        XCTAssertFalse(smc.attempts[before...].contains("CHTE"))
        XCTAssertFalse(smc.attempts[before...].contains("CHIE"))
        XCTAssertEqual(smc.bytes("CH0I"), [0])
        XCTAssertEqual(control.isChargingEnabled, true)
    }

    func testAllMethodsLockedStopsWithoutRetryLoop() {
        let smc = RuntimeFakeSMC.m2Pro()
        smc.lockedKeys = ["CHTE", "CH0B", "CH0C"]
        let control = ChargingControl(smc: smc, isAppleSilicon: true)
        XCTAssertThrowsError(try control.setChargingEnabled(false))
        XCTAssertNil(control.chargingKeys)
        XCTAssertEqual(smc.attempts, ["CHTE", "CH0C"])
        XCTAssertThrowsError(try control.setChargingEnabled(false))
        XCTAssertEqual(smc.attempts.count, 2, "Không còn phương thức thì không ghi nữa")
    }

    func testLegacyLockedNeverTouchesCH0B() {
        let smc = RuntimeFakeSMC.m2Pro()
        smc.values["CHTE"] = nil
        smc.lockedKeys = ["CH0C"]
        let control = ChargingControl(smc: smc, isAppleSilicon: true)
        XCTAssertThrowsError(try control.setChargingEnabled(false))
        XCTAssertFalse(smc.attempts.contains("CH0B"), "CH0B thuộc về Sạc tối ưu của macOS")
        XCTAssertEqual(smc.bytes("CH0B"), [0])
        XCTAssertNil(control.chargingKeys)
    }

    func testAdapterReEnableFailureClearsEveryAdapterKey() throws {
        let smc = RuntimeFakeSMC.m2Pro()
        let control = ChargingControl(smc: smc, isAppleSilicon: true)
        try control.setAdapterEnabled(false)
        smc.set("CH0J", type: "ui8 ", [0x20])
        smc.ignoredKeys = ["CHIE"]
        XCTAssertThrowsError(try control.setAdapterEnabled(true), "CHIE vẫn khác 0")
        XCTAssertEqual(smc.bytes("CH0J"), [0], "Các key ngắt adapter còn lại vẫn được xóa")

        smc.ignoredKeys = []
        smc.set("CHIE", type: "hex_", [0x08])
        smc.lockedKeys = ["CHIE"]
        smc.set("CH0I", type: "ui8 ", [0x01])
        try control.setAdapterEnabled(true)
        XCTAssertEqual(smc.bytes("CH0I"), [0])
    }

    // MARK: Khôi phục

    func testRestoreDefaultsClearsAllAdapterKeysAndInhibit() {
        let smc = RuntimeFakeSMC.m2Pro()
        smc.set("CHTE", type: "ui32", [1, 0, 0, 0])
        smc.set("CHIE", type: "hex_", [0x08])
        smc.set("CH0I", type: "ui8 ", [0x01])
        smc.set("CH0J", type: "ui8 ", [0x20])
        smc.set("CH0C", type: "hex_", [0x02])
        smc.set("CH0B", type: "hex_", [0x02])
        let control = ChargingControl(smc: smc, isAppleSilicon: true)
        XCTAssertTrue(control.restoreDefaults())
        for key in ["CHTE", "CHIE", "CH0I", "CH0J", "CH0C"] {
            XCTAssertTrue(smc.bytes(key)!.allSatisfy { $0 == 0 }, key)
        }
        XCTAssertEqual(smc.bytes("CH0B"), [0x02], "CH0B (Sạc tối ưu) chỉ bị xóa khi helper từng ghi")

        XCTAssertTrue(control.restoreDefaults(clearing: ["CH0B"]))
        XCTAssertEqual(smc.bytes("CH0B"), [0])
    }

    func testRestoreDefaultsReportsFailure() {
        let smc = RuntimeFakeSMC.m2Pro()
        smc.set("CH0J", type: "ui8 ", [0x01])
        smc.lockedKeys = ["CH0J"]
        XCTAssertFalse(ChargingControl(smc: smc, isAppleSilicon: true).restoreDefaults())
    }

    func testClearAdapterKeysReportsClearedKeys() {
        let smc = RuntimeFakeSMC.m2Pro()
        smc.set("CH0I", type: "ui8 ", [0x01])
        let control = ChargingControl(smc: smc, isAppleSilicon: true)
        XCTAssertEqual(control.isAdapterEnabled, true, "CHIE đang được dùng và bằng 0")
        XCTAssertEqual(control.clearAdapterKeys(), ["CH0I"])
        XCTAssertEqual(smc.bytes("CH0I"), [0])
        XCTAssertFalse(smc.writes.contains { $0.key == "CHTE" }, "Không đụng tới trạng thái chặn sạc")
    }

    // MARK: Trust (XPC)

    private let h1 = "e62fda5d4885bb26075e52e7991eb62103607706"
    private let h2 = "78FA279D5178C6FB94830865CBFF3C7CE48CA73B"

    func testRequirementString() {
        XCTAssertEqual(TrustedClients.requirement(cdhashes: []), "identifier \"com.hasoftware.MacPowerManager\"")
        XCTAssertEqual(TrustedClients.requirement(cdhashes: [h1, h2, h1]),
                       "identifier \"com.hasoftware.MacPowerManager\" and (cdhash H\"\(h1)\" or cdhash H\"\(h2.lowercased())\")")
        let injected = "\(h1)\") or anchor apple or (cdhash H\"\(h1)"
        XCTAssertEqual(TrustedClients.requirement(cdhashes: ["abc", injected, h1 + "0", "g" + h1.dropFirst()]),
                       "identifier \"com.hasoftware.MacPowerManager\"", "Giá trị không hợp lệ bị bỏ qua")
        XCTAssertEqual(TrustedClients.requirement(cdhashes: [injected, h1]),
                       "identifier \"com.hasoftware.MacPowerManager\" and (cdhash H\"\(h1)\")")
    }

    func testRequirementCompiles() {
        for hashes in [[], [h1], [h1, h2]] {
            let text = TrustedClients.requirement(cdhashes: hashes)
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess, text)
            XCTAssertNotNil(requirement)
        }
    }

    func testTrustedClientsFileParsing() throws {
        let data = Data("{\"cdhashes\":[\"\(h1)\",\"bad\",\"\(h2)\"],\"extra\":1}".utf8)
        XCTAssertEqual(TrustedClients.hashes(from: data), [h1, h2.lowercased()])
        XCTAssertEqual(TrustedClients.hashes(from: nil), [])
        XCTAssertEqual(TrustedClients.hashes(from: Data("not json".utf8)), [])
        XCTAssertEqual(TrustedClients.hashes(from: Data("{}".utf8)), [])
        let encoded = try JSONEncoder().encode(TrustedClients.File(cdhashes: [h1]))
        XCTAssertEqual(TrustedClients.hashes(from: encoded), [h1])
    }

    // MARK: Phiên khởi động

    func testNewBootClearsSessionState() {
        var state = RuntimeState()
        state.bootSessionUUID = "A"
        state.controller.thermalPaused = true
        state.controller.holdingAtLimit = true
        state.controller.chargeToLimitOnce = true
        state.controller.topUp = TopUpState(startedAt: Date(), expiresAt: Date().addingTimeInterval(3600),
                                           bootSessionUUID: "A")
        state.lastWritten = ["CHTE": [1, 0, 0, 0]]

        let same = BootSession.reconcile(state, currentUUID: "A")
        XCTAssertFalse(same.isNewBoot)
        XCTAssertEqual(same.state, state)

        let next = BootSession.reconcile(state, currentUUID: "B")
        XCTAssertTrue(next.isNewBoot)
        XCTAssertNil(next.state.controller.topUp)
        XCTAssertFalse(next.state.controller.holdingAtLimit)
        XCTAssertFalse(next.state.controller.chargeToLimitOnce)
        XCTAssertTrue(next.state.lastWritten.isEmpty, "SMC đã reset sau khi khởi động lại")
        XCTAssertEqual(next.state.bootSessionUUID, "B")
        XCTAssertTrue(next.state.controller.thermalPaused, "Bảo vệ nhiệt tự đánh giá lại")

        let fresh = BootSession.reconcile(RuntimeState(), currentUUID: "B")
        XCTAssertTrue(fresh.isNewBoot)
        XCTAssertEqual(fresh.state.bootSessionUUID, "B")
    }

    func testRuntimeStateRoundTripAndTolerantDecoding() throws {
        var state = RuntimeState()
        state.bootSessionUUID = "A"
        state.lastWritten = ["CHTE": [1, 0, 0, 0], "CHIE": [0]]
        state.controller.topUp = TopUpState(startedAt: Date(timeIntervalSince1970: 1),
                                           expiresAt: Date(timeIntervalSince1970: 2), bootSessionUUID: "A")
        let decoded = try JSONDecoder().decode(RuntimeState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)

        let broken = Data("{\"lastWritten\":\"x\",\"bootSessionUUID\":\"A\",\"controller\":{\"holdingAtLimit\":true}}".utf8)
        let partial = try JSONDecoder().decode(RuntimeState.self, from: broken)
        XCTAssertEqual(partial.bootSessionUUID, "A")
        XCTAssertTrue(partial.lastWritten.isEmpty)
        XCTAssertTrue(partial.controller.holdingAtLimit)
    }

    func testBootSessionUUIDIsReadable() {
        XCTAssertFalse(SystemInfo.bootSessionUUID.isEmpty)
        XCTAssertEqual(SystemInfo.bootSessionUUID, SystemInfo.bootSessionUUID)
    }
}
