import PowerCore
import SwiftUI

struct LimitPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let helper = model.helper
        let config = helper.config
        let status = helper.status
        SettingsPage {
            ControlUnavailableSection()

            if model.isIntel {
                Section {
                    LabeledContent("Giới hạn trong firmware (BCLM)",
                                   value: status?.firmwareLimit.map { "\($0)%" } ?? "—")
                } header: {
                    Text("Máy Intel (thử nghiệm)")
                } footer: {
                    Footnote("Firmware giữ giới hạn cả khi máy ngủ hoặc tắt; pin có thể vượt khoảng 3% vì firmware dùng phần trăm phần cứng. Giới hạn tối thiểu 50%. Xả pin chưa hỗ trợ trên Intel. Nên tắt \"Optimized Battery Charging\" trong System Settings → Battery.")
                }
            }

            Group {
                Section {
                    Toggle("Bật giới hạn sạc", isOn: helper.binding(\.chargeLimitEnabled))
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        LimitBar(limit: config.chargeLimit, percent: model.battery?.percent,
                                 sailingGap: model.sailingGapForDisplay, range: model.limitRange,
                                 fillTint: model.summary.state.tint, style: .large, onCommit: model.setLimit)
                        HStack {
                            Text("Chọn nhanh").foregroundStyle(.secondary)
                            Spacer()
                            LimitPresets(values: [60, 70, 80, 90, 100], current: config.chargeLimit,
                                         onSelect: model.setLimit)
                        }
                    }
                    .padding(.vertical, 4)
                    .disabled(!config.chargeLimitEnabled)
                } header: {
                    Text("Giới hạn sạc")
                } footer: {
                    Footnote("Giữ pin ở khoảng 20–80% giúp giảm chai pin lithium-ion. Khi đạt giới hạn, máy dùng điện trực tiếp từ bộ sạc. Kéo vạch hoặc dùng phím mũi tên để chỉnh.")
                }

                if !model.isIntel {
                    Section {
                        Stepper(value: helper.binding(\.sailingGap), in: 1...20) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Khoảng sạc lại: \(config.sailingGap)%")
                                Text("Sạc lại khi pin xuống dưới \(max(config.chargeLimit - config.sailingGap, PowerConstants.sailingFloorPercent))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        LabeledContent {
                            Button("Sạc tới giới hạn ngay") { Task { await helper.chargeToLimitNow() } }
                                .disabled(helper.isSending || chargeNowBlocker(config: config, status: status) != nil)
                                .help(chargeNowBlocker(config: config, status: status)
                                      ?? "Sạc tới giới hạn ngay, không chờ pin xuống dưới khoảng sạc lại. Tự tắt khi đạt giới hạn.")
                        } label: {
                            Text("Bỏ qua khoảng sạc lại một lần")
                            if status?.chargeToLimitOnce == true {
                                Text("Đang sạc tới \(config.chargeLimit)%…")
                            } else if status?.topUp != nil {
                                Text("Không dùng được khi đang sạc đầy một lần.")
                            }
                        }
                    } header: {
                        Text("Khoảng sạc lại")
                    } footer: {
                        Footnote("Sau khi đạt giới hạn, máy chỉ sạc lại khi pin giảm quá khoảng này để tránh bật/tắt sạc liên tục. Dưới \(PowerConstants.sailingFloorPercent)% luôn được sạc.")
                    }
                    .disabled(!config.chargeLimitEnabled)
                }

                Section {
                    if let topUp = status?.topUp {
                        LabeledContent {
                            Button("Hủy") { Task { await helper.cancelTopUp() } }
                                .disabled(helper.isSending)
                        } label: {
                            if let ready = topUp.scheduledFor {
                                Label("Đang sạc đầy theo lịch", systemImage: "calendar.badge.clock")
                                Text("Đầy lúc \(Format.time(ready)); giữ 100% tới \(Format.time(topUp.expiresAt)) hoặc tới khi rút sạc sau giờ hẹn.")
                            } else {
                                Label("Đang sạc đầy một lần", systemImage: "arrow.up.to.line")
                                Text("Tự kết thúc lúc \(Format.dateTime(topUp.expiresAt)), hoặc khi rút sạc.")
                            }
                        }
                    } else {
                        Picker("Tự kết thúc sau", selection: $model.prefs.topUpHours) {
                            ForEach([4, 8, 12, 24, 48], id: \.self) { Text("\($0) giờ").tag($0) }
                        }
                        LabeledContent {
                            Button("Sạc đầy một lần") { Task { await helper.startTopUp(hours: model.prefs.topUpHours) } }
                                .disabled(helper.isSending || model.battery?.externalConnected != true)
                        } label: {
                            Text("Tạm bỏ giới hạn, sạc tới 100%")
                            if model.battery?.externalConnected != true {
                                Text("Cần cắm sạc.")
                            }
                        }
                    }
                } header: {
                    Text("Sạc đầy một lần")
                } footer: {
                    Footnote("Dùng khi cần pin đầy (ví dụ trước chuyến đi). Giới hạn được áp dụng lại khi rút sạc, khi hết hạn hoặc khi khởi động lại máy.")
                }

                ScheduleSection(config: config, percent: model.battery?.percent)
                    .disabled(!config.chargeLimitEnabled || config.chargeLimit >= 100)

                Section {
                    Toggle("Tạm dừng sạc", isOn: helper.binding(\.pauseCharging))
                } header: {
                    Text("Chỉ dùng bộ sạc")
                } footer: {
                    Footnote(model.isIntel
                             ? "Firmware giữ pin ở mức hiện tại. Trên Intel không dừng sạc được dưới 50%: pin sẽ sạc tới 50% rồi mới dừng."
                             : "Pin giữ nguyên mức hiện tại, máy chạy hoàn toàn bằng bộ sạc.")
                }

                Section {
                    LabeledContent("Phương thức", value: status?.methodText ?? "—")
                    LabeledContent("Giới hạn đang áp dụng") {
                        Text(status?.effectiveLimit.map { "\($0)%" } ?? (config.chargeLimitEnabled ? "\(config.chargeLimit)%" : "100%"))
                            .monospacedDigit()
                    }
                    LabeledContent("Xác minh") { EffectLabel(effect: status?.effect) }
                } header: {
                    Text("Phương thức và xác minh")
                } footer: {
                    Footnote("Sau khi chặn sạc, helper kiểm tra dòng điện vào pin. Nếu sau \(Int(PowerConstants.effectVerifySeconds)) giây pin vẫn nhận dòng sạc, app sẽ cảnh báo vì có thể macOS hoặc ứng dụng khác đang can thiệp.")
                }
            }
            .disabled(!model.canControl)

            HelperErrorSection()
        }
    }

    /// Lý do không dùng được "Sạc tới giới hạn ngay" (hiện ở chú thích của nút), nil nếu dùng được.
    /// Helper cũng từ chối các trường hợp này, nhưng thông báo lỗi chung chung không giúp người dùng hiểu vì sao.
    private func chargeNowBlocker(config: PowerConfig, status: HelperStatus?) -> LocalizedStringKey? {
        if status?.chargeToLimitOnce == true { return "Đang sạc tới giới hạn." }
        if status?.topUp != nil { return "Không dùng được khi đang sạc đầy một lần." }
        if !config.chargeLimitEnabled || config.chargeLimit >= 100 { return "Cần bật giới hạn sạc dưới 100%." }
        if model.battery?.externalConnected != true { return "Cần cắm sạc." }
        return nil
    }
}

