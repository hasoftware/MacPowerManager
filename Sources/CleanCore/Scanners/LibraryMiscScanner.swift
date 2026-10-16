import Foundation

/// `scan_state` phần 2-5 (HTTPStorages, WebKit, Application Scripts, Cookies) + `scan_logs` (spec A §3.6-3.7).
/// `/Library/Logs` không quét: DiagnosticReports, CrashReporter... do SYS_KEEP / chỉ mục hệ thống bảo vệ.
public struct LibraryMiscScanner: Scanner {
    public init() {}

    public var id: String { "LibraryMisc" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        let lib = "\(context.env.homePath)/Library"
        var out: [Finding] = []
        // Chỉ THƯ MỤC: các file *.binarycookies nằm cạnh trong HTTPStorages bị bỏ qua (như bản gốc)
        out += try context.scanContainer("\(lib)/HTTPStorages", category: .httpStorage)
        out += try context.scanContainer("\(lib)/WebKit", category: .webKit)
        // Tên thường là TEAMID.com.foo / group.com.foo - orphan_check tự cắt
        out += try context.scanContainer("\(lib)/Application Scripts", category: .appScripts)
        out += try scanCookies(context, dir: "\(lib)/Cookies")
        out += try context.scanContainer("\(lib)/Logs", category: .logs)
        return out
    }

    /// Mỗi file thường `*.binarycookies` (không symlink) mang bundle id. `Cookies.binarycookies` của Safari không
    /// giống bundle id nên tự bị bỏ.
    private func scanCookies(_ context: ScanContext, dir: String) throws -> [Finding] {
        var out: [Finding] = []
        for f in context.env.list(dir, .regularFiles, suffix: ".binarycookies") {
            try context.checkCancelled()
            let name = Names.removingSuffix(PathResolver.tail(f), ".binarycookies")
            guard Names.looksLikeBundleID(name) else { continue }
            if let finding = context.reportOrphan(name: name, path: f, category: .cookies) { out.append(finding) }
        }
        return out
    }
}
