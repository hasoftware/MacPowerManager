import Foundation
import PowerCore

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let daemon: ChargeDaemon

    init(daemon: ChargeDaemon) {
        self.daemon = daemon
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Chỉ chấp nhận app có đúng bundle identifier đã ký.
        connection.setCodeSigningRequirement("identifier \"\(PowerConstants.appBundleID)\"")
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

    func restoreDefaults(reply: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.daemon.restoreDefaults()
            reply()
        }
    }
}
