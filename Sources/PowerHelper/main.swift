import Foundation
import PowerCore

// Helper chạy dưới dạng LaunchDaemon (root). Nó giữ vòng điều khiển sạc
// nên giới hạn sạc vẫn có hiệu lực khi app đã thoát hoặc chưa đăng nhập.

guard getuid() == 0 else {
    FileHandle.standardError.write("PowerHelper cần chạy bằng root (LaunchDaemon).\n".data(using: .utf8)!)
    exit(1)
}

let daemon: ChargeDaemon
do {
    daemon = try ChargeDaemon()
} catch {
    log("Không khởi tạo được daemon: \(error)")
    exit(1)
}
daemon.start()

let listener = NSXPCListener(machServiceName: PowerConstants.helperMachService)
let listenerDelegate = ListenerDelegate(daemon: daemon)
listener.delegate = listenerDelegate
listener.resume()

// Khi bị dừng (gỡ cài đặt, launchctl bootout) phải trả SMC về mặc định,
// nếu không máy có thể bị kẹt ở trạng thái không sạc hoặc ngắt adapter.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let signalSources = [SIGTERM, SIGINT].map { sig in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        log("Nhận tín hiệu \(sig), khôi phục mặc định và thoát")
        daemon.restoreDefaults()
        exit(0)
    }
    source.resume()
    return source
}

log("PowerHelper \(AppVersion.current) đã khởi động")
dispatchMain()
