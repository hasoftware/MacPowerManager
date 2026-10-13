import Foundation

/// Phiên bản dạng SemVer `X.Y.Z[-prerelease][+build]`, có thể có tiền tố "v" (tag GitHub `v0.3.0`).
/// Bản pre-release cũ hơn bản chính thức cùng số: `0.3.0-dev` < `0.3.0`, nhưng vẫn mới hơn mọi bản `0.2.x`.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Các thành phần sau dấu "-", ví dụ `["beta", "2"]`. Rỗng là bản chính thức.
    public var prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Chấp nhận "v1.2.3", "1.2.3-dev", "1.2" (= 1.2.0); bỏ phần build "+…". Trả về nil nếu không phải số.
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        var pre: [String] = []
        if let dash = text.firstIndex(of: "-") {
            pre = text[text.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty }) else { return nil }
            text = String(text[..<dash])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: pre)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        // Cùng số: bản chính thức mới hơn mọi bản pre-release.
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        // So từng thành phần theo SemVer 2.0: số so theo giá trị và đứng trước chữ; chữ so theo ASCII.
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (nx?, ny?): return nx < ny
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

/// Một bản phát hành trên GitHub (`GET /repos/{owner}/{repo}/releases/latest`).
public struct ReleaseInfo: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public var name: String
        public var downloadURL: URL
        public var size: Int

        public init(name: String, downloadURL: URL, size: Int) {
            self.name = name
            self.downloadURL = downloadURL
            self.size = size
        }

        enum CodingKeys: String, CodingKey {
            case name, size
            case downloadURL = "browser_download_url"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            downloadURL = try c.decode(URL.self, forKey: .downloadURL)
            size = (try? c.decodeIfPresent(Int.self, forKey: .size)) ?? 0
        }
    }

    public var tagName: String
    public var name: String?
    /// Nội dung gốc (Markdown): ghi chú của version, rồi phần chân từ dòng `---` (hướng dẫn cài đặt, tác giả).
    public var body: String?
    public var pageURL: URL
    public var publishedAt: Date?
    public var draft: Bool
    public var prerelease: Bool
    public var assets: [Asset]

    public init(tagName: String, name: String? = nil, body: String? = nil, pageURL: URL, publishedAt: Date? = nil,
                draft: Bool = false, prerelease: Bool = false, assets: [Asset] = []) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.pageURL = pageURL
        self.publishedAt = publishedAt
        self.draft = draft
        self.prerelease = prerelease
        self.assets = assets
    }

    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case pageURL = "html_url"
        case publishedAt = "published_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decode(String.self, forKey: .tagName)
        pageURL = try c.decode(URL.self, forKey: .pageURL)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        body = try? c.decodeIfPresent(String.self, forKey: .body)
        draft = (try? c.decodeIfPresent(Bool.self, forKey: .draft)) ?? false
        prerelease = (try? c.decodeIfPresent(Bool.self, forKey: .prerelease)) ?? false
        assets = (try? c.decodeIfPresent([Asset].self, forKey: .assets)) ?? []
        // "2026-10-07T15:34:34Z"; có thể là null (bản nháp) hoặc có phần lẻ của giây.
        publishedAt = (try? c.decodeIfPresent(String.self, forKey: .publishedAt)).flatMap { $0.flatMap(Self.parseDate) }
    }

    /// Giải mã JSON trả về từ GitHub API.
    public static func decode(_ data: Data) throws -> ReleaseInfo {
        try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }

    private static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// Version từ tag ("v0.3.0" → 0.3.0), nil nếu tag không phải SemVer.
    public var version: SemanticVersion? { SemanticVersion(tagName) }

    /// Bản dùng được để cập nhật: không phải bản nháp, không phải pre-release (cờ của GitHub hoặc hậu tố "-…").
    public var isStable: Bool {
        guard !draft, !prerelease, let version else { return false }
        return !version.isPrerelease
    }

    /// Ghi chú thay đổi của version này (phần chân đã bỏ).
    public var notes: String { Self.releaseNotes(from: body ?? "") }

    /// File `.dmg` để tải: ưu tiên đúng tên `MacPowerManager-X.Y.Z.dmg`, nếu không thì file .dmg đầu tiên.
    public var diskImage: Asset? {
        let dmgs = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        if let version, let exact = dmgs.first(where: { $0.name == "MacPowerManager-\(version).dmg" }) {
            return exact
        }
        return dmgs.first
    }

    /// File `.zip` của app dùng cho cập nhật tự động (`MacPowerManager-X.Y.Z.zip`).
    public var updateArchive: Asset? {
        guard let version else { return nil }
        return assets.first { $0.name == "MacPowerManager-\(version).zip" }
    }

    /// Chữ ký Ed25519 của file `.zip` (`MacPowerManager-X.Y.Z.zip.sig`). Bản phát hành cũ không có.
    public var updateSignature: Asset? {
        guard let archive = updateArchive else { return nil }
        return assets.first { $0.name == archive.name + ".sig" }
    }

    /// Cập nhật tự động được khi bản phát hành có cả file .zip và chữ ký.
    public var supportsAutomaticUpdate: Bool { updateArchive != nil && updateSignature != nil }

    /// Liên kết tải: file .dmg nếu có, nếu không thì trang release.
    public var downloadURL: URL { diskImage?.downloadURL ?? pageURL }

    /// Có phải bản ổn định mới hơn `current` (ví dụ `AppVersion.current`) hay không.
    public func isNewer(than current: String) -> Bool {
        guard isStable, let version else { return false }
        guard let installed = SemanticVersion(current) else { return true }
        return version > installed
    }

    /// Bỏ phần chân (từ dòng đầu tiên chỉ có `---`, thường là hướng dẫn cài đặt) và dòng trống ở đầu/cuối.
    public static func releaseNotes(from body: String) -> String {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if let footer = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(footer...)
        }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
