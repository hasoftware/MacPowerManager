#if DEBUG
import AppKit
import SwiftUI

/// `--bench [trang…] [--seconds N]`: đo CPU của app khi một trang đang hiển thị, với dữ liệu thật (pin, CPU, tiến
/// trình…). Mỗi trang được dựng trong cửa sổ ngoài màn hình (vẫn được vẽ như cửa sổ thật), chạy vòng cập nhật như app
/// rồi đo thời gian CPU của chính tiến trình. "idle" = không có cửa sổ nào, "popover" = bảng thanh menu.
/// `--warmup N`: chờ N giây trước khi đo (mặc định 4; trang Gỡ ứng dụng cần chờ tính xong dung lượng app).
@MainActor
enum Benchmark {
    static func run(_ arguments: [String]) {
        var seconds = 20.0
        var warmup = 4.0
        var names: [String] = []
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if argument == "--seconds", let value = iterator.next().flatMap(Double.init) {
                seconds = value
            } else if argument == "--warmup", let value = iterator.next().flatMap(Double.init) {
                warmup = value
            } else {
                names.append(argument)
            }
        }
        if names.isEmpty { names = ["idle", "popover"] + Page.allCases.map(\.rawValue) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        print("trang\tCPU %\t(trong \(Int(seconds)) giây)")
        for name in names {
            let percent = measure(name, seconds: seconds, warmup: warmup)
            print("\(name)\t\(percent.map { String(format: "%.2f", $0) } ?? "?")")
            fflush(stdout)
        }
    }

    private static func measure(_ name: String, seconds: Double, warmup: Double) -> Double? {
        let model = AppModel()
        let page = Page(rawValue: name)
        guard page != nil || name == "idle" || name == "popover" else { return nil }
        model.startForBenchmark(dashboardVisible: page != nil, popoverVisible: name == "popover")
        var window: NSWindow?
        if name != "idle" {
            let root: AnyView
            if let page {
                root = AnyView(PageView(page: page).frame(width: 860, height: 680))
                model.setDashboardPage(page)
                model.system.retain()
            } else {
                root = AnyView(PopoverView().frame(width: PopoverView.width))
            }
            let host = NSHostingView(rootView: root.environment(model).environment(\.locale, Format.locale))
            // MPM_BENCH_SIZING=none|min|all: cách NSHostingView báo kích thước cho cửa sổ.
            switch ProcessInfo.processInfo.environment["MPM_BENCH_SIZING"] {
            case "none": host.sizingOptions = []
            case "min": host.sizingOptions = [.minSize]
            default: break
            }
            let size = host.fittingSize
            let w = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host
            w.orderFrontRegardless()
            window = w
        }
        // Khởi động (đọc lịch sử, lần đo đầu) không tính.
        RunLoop.main.run(until: Date().addingTimeInterval(warmup))
        let start = cpuTime()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        let used = cpuTime() - start
        if page != nil { model.system.release() }
        window?.orderOut(nil)
        window?.contentView = nil
        return used / seconds * 100
    }

    private static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
#endif
