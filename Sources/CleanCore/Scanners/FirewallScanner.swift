import Foundation

/// `scan_firewall`: luật Application Firewall trỏ tới file không tồn tại (spec B §6).
/// Gỡ = `socketfilterfw --remove` nên luôn cần quyền quản trị (Remover tự tính, P0 chỉ trả lệnh tương đương).
public struct FirewallScanner: Scanner {
    public init() {}

    public var id: String { "Firewall" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        var out: [Finding] = []
        let r = context.runner.run(Tool.socketfilterfw, ["--listapps"])
        for line in r.lines {
            try context.checkCancelled()
            guard let target = FirewallScanner.target(fromLine: line) else { continue }
            guard target.hasPrefix("/"), !context.env.exists(target) else { continue }
            out.append(Finding(category: .firewall, severity: .medium, name: PathResolver.tail(target), target: target,
                               reason: .firewallRuleDead, action: .firewallApp(path: target)))
        }
        return out
    }

    /// Định dạng: `"12 : /Applications/Foo.app/Contents/MacOS/Foo "`. Dòng phải khớp `[0-9]##' : '*`;
    /// target = phần sau ` : ` đầu tiên, bỏ dấu cách cuối dòng (chỉ dấu cách). Rỗng hoặc không khớp → nil.
    static func target(fromLine line: String) -> String? {
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let rest = line[digits.endIndex...]
        guard rest.hasPrefix(" : "), let sep = line.range(of: " : ") else { return nil }
        var t = line[sep.upperBound...]
        while t.hasSuffix(" ") { t = t.dropLast() }
        return t.isEmpty ? nil : String(t)
    }
}
