import os

private let logger = Logger(subsystem: "com.hasoftware.MacPowerManager.helper", category: "daemon")

func log(_ message: String) {
    logger.notice("\(message, privacy: .public)")
}
