import Foundation
import PowerCore

// Helper chạy dưới dạng LaunchDaemon (root). Nó giữ vòng điều khiển sạc
// nên giới hạn sạc vẫn có hiệu lực khi app đã thoát hoặc chưa đăng nhập.

guard getuid() == 0 else {
    FileHandle.standardError.write("PowerHelper cần chạy bằng root (LaunchDaemon).\n".data(using: .utf8)!)
    exit(1)
}

/// Trả SMC về mặc định của macOS mà không cần daemon (dùng khi gỡ cài đặt hoặc khi bị dừng sớm).
/// Trên Intel chỉ trả `BCLM` về 100% khi gỡ cài đặt (xem `ChargeDaemon.restoreDefaults`).
func restoreSMCDefaults(forUninstall: Bool) -> Bool {
    guard let smc = try? SMC() else { return false }
    var ok = ChargingControl(smc: smc).restoreDefaults()
    if forUninstall, let intel = IntelChargeLimiter(smc: smc) {
        ok = intel.restoreDefaults() && ok
    }
    return ok
}

// 1. Cài handler tín hiệu trước tiên: khi bị dừng (gỡ cài đặt, launchctl bootout) phải trả SMC
//    về mặc định, nếu không máy có thể bị kẹt ở trạng thái không sạc hoặc ngắt adapter.
var daemon: ChargeDaemon?
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let signalSources = [SIGTERM, SIGINT].map { sig in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        log("Nhận tín hiệu \(sig), khôi phục mặc định và thoát")
        if let daemon {
            daemon.restoreDefaults(forUninstall: false)
        } else {
            _ = restoreSMCDefaults(forUninstall: false)
        }
        exit(0)
    }
    source.resume()
    return source
}

// 2. Chế độ dòng lệnh dùng khi gỡ cài đặt: khôi phục, xác minh rồi thoát.
//    Tham số lạ thì thoát ngay, để script gỡ không vô tình khởi động một daemon không có launchd quản lý.
let arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.isEmpty && arguments != ["--restore-defaults"] {
    FileHandle.standardError.write("Cách dùng: PowerHelper [--restore-defaults]\n".data(using: .utf8)!)
    exit(64)
}
if arguments == ["--restore-defaults"] {
    let ok = restoreSMCDefaults(forUninstall: true)
    print(ok ? "Đã khôi phục sạc và adapter về mặc định." : "Không xác minh được việc khôi phục.")
    exit(ok ? 0 : 1)
}

// 3. Khởi động daemon (mở SMC và bật lại adapter ngay lập tức).
do {
    daemon = try ChargeDaemon()
} catch {
    log("Không khởi tạo được daemon: \(error)")
    exit(1)
}
daemon?.start()

let listener = NSXPCListener(machServiceName: PowerConstants.helperMachService)
let listenerDelegate = ListenerDelegate(daemon: daemon!)
listener.delegate = listenerDelegate
listener.resume()

log("PowerHelper \(AppVersion.current) đã khởi động")
dispatchMain()
