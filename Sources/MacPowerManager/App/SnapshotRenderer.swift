#if DEBUG
import AppKit
import PowerCore
import SwiftUI

/// `--render-snapshots <thư mục>`: vẽ các màn hình chính với dữ liệu giả ra PNG (sáng và tối) để kiểm tra bố cục,
/// rồi thoát. Không đọc phần cứng, không gọi helper, không hiện cửa sổ nào.
@MainActor
enum SnapshotRenderer {
    enum Backend {
        /// `ImageRenderer`: chỉ vẽ được view SwiftUI thuần (không có vật liệu, điều khiển AppKit hiện ô giữ chỗ).
        case imageRenderer
        /// `NSHostingView` trong cửa sổ ngoài màn hình: vẽ được cả Form, Toggle, Slider…
        case hosting
    }

    static func run(directory: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scenes = Scenario.all
        let filter = ProcessInfo.processInfo.environment["MPM_SNAPSHOT_FILTER"]
        let minimumScale = ProcessInfo.processInfo.environment["MPM_SNAPSHOT_SCALE"].flatMap(Double.init).map { CGFloat($0) } ?? 1
        for scene in scenes where filter.map({ scene.name.contains($0) }) ?? true {
            for dark in [false, true] {
                let view = AnyView(scene.view()
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.locale, Format.locale))
                // MPM_SNAPSHOT_SCALE=2: ảnh Retina cho README.
                let scale = max(scene.scale, minimumScale)
                let image: CGImage? = switch scene.backend {
                case .imageRenderer: renderWithImageRenderer(view, size: scene.size, scale: scale, dark: dark)
                case .hosting: renderWithHostingView(view, size: scene.size, scale: scale, dark: dark)
                }
                let url = directory.appendingPathComponent("\(scene.name)-\(dark ? "dark" : "light").png")
                if let image, write(image, to: url) {
                    print(url.path)
                } else {
                    print("LỖI: không vẽ được \(url.lastPathComponent)")
                }
            }
        }
    }

    private static func renderWithImageRenderer(_ view: AnyView, size: CGSize, scale: CGFloat, dark: Bool) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        var image: CGImage?
        appearance(dark).performAsCurrentDrawingAppearance { image = renderer.cgImage }
        return image
    }

    private static func renderWithHostingView(_ view: AnyView, size: CGSize, scale: CGFloat, dark: Bool) -> CGImage? {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance(dark)
        window.contentView = host
        // Cho SwiftUI vài vòng cập nhật (onAppear, GeometryReader, biểu đồ).
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        window.close()
        return rep.cgImage
    }

    private static func appearance(_ dark: Bool) -> NSAppearance {
        NSAppearance(named: dark ? .darkAqua : .aqua)!
    }

    private static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}

// MARK: - Kịch bản

private struct Scenario {
    var name: String
    var size: CGSize
    var backend: SnapshotRenderer.Backend = .hosting
    var scale: CGFloat = 1
    var view: @MainActor () -> AnyView

