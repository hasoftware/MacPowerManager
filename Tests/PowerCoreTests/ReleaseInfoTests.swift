import XCTest
@testable import PowerCore

final class SemanticVersionTests: XCTestCase {
    private func v(_ s: String) -> SemanticVersion { SemanticVersion(s)! }

    func testParsesTagsWithAndWithoutPrefix() {
        XCTAssertEqual(SemanticVersion("v0.3.0"), SemanticVersion(major: 0, minor: 3, patch: 0))
        XCTAssertEqual(SemanticVersion("V1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion(" 1.2.3\n"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion("1.2"), SemanticVersion(major: 1, minor: 2, patch: 0))
        XCTAssertEqual(SemanticVersion("0.3.0-dev")?.prerelease, ["dev"])
        XCTAssertEqual(SemanticVersion("1.0.0-beta.2+build.7")?.prerelease, ["beta", "2"])
        XCTAssertEqual(SemanticVersion("v0.3.0")?.description, "0.3.0")
        XCTAssertEqual(SemanticVersion("0.3.0-rc.1")?.description, "0.3.0-rc.1")
    }

    func testRejectsGarbage() {
        for text in ["", "v", "latest", "1.2.3.4", "1..2", "a.b.c", "1.2.-3", "1.2.3-", "1.2.3-a..b", "nightly-2026"] {
            XCTAssertNil(SemanticVersion(text), text)
        }
    }

    func testOrdering() {
        XCTAssertLessThan(v("0.2.0"), v("0.3.0"))
        XCTAssertLessThan(v("0.2.9"), v("0.10.0"), "So theo số, không theo chữ")
        XCTAssertLessThan(v("0.9.9"), v("1.0.0"))
        XCTAssertLessThan(v("1.0.0"), v("1.0.1"))
        XCTAssertEqual(v("v1.0.0"), v("1.0.0"))
    }

    func testDevBuildIsOlderThanReleaseButNewerThanPreviousMinor() {
        XCTAssertLessThan(v("0.3.0-dev"), v("0.3.0"))
        XCTAssertGreaterThan(v("0.3.0-dev"), v("0.2.0"))
        XCTAssertGreaterThan(v("0.3.0-dev"), v("0.2.9"))
        XCTAssertLessThan(v("0.3.0-dev"), v("0.3.1"))
    }

    func testPrereleasePrecedence() {
        // Thứ tự mẫu của SemVer 2.0.
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                       "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"].map(v)
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(a, b, "\(a) < \(b)")
            XCTAssertFalse(b < a)
        }
    }
}

