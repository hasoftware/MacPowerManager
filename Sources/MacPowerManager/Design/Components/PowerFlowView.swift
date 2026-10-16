import PowerCore
import SwiftUI

/// Sơ đồ dòng điện năng: Bộ sạc → Hệ thống / Pin, hoặc Pin → Hệ thống khi dùng pin.
/// Độ dày đường theo công suất, đường có dòng điện là nét đứt màu. Không có hiệu ứng chạy: mỗi khung hình hiệu ứng phải
/// tính và vẽ lại cả sơ đồ, tốn khoảng 10% CPU khi trang Tổng quan đang mở (đo bằng `--bench overview`).
struct PowerFlowView: View {
    struct Flow: Equatable {
        /// Công suất bộ sạc cấp vào (W), nil khi không cắm.
        var adapterIn: Double?
        var adapterRated: Int?
        var system: Double?
        /// Dương = đang nạp vào pin, âm = pin đang cấp cho máy.
        var battery: Double
        var percent: Int
        var pluggedIn: Bool
        /// Helper đang ngắt bộ sạc để xả pin.
        var adapterCut: Bool
        var batteryTint: Color = .green
    }

    let flow: Flow

    var body: some View {
        GeometryReader { geo in
            diagram(size: geo.size, phase: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var adapterActive: Bool { flow.pluggedIn && !flow.adapterCut }
    private var toBattery: Double { adapterActive ? max(flow.battery, 0) : 0 }
    private var fromBattery: Double { max(-flow.battery, 0) }
    private var toSystem: Double {
        guard adapterActive else { return 0 }
        return flow.system ?? max((flow.adapterIn ?? 0) - toBattery, 0)
    }

    private func thickness(_ watts: Double) -> CGFloat {
        watts < 0.3 ? 1.5 : 2 + CGFloat(min(watts / 90, 1)) * 8
    }

    @ViewBuilder
    private func diagram(size: CGSize, phase: Double) -> some View {
        let nodeSize: CGFloat = 44
        let left = CGPoint(x: nodeSize / 2 + 2, y: size.height / 2 - 12)
        let rightX = max(size.width * 0.52, 150)
        let system = CGPoint(x: rightX, y: nodeSize / 2 + 2)
        let battery = CGPoint(x: rightX, y: size.height - nodeSize / 2 - 2)
        let labelWidth = max(size.width - rightX - nodeSize / 2 - 10, 60)

        ZStack {
            link(from: left, to: system, watts: toSystem, tint: .green, phase: phase, offset: nodeSize / 2)
            link(from: left, to: battery, watts: toBattery, tint: .green, phase: phase, offset: nodeSize / 2)
            verticalLink(from: battery, to: system, watts: fromBattery, phase: phase, offset: nodeSize / 2)

            circle(symbol: flow.adapterCut ? "powerplug" : "powerplug.fill", tint: .green,
                   dimmed: !adapterActive, size: nodeSize)
                .position(left)
            labels(title: "Bộ sạc", value: adapterValue, caption: adapterCaption, dimmed: !adapterActive,
                   alignment: .leading)
                .frame(width: 140, alignment: .leading)
                .position(x: 70, y: left.y + nodeSize / 2 + 26)

            circle(symbol: "laptopcomputer", tint: .blue, dimmed: false, size: nodeSize)
                .position(system)
            labels(title: "Hệ thống", value: Format.watts(flow.system ?? (adapterActive ? toSystem : fromBattery)),
                   caption: nil, dimmed: false, alignment: .leading)
                .frame(width: labelWidth, alignment: .leading)
                .position(x: rightX + nodeSize / 2 + 10 + labelWidth / 2, y: system.y)

            circle(symbol: batterySymbol, tint: flow.batteryTint, dimmed: false, size: nodeSize)
                .position(battery)
            labels(title: "Pin", value: Format.watts(flow.battery, signed: true),
                   caption: batteryCaption, dimmed: false, alignment: .leading)
                .frame(width: labelWidth, alignment: .leading)
                .position(x: rightX + nodeSize / 2 + 10 + labelWidth / 2, y: battery.y)
        }
    }

    private var batteryCaption: String {
        if flow.battery >= 0.3 { return String(localized: "\(flow.percent)% · đang nạp") }
        if flow.battery <= -0.3 { return String(localized: "\(flow.percent)% · đang cấp điện") }
        return String(localized: "\(flow.percent)% · không sạc")
    }

    private var adapterValue: String {
        if flow.adapterCut { return String(localized: "Đã ngắt") }
        guard flow.pluggedIn else { return String(localized: "Chưa cắm") }
        return Format.watts(flow.adapterIn)
    }

    private var adapterCaption: String? {
        guard flow.pluggedIn || flow.adapterCut, let rated = flow.adapterRated else { return nil }
        return String(localized: "Tối đa \(rated) W")
    }

    private var batterySymbol: String {
        switch flow.percent {
        case 88...: "battery.100percent"
        case 63...: "battery.75percent"
        case 38...: "battery.50percent"
        case 13...: "battery.25percent"
        default: "battery.0percent"
        }
    }

    private func link(from a: CGPoint, to b: CGPoint, watts: Double, tint: Color, phase: Double, offset: CGFloat) -> some View {
        let start = CGPoint(x: a.x + offset, y: a.y)
        let end = CGPoint(x: b.x - offset, y: b.y)
        let path = Path { p in
            p.move(to: start)
            let mid = (start.x + end.x) / 2
            p.addCurve(to: end, control1: CGPoint(x: mid, y: start.y), control2: CGPoint(x: mid, y: end.y))
        }
        return flowStroke(path, watts: watts, tint: tint, phase: phase)
    }

    private func verticalLink(from a: CGPoint, to b: CGPoint, watts: Double, phase: Double, offset: CGFloat) -> some View {
        let path = Path { p in
            p.move(to: CGPoint(x: a.x, y: a.y - offset))
            p.addLine(to: CGPoint(x: b.x, y: b.y + offset + 4))
        }
        return flowStroke(path, watts: watts, tint: .orange, phase: phase)
    }

    private func flowStroke(_ path: Path, watts: Double, tint: Color, phase: Double) -> some View {
        let active = watts >= 0.3
        let width = thickness(watts)
        return ZStack {
            path.stroke(active ? tint.opacity(0.22) : Theme.track,
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
            if active {
                path.stroke(tint, style: StrokeStyle(lineWidth: max(1.5, width * 0.45), lineCap: .round,
                                                     dash: [5, 7], dashPhase: phase))
            }
        }
    }

    private func circle(symbol: String, tint: Color, dimmed: Bool, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(Theme.card)
            Circle().fill(tint.opacity(dimmed ? 0.05 : 0.14))
            Circle().strokeBorder(tint.opacity(dimmed ? 0.15 : 0.4), lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
        }
        .frame(width: size, height: size)
    }

    private func labels(title: LocalizedStringKey, value: String, caption: String?, dimmed: Bool,
                        alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(dimmed ? .secondary : .primary)
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}
