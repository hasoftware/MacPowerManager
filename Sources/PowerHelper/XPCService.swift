import Foundation
import PowerCore

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let daemon: ChargeDaemon

    init(daemon: ChargeDaemon) {
        self.daemon = daemon
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Chỉ chấp nhận app có đúng bundle identifier đã ký. Nếu script cài đặt đã ghi cdhash của app
        // (`trusted-clients.json`, root 0644) thì ghim thêm theo cdhash. Đọc lại ở mỗi kết nối để cài lại app
        // không cần khởi động lại helper.
        let hashes = TrustedClients.hashes(from: try? Data(contentsOf: PowerConstants.trustedClientsURL))
        connection.setCodeSigningRequirement(TrustedClients.requirement(cdhashes: hashes))
        connection.exportedInterface = NSXPCInterface(with: PowerHelperProtocol.self)
        connection.exportedObject = HelperService(daemon: daemon)
        connection.resume()
        return true
    }
}

final class HelperService: NSObject, PowerHelperProtocol {
    private let daemon: ChargeDaemon

    init(daemon: ChargeDaemon) {
        self.daemon = daemon
    }

    func version(reply: @escaping (String) -> Void) {
        reply(AppVersion.current)
    }

    func status(reply: @escaping (Data?) -> Void) {
        DispatchQueue.main.async {
            reply(try? JSONEncoder().encode(self.daemon.status()))
        }
    }

    func apply(config data: Data, reply: @escaping (String?) -> Void) {
        guard let config = try? JSONDecoder().decode(PowerConfig.self, from: data) else {
            reply("Cấu hình không hợp lệ")
            return
        }
        DispatchQueue.main.async {
            self.daemon.update(config: config)
            reply(self.daemon.status().lastError)
        }
    }

    func perform(command data: Data, reply: @escaping (Data?) -> Void) {
        guard let command = try? JSONDecoder().decode(HelperCommand.self, from: data) else {
            reply(try? JSONEncoder().encode(HelperResponse(ok: false, error: .invalidArgument, message: "Lệnh không hợp lệ")))
            return
        }
        DispatchQueue.main.async {
            reply(try? JSONEncoder().encode(self.daemon.handle(command)))
        }
    }

    func restoreDefaults(reply: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.daemon.restoreDefaults(forUninstall: true)
            reply()
        }
    }
}
