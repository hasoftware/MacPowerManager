import PowerCore

/// Thao tác dùng chung cho bảng nhanh, Tổng quan và các trang cài đặt.
extension AppModel {
    /// Khoảng giới hạn chọn được: Intel (BCLM) tối thiểu 50%.
    var limitRange: ClosedRange<Int> { isIntel ? 50...100 : 20...100 }

    /// Khoảng giữ pin để vẽ trên thanh giới hạn (không có trên Intel).
    var sailingGapForDisplay: Int? {
        guard !isIntel, helper.config.chargeLimitEnabled else { return nil }
        return helper.config.sailingGap
    }

    var canDischarge: Bool {
        guard let battery else { return false }
        return helper.config.dischargeEnabled || battery.percent > helper.config.dischargeTarget
    }

    /// Trạng thái bật/tắt của một chế độ để tô ô thao tác. Chưa có helper thì không chế độ nào đang thực thi.
    func isOn(_ keyPath: KeyPath<PowerConfig, Bool>) -> Bool {
        canControl && helper.config[keyPath: keyPath]
    }

    /// Sạc đầy một lần cần cắm sạc (hủy thì luôn được).
    var canTopUp: Bool { helper.topUpActive || (battery?.externalConnected == true && !helper.calibrating) }

    func setLimit(_ value: Int) {
        helper.update { $0.chargeLimit = value }
    }

    func toggleLimit() {
        helper.update { $0.chargeLimitEnabled.toggle() }
    }

    func togglePause() {
        helper.update { $0.pauseCharging.toggle() }
    }

    func toggleDischarge() {
        helper.update { $0.dischargeEnabled.toggle() }
    }

    func toggleThermal() {
        helper.update { $0.thermalProtectionEnabled.toggle() }
    }

    func toggleTopUp() {
        Task {
            if helper.topUpActive {
                await helper.cancelTopUp()
            } else {
                await helper.startTopUp(hours: prefs.topUpHours)
            }
        }
    }
}
