import Foundation

/// Vì sao một mục bị đánh dấu (thay cho `F_DETAIL`). CleanCore không chứa chuỗi giao diện:
/// UI dịch từng case (VI/EN lấy từ `_i18n_vi` / `_i18n_en` của MacTrash, khóa zsh ghi ở comment).
public enum CleanReason: Sendable, Codable, Hashable {
    // MARK: Tàn dư mồ côi
    /// DOrphanBid: bundle id (đã cắt Team ID / `group.`) không thuộc app nào đang cài.
    case orphanBundleID(String)
    /// DOrphanName: không có app hay lệnh nào tên này; `days` = số ngày từ lần sửa cuối.
    case orphanName(String, days: Int)

    // MARK: PATH / biến môi trường
    /// DEmptyPath: mục PATH rỗng (thừa dấu `:`).
    case emptyPathEntry
    /// DDupPath: trùng với mục #firstIndex.
    case duplicatePathEntry(firstIndex: Int)
    /// DDeadDir: thư mục không tồn tại; `source` = file khai báo nếu tìm được.
    case deadPathDir(source: String?)
    /// DEnvDead: biến `name` trỏ tới đường dẫn không tồn tại; `file` = file khai báo nếu có.
    case envVarDead(name: String, file: String?)

    // MARK: Khởi động / helper / gói
    /// DMissingProg: chương trình của job launchd không tồn tại.
    case missingProgram(String)
    /// DOwnerGone: ứng dụng chủ đã bị gỡ.
    case ownerGone(String)
    /// DLoginItemDead
    case loginItemDead
    /// DNeedSudoBtm: cần quyền quản trị để đọc `sfltool dumpbtm`.
    case needRootForBackgroundTasks
    /// DHelperOrphan
    case helperOrphan
    /// DHelperNoJob
    case helperNoJob
    /// DReceiptOrph
    case receiptOrphan
    /// DDockerGone
    case dockerGone

    // MARK: Bảo mật / hệ thống
    /// DDyldInject: `location` là basename plist hoặc đường dẫn file shell.
    case dyldInsert(location: String)
    /// DSudoers
    case thirdPartySudoers(file: String)
    /// DCertProxy: `tool` là tên trong danh sách nghi vấn.
    case proxyRootCertificate(tool: String)
    /// DFirewallDead
    case firewallRuleDead
    /// DTccOrphan
    case tccOrphan(service: String)
    /// DSysExtStale
    case sysExtStale(state: String)
    /// DKextOrphan
    case kextOrphan

    // MARK: Symlink / LaunchServices / plugin / app
    /// DBrokenLink: đích hoặc `?`.
    case brokenSymlink(destination: String)
    /// DGhostLS
    case ghostLaunchServices(count: Int)
    /// DNativeDead
    case nativeHostDead(executable: String)
    /// DPluginBroken
    case bundleBroken(executable: String)
    /// DPluginOrphan
    case pluginOrphan(owner: String)
    /// DHollowApp: không có Info.plist.
    case hollowApp
    /// DBrokenApp: có Info.plist nhưng thiếu file thực thi.
    case brokenApp(executable: String)

    // MARK: P1-P3 (khai báo sẵn để model ổn định)
    /// DTrashUse
    case trashUsage(bytes: Int64)
    case appBundle
    case appRelated(name: String)
    case xcodeDerived
    case xcodeDeviceSupport(version: String)
    case xcodeArchive
    case simulatorUnavailable
    case cacheOrphan(command: String)
    case cacheActive(command: String)
    case brewOrphan
    case brewCache
    case snapshot(date: String)
    case mobileSyncBackup(date: String)
    case hostsBlock(domain: String)
}
