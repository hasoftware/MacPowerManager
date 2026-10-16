import Foundation

/// `scan_certs`: chứng chỉ gốc của công cụ proxy HTTPS - chỉ báo (spec B §5).
/// Xóa chứng chỉ tự động là quá nguy hiểm, Keychain Access là nơi đúng để người dùng tự quyết.
public struct CertificatesScanner: Scanner {
    public init() {}

    public var id: String { "Security.Certs" }

    /// Công cụ chặn HTTPS; thứ tự quan trọng (khớp cái đầu tiên).
    static let suspects = ["PortSwigger", "Burp", "Fiddler", "Charles Proxy", "mitmproxy",
                           "Proxyman", "HTTP Toolkit", "OWASP ZAP", "Titanium", "Reqable", "Whistle"]

    public func scan(_ context: ScanContext) throws -> [Finding] {
        let env = context.env
        var out: [Finding] = []
        for kc in ["/Library/Keychains/System.keychain", "\(env.homePath)/Library/Keychains/login.keychain-db"] {
            try context.checkCancelled()
            guard env.isReadableFile(kc) else { continue }
            let r = context.runner.run(Tool.security, ["find-certificate", "-a", env.physicalPath(kc)])
            // lệnh lỗi -> coi như output rỗng (zsh 2>/dev/null, không xét mã thoát: vẫn đọc stdout đã có)
            for line in r.lines where line.contains("\"labl\"") {
                try context.checkCancelled()
                let label = CertificatesScanner.label(fromLine: line)
                let low = label.lowercased()
                guard let tool = CertificatesScanner.suspects.first(where: { low.contains($0.lowercased()) }) else {
                    continue
                }
                out.append(Finding(category: .security, severity: .high, name: label, target: kc,
                                   reason: .proxyRootCertificate(tool: tool), action: .reportOnly))
            }
        }
        return out
    }

    /// `sed 's/.*"labl"<blob>="//; s/"$//'`: bỏ tới lần xuất hiện CUỐI của tiền tố (`.*` tham), rồi bỏ một `"`
    /// cuối dòng. Dòng dạng khác (`<blob>=0x…  "…"`, `<NULL>`) giữ nguyên cả dòng thô (chỉ lệnh thứ hai áp dụng).
    static func label(fromLine line: String) -> String {
        var s = Substring(line)
        if let r = line.range(of: "\"labl\"<blob>=\"", options: .backwards) { s = line[r.upperBound...] }
        if s.hasSuffix("\"") { s = s.dropLast() }
        return String(s)
    }
}
