import Foundation

/// `scan_lsregister`: bản ghi ma trong CSDL LaunchServices (spec B §10).
/// Không gỡ được từng bản ghi một: cách chính thức là dựng lại toàn bộ CSDL, nên chỉ ra MỘT finding.
public struct LaunchServicesScanner: Scanner {
    public init() {}

    public var id: String { "LaunchServices" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        let env = context.env
        guard env.isExecutableFile(Tool.lsregister) else { return [] }
        var ghosts: [String] = []
        // Output ~30 MB: đọc DẦN theo dòng trong lúc lệnh chạy (hủy là dừng lệnh ngay), lọc `path:` trên byte thô
        // như `grep` của bản gốc, chỉ giải mã dòng khớp.
        let r = context.runner.streamLines(Tool.lsregister, ["-dump"], timeout: 120,
                                           cancellation: context.cancellation) { bytes in
            guard LaunchServicesScanner.isPathLine(bytes),
                  let p = LaunchServicesScanner.path(fromLine: String(decoding: bytes, as: UTF8.self)) else { return true }
            // ổ ngoài chưa mount / không xem được: không phải bản ghi ma
            if p.hasPrefix("/"), env.existence(p) == .missing { ghosts.append(p) }   // không khử trùng: n = số dòng
            return true
        }
        if r.cancelled { throw CancellationError() }
        try context.checkCancelled()
        guard let first = ghosts.first else { return [] }
        let n = ghosts.count
        return [Finding(category: .launchServices, severity: .info, name: FindingLiteral.ghostRecordsName(n),
                        target: first, reason: .ghostLaunchServices(count: n), action: .lsRebuild)]
    }

    /// Lọc nhanh trên byte: sau khoảng trắng đầu dòng là `path:`.
    static func isPathLine(_ b: ArraySlice<UInt8>) -> Bool {
        var i = b.startIndex
        while i < b.endIndex, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0D || b[i] == 0x0B || b[i] == 0x0C { i += 1 }
        let tag: [UInt8] = Array("path:".utf8)
        guard b.endIndex - i >= tag.count else { return false }
        return b[i..<(i + tag.count)].elementsEqual(tag)
    }

    /// Dòng `^[[:space:]]*path:` → phần sau `path:` đầu tiên, bỏ khoảng trắng đầu, bỏ hậu tố ` (0x…)` ngắn nhất.
    /// Comment gốc: dấu ngoặc trong glob zsh là toán tử NHÓM, phải escape mới cắt được phần ` (0x80f8)` mà
    /// lsregister gắn ở cuối mỗi dòng path: - quên escape thì không đường dẫn nào khớp.
    static func path(fromLine line: String) -> String? {
        let lead = line.drop(while: EnvironmentScanner.isZshSpace)
        guard lead.hasPrefix("path:") else { return nil }
        var p = lead.dropFirst("path:".count).drop(while: EnvironmentScanner.isZshSpace)
        // ${p% \(0x*\)}: hậu tố ngắn nhất -> lần xuất hiện CUỐI của " (0x", miễn dòng kết thúc bằng ")"
        if p.hasSuffix(")"), let r = p.range(of: " (0x", options: .backwards) { p = p[..<r.lowerBound] }
        return String(p)
    }
}
