import Foundation

/// Sạc đầy theo lịch (thuần, để kiểm thử): bắt đầu "sạc đầy một lần" sớm vừa đủ để pin đầy đúng giờ hẹn,
/// giữ 100% thêm `holdAfter` rồi trở về giới hạn. Rút sạc sau giờ hẹn cũng trả lại giới hạn.
public enum ScheduledCharge {
    /// Giữ pin đầy thêm chừng này sau giờ hẹn (người dùng có thể đi muộn một chút).
    public static let holdAfter: TimeInterval = 2 * 3600

    /// Thời gian bắt đầu sạc trước giờ hẹn, theo mức pin hiện tại. Gồm khoảng dự phòng vì pin Apple sạc chậm dần
    /// trên 80% và pin nóng có thể tạm dừng sạc. Ví dụ 80% → 1 giờ, 50% → 1 giờ 45 phút.
    public static func leadTime(percent: Int) -> TimeInterval {
        let minutes = 30 + Double(100 - min(max(percent, 0), 100)) * 1.5
        return min(max(minutes, 45), 180) * 60
    }

    /// Giờ hẹn kế tiếp sau `date` (không tính đúng `date`), nil nếu lịch không có ngày nào.
    public static func nextReadyTime(after date: Date, schedule: ChargeSchedule, calendar: Calendar = .current) -> Date? {
        let schedule = schedule.sanitized()
        guard !schedule.weekdays.isEmpty else { return nil }
        let today = calendar.startOfDay(for: date)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  schedule.weekdays.contains(calendar.component(.weekday, from: day)),
                  let ready = calendar.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: day),
                  ready > date else { continue }
            return ready
        }
        return nil
    }

    /// Lúc sẽ bắt đầu sạc cho giờ hẹn kế tiếp (để hẹn giờ đánh thức máy và hiển thị), nil nếu tắt lịch.
    public static func nextStart(now: Date, percent: Int, schedule: ChargeSchedule,
                                 calendar: Calendar = .current) -> (start: Date, readyBy: Date)? {
        guard schedule.enabled, let ready = nextReadyTime(after: now, schedule: schedule, calendar: calendar) else { return nil }
        return (ready.addingTimeInterval(-leadTime(percent: percent)), ready)
    }

    /// Bắt đầu sạc đầy theo lịch nếu đã tới lúc. Trả về giờ hẹn nếu vừa bắt đầu (hoặc kéo dài phiên đang có).
    ///
    /// Chỉ chạy khi đang cắm sạc và có giới hạn dưới 100%; không chen vào lúc người dùng đang tạm dừng sạc hoặc xả pin.
    /// Mỗi giờ hẹn chỉ xử lý một lần: người dùng hủy thì không tự bắt đầu lại.
    @discardableResult
    public static func startIfDue(state: inout ControllerState, config rawConfig: PowerConfig, input: ControllerInput,
                                  calendar: Calendar = .current) -> Date? {
        let config = rawConfig.sanitized()
        guard config.fullChargeSchedule.enabled, config.chargeLimitEnabled, config.chargeLimit < 100,
              !config.pauseCharging, !config.dischargeEnabled, input.acPresent, state.calibration == nil,
              input.percent > PowerConstants.criticalPercent,
              let next = nextStart(now: input.now, percent: input.percent, schedule: config.fullChargeSchedule,
                                   calendar: calendar),
              input.now >= next.start, state.scheduledChargeHandled != next.readyBy else { return nil }
        state.scheduledChargeHandled = next.readyBy
        let expiresAt = next.readyBy.addingTimeInterval(holdAfter)
        if var topUp = state.topUp {
            // Đang sạc đầy (người dùng bấm): chỉ kéo dài để pin còn đầy lúc hẹn.
            topUp.expiresAt = max(topUp.expiresAt, expiresAt)
            topUp.scheduledFor = next.readyBy
            state.topUp = topUp
        } else {
            state.topUp = TopUpState(startedAt: input.now, expiresAt: expiresAt, bootSessionUUID: input.bootSessionUUID,
                                     scheduledFor: next.readyBy)
        }
        state.chargeToLimitOnce = false
        state.holdingAtLimit = false
        return next.readyBy
    }
}
