import Foundation

/// Đọc plist thay cho `plist_get` (`plutil -extract <keyPath> raw`).
///
/// plutil in thông báo lỗi ra stdout chứ không phải stderr, nên bản zsh bắt buộc phải xét mã thoát - nếu không,
/// chuỗi lỗi bị nhét vào biến như thể là giá trị. Ở đây: mọi lỗi → nil, không bao giờ trả chuỗi lỗi.
public enum Plist {
    /// Nạp toàn bộ plist (XML, binary; dự phòng JSON như plutil). File phải là file thường (đi xuyên symlink).
    public static func load(_ path: String) -> Any? {
        guard FileProbe.isRegularFile(path), let data = FileManager.default.contents(atPath: path) else { return nil }
        if let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) { return obj }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Giá trị thô tại `keyPath` (tách theo `.`: thành phần trên dict là key, trên array là chỉ số thập phân).
    /// Không truy cập được key chứa dấu chấm (giống plutil).
    public static func object(_ path: String, _ keyPath: String) -> Any? {
        guard let root = load(path) else { return nil }
        return object(in: root, keyPath)
    }

    public static func object(in root: Any, _ keyPath: String) -> Any? {
        var cur: Any = root
        for comp in keyPath.split(separator: ".", omittingEmptySubsequences: false) {
            if let d = cur as? [String: Any] {
                guard let next = d[String(comp)] else { return nil }
                cur = next
            } else if let a = cur as? [Any] {
                guard let i = Int(comp), i >= 0, i < a.count else { return nil }
                cur = a[i]
            } else {
                return nil
            }
        }
        return cur
    }

    /// `plist_get(file, keyPath)`: chuỗi "raw" như `plutil -extract K raw`.
    /// String → chính nó (rỗng vẫn là `""`, khác nil); Bool → `true`/`false`; số → thập phân; Date → ISO-8601;
    /// Data → base64; Array → số phần tử; Dict → các key đã sắp nối bằng `\n`.
    /// Phía gọi thường coi rỗng = không có (`[[ -n $x ]]`).
    public static func get(_ path: String, _ keyPath: String) -> String? {
        guard let v = object(path, keyPath) else { return nil }
        return raw(v)
    }

    static func raw(_ v: Any) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case let d as Date: return ISO8601DateFormatter().string(from: d)
        case let d as Data: return d.base64EncodedString()
        case let a as [Any]: return String(a.count)
        case let d as [String: Any]: return d.keys.sorted().joined(separator: "\n")
        default: return nil
        }
    }
}
