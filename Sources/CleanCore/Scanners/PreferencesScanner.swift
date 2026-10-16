import Foundation

/// `scan_prefs`: plist mồ côi trong `~/Library/Preferences`, `.../ByHost` và `/Library/Preferences` (spec A §3.4).
/// Chỉ xét file thường `*.plist` mang bundle id. name trong ID là tên đã cắt hậu tố ByHost, target là file đầy đủ.
public struct PreferencesScanner: Scanner {
    public init() {}

    public var id: String { "Prefs" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        let env = context.env
        let h = env.homePath
        var out: [Finding] = []
        for d in ["\(h)/Library/Preferences", "\(h)/Library/Preferences/ByHost", "/Library/Preferences"] {
            guard env.isDirectory(d) else { continue }
            let byHost = PathResolver.tail(d) == "ByHost"
            for f in env.list(d, .regularFiles, suffix: ".plist") {
                try context.checkCancelled()
                var name = Names.removingSuffix(PathResolver.tail(f), ".plist")
                // ByHost gắn thêm UUID phần cứng ở cuối: com.foo.bar.<UUID>.plist
                if byHost { name = PreferencesScanner.stripHostSuffix(name) }
                if name.hasPrefix(".GlobalPreferences") || name.hasPrefix("GlobalPreferences") { continue }
                // chỉ xét file mang bundle id
                guard Names.looksLikeBundleID(name) else { continue }
                if let finding = context.reportOrphan(name: name, path: f, category: .prefs) { out.append(finding) }
            }
        }
        return out
    }

    /// `${name%.[0-9A-Fa-f-]##}`: bỏ hậu tố ngắn nhất = từ dấu chấm CUỐI, nếu phía sau không rỗng và chỉ gồm
    /// hex hoặc `-` (UUID phần cứng, MAC cũ `.001122aabbcc`). Parity: thành phần cuối toàn hex của bundle id
    /// cũng bị cắt (`com.foo.cafe` → `com.foo`).
    static func stripHostSuffix(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return name }
        let tail = name[name.index(after: dot)...]
        guard !tail.isEmpty, tail.unicodeScalars.allSatisfy({ isHexOrDash($0) }) else { return name }
        return String(name[..<dot])
    }

    private static func isHexOrDash(_ u: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(u) || ("a"..."f").contains(u) || ("A"..."F").contains(u) || u == "-"
    }
}
