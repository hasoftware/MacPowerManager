public enum SMCSensors {
    /// Nhiệt độ pin cao nhất trong các cảm biến TB0T…TB2T (°C). Một số máy Intel thiếu TB0T.
    public static func batteryTemperature(_ smc: SMCAccess) -> Double? {
        ["TB0T", "TB1T", "TB2T"]
            .compactMap { smc.read($0)?.doubleValue }
            .filter { $0 > 0 && $0 < 120 }
            .max()
    }
}

extension SMCSensors {
    /// Key nhiệt độ CPU trên Apple Silicon: `Tp…` (nhân hiệu năng), `Te…` (nhân tiết kiệm điện). Tên cụ thể khác nhau
    /// theo từng chip (M1, M2, M3…), nên tìm theo tiền tố trong danh sách key rồi chỉ giữ key đọc ra nhiệt độ hợp lý.
    public static func cpuTemperatureKeys(_ smc: SMCAccess, allKeys: [String]) -> [String] {
        allKeys.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") }
            .filter { key in smc.read(key)?.doubleValue.map(isPlausibleTemperature) ?? false }
    }

    /// Nhiệt độ CPU (trung bình, cao nhất) từ các key đã tìm.
    public static func cpuTemperature(_ smc: SMCAccess, keys: [String]) -> (average: Double, hottest: Double)? {
        let values = keys.compactMap { smc.read($0)?.doubleValue }.filter(isPlausibleTemperature)
        guard let hottest = values.max() else { return nil }
        return (values.reduce(0, +) / Double(values.count), hottest)
    }

    static func isPlausibleTemperature(_ value: Double) -> Bool { value > 10 && value < 125 }
}
