import Foundation

/// `scan_docker`: chỉ báo khi Docker Desktop KHÔNG còn nhưng dữ liệu vẫn nằm đó (thường vài GB) (spec A §3.13).
/// Parity (R9): kiểm tra `-d /Applications/Docker.app` chứ không phải bundle hợp lệ - vỏ rỗng do BrokenAppScanner báo.
/// Cùng đường dẫn có thể đã được Containers/Caches/AppSupport/Helper báo dưới nhóm khác (R5): Remover khử trùng.
public struct DockerScanner: Scanner {
    public init() {}

    public var id: String { "Docker" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        let env = context.env
        if env.isDirectory("/Applications/Docker.app") { return [] }
        // Engine khác (colima, OrbStack, docker CLI của brew) vẫn dùng các file này
        if env.commandExists("docker") { return [] }
        let h = env.homePath
        let leftovers = [
            "\(h)/Library/Containers/com.docker.docker",
            "\(h)/Library/Containers/com.docker.helper",
            "\(h)/Library/Group Containers/group.com.docker",
            "\(h)/Library/Application Support/Docker Desktop",
            "\(h)/Library/Caches/com.docker.docker",
            "\(h)/.docker",
            "/Library/PrivilegedHelperTools/com.docker.vmnetd",
            "/Library/PrivilegedHelperTools/com.docker.socket",
            "/Library/LaunchDaemons/com.docker.vmnetd.plist",
            "/Library/LaunchDaemons/com.docker.socket.plist",
        ]
        var out: [Finding] = []
        for p in leftovers where env.exists(p) {
            try context.checkCancelled()
            out.append(Finding(category: .docker, severity: .high, name: PathResolver.tail(p), target: p,
                               reason: .dockerGone, sizeBytes: context.sizeBytes(p), action: .trashPath(path: p)))
        }
        return out
    }
}