    @MainActor static var all: [Scenario] {
        var list: [Scenario] = []

        func popover(_ name: String, _ model: AppModel, backend: SnapshotRenderer.Backend = .hosting) {
            list.append(Scenario(name: "popover-\(name)", size: CGSize(width: PopoverView.width, height: 560),
                                 backend: backend, scale: 2) {
                AnyView(PopoverView()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(PopoverBackdrop())
                    .environment(model))
            })
        }

        func page(_ name: String, _ page: Page, _ model: AppModel, size: CGSize = CGSize(width: 860, height: 1000)) {
            list.append(Scenario(name: "page-\(name)", size: size) {
                AnyView(PageView(page: page).environment(model))
            })
        }

        popover("holding", Mock.model(.holding))
        popover("charging-conflict", Mock.model(.chargingConflict))
        popover("nohelper", Mock.model(.noHelper))
        popover("discharging", Mock.model(.discharging))
        popover("topup-heat", Mock.model(.topUpHeat))
        popover("update", Mock.model(.holding, update: .available(Mock.release)))

        list.append(Scenario(name: "window", size: CGSize(width: 1080, height: 720)) {
            AnyView(RootView().environment(Mock.model(.holding)))
        })
        page("overview", .overview, Mock.model(.holding), size: CGSize(width: 860, height: 1060))
        page("overview-narrow", .overview, Mock.model(.chargingConflict), size: CGSize(width: 680, height: 1500))
        page("overview-nohelper", .overview, Mock.model(.noHelper), size: CGSize(width: 1100, height: 1000))
        page("limit", .limit, Mock.model(.holding), size: CGSize(width: 760, height: 1100))
        page("limit-topup", .limit, Mock.model(.topUpHeat), size: CGSize(width: 760, height: 1100))
        page("heat", .heat, Mock.model(.topUpHeat), size: CGSize(width: 760, height: 820))
        page("discharge", .discharge, Mock.model(.discharging), size: CGSize(width: 760, height: 720))
        page("sleep", .sleep, Mock.model(.holding), size: CGSize(width: 760, height: 640))
        page("menubar", .menuBar, Mock.model(.holding), size: CGSize(width: 760, height: 980))
        page("notifications", .notifications, Mock.model(.holding), size: CGSize(width: 760, height: 900))
        page("system", .system, Mock.model(.chargingConflict), size: CGSize(width: 760, height: 1500))
        page("system-outdated", .system, Mock.model(.noHelper), size: CGSize(width: 760, height: 1100))
        page("about", .about, Mock.model(.holding, update: .upToDate), size: CGSize(width: 760, height: 1180))
        page("about-update", .about, Mock.model(.holding, update: .available(Mock.release)),
             size: CGSize(width: 760, height: 1000))
        page("about-failed", .about, Mock.model(.holding, update: .failed(UpdateChecker.message(for: URLError(.notConnectedToInternet)))),
             size: CGSize(width: 760, height: 520))
        page("overview-update", .overview, Mock.model(.holding, update: .available(Mock.release)),
             size: CGSize(width: 860, height: 1060))
        list.append(Scenario(name: "whatsnew", size: WhatsNewView.size) {
            AnyView(WhatsNewView().environment(Mock.model(.holding, update: .available(Mock.release))))
        })
        list.append(Scenario(name: "whatsnew-none", size: WhatsNewView.size) {
            AnyView(WhatsNewView().environment(Mock.model(.holding, update: .upToDate)))
        })
        page("history", .history, Mock.model(.holding), size: CGSize(width: 860, height: 1180))
        for range in [HistoryPage.Range.hours6, .day, .week, .month] {
            let model = Mock.model(.holding, historyHours: 30 * 24)
            list.append(Scenario(name: "page-history-\(range.rawValue)", size: CGSize(width: 860, height: 1180)) {
                AnyView(HistoryPage(fixedRange: range).environment(model))
            })
        }
        page("health", .health, Mock.model(.holding), size: CGSize(width: 860, height: 900))

        list.append(Scenario(name: "glyphs", size: CGSize(width: 600, height: 1180), backend: .imageRenderer, scale: 2) {
            AnyView(GlyphSheet())
        })
        return list
    }
}

/// Nền thay cho vật liệu menu (ImageRenderer và cửa sổ ngoài màn hình không vẽ vật liệu).
private struct PopoverBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(scheme == .dark ? Color(white: 0.17) : Color(white: 0.95))
    }
}

