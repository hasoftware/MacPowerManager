import Foundation

/// Đưa một mục vào Thùng rác. Tiêm được: test dùng `DirectoryTrasher` trỏ vào thư mục tạm, KHÔNG BAO GIỜ đụng
/// Thùng rác thật.
public protocol Trasher: Sendable {
    /// Chuyển CHÍNH mục ở `item` (không đi xuyên symlink) vào Thùng rác, trả URL thực tế trong Thùng rác
    /// (có thể đã bị đổi tên, hoặc nằm ở `.Trashes` của ổ khác).
    func moveToTrash(_ item: URL) throws -> URL
}

/// Thùng rác thật qua `FileManager.trashItem`; lỗi thì tự chuyển vào `fallbackTrash` (đổi tên khi trùng) - vẫn
/// khôi phục được bằng Finder.
public struct SystemTrasher: Trasher {
    public var fallbackTrash: URL

    public init(fallbackTrash: URL) {
        self.fallbackTrash = fallbackTrash
    }

    public func moveToTrash(_ item: URL) throws -> URL {
        var result: NSURL?
        do {
            try FileManager.default.trashItem(at: item, resultingItemURL: &result)
            if let url = result as URL? { return url }
            return fallbackTrash.appendingPathComponent(item.lastPathComponent)
        } catch {
            return try DirectoryTrasher(trashDir: fallbackTrash).moveToTrash(item)
        }
    }
}

/// Chuyển vào một thư mục cụ thể (dự phòng của `to_trash`, và Thùng rác giả cho test).
/// Trùng tên → `"<tên> HHmmss"`, vẫn trùng thì thêm `-2`, `-3`...
public struct DirectoryTrasher: Trasher {
    public var trashDir: URL

    public init(trashDir: URL) {
        self.trashDir = trashDir
    }

    public func moveToTrash(_ item: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let name = item.lastPathComponent
        var dest = trashDir.appendingPathComponent(name)
        if FileProbe.lexists(dest.path) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "HHmmss"
            let stamped = "\(name) \(f.string(from: Date()))"
            dest = trashDir.appendingPathComponent(stamped)
            var n = 2
            while FileProbe.lexists(dest.path) {
                dest = trashDir.appendingPathComponent("\(stamped)-\(n)")
                n += 1
            }
        }
        // rename(2) không đi xuyên symlink: chuyển chính cái link.
        if rename(item.path, dest.path) != 0 {
            try fm.moveItem(at: item, to: dest)
        }
        return dest
    }
}
