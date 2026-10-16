import Foundation

/// `scan_tcc`: quyền riêng tư còn cấp cho app đã gỡ, chỉ khi có Full Disk Access (spec B §7).
public struct TCCScanner: Scanner {
    public init() {}

    public var id: String { "TCC" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        // Không có FDA -> không quét, không finding (UI tự báo thiếu quyền)
        guard context.hasFullDiskAccess else { return [] }
        let env = context.env
        var out: [Finding] = []
        var seen = Set<String>()
        let userDB = "\(env.homePath)/Library/Application Support/com.apple.TCC/TCC.db"
        for db in [userDB, "/Library/Application Support/com.apple.TCC/TCC.db"] {
            try context.checkCancelled()
            guard env.isReadableFile(db) else { continue }
            // Chỉ đọc (mode=ro), qua sqlite3 để giữ seam test
            let r = context.runner.run(Tool.sqlite3, ["file:\(env.physicalPath(db))?mode=ro",
                                                      "SELECT DISTINCT service, client FROM access;"])
            for row in r.lines {
                try context.checkCancelled()
                // IFS='|' read -r service client: tách tại | ĐẦU TIÊN, client là phần còn lại
                guard let bar = row.firstIndex(of: "|") else { continue }
                let service = String(row[..<bar])
                let client = String(row[row.index(after: bar)...])
                guard !client.isEmpty else { continue }
                // Giữ như zsh: client kiểu đường dẫn có ≥ 2 dấu chấm vẫn lọt looks_like_bid (rủi ro đã biết)
                guard Names.looksLikeBundleID(client), !context.bundleIDAlive(client) else { continue }
                let svc = service.hasPrefix("kTCCService") ? String(service.dropFirst("kTCCService".count)) : service
                // cùng (service, client) ở cả hai CSDL: một finding (cùng ID)
                guard seen.insert(svc + "|" + client).inserted else { continue }
                // `tccutil reset` chạy quyền người dùng chỉ sửa CSDL của người dùng (vẫn thoát 0): quyền trong CSDL
                // hệ thống mà báo "xong" là sai sự thật -> chỉ báo cho tới khi có helper root (P5).
                let action: CleanAction = db == userDB ? .tccReset(service: svc, client: client) : .reportOnly
                out.append(Finding(category: .tcc, severity: .medium, name: client, target: svc,
                                   reason: .tccOrphan(service: svc), action: action))
            }
        }
        return out
    }
}