/// Bảng mọi biến thể biểu tượng thanh menu, phóng to 4 lần.
private struct GlyphSheet: View {
    private let states: [(PowerState, Int)] = [
        (.charging, 48), (.topUp, 91), (.full, 100), (.holding, 80), (.sailing, 77), (.paused, 64),
        (.discharging, 72), (.dischargeSuspended, 70), (.heat, 58), (.critical, 8), (.low, 15), (.onBattery, 54),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            column(dark: false)
            column(dark: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func column(dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(states, id: \.0) { state, percent in
                HStack(spacing: 14) {
                    Text(state.legendTitle)
                        .font(.caption)
                        .frame(width: 140, alignment: .leading)
                    glyph(MenuBarContent(percent: percent, limit: 80, state: state, style: .inside), dark: dark)
                    glyph(MenuBarContent(percent: percent, limit: 80, state: state, style: .inside, colored: true), dark: dark)
                    glyph(MenuBarContent(percent: percent, limit: 80, state: state, style: .glyph), dark: dark)
                    glyph(MenuBarContent(percent: percent, limit: 80, state: state, style: .symbol), dark: dark)
                }
            }
            HStack(spacing: 18) {
                Text(verbatim: "text / no %").font(.caption).frame(width: 140, alignment: .leading)
                glyph(MenuBarContent(percent: 80, limit: 80, state: .holding, style: .text), dark: dark)
                glyph(MenuBarContent(percent: 80, limit: nil, state: .onBattery, showPercent: false), dark: dark)
            }
        }
        .foregroundStyle(dark ? .white : .black)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dark ? Color(white: 0.12) : Color(white: 0.92))
    }

    private func glyph(_ content: MenuBarContent, dark: Bool) -> some View {
        let image = MenuBarRenderer.previewImage(for: content, dark: dark, scale: 4)
        return Image(nsImage: image)
            .resizable()
            .interpolation(.none)
            .frame(width: image.size.width * 2, height: image.size.height * 2)
    }
}

// MARK: - Dữ liệu giả

@MainActor
private enum Mock {
    enum Kind { case holding, chargingConflict, noHelper, discharging, topUpHeat }

    /// Bản phát hành giả theo đúng định dạng của GitHub Release: ghi chú từ CHANGELOG, rồi phần chân từ dòng `---`.
    static let release = ReleaseInfo(
        tagName: "v0.3.0", name: "MacPowerManager v0.3.0",
        body: /* l10n-ignore: ghi chú phát hành luôn là tiếng Việt */ """

        ### Tính năng
        - **Giao diện mới**: cửa sổ có thanh bên (Tổng quan, Lịch sử, Tình trạng pin, Giới hạn sạc…) và bảng nhanh
          trên thanh menu với biểu tượng pin có vạch giới hạn.
        - **Sạc đầy một lần** và **Sạc tới giới hạn ngay**.
        - Kiểm tra hiệu lực: helper đo dòng vào pin sau khi chặn sạc và cảnh báo nếu pin vẫn nhận sạc.
        - Giao diện tiếng Việt và tiếng Anh.

        ### Sửa lỗi
        - Dừng xả pin khi không ngắt được adapter thay vì chặn sạc tới 6 giờ.
        - Thông báo "ứng dụng khác ghi vào SMC" chỉ báo một lần cho mỗi sự việc.

        ### An toàn
        - Pin ≤ 10% luôn được sạc; helper chỉ nhận lệnh từ đúng bản app đã cài nó (`cdhash`).

        ---

        ### Cài đặt
        1. Tải **MacPowerManager-x.y.z.dmg** ở phần *Assets* bên dưới.
        """,
        pageURL: URL(string: "https://github.com/hasoftware/MacPowerManager/releases/tag/v0.3.0")!,
        publishedAt: Date(timeIntervalSince1970: 1_791_000_000),
        assets: [
            .init(name: "MacPowerManager-0.3.0.dmg",
                  downloadURL: URL(string: "https://github.com/hasoftware/MacPowerManager/releases/download/v0.3.0/MacPowerManager-0.3.0.dmg")!,
                  size: 1_012_345),
            .init(name: "SHA256SUMS.txt",
                  downloadURL: URL(string: "https://github.com/hasoftware/MacPowerManager/releases/download/v0.3.0/SHA256SUMS.txt")!,
                  size: 184),
        ])

