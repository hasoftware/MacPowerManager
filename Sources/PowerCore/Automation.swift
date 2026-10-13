import Foundation

/// Một thao tác tự động hóa, từ dòng lệnh `mpm …` hoặc URL `macpowermanager://…` (Phím tắt, script).
public enum AutomationAction: Equatable, Sendable {
    case status(json: Bool)
    case version
    case help
    /// Đặt mức giới hạn (và bật giới hạn).
    case setLimit(Int)
    case limitEnabled(Bool)
    case pause(Bool)
    /// Xả về mức này; nil = dừng xả.
    case discharge(Int?)
    case topUp(hours: Int?)
    case cancelTopUp
    case chargeToLimitNow
    case calibration(start: Bool)
    case magSafe(MagSafeLEDMode)
    /// Chỉ từ URL: mở bảng điều khiển.
    case open

    /// Cấu hình mới nếu đây là thao tác đổi cấu hình, nil nếu không.
    public func applied(to config: PowerConfig) -> PowerConfig? {
        var c = config
        switch self {
        case .setLimit(let value):
            c.chargeLimitEnabled = true
            c.chargeLimit = value
        case .limitEnabled(let on): c.chargeLimitEnabled = on
        case .pause(let on): c.pauseCharging = on
        case .discharge(let target?):
            c.dischargeEnabled = true
            c.dischargeTarget = target
        case .discharge(nil): c.dischargeEnabled = false
        case .magSafe(let mode): c.magSafeLED = mode
        default: return nil
        }
        return c.sanitized()
    }

    /// Lệnh gửi helper nếu đây là thao tác dạng lệnh.
    public var helperCommand: HelperCommand? {
        switch self {
        case .topUp(let hours): .startTopUp(hours: hours)
        case .cancelTopUp: .cancelTopUp
        case .chargeToLimitNow: .chargeToLimitNow
        case .calibration(let start): start ? .startCalibration : .cancelCalibration
        default: nil
        }
    }

    /// Thao tác được phép từ URL. URL có thể được mở từ trang web (trình duyệt hỏi trước), nên không cho các thao tác
    /// ngắt bộ sạc hoặc kéo dài nhiều giờ (xả pin, hiệu chuẩn); dùng `mpm` cho các thao tác đó.
    public var allowedFromURL: Bool {
        switch self {
        case .discharge(.some), .calibration(start: true): false
        default: true
        }
    }
}

public enum Automation {
    public static let urlScheme = "macpowermanager"

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// `mpm limit 80`, `mpm pause on`, `mpm topup 4`… (không gồm tên lệnh `mpm`).
    public static func parse(_ arguments: [String]) -> Result<AutomationAction, ParseError> {
        let args = arguments.map { $0.lowercased() }
        guard let verb = args.first else { return .success(.help) }
        let rest = Array(args.dropFirst())
        let value = rest.first
        func fail(_ message: String) -> Result<AutomationAction, ParseError> { .failure(ParseError(description: message)) }
        func percent(_ text: String?, in range: ClosedRange<Int>) -> Int? {
            guard let text, let n = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "%"))), range.contains(n) else {
                return nil
            }
            return n
        }
        func onOff(_ text: String?) -> Bool? {
            switch text {
            case "on", "true", "1", "yes": true
            case "off", "false", "0", "no": false
            default: nil
            }
        }

        switch verb {
        case "status":
            return .success(.status(json: rest.contains("--json") || rest.contains("json")))
        case "version", "--version", "-v":
            return .success(.version)
        case "help", "--help", "-h":
            return .success(.help)
        case "open":
            return .success(.open)
        case "limit":
            if let on = onOff(value) { return .success(.limitEnabled(on)) }
            if let n = percent(value, in: ChargeController.limitRange) { return .success(.setLimit(n)) }
            return fail("limit: expected 20–100, on or off")
        case "pause":
            return .success(.pause(onOff(value) ?? true))
        case "resume":
            return .success(.pause(false))
        case "discharge":
            if value == "stop" || value == "off" { return .success(.discharge(nil)) }
            if let n = percent(value, in: (PowerConstants.criticalPercent + 5)...95) { return .success(.discharge(n)) }
            return fail("discharge: expected a target 15–95 or stop")
        case "topup", "top-up", "full":
            if value == "cancel" || value == "off" { return .success(.cancelTopUp) }
            guard let value else { return .success(.topUp(hours: nil)) }
            guard let hours = Int(value), ControllerCommands.topUpHoursRange.contains(hours) else {
                return fail("topup: expected hours 1–72 or cancel")
            }
            return .success(.topUp(hours: hours))
        case "charge-to-limit", "chargetolimit":
            return .success(.chargeToLimitNow)
        case "calibrate", "calibration":
            switch value {
            case nil, "start": return .success(.calibration(start: true))
            case "cancel", "stop": return .success(.calibration(start: false))
            default: return fail("calibrate: expected start or cancel")
            }
        case "magsafe", "led":
            guard let value, let mode = MagSafeLEDMode(rawValue: value) else {
                return fail("magsafe: expected system, status or off")
            }
            return .success(.magSafe(mode))
        default:
            return fail("unknown command \"\(verb)\" (try: mpm help)")
        }
    }

    /// `macpowermanager://limit/80`, `macpowermanager://pause/on`, `macpowermanager://topup`…
    /// Không có thao tác (`macpowermanager://`) thì mở bảng điều khiển.
    public static func parse(url: URL) -> Result<AutomationAction, ParseError> {
        guard url.scheme?.lowercased() == urlScheme else { return .failure(ParseError(description: "not a \(urlScheme) URL")) }
        let parts = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
            .compactMap { $0.removingPercentEncoding }
        guard !parts.isEmpty else { return .success(.open) }
        let result = parse(parts)
        if case .success(let action) = result, !action.allowedFromURL {
            return .failure(ParseError(description: "\(parts[0]) is not allowed from a URL; use mpm"))
        }
        return result
    }

    public static let usage = """
    Usage: mpm <command>

      status [--json]          Battery and charging state
      limit <20-100|on|off>    Set or toggle the charge limit
      pause [on|off]           Pause charging (run on the adapter); "resume" = pause off
      discharge <15-95|stop>   Discharge to a target while plugged in (Apple Silicon)
      topup [hours|cancel]     Charge to 100% once (default 24 h)
      charge-to-limit          Skip the sailing range once and charge to the limit
      calibrate [start|cancel] Battery calibration (full → 15% → full)
      magsafe <system|status|off>  MagSafe light
      version

    Shortcuts: use "Run Shell Script" with mpm, or "Open URLs" with macpowermanager://limit/80,
    macpowermanager://pause/on, macpowermanager://topup … (discharge and calibrate are CLI only).
    """
}
