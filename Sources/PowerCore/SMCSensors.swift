public enum SMCSensors {
    /// Nhiệt độ pin cao nhất trong các cảm biến TB0T…TB2T (°C). Một số máy Intel thiếu TB0T.
    public static func batteryTemperature(_ smc: SMCAccess) -> Double? {
        ["TB0T", "TB1T", "TB2T"]
            .compactMap { smc.read($0)?.doubleValue }
            .filter { $0 > 0 && $0 < 120 }
            .max()
    }
}
