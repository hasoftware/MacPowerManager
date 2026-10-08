import Foundation
import PowerCore
import XCTest
@testable import MacPowerManager

/// Máy chủ giả: trả lần lượt các phản hồi đã định và ghi lại các request.
private final class FakeGitHub: @unchecked Sendable {
    enum Reply {
        case status(Int, body: String = "", etag: String? = nil)
        case error(URLError.Code)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    var fetch: UpdateChecker.Fetch {
        { [self] request in
            let reply: Reply = lock.withLock {
                requests.append(request)
                return replies.isEmpty ? .error(.notConnectedToInternet) : replies.removeFirst()
            }
            switch reply {
            case .error(let code):
                throw URLError(code)
            case .status(let code, let body, let etag):
                var headers: [String: String] = [:]
                if let etag { headers["ETag"] = etag }
                let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                               headerFields: headers)!
                return (Data(body.utf8), response)
            }
        }
    }
}

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "UpdateCheckerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func releaseJSON(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> String {
        """
        {"tag_name": "\(tag)", "name": "MacPowerManager \(tag)", "draft": \(draft), "prerelease": \(prerelease),
         "html_url": "https://github.com/hasoftware/MacPowerManager/releases/tag/\(tag)",
         "published_at": "2026-10-10T08:00:00Z",
         "body": "### Tính năng\\n- Mới\\n\\n---\\nCài đặt",
         "assets": [{"name": "MacPowerManager-\(tag.dropFirst()).dmg", "size": 1000,
                     "browser_download_url": "https://example.com/MacPowerManager-\(tag.dropFirst()).dmg"}]}
        """
    }

    private func checker(_ server: FakeGitHub, current: String = "0.2.0") -> UpdateChecker {
        UpdateChecker(currentVersion: current, defaults: defaults, fetch: server.fetch)
    }

    func testFindsNewerReleaseAndSendsHeaders() async throws {
        let server = FakeGitHub([.status(200, body: releaseJSON("v0.3.0"), etag: "\"abc\"")])
        let updates = checker(server)
        var announced: [(String, Bool)] = []
        updates.onAnnounce = { release, manual in announced.append((release.tagName, manual)) }

        await updates.check(manual: false)

        guard case .available(let release) = updates.state else { return XCTFail("\(updates.state)") }
        XCTAssertEqual(release.tagName, "v0.3.0")
        XCTAssertEqual(updates.announcement?.tagName, "v0.3.0")
        XCTAssertEqual(announced.map(\.0), ["v0.3.0"])
        XCTAssertEqual(announced.first?.1, false)
        XCTAssertNotNil(updates.lastChecked)

        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.url, UpdateChecker.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("MacPowerManager/0.2.0") ?? false)
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"), "Chưa có bản lưu thì không gửi ETag")
    }

    func testDevBuildSeesReleaseOfSameVersion() async {
        let updates = checker(FakeGitHub([.status(200, body: releaseJSON("v0.3.0"))]), current: "0.3.0-dev")
        await updates.check(manual: true)
        XCTAssertEqual(updates.available?.tagName, "v0.3.0")
    }

    func testUpToDate() async {
        let updates = checker(FakeGitHub([.status(200, body: releaseJSON("v0.2.0"))]))
        await updates.check(manual: true)
        XCTAssertEqual(updates.state, .upToDate)
        XCTAssertNil(updates.announcement)
    }

    func testNoReleaseYetIsUpToDate() async {
        let updates = checker(FakeGitHub([.status(404, body: #"{"message": "Not Found"}"#)]))
        await updates.check(manual: true)
        XCTAssertEqual(updates.state, .upToDate)
    }

    func testIgnoresDraftAndPrerelease() async {
        let updates = checker(FakeGitHub([.status(200, body: releaseJSON("v0.4.0", prerelease: true)),
                                          .status(200, body: releaseJSON("v0.4.0", draft: true))]))
        await updates.check(manual: true)
        XCTAssertEqual(updates.state, .upToDate)
        await updates.check(manual: true)
        XCTAssertEqual(updates.state, .upToDate)
    }

    func testNotModifiedUsesCachedRelease() async throws {
        let server = FakeGitHub([.status(200, body: releaseJSON("v0.3.0"), etag: "W/\"v1\""), .status(304)])
        await checker(server).check(manual: false)

        // Lần mở app sau: dùng ETag đã lưu, GitHub trả 304 và app dùng bản đã lưu.
        let updates = checker(server)
        await updates.check(manual: false)
        XCTAssertEqual(server.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "W/\"v1\"")
        XCTAssertEqual(updates.available?.tagName, "v0.3.0")
    }

    func testBackgroundFailureIsSilentManualFailureShowsMessage() async {
        let server = FakeGitHub([.status(200, body: releaseJSON("v0.3.0")), .error(.notConnectedToInternet),
                                 .status(403), .status(500), .status(200, body: "<html>")])
        let updates = checker(server)
        await updates.check(manual: false)
        XCTAssertNotNil(updates.available)

        await updates.check(manual: false)
        guard case .available = updates.state else { return XCTFail("Lỗi nền không đổi trạng thái: \(updates.state)") }

        await updates.check(manual: true)
        XCTAssertEqual(updates.state, .failed(UpdateChecker.message(for: UpdateChecker.CheckError.rateLimited)))
        XCTAssertEqual(updates.available?.tagName, "v0.3.0", "Lỗi không làm mất bản mới đã tìm thấy")

        await updates.check(manual: true)
        XCTAssertEqual(updates.state, .failed(UpdateChecker.message(for: UpdateChecker.CheckError.http(500))))

        await updates.check(manual: true)
        XCTAssertEqual(updates.state, .failed(UpdateChecker.message(for: UpdateChecker.CheckError.invalidResponse)))
    }

    func testFreshBackgroundFailureStaysIdle() async {
        let updates = checker(FakeGitHub([.error(.timedOut)]))
        await updates.check(manual: false)
        XCTAssertEqual(updates.state, .idle)
    }

    func testSkipAndRemindLaterArePersistedPerVersion() async {
        let server = FakeGitHub([.status(200, body: releaseJSON("v0.3.0")), .status(200, body: releaseJSON("v0.3.1"))])
        let updates = checker(server)
        await updates.check(manual: false)
        let release = updates.available!

        updates.remindLater(release, now: Date())
        XCTAssertNil(updates.announcement, "Để sau: ẩn banner")
        XCTAssertNotNil(updates.available, "Trang Giới thiệu vẫn thấy bản mới")
        XCTAssertEqual(checker(server).snoozedVersion, "0.3.0")

        updates.remindLater(release, now: Date().addingTimeInterval(-25 * 3600))
        XCTAssertNotNil(updates.announcement, "Hết 24 giờ thì nhắc lại")

        updates.skip(release)
        XCTAssertNil(updates.announcement)
        XCTAssertEqual(checker(server).skippedVersion, "0.3.0", "Lưu qua các lần mở app")

        var announced: [String] = []
        updates.onAnnounce = { release, _ in announced.append(release.tagName) }
        await updates.check(manual: false)
        XCTAssertEqual(updates.announcement?.tagName, "v0.3.1", "Bỏ qua 0.3.0 không ảnh hưởng 0.3.1")
        XCTAssertEqual(announced, ["v0.3.1"])
    }
}

@MainActor
final class UpdateNotificationTests: XCTestCase {
    func testNotifiesOncePerVersion() {
        let suite = "UpdateNotificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var posted: [String] = []
        let notifier = Notifier(defaults: defaults) { id, _, _ in posted.append(id) }
        let page = URL(string: "https://example.com")!
        let prefs = Preferences()

        notifier.updateAvailable(ReleaseInfo(tagName: "v0.3.0", pageURL: page), prefs: prefs)
        notifier.updateAvailable(ReleaseInfo(tagName: "v0.3.0", pageURL: page), prefs: prefs)
        XCTAssertEqual(posted, [Notifier.updateNotificationID])

        // Mở lại app: vẫn không báo lại.
        Notifier(defaults: defaults) { id, _, _ in posted.append(id) }
            .updateAvailable(ReleaseInfo(tagName: "v0.3.0", pageURL: page), prefs: prefs)
        XCTAssertEqual(posted.count, 1)

        // Người dùng tự kiểm tra: không gửi thông báo nhưng ghi nhận đã báo.
        notifier.updateAvailable(ReleaseInfo(tagName: "v0.3.1", pageURL: page), prefs: prefs, post: false)
        notifier.updateAvailable(ReleaseInfo(tagName: "v0.3.1", pageURL: page), prefs: prefs)
        XCTAssertEqual(posted.count, 1)

        var off = prefs
        off.notifyUpdate = false
        notifier.updateAvailable(ReleaseInfo(tagName: "v0.4.0", pageURL: page), prefs: off)
        XCTAssertEqual(posted.count, 1, "Tắt trong trang Thông báo")
    }
}
