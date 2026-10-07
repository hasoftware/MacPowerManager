import Foundation
import PowerCore

// Công cụ chẩn đoán: in ra các SMC key liên quan tới sạc trên máy hiện tại.
do {
    let smc = try SMC()
    let keys = ["CHTE", "CH0B", "CH0C", "CHIE", "CH0I", "CH0J", "ACLC", "AC-W", "BUIC", "TB0T", "TB1T", "TB2T"]
    for key in keys {
        if let r = smc.read(key) {
            let value = r.doubleValue.map { String(format: " = %.2f", $0) } ?? ""
            print("\(key)  type=\(r.type)  bytes=\(r.hex)\(value)")
        } else {
            print("\(key)  (không có)")
        }
    }
    let control = ChargingControl(smc: smc)
    print("---")
    print("Key sạc:    \(control.chargingKeys?.rawValue ?? "không hỗ trợ")")
    print("Key adapter: \(control.adapterKeys?.rawValue ?? "không hỗ trợ")")
    print("Sạc đang bật: \(control.isChargingEnabled.map(String.init) ?? "?")")
    print("Adapter đang bật: \(control.isAdapterEnabled.map(String.init) ?? "?")")
} catch {
    print("Không mở được SMC: \(error)")
    exit(1)
}
