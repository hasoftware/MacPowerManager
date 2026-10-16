import Foundation

/// Các hàm chuẩn hóa / nhận dạng tên dùng chung (port nguyên văn hành vi zsh).
public enum Names {
    /// `norm_name`: lowercase rồi XÓA mọi ký tự ngoài `[a-z0-9]` (ASCII). Không phiên âm: chữ có dấu bị xóa hẳn.
    /// Chỉ mục và tên tra cứu đều qua cùng hàm nên vẫn nhất quán.
    public static func norm(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.lowercased().unicodeScalars where isLowerAlnum(u) { out.append(u) }
        return String(out)
    }

    /// Tách từ: lowercase, ký tự ngoài `[a-z0-9]` thành khoảng trắng, bỏ phần rỗng.
    public static func words(_ s: String) -> [String] {
        var words: [String] = []
        var cur = String.UnicodeScalarView()
        for u in s.lowercased().unicodeScalars {
            if isLowerAlnum(u) {
                cur.append(u)
            } else if !cur.isEmpty {
                words.append(String(cur)); cur = String.UnicodeScalarView()
            }
        }
        if !cur.isEmpty { words.append(String(cur)) }
        return words
    }

    /// Từ đủ làm bằng chứng: dài ≥ 4 và không thuộc `stopWords`.
    public static func significantWords(_ s: String) -> [String] {
        words(s).filter { $0.count >= 4 && !stopWords.contains($0) }
    }

    /// `looks_like_bid`. Lưu ý (parity): mọi tên có ≥ 2 dấu chấm đều "giống bundle id" (`Foo 1.2.3`).
    public static func looksLikeBundleID(_ s: String) -> Bool {
        let n = s.lowercased()
        guard n.contains(".") else { return false }
        if let dot = n.firstIndex(of: "."), tlds.contains(String(n[..<dot])) { return true }
        return n.filter { $0 == "." }.count >= 2
    }

    /// `looks_like_uuid`: khớp đúng `8-4-4-4-12` hex (không phân biệt hoa thường).
    public static func looksLikeUUID(_ s: String) -> Bool {
        let u = Array(s.uppercased().unicodeScalars)
        guard u.count == 36 else { return false }
        for (i, c) in u.enumerated() {
            if [8, 13, 18, 23].contains(i) {
                if c != "-" { return false }
            } else if !(("0"..."9").contains(c) || ("A"..."F").contains(c)) {
                return false
            }
        }
        return true
    }

    /// `strip_team_prefix`: bỏ `group.` (phân biệt hoa thường) rồi bỏ Team ID.
    /// Team ID luôn là 10 ký tự HOA + số. Bắt buộc hoa để không cắt nhầm bundle id thật có thành phần đầu
    /// dài 10 ký tự thường.
    public static func stripTeamPrefix(_ s: String) -> String {
        var b = s
        if b.hasPrefix("group.") { b.removeFirst("group.".count) }
        let u = Array(b.unicodeScalars)
        if u.count > 10, u[10] == ".",
           u[0..<10].allSatisfy({ ("0"..."9").contains($0) || ("A"..."Z").contains($0) }) {
            return String(String.UnicodeScalarView(u[11...]))
        }
        return b
    }

    /// Team ID ở đầu tên (sau khi bỏ `group.`): `UBF8T346G9.Office` → `UBF8T346G9`. Không có → nil.
    public static func teamIdentifier(_ s: String) -> String? {
        var b = Substring(s)
        if b.hasPrefix("group.") { b = b.dropFirst("group.".count) }
        let u = Array(b.unicodeScalars)
        guard u.count > 10, u[10] == ".",
              u[0..<10].allSatisfy({ ("0"..."9").contains($0) || ("A"..."Z").contains($0) }) else { return nil }
        return String(String.UnicodeScalarView(u[0..<10]))
    }

    /// Phần sau dấu chấm cuối (`${x##*.}`); không có dấu chấm thì là cả chuỗi.
    public static func lastComponent(_ s: String) -> String {
        guard let dot = s.lastIndex(of: ".") else { return s }
        return String(s[s.index(after: dot)...])
    }

    /// Bỏ đuôi cuối cùng của tên (`${x:r}`): `Foo.bar.qlgenerator` → `Foo.bar`. Tên bắt đầu bằng `.` giữ nguyên.
    public static func removingLastExtension(_ s: String) -> String {
        guard let dot = s.lastIndex(of: "."), dot != s.startIndex else { return s }
        return String(s[..<dot])
    }