final class ReleaseInfoTests: XCTestCase {
    /// Rút gọn từ JSON thật của `GET /repos/hasoftware/MacPowerManager/releases/latest` (v0.2.0).
    private let json = #"""
    {
      "url": "https://api.github.com/repos/hasoftware/MacPowerManager/releases/1",
      "html_url": "https://github.com/hasoftware/MacPowerManager/releases/tag/v0.2.0",
      "id": 1,
      "tag_name": "v0.2.0",
      "name": "MacPowerManager v0.2.0",
      "draft": false,
      "prerelease": false,
      "created_at": "2026-10-07T15:30:00Z",
      "published_at": "2026-10-07T15:34:34Z",
      "assets": [
        {"name": "MacPowerManager-0.2.0.zip", "size": 846163, "content_type": "application/zip",
         "browser_download_url": "https://github.com/hasoftware/MacPowerManager/releases/download/v0.2.0/MacPowerManager-0.2.0.zip"},
        {"name": "MacPowerManager-0.2.0.dmg", "size": 957311, "content_type": "application/x-apple-diskimage",
         "browser_download_url": "https://github.com/hasoftware/MacPowerManager/releases/download/v0.2.0/MacPowerManager-0.2.0.dmg"},
        {"name": "SHA256SUMS.txt", "size": 184,
         "browser_download_url": "https://github.com/hasoftware/MacPowerManager/releases/download/v0.2.0/SHA256SUMS.txt"}
      ],
      "body": "\n### Tính năng\n- **Intel** (thử nghiệm)\n\n### Sửa lỗi\n- Một lỗi.\n\n\n---\n\n### Cài đặt\n1. Tải file.\n"
    }
    """#

    func testDecodesGitHubLatestRelease() throws {
        let release = try ReleaseInfo.decode(Data(json.utf8))
        XCTAssertEqual(release.tagName, "v0.2.0")
        XCTAssertEqual(release.name, "MacPowerManager v0.2.0")
        XCTAssertEqual(release.version, SemanticVersion(major: 0, minor: 2, patch: 0))
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/hasoftware/MacPowerManager/releases/tag/v0.2.0")
        XCTAssertEqual(release.publishedAt, ISO8601DateFormatter().date(from: "2026-10-07T15:34:34Z"))
        XCTAssertFalse(release.draft)
        XCTAssertFalse(release.prerelease)
        XCTAssertEqual(release.assets.count, 3)
        XCTAssertEqual(release.assets[1].size, 957311)
        XCTAssertTrue(release.isStable)
    }

    func testPicksDiskImage() throws {
        let release = try ReleaseInfo.decode(Data(json.utf8))
        XCTAssertEqual(release.diskImage?.name, "MacPowerManager-0.2.0.dmg")
        XCTAssertEqual(release.downloadURL.lastPathComponent, "MacPowerManager-0.2.0.dmg")
    }

    func testPrefersExactDiskImageNameAndFallsBackToPage() {
        let page = URL(string: "https://example.com/release")!
        func asset(_ name: String) -> ReleaseInfo.Asset {
            .init(name: name, downloadURL: URL(string: "https://example.com/\(name)")!, size: 1)
        }
        var release = ReleaseInfo(tagName: "v1.0.0", pageURL: page,
                                  assets: [asset("Other.DMG"), asset("MacPowerManager-1.0.0.dmg")])
        XCTAssertEqual(release.diskImage?.name, "MacPowerManager-1.0.0.dmg")
        release.assets = [asset("Other.DMG"), asset("notes.txt")]
        XCTAssertEqual(release.diskImage?.name, "Other.DMG", "Không có tên chuẩn thì lấy .dmg đầu tiên")
        release.assets = [asset("MacPowerManager-1.0.0.zip")]
        XCTAssertNil(release.diskImage)
        XCTAssertEqual(release.downloadURL, page, "Không có .dmg thì mở trang release")
    }

    func testToleratesNullsAndMissingFields() throws {
        let minimal = #"""
        {"tag_name": "v1.0.0", "html_url": "https://example.com/r", "name": null, "body": null, "published_at": null}
        """#
        let release = try ReleaseInfo.decode(Data(minimal.utf8))
        XCTAssertNil(release.name)
        XCTAssertNil(release.publishedAt)
        XCTAssertEqual(release.notes, "")
        XCTAssertEqual(release.assets, [])
        XCTAssertTrue(release.isStable)

        let fractional = #"{"tag_name": "v1.0.0", "html_url": "https://example.com/r", "published_at": "2026-10-07T15:34:34.250Z"}"#
        XCTAssertNotNil(try ReleaseInfo.decode(Data(fractional.utf8)).publishedAt)
    }

    func testRejectsInvalidJSON() {
        XCTAssertThrowsError(try ReleaseInfo.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try ReleaseInfo.decode(Data(#"{"message": "Not Found"}"#.utf8)))
        XCTAssertThrowsError(try ReleaseInfo.decode(Data("<html>".utf8)))
    }

    func testReleaseNotesStripFooter() throws {
        let release = try ReleaseInfo.decode(Data(json.utf8))
        XCTAssertEqual(release.notes, "### Tính năng\n- **Intel** (thử nghiệm)\n\n### Sửa lỗi\n- Một lỗi.")
    }

    func testReleaseNotesEdgeCases() {
        XCTAssertEqual(ReleaseInfo.releaseNotes(from: "- a\r\n- b\r\n---\r\nfooter"), "- a\n- b", "CRLF")
        XCTAssertEqual(ReleaseInfo.releaseNotes(from: "- a\n\n"), "- a", "Không có phần chân")
        XCTAssertEqual(ReleaseInfo.releaseNotes(from: "---\nchỉ có chân"), "")
        XCTAssertEqual(ReleaseInfo.releaseNotes(from: "- a\n----\n- b\n---\nchân"), "- a\n----\n- b",
                       "Chỉ dòng đúng ba gạch mới là phần chân")
        XCTAssertEqual(ReleaseInfo.releaseNotes(from: "- a --- b\n---  \nchân"), "- a --- b")
    }

    func testIsNewerIgnoresDraftsAndPrereleases() {
        let page = URL(string: "https://example.com")!
        XCTAssertTrue(ReleaseInfo(tagName: "v0.3.0", pageURL: page).isNewer(than: "0.2.0"))
        XCTAssertTrue(ReleaseInfo(tagName: "v0.3.0", pageURL: page).isNewer(than: "0.3.0-dev"))
        XCTAssertFalse(ReleaseInfo(tagName: "v0.3.0", pageURL: page).isNewer(than: "0.3.0"))
        XCTAssertFalse(ReleaseInfo(tagName: "v0.2.0", pageURL: page).isNewer(than: "0.3.0-dev"))
        XCTAssertFalse(ReleaseInfo(tagName: "v0.4.0", pageURL: page, draft: true).isNewer(than: "0.3.0"))
        XCTAssertFalse(ReleaseInfo(tagName: "v0.4.0", pageURL: page, prerelease: true).isNewer(than: "0.3.0"))
        XCTAssertFalse(ReleaseInfo(tagName: "v0.4.0-beta.1", pageURL: page).isNewer(than: "0.3.0"),
                       "Tag có hậu tố pre-release cũng bị bỏ qua")
        XCTAssertFalse(ReleaseInfo(tagName: "nightly", pageURL: page).isNewer(than: "0.3.0"))
    }
}

final class UpdatePolicyTests: XCTestCase {
    private let release = ReleaseInfo(tagName: "v0.3.0", pageURL: URL(string: "https://example.com")!)
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func announce(current: String = "0.2.0", skipped: String? = nil, snoozed: String? = nil,
                          until: Date? = nil) -> Bool {
        UpdatePolicy.shouldAnnounce(release, current: current, skippedVersion: skipped, snoozedVersion: snoozed,
                                    snoozedUntil: until, now: now)
    }

    func testAnnouncesNewerVersion() {
        XCTAssertTrue(announce())
        XCTAssertTrue(announce(current: "0.3.0-dev"))
        XCTAssertFalse(announce(current: "0.3.0"))
        XCTAssertFalse(announce(current: "0.4.0"))
    }

    func testSkippedVersion() {
        XCTAssertFalse(announce(skipped: "0.3.0"))
        XCTAssertFalse(announce(skipped: "v0.3.0"))
        XCTAssertTrue(announce(skipped: "0.2.5"), "Bỏ qua bản cũ không ảnh hưởng bản mới hơn")
    }

    func testRemindLater() {
        XCTAssertFalse(announce(snoozed: "0.3.0", until: now.addingTimeInterval(60)))
        XCTAssertTrue(announce(snoozed: "0.3.0", until: now.addingTimeInterval(-1)), "Hết 24 giờ thì nhắc lại")
        XCTAssertTrue(announce(snoozed: "0.2.9", until: now.addingTimeInterval(60)), "Để sau chỉ áp dụng cho đúng bản đó")
    }

    func testIsDue() {
        XCTAssertTrue(UpdatePolicy.isDue(lastAttempt: nil, lastFailed: false, now: now))
        XCTAssertFalse(UpdatePolicy.isDue(lastAttempt: now.addingTimeInterval(-23 * 3600), lastFailed: false, now: now))
        XCTAssertTrue(UpdatePolicy.isDue(lastAttempt: now.addingTimeInterval(-24 * 3600), lastFailed: false, now: now))
        XCTAssertTrue(UpdatePolicy.isDue(lastAttempt: now.addingTimeInterval(-3600), lastFailed: true, now: now),
                      "Lỗi thì thử lại sau 1 giờ")
        XCTAssertTrue(UpdatePolicy.isDue(lastAttempt: now.addingTimeInterval(3600), lastFailed: false, now: now),
                      "Đồng hồ bị lùi")
    }
}

final class ReleaseNoteBlockTests: XCTestCase {
    func testParsesChangelogSection() {
        let markdown = """
        ### Tính năng
        - **Điều khiển sạc trên máy Intel (thử nghiệm)** qua key `BCLM`:
          giới hạn sạc 50–100%.
        - Mục hai
          - Mục con