/// Sạc đầy theo lịch: các thứ trong tuần và giờ pin cần đầy.
private struct ScheduleSection: View {
    @Environment(AppModel.self) private var model
    let config: PowerConfig
    let percent: Int?

    private var schedule: ChargeSchedule { config.fullChargeSchedule }

    var body: some View {
        let helper = model.helper
        Section {
            Toggle("Sạc đầy theo lịch", isOn: helper.binding(\.fullChargeSchedule.enabled))
            if schedule.enabled {
                LabeledContent("Ngày") {
                    WeekdayPicker(selection: schedule.weekdays) { days in
                        helper.update { $0.fullChargeSchedule.weekdays = days }
                    }
                }
                DatePicker("Pin đầy lúc", selection: timeBinding, displayedComponents: .hourAndMinute)
                LabeledContent("Lần tới") {
                    if let next = ScheduledCharge.nextStart(now: Date(), percent: percent ?? 80, schedule: schedule) {
                        Text("\(Self.dayText(next.readyBy)) \(Format.time(next.readyBy)) · bắt đầu sạc khoảng \(Format.time(next.start))")
                            .monospacedDigit()
                    } else {
                        Text("Chưa chọn ngày nào").foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Sạc đầy theo lịch")
        } footer: {
            Footnote("Pin được sạc tới 100% đúng giờ hẹn (ví dụ trước khi đi làm), giữ đầy thêm 2 giờ rồi trở về giới hạn. Rút sạc sau giờ hẹn cũng trả lại giới hạn. Máy cần cắm sạc; nếu máy đang ngủ, helper hẹn giờ đánh thức máy để bắt đầu sạc.")
        }
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.helper.update {
                    $0.fullChargeSchedule.hour = parts.hour ?? 8
                    $0.fullChargeSchedule.minute = parts.minute ?? 0
                }
            }
        )
    }

    /// "Hôm nay", "Ngày mai" hoặc tên thứ.
    static func dayText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Hôm nay") }
        if calendar.isDateInTomorrow(date) { return String(localized: "Ngày mai") }
        return date.formatted(.dateTime.weekday(.wide).locale(Format.locale))
    }
}

/// Bảy nút chọn thứ trong tuần, theo thứ tự và tên ngắn của ngôn ngữ đang dùng.
private struct WeekdayPicker: View {
    let selection: Set<Int>
    let onChange: (Set<Int>) -> Void

    var body: some View {
        var calendar = Calendar.current
        calendar.locale = Format.locale
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        return HStack(spacing: 4) {
            ForEach(order, id: \.self) { day in
                let on = selection.contains(day)
                Button {
                    onChange(on ? selection.subtracting([day]) : selection.union([day]))
                } label: {
                    Text(verbatim: symbols[day - 1])
                        .font(.caption.weight(.semibold))
                        .frame(width: 26, height: 22)
                        .background(on ? Color.accentColor : Theme.track, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