    /// Khoảng 14 tháng nhật ký sức khỏe: macOS hạ "Maximum Capacity" từng bậc 1% vài tuần một lần.
    static func healthLog() -> [HealthPoint] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return stride(from: 420, through: 0, by: -3).map { daysAgo in
            let progress = Double(420 - daysAgo) / 420
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
            return HealthPoint(day: day, maximumCapacityPercent: 96 - Int(progress * 5.4),
                               estimatedPercent: 95.5 - progress * 5.2 + sin(Double(daysAgo)) * 0.6,
                               cycleCount: 40 + Int(progress * 52), nominalCapacity: 7822, designCapacity: 8694)
        }
    }

    static func model(_ kind: Kind, update: UpdateChecker.State = .idle, historyHours: Double = 26) -> AppModel {
        var b = BatteryInfo()
        b.designCapacity = 8694
        b.maxCapacity = 7822
        b.cycleCount = 92
        b.designCycleCount = 1000
        b.voltage = 12_950
        b.serial = "F8Y0000000000000X"
        b.adapterName = "140W USB-C Power Adapter"
        b.temperature = 31.6

        var config = PowerConfig()
        config.chargeLimit = 80
        config.sailingGap = 5
        config.fullChargeSchedule = ChargeSchedule(enabled: true, weekdays: [2, 3, 4, 5, 6], hour: 8, minute: 0)
        var status = HelperStatus(version: AppVersion.current, config: config, chargingKeys: "CHTE", adapterKeys: "CHIE",
                                  chargingEnabled: false, adapterEnabled: true, reason: .limitReached,
                                  temperature: 33.4, lastError: nil)
        status.capabilities = Capabilities(chargeMethod: "CHTE", adapterMethod: "CHIE", keys: [
            KeyCapability(name: "CHTE", present: true, writable: true),
            KeyCapability(name: "CH0B", present: false, writable: false),
            KeyCapability(name: "CH0C", present: true, writable: true, locked: true),
            KeyCapability(name: "CHIE", present: true, writable: true),
            KeyCapability(name: "CH0I", present: false, writable: false),
            KeyCapability(name: "CH0J", present: true, writable: true),
        ])
        status.effect = .verified
        status.effectiveLimit = 80
        status.lidClosed = false
        status.firmware = "iBoot-11881.121.1"
        var install = HelperClient.InstallState.installed
        var conflicts: [ConflictFinding] = [
            ConflictFinding(product: .aldente, installedPaths: ["/Applications/AlDente.app",
                                                                "/Library/PrivilegedHelperTools/com.apphousekitchen.aldente-pro.helper"],
                            running: false, chargeLimit: 95),
        ]
        var temperature = 33.4
        var prefs = Preferences()
        prefs.menuBarStyle = .glyph

        switch kind {
        case .holding:
            b.percent = 80
            b.externalConnected = true
            b.amperage = 0
            b.adapterWatts = 140
            b.systemPowerIn = 14.2
            b.systemLoad = 13.8
        case .chargingConflict:
            b.percent = 64
            b.externalConnected = true
            b.isCharging = true
            b.amperage = 3100
            b.adapterWatts = 96
            b.systemPowerIn = 62.4
            b.systemLoad = 21.3
            b.timeRemaining = 48
            status.reason = .normal
            status.chargingEnabled = true
            status.effect = .notApplicable
            status.foreignWrites = [ForeignWrite(key: "CHTE", expected: "00000000", found: "01000000",
                                                 at: Date().addingTimeInterval(-340))]
            conflicts[0].running = true
            conflicts[0].processes = ["/Library/PrivilegedHelperTools/com.apphousekitchen.aldente-pro.helper"]
            temperature = 35.1
        case .noHelper:
            b.percent = 46
            b.externalConnected = false
            b.amperage = -1450
            b.timeRemaining = 222
            b.systemLoad = 18.6
            install = .outdated("?")
            conflicts = []
            temperature = 30.2
        case .discharging:
            b.percent = 72
            b.externalConnected = true
            b.amperage = -1800
            b.adapterWatts = 140
            b.systemPowerIn = 0.2
            b.systemLoad = 23.1
            config.dischargeEnabled = true
            config.dischargeTarget = 60
            status.config = config
            status.reason = .discharging
            status.adapterEnabled = false
            status.effect = .notApplicable
            prefs.menuBarColored = true
        case .topUpHeat:
            b.percent = 91
            b.externalConnected = true
            b.isCharging = false
            b.amperage = 0
            b.adapterWatts = 140
            b.systemPowerIn = 16.9
            b.systemLoad = 16.4
            status.reason = .thermal
            status.topUp = TopUpState(startedAt: Date().addingTimeInterval(-3600),
                                      expiresAt: Date().addingTimeInterval(20 * 3600), bootSessionUUID: "mock")
            status.effectiveLimit = 100
            // Chi tiết do helper viết (luôn tiếng Việt), app chỉ hiện ở dòng chẩn đoán.
            status.effect = .ineffective(detail: "Pin vẫn nhận 1,2 A sau 90 giây.")  // l10n-ignore
            temperature = 41.3
            prefs.menuBarStyle = .symbol
        }

        b.currentCapacity = b.maxCapacity * b.percent / 100
        return AppModel(preview: b, status: install == .outdated("?") ? nil : status, installState: install,
                        samples: history(endPercent: b.percent, limit: 80, hours: historyHours),
                        healthPoints: healthLog(), conflicts: conflicts,
                        temperature: temperature, prefs: prefs, needsMove: kind == .noHelper, update: update)
    }

    /// Lịch sử giả mỗi phút (mặc định 26 giờ) với các khoảng trống như máy thật: buổi đêm máy ngủ và chỉ thức dậy
    /// chốc lát mỗi 15 phút (Power Nap), một khoảng dài không có mẫu (máy tắt), vài lần ngủ 15 phút ban ngày và một
    /// lần gập máy 7 phút. Ngày thứ 10 trước đó máy tắt cả ngày (để xem 30 ngày).
    static func history(endPercent: Int, limit: Int, hours: Double = 26) -> [HistorySample] {
        let now = Date()
        var samples: [HistorySample] = []
        let step: TimeInterval = 60
        let count = Int(hours * 3600 / step)
        var percent = 62.0
        // Các khoảng (giờ trong ngày giả, 0 = 24 giờ trước lúc chụp) không có mẫu.
        let naps: [ClosedRange<Double>] = [12.0...12.25, 13.5...13.75, 15.0...15.12, 18.2...18.45, 21.0...21.25, 23.3...23.55]
        for i in 0..<count {
            let t = now.addingTimeInterval(-Double(count - i) * step)
            let before = Double(count - i) * step / 3600
            let day = Int(before / 24)
            let hour = 24 - before.truncatingRemainder(dividingBy: 24)
            let vary = 1 + 0.3 * sin(Double(day) * 1.7)
            let plugged: Bool
            var charging = false
            var power: Double
            var record = true
            switch hour {
            case ..<1.5:
                plugged = false
                percent -= 0.09 * vary; power = -9 - sin(hour) * 2
            case ..<3.5:
                // Máy ngủ, Power Nap đánh thức mỗi 15 phút: chỉ có một mẫu mỗi lần thức.
                plugged = false
                percent -= 0.01; power = -0.6
                record = i % 15 == 0
            case ..<8.5:
                // Máy ngủ sâu (hoặc tắt): không có mẫu.
                plugged = false
                percent -= 0.008; power = -0.4
                record = false
            case ..<11:
                plugged = true
                charging = percent < Double(limit)
                if charging { percent += 0.28; power = 38 } else { power = 0 }
            case ..<16:
                plugged = false
                percent -= 0.11 * vary; power = -11 - cos(hour) * 3
            default:
                plugged = true
                charging = percent < Double(limit)
                if charging { percent += 0.25; power = 34 } else { power = 0.1 }
            }
            if naps.contains(where: { $0.contains(hour) }) { record = false }
            if day == 9 { record = false }
            percent = min(max(percent, 5), 100)
            guard record else { continue }
            let temperature = 30 + (charging ? 5 : 1.5) + sin(hour / 2) * 1.2
            samples.append(HistorySample(date: t, percent: Int(percent.rounded()), temperature: temperature,
                                         batteryPower: power, pluggedIn: plugged, charging: charging,
                                         systemLoad: power > -1 && !plugged ? 2.5 : 12 + abs(sin(hour)) * 9,
                                         powerIn: plugged ? 14 + (charging ? 34 : 0) : nil,
                                         limit: limit))
        }
        if let last = samples.indices.last {
            samples[last].percent = endPercent
        }
        return samples
    }
}
#endif
