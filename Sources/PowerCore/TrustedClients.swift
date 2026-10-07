import Foundation

/// Danh sách cdhash của app được phép điều khiển helper (`trusted-clients.json`, do script cài đặt ghi bằng root).
public enum TrustedClients {
    public struct File: Codable, Equatable, Sendable {
        public var cdhashes: [String]

        public init(cdhashes: [String]) {
            self.cdhashes = cdhashes
        }
    }

    /// cdhash hợp lệ: đúng 40 ký tự hex (SHA-256 rút gọn còn 20 byte). Trả về dạng chữ thường.
    public static func normalizedHash(_ text: String) -> String? {
        let hash = text.lowercased()
        guard hash.count == 40, hash.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            return nil
        }
        return hash
    }

    /// Đọc danh sách cdhash từ nội dung file; bỏ giá trị không hợp lệ và trùng lặp.
    public static func hashes(from data: Data?) -> [String] {
        guard let data, let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return valid(file.cdhashes)
    }

    /// Code signing requirement cho kết nối XPC. Có cdhash hợp lệ thì ghim theo cdhash,
    /// không thì chỉ kiểm tra bundle identifier (như v0.2.0).
    /// Chỉ các giá trị đã kiểm tra là hex mới được ghép vào chuỗi, nên file hỏng không chèn thêm được điều kiện.
    public static func requirement(identifier: String = PowerConstants.appBundleID, cdhashes: [String]) -> String {
        let base = "identifier \"\(identifier)\""
        let hashes = valid(cdhashes)
        guard !hashes.isEmpty else { return base }
        return base + " and (" + hashes.map { "cdhash H\"\($0)\"" }.joined(separator: " or ") + ")"
    }

    private static func valid(_ hashes: [String]) -> [String] {
        var seen = Set<String>()
        return hashes.compactMap(normalizedHash).filter { seen.insert($0).inserted }
    }
}