    /// Bỏ hậu tố cố định một lần nếu có (`${x%suffix}`).
    public static func removingSuffix(_ s: String, _ suffix: String) -> String {
        guard !suffix.isEmpty, s.hasSuffix(suffix) else { return s }
        return String(s.dropLast(suffix.count))
    }

    private static func isLowerAlnum(_ u: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(u) || ("0"..."9").contains(u)
    }

    static let tlds: Set<String> = [
        "com", "org", "net", "io", "co", "dev", "app", "us", "uk", "de", "fr", "nl", "se", "it", "es", "ru", "jp",
        "kr", "cn", "tv", "cc", "me", "ai", "xyz", "info", "biz", "eu", "ch", "at", "pl", "br", "in", "au", "ca",
        "no", "fi", "dk", "cz", "gr", "sh", "to", "ly", "group", "edu", "gov",
    ]

    /// STOP_WORD: từ quá chung. Nếu nhận làm bằng chứng "app còn sống" thì mọi thư mục tên
    /// "Something Helper/Updater/Client" đều được tha -> bỏ sót thật sự.
    public static let stopWords: Set<String> = [
        "client", "server", "helper", "update", "updater", "tool", "tools", "manager", "service", "services",
        "agent", "launcher", "installer", "uninstaller", "setup", "desktop", "studio", "player", "viewer",
        "editor", "cloud", "mobile", "sync", "core", "base", "common", "shared", "data", "cache", "caches",
        "plugin", "plugins", "framework", "library", "driver", "support", "assistant", "browser", "engine",
        "monitor", "control", "center", "media", "audio", "video", "photo", "photos", "mail", "chat", "game",
        "games", "app", "apps", "main", "free", "pro", "plus", "lite", "home", "office", "work", "user", "users",
        "system", "config", "settings", "preference", "preferences", "default", "defaults", "temp", "tmp", "new",
        "old", "backup",
    ]

    /// SYS_KEEP: thư mục do macOS/Apple quản lý, so khớp chính xác với `norm(...)`, không bao giờ đánh dấu.
    /// Tài nguyên dùng chung của bộ Pro/iLife: GarageBand và Logic xài chung thư mục 'Logic'/'ProApps' -
    /// gỡ nhầm là mất hàng GB thư viện âm thanh.
    public static let systemKeep: Set<String> = [
        // livefsd: thư mục rỗng do LiveFS của macOS tạo trong /Library/Application Support
        "livefsd",
        "addressbook", "addressbooksourcesync", "animoji", "appstore", "appstored", "applemediaservices",
        "biome", "callhistorydb", "callhistorytransactions", "cloudartifacts", "clouddocs", "cloudkit",
        "coresimulator", "crashreporter", "developer", "dock", "facetime", "fileprovider", "findmy", "homekit",
        "icdd", "icloud", "knowledge", "mail", "mobilesync", "notes", "personalizationportrait", "quicklook",
        "safari", "screensharing", "siri", "sms", "spotlight", "storekit", "syncedpreferences", "syncservices",
        "textinput", "translation", "ubiquity", "weather", "apple", "appleintelligence", "containers",
        "caches", "preferences", "logs", "fonts", "keychains", "cookies", "webkit", "httpstorages",
        "audio", "scripts", "services", "widgets", "accountpolicy", "assistant", "autofill",
        "logic", "proapps", "ilifemediabrowser", "garageband", "finalcut", "motion", "compressor",
        "amsdatamigratortool", "btserver", "desktoppictures", "installation", "mobiledevice",
        "provisioningprofiles", "sharedfilelist", "iconservices", "bookkeeping",
        "databases", "webpush", "mediakeys", "baseband", "privacypreservingmeasurement",
        "diagnosticreports", "powerlog", "networkserviceproxy",
    ]

    /// TOOLCHAIN_PREFIX: tiền tố bundle id → lệnh CLI. Lệnh còn thì tiền tố được coi là còn sống.
    public static let toolchainPrefixes: [(prefix: String, command: String)] = [
        ("org.swift", "swift"), ("org.python", "python3"), ("org.llvm", "clang"), ("org.nodejs", "node"),
        ("org.rust", "cargo"), ("org.gradle", "gradle"), ("org.apache", "mvn"), ("org.cocoapods", "pod"),
        ("org.videolan", "vlc"), ("org.mozilla", "firefox"), ("org.cups", "lp"), ("org.gnu", "make"),
        ("com.docker", "docker"), ("io.podman", "podman"), ("com.google.android", "adb"), ("sh.brew", "brew"),
    ]
}
