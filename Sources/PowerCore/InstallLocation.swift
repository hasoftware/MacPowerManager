public enum InstallLocation {
    /// App đang chạy từ vị trí tạm: bản bị macOS "translocate" (mở từ Downloads hoặc file .dmg chưa chuyển đi)
    /// hoặc trực tiếp từ một ổ đĩa chỉ đọc trong /Volumes (file .dmg). Ổ đĩa ngoài ghi được không tính,
    /// vì có người cố ý để app ở đó. Khi là vị trí tạm thì nên chuyển app vào /Applications.
    public static func isTemporary(bundlePath: String, isOnReadOnlyVolume: Bool) -> Bool {
        bundlePath.contains("/AppTranslocation/") || (bundlePath.hasPrefix("/Volumes/") && isOnReadOnlyVolume)
    }

    /// So sánh version dạng X.Y.Z. Trả về true nếu `a` mới hơn hoặc bằng `b`.
    public static func version(_ a: String, isAtLeast b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return true
    }
}
