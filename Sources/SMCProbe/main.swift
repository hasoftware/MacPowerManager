import Foundation
import PowerCore

// Công cụ chẩn đoán: in ra thông tin máy và các SMC key liên quan tới sạc.
// Người dùng có thể dán kết quả vào GitHub Issues để mở rộng hỗ trợ cho máy khác.

print("MacPowerManager smc-probe \(AppVersion.current)")
print("Máy: \(SystemInfo.model) · macOS \(SystemInfo.osVersion) · \(Platform.isAppleSilicon ? "Apple Silicon" : "Intel")"
      + " · firmware \(SystemInfo.firmwareVersion ?? "?")")
print("---")

do {
    let smc = try SMC()
    let groups: [(String, [String])] = [
        ("Điều khiển sạc", ["CHTE", "CH0B", "CH0C", "CHIE", "CH0I", "CH0J", "CH0K", "BCLM", "BFCL", "CHWA", "CHLS"]),
        ("LED / adapter", ["ACLC", "AC-W", "ACMg", "PDTR", "PSTR"]),
        ("Pin", ["BUIC", "BRSC", "B0AC", "B0AP", "B0AV", "B0AT", "B0FC", "B0DC", "B0CT"]),
        ("Nhiệt độ", ["TB0T", "TB1T", "TB2T"]),
    ]
    for (title, keys) in groups {
        print("[\(title)]")
        for key in keys {
            guard let r = smc.read(key) else {
                print("  \(key)  (không có)")
                continue
            }
            let value = r.doubleValue.map { String(format: " = %.2f", $0) } ?? ""
            let attr = String(format: "%02x", r.attributes)
            print("  \(key)  type=\(r.type)  attr=\(attr)\(r.isWritable ? " (ghi được)" : "")  bytes=\(r.hex)\(value)")
        }
    }
    let control = ChargingControl(smc: smc)
    print("---")
    print("Key sạc:     \(control.chargingKeys?.rawValue ?? "không hỗ trợ")")
    print("Key adapter: \(control.adapterKeys?.rawValue ?? "không hỗ trợ")")
    print("Sạc đang bật: \(control.isChargingEnabled.map(String.init) ?? "?")")
    print("Adapter đang bật: \(control.isAdapterEnabled.map(String.init) ?? "?")")
    if !Platform.isAppleSilicon {
        if let intel = IntelChargeLimiter(smc: smc) {
            print("Intel BCLM (thử nghiệm): giới hạn hiện tại \(intel.currentLimit.map { "\($0)%" } ?? "?"),"
                  + " pin phần cứng \(intel.hardwarePercent.map { "\($0)%" } ?? "?")")
        } else {
            print("Intel: không tìm thấy BCLM dạng ui8 ghi được, chưa hỗ trợ điều khiển sạc")
        }
    }
} catch {
    print("Không mở được SMC: \(error)")
    exit(1)
}
