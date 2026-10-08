import AppKit
import Foundation
import Observation
import PowerCore

/// Kiểm tra bản phát hành mới trên GitHub. Đây là yêu cầu mạng duy nhất của app: một lệnh GET tới
/// api.github.com (không kèm dữ liệu cá nhân), lúc mở app và mỗi 24 giờ, tắt được trong trang Giới thiệu.
@MainActor
@Observable
final class UpdateChecker {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case failed(String)
    }

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let endpoint = URL(string: "https://api.github.com/repos/hasoftware/MacPowerManager/releases/latest")!
    /// Chờ một chút sau khi mở app để không tranh tài nguyên lúc khởi động.
    static let launchDelay: Duration = .seconds(8)

    private(set) var state: State = .idle
    /// Bản ổn định mới nhất trên GitHub (kể cả khi không mới hơn bản đang chạy).
    private(set) var latest: ReleaseInfo?
    private(set) var lastChecked: Date?
    private(set) var skippedVersion: String?
    private(set) var snoozedVersion: String?
    private(set) var snoozedUntil: Date?

    /// Gọi khi lần kiểm tra tìm thấy bản cần nhắc (`manual`: người dùng bấm kiểm tra).
    @ObservationIgnored var onAnnounce: ((ReleaseInfo, _ manual: Bool) -> Void)?

    @ObservationIgnored let currentVersion: String
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var automatic = false
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var lastFailed = false
    @ObservationIgnored private var running: Task<Void, Never>?

    private enum Key {
        static let etag = "update.etag"
        static let cachedResponse = "update.cachedResponse"
        static let lastChecked = "update.lastChecked"
        static let skippedVersion = "update.skippedVersion"
        static let snoozedVersion = "update.snoozedVersion"
        static let snoozedUntil = "update.snoozedUntil"
    }

    /// - defaults: nil thì không đọc/ghi gì (dữ liệu giả cho chụp giao diện).
    init(currentVersion: String = AppVersion.current, defaults: UserDefaults? = .standard,
         fetch: @escaping Fetch = UpdateChecker.urlSessionFetch) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.fetch = fetch
        if let defaults {
            skippedVersion = defaults.string(forKey: Key.skippedVersion)
            snoozedVersion = defaults.string(forKey: Key.snoozedVersion)
            snoozedUntil = defaults.object(forKey: Key.snoozedUntil) as? Date
            lastChecked = defaults.object(forKey: Key.lastChecked) as? Date
            // Bản đã biết từ lần kiểm tra trước: banner, trang Giới thiệu và Có gì mới dùng được ngay khi mở app
            // (kể cả khi offline), không phải chờ lần kiểm tra đầu tiên.
            if let data = defaults.data(forKey: Key.cachedResponse),
               let release = try? ReleaseInfo.decode(data), release.isStable {
                latest = release
            }
        }
    }

    // MARK: Trạng thái suy ra

    /// Bản mới hơn bản đang chạy (cửa sổ Có gì mới, trang Giới thiệu; kể cả khi đã bỏ qua). Giữ nguyên khi lần
    /// kiểm tra sau bị lỗi.
    var available: ReleaseInfo? {
        guard let latest, latest.isNewer(than: currentVersion) else { return nil }
        return latest
    }

    /// Bản cần nhắc bằng banner: mới hơn, chưa bị bỏ qua và không trong thời gian "Để sau".
    var announcement: ReleaseInfo? {
        guard let release = available else { return nil }
        return shouldAnnounce(release, now: Date()) ? release : nil
    }

    private func shouldAnnounce(_ release: ReleaseInfo, now: Date) -> Bool {
        UpdatePolicy.shouldAnnounce(release, current: currentVersion, skippedVersion: skippedVersion,
                                    snoozedVersion: snoozedVersion, snoozedUntil: snoozedUntil, now: now)
    }

    // MARK: Lịch kiểm tra

    /// Bật/tắt tự kiểm tra: lần đầu sau `launchDelay`, rồi mỗi 24 giờ (thử lại sau 1 giờ nếu lỗi).
    /// Đồng hồ chạy mỗi giờ và so với thời điểm thật, vì Timer không đếm thời gian máy ngủ.
    func setAutomatic(_ enabled: Bool) {
        guard enabled != automatic else { return }
        automatic = enabled
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.launchDelay)
            guard let self, self.automatic else { return }
            await self.checkIfDue()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
    }

    private func checkIfDue() async {
        guard automatic, UpdatePolicy.isDue(lastAttempt: lastAttempt, lastFailed: lastFailed, now: Date()) else { return }
        await check(manual: false)
    }

    // MARK: Kiểm tra

    /// Người dùng bấm "Kiểm tra cập nhật": hiện lỗi nếu có.
    func checkNow() async {
        await check(manual: true)
    }

    func check(manual: Bool) async {
        if let running {
            // Đang chạy nền mà người dùng bấm kiểm tra: chờ lần đó xong rồi kiểm tra lại để hiện lỗi (nếu có).
            await running.value
            if !manual { return }
        }
        let task = Task { await perform(manual: manual) }
        running = task
        await task.value
        running = nil
    }

    private func perform(manual: Bool) async {
        let previous = state
        state = .checking
        lastAttempt = Date()
        do {
            let release = try await fetchLatest()
            lastFailed = false
            lastChecked = Date()
            defaults?.set(lastChecked, forKey: Key.lastChecked)
            latest = release
            if let release, release.isNewer(than: currentVersion) {
                state = .available(release)
                if shouldAnnounce(release, now: Date()) { onAnnounce?(release, manual) }
            } else {
                state = .upToDate
            }
        } catch {
            lastFailed = true
            // Kiểm tra nền thất bại thì im lặng: giữ trạng thái trước đó (không hiện lỗi mạng tự phát).
            if manual {
                state = .failed(Self.message(for: error))
            } else {
                state = previous == .checking ? .idle : previous
            }
        }
    }

    enum CheckError: Error, Equatable {
        case http(Int)
        case rateLimited
        case invalidResponse
    }

    /// Bản phát hành mới nhất, nil khi repo chưa có bản ổn định nào (404) hoặc bản mới nhất không phải SemVer.
    private func fetchLatest() async throws -> ReleaseInfo? {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("MacPowerManager/\(currentVersion) (+https://github.com/hasoftware/MacPowerManager)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let cached = defaults?.data(forKey: Key.cachedResponse)
        if cached != nil, let etag = defaults?.string(forKey: Key.etag) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse else { throw CheckError.invalidResponse }
        let body: Data
        switch http.statusCode {
        case 200:
            body = data
            if let etag = http.value(forHTTPHeaderField: "ETag") {
                defaults?.set(etag, forKey: Key.etag)
                defaults?.set(data, forKey: Key.cachedResponse)
            }
        case 304:
            guard let cached else { throw CheckError.invalidResponse }
            body = cached
        case 404:
            return nil
        case 403, 429:
            throw CheckError.rateLimited
        default:
            throw CheckError.http(http.statusCode)
        }
        do {
            let release = try ReleaseInfo.decode(body)
            return release.isStable ? release : nil
        } catch {
            // Dữ liệu lưu tạm hỏng: xóa để lần sau tải lại đầy đủ.
            defaults?.removeObject(forKey: Key.etag)
            defaults?.removeObject(forKey: Key.cachedResponse)
            throw CheckError.invalidResponse
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case CheckError.rateLimited:
            return String(localized: "GitHub đang tạm giới hạn số lần kiểm tra. Hãy thử lại sau.")
        case CheckError.http(let code):
            return String(localized: "GitHub trả về lỗi \(code). Hãy thử lại sau.")
        case CheckError.invalidResponse:
            return String(localized: "Không đọc được thông tin bản phát hành từ GitHub.")
        case let error as URLError where error.code == .timedOut:
            return String(localized: "GitHub không phản hồi. Kiểm tra kết nối mạng rồi thử lại.")
        default:
            return String(localized: "Không kết nối được tới GitHub. Kiểm tra kết nối mạng rồi thử lại.")
        }
    }

    // MARK: Lựa chọn của người dùng

    /// "Bỏ qua bản này": không nhắc bản này nữa (bản mới hơn vẫn được nhắc).
    func skip(_ release: ReleaseInfo) {
        guard let version = release.version?.description else { return }
        skippedVersion = version
        defaults?.set(version, forKey: Key.skippedVersion)
    }

    /// "Để sau": ẩn banner của bản này trong 24 giờ.
    func remindLater(_ release: ReleaseInfo, now: Date = Date()) {
        guard let version = release.version?.description else { return }
        snoozedVersion = version
        snoozedUntil = now.addingTimeInterval(UpdatePolicy.remindLaterInterval)
        defaults?.set(version, forKey: Key.snoozedVersion)
        defaults?.set(snoozedUntil, forKey: Key.snoozedUntil)
    }

    func download(_ release: ReleaseInfo) {
        NSWorkspace.shared.open(release.downloadURL)
    }

    func openReleasePage(_ release: ReleaseInfo) {
        NSWorkspace.shared.open(release.pageURL)
    }

    // MARK: Mạng

    nonisolated static let urlSessionFetch: Fetch = { request in
        try await session.data(for: request)
    }

    /// Không dùng URLCache: app tự gửi If-None-Match để nhận 304 và dùng bản đã lưu.
    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    #if DEBUG
    /// Dữ liệu giả cho chế độ chụp giao diện.
    func setPreview(state: State, latest: ReleaseInfo? = nil) {
        self.state = state
        if case .available(let release) = state {
            self.latest = release
        } else {
            self.latest = latest
        }
        lastChecked = Date().addingTimeInterval(-25 * 60)
    }
    #endif
}