        ### Sửa lỗi
        1. Lỗi một
        2. Lỗi hai
        > Lưu ý
        > dòng hai

        Đoạn văn
        nối tiếp.
        """
        XCTAssertEqual(ReleaseNoteBlock.parse(markdown), [
            .heading(level: 3, text: "Tính năng"),
            .bullet(depth: 0, text: "**Điều khiển sạc trên máy Intel (thử nghiệm)** qua key `BCLM`: giới hạn sạc 50–100%."),
            .bullet(depth: 0, text: "Mục hai"),
            .bullet(depth: 1, text: "Mục con"),
            .heading(level: 3, text: "Sửa lỗi"),
            .numbered(number: 1, text: "Lỗi một"),
            .numbered(number: 2, text: "Lỗi hai"),
            .quote("Lưu ý dòng hai"),
            .paragraph("Đoạn văn nối tiếp."),
        ])
    }

    func testBoldTextIsNotABullet() {
        XCTAssertEqual(ReleaseNoteBlock.parse("**Gỡ cài đặt:** vào app"), [.paragraph("**Gỡ cài đặt:** vào app")])
        XCTAssertEqual(ReleaseNoteBlock.parse("* sao"), [.bullet(depth: 0, text: "sao")])
        XCTAssertEqual(ReleaseNoteBlock.parse("#hashtag"), [.paragraph("#hashtag")])
        XCTAssertEqual(ReleaseNoteBlock.parse(""), [])
    }
}
