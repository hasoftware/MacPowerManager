import AppKit
import CleanCore
import SwiftUI

/// Chữ giao diện cho CleanCore (lõi không có chuỗi giao diện). Câu VI/EN theo bảng lý do trong docs/mactrash/spec-*.md.
enum CleanupText {
    // MARK: Tên, đường dẫn

    /// Tên hiển thị: tên trong finding là dữ liệu (nằm trong ID), vài tên cố định được dịch.
    static func displayName(_ f: Finding) -> String {
        switch f.reason {
        case .ghostLaunchServices: return "LaunchServices"
        default: break
        }
        if f.name == FindingLiteral.trashName { return String(localized: "Thùng rác") }
        return f.name
    }

    static func displayTarget(_ f: Finding) -> String {
        if f.target == FindingLiteral.emptyPathTarget { return String(localized: "<rỗng>") }
        return f.target
    }

    /// Đường dẫn để hiện trong Finder / sao chép: file cấu hình với mục PATH/biến môi trường, plist với job launchd.
    static func filePath(_ f: Finding) -> String? {
        let p: String
        switch f.action {
        case .trashPath(let x), .symlink(let x), .purgeAny(let x), .purgeTrash(let x), .firewallApp(let x):
            p = x.isEmpty ? f.target : x
        case .pathEntry(let file, _), .envLine(let file, _): p = file
        case .launchdJob(let plist, _, _): p = plist
        default: p = f.target
        }
        return p.hasPrefix("/") ? p : nil
    }

    // MARK: Mức độ

    static func severity(_ s: Severity) -> String {
        switch s {
        // khóa riêng: "Cao"/"Vừa" đã dùng cho áp lực bộ nhớ, tải CPU (bản dịch khác)
        case .high: String(localized: "Cao (mức độ dọn dẹp)", defaultValue: "Cao")
        case .medium: String(localized: "Vừa (mức độ dọn dẹp)", defaultValue: "Vừa")
        case .info: String(localized: "Thông tin (mức độ dọn dẹp)", defaultValue: "Thông tin")
        }
    }

    static func severityTint(_ s: Severity) -> Color {
        switch s {
        case .high: .red
        case .medium: .orange
        case .info: .blue
        }
    }

    static func severityFilter(_ f: CleanupModel.SeverityFilter) -> String {
        switch f {
        case .all: String(localized: "Tất cả")
        case .high: severity(.high)
        case .medium: severity(.medium)
        case .info: severity(.info)
        }
    }

    // MARK: Nhóm

    static func category(_ c: CleanCategory) -> String {
        switch c {
        case .path: "PATH"
        case .envVar: String(localized: "Biến môi trường")
        case .appSupport: "Application Support"
        case .caches: String(localized: "Bộ nhớ đệm")
        case .prefs: String(localized: "Tùy chọn (plist)")
        case .containers: String(localized: "Container")
        case .groupContainer: "Group Container"
        case .savedState: String(localized: "Trạng thái cửa sổ đã lưu")
        case .httpStorage: "HTTPStorages"
        case .webKit: String(localized: "Dữ liệu WebKit")
        case .appScripts: "Application Scripts"
        case .cookies: "Cookies"
        case .logs: String(localized: "Nhật ký")
        case .launchAgent: String(localized: "LaunchAgent / LaunchDaemon")
        case .loginItem: String(localized: "Mục khởi động")
        case .helper: String(localized: "Helper đặc quyền")
        case .receipt: String(localized: "Biên nhận gói cài")
        case .security: String(localized: "Bảo mật")
        case .firewall: String(localized: "Tường lửa")
        case .tcc: String(localized: "Quyền riêng tư")
        case .sysExt: String(localized: "System extension")
        case .symlink: String(localized: "Symlink gãy")
        case .launchServices: "LaunchServices"
        case .nativeMsg: "Native messaging"
        case .plugin: String(localized: "Plugin")
        case .app: String(localized: "Ứng dụng hỏng")
        case .docker: "Docker"
        case .xcode: "Xcode"
        case .devCache: String(localized: "Bộ nhớ đệm lập trình")
        case .homebrew: "Homebrew"
        case .backup: String(localized: "Bản sao lưu")
        case .snapshot: String(localized: "Snapshot")
        case .trash: String(localized: "Thùng rác")
        case .appFiles: String(localized: "File của ứng dụng")
        case .disk: String(localized: "Ổ đĩa")
        }
    }

    static func categorySymbol(_ c: CleanCategory) -> String {
        switch c {
        case .path, .envVar: "terminal"
        case .appSupport, .containers, .groupContainer, .appScripts, .appFiles: "folder"
        case .caches, .devCache: "archivebox"
        case .prefs: "slider.horizontal.3"
        case .savedState: "macwindow"
        case .httpStorage, .webKit, .cookies: "globe"
        case .logs: "doc.text"
        case .launchAgent: "gearshape.2"
        case .loginItem: "power"
        case .helper: "lock.shield"
        case .receipt: "shippingbox"
        case .security: "exclamationmark.shield"
        case .firewall: "flame"
        case .tcc: "hand.raised"
        case .sysExt: "puzzlepiece.extension"
        case .symlink: "link"
        case .launchServices: "square.stack.3d.up"
        case .nativeMsg: "message"
        case .plugin: "puzzlepiece"
        case .app: "app.dashed"
        case .docker: "shippingbox.fill"
        case .xcode: "hammer"
        case .homebrew: "mug"
        case .backup: "externaldrive"
        case .snapshot: "clock.arrow.circlepath"
        case .trash: "trash"
        case .disk: "internaldrive"
        }
    }

    // MARK: Lý do

    static func reason(_ r: CleanReason) -> String {
        switch r {
        case .orphanBundleID(let bid):
            return String(localized: "Bundle id \"\(bid)\" không thuộc ứng dụng nào đang cài")
        case .orphanName(let name, let days):
            return String(localized: "Không có ứng dụng hay lệnh nào tên \"\(name)\" (sửa lần cuối \(days) ngày trước)")
        case .emptyPathEntry:
            return String(localized: "Mục rỗng (thừa dấu :)")
        case .duplicatePathEntry(let first):
            return String(localized: "Trùng lặp với mục #\(first)")
        case .deadPathDir(let source):
            if let source { return String(localized: "Thư mục không tồn tại → \(source)") }
            return String(localized: "Thư mục không tồn tại")
        case .envVarDead(let name, let file):
            if let file { return String(localized: "\(name) trỏ tới đường dẫn không tồn tại (\(file))") }
            return String(localized: "\(name) trỏ tới đường dẫn không tồn tại")
        case .missingProgram(let p):
            return String(localized: "Chương trình không tồn tại: \(p)")
        case .ownerGone(let x):
            return String(localized: "Ứng dụng chủ đã bị gỡ: \(x)")
        case .loginItemDead:
            return String(localized: "Mục khởi động trỏ tới đường dẫn không tồn tại")
        case .needRootForBackgroundTasks:
            return String(localized: "Cần sudo để đọc danh sách mục khởi động nền (sfltool dumpbtm)")
        case .helperOrphan:
            return String(localized: "Helper chạy quyền root còn sót của phần mềm đã gỡ")
        case .helperNoJob:
            return String(localized: "Helper root không còn LaunchDaemon nào tham chiếu")
        case .receiptOrphan:
            return String(localized: "Biên nhận gói cài của phần mềm đã gỡ (không còn file nào tồn tại)")
        case .dockerGone:
            return String(localized: "Docker Desktop đã gỡ nhưng dữ liệu còn lại")
        case .dyldInsert(let location):
            return String(localized: "DYLD_INSERT_LIBRARIES trong \(location) - kỹ thuật chèn thư viện, hãy kiểm tra")
        case .thirdPartySudoers(let file):
            return String(localized: "File sudoers thêm ngoài: \(file) - CHỈ BÁO, tự đọc và quyết định")
        case .proxyRootCertificate(let tool):
            return String(localized: "Chứng chỉ gốc của công cụ proxy: \(tool) - CHỈ BÁO, tự xóa trong Keychain Access")
        case .firewallRuleDead:
            return String(localized: "Luật tường lửa trỏ tới file không tồn tại")
        case .tccOrphan(let service):
            return String(localized: "Quyền riêng tư \"\(service)\" còn cấp cho app đã gỡ")
        case .sysExtStale(let state):
            return String(localized: "System extension treo ở trạng thái: \(state)")
        case .kextOrphan:
            return String(localized: "Kernel extension của phần mềm đã gỡ")
        case .brokenSymlink(let dest):
            return String(localized: "Symlink gãy, trỏ tới: \(dest)")
        case .ghostLaunchServices(let count):
            return String(localized: "LaunchServices còn \(count) bản ghi trỏ tới app đã xóa (gây trùng menu \"Open With\")")
        case .nativeHostDead(let exe):
            return String(localized: "Native messaging host trỏ tới file không tồn tại: \(exe)")
        case .bundleBroken(let exe):
            return String(localized: "Bundle hỏng: thiếu file thực thi \(exe)")
        case .pluginOrphan(let owner):
            return String(localized: "Plugin của phần mềm đã gỡ (\(owner))")
        case .hollowApp:
            return String(localized: "Vỏ .app rỗng: không có Info.plist lẫn file thực thi - ứng dụng đã đi, chỉ còn lại thư mục")
        case .brokenApp:
            return String(localized: "Ứng dụng hỏng: thiếu file thực thi")
        // P1–P3
        case .trashUsage(let bytes):
            let size = Format.bytes(UInt64(max(bytes, 0)))
            return String(localized: "Thùng rác đang chiếm \(size) - dùng mục \"Dọn Thùng rác\" để xem và chọn từng mục")
        case .appBundle:
            return String(localized: "Gói ứng dụng")
        case .appRelated(let name):
            return String(localized: "File liên quan tới ứng dụng \(name)")
        case .xcodeDerived:
            return String(localized: "Dữ liệu build tạm của Xcode (DerivedData), Xcode tự tạo lại khi cần")
        case .xcodeDeviceSupport(let version):
            return String(localized: "Dữ liệu hỗ trợ thiết bị iOS \(version), tải lại khi cắm thiết bị")
        case .xcodeArchive:
            return String(localized: "Bản archive của Xcode")
        case .simulatorUnavailable:
            return String(localized: "Simulator không còn dùng được (runtime đã gỡ)")
        case .cacheOrphan(let command):
            return String(localized: "Bộ nhớ đệm của \(command), lệnh này không còn được cài")
        case .cacheActive(let command):
            return String(localized: "Bộ nhớ đệm của \(command) (đang dùng, sẽ được tạo lại)")
        case .brewOrphan:
            return String(localized: "Tàn dư Homebrew không còn được dùng")
        case .brewCache:
            return String(localized: "Bộ nhớ đệm tải về của Homebrew")
        case .snapshot(let date):
            return String(localized: "Snapshot Time Machine cục bộ lúc \(date)")
        case .mobileSyncBackup(let date):
            return String(localized: "Bản sao lưu iPhone/iPad lúc \(date)")
        case .hostsBlock(let domain):
            return String(localized: "Dòng chặn \(domain) trong /etc/hosts")
        }
    }

    // MARK: Tiến độ quét

    static func scanStage(_ stage: CleanupScanStatus.Stage) -> String {
        switch stage {
        case .preparing: String(localized: "Đang đọc môi trường shell…")
        case .indexing: String(localized: "Đang lập chỉ mục ứng dụng đã cài…")
        case .finishing: String(localized: "Đang tổng hợp kết quả…")
        case .scanner(let id): String(localized: "Đang quét: \(scannerName(id))")
        }
    }

    static func scannerName(_ id: String) -> String {
        switch id {
        case "Environment": String(localized: "PATH và biến môi trường")
        case "AppSupport": "Application Support"
        case "Caches": String(localized: "Bộ nhớ đệm")
        case "Prefs": String(localized: "Tùy chọn (plist)")
        case "Containers": String(localized: "Container")
        case "SavedState": String(localized: "Trạng thái cửa sổ đã lưu")
        case "LibraryMisc": String(localized: "Dữ liệu web, cookie, nhật ký")
        case "LaunchAgent": String(localized: "LaunchAgent / LaunchDaemon")
        case "LoginItem": String(localized: "Mục khởi động")
        case "Helper": String(localized: "Helper đặc quyền")
        case "Receipt": String(localized: "Biên nhận gói cài")
        case "Security.Dyld": "DYLD_INSERT_LIBRARIES"
        case "Security.Certs": String(localized: "Chứng chỉ")
        case "Firewall": String(localized: "Tường lửa")
        case "TCC": String(localized: "Quyền riêng tư")
        case "SysExt": String(localized: "System extension")
        case "Symlink": String(localized: "Symlink gãy")
        case "LaunchServices": "LaunchServices"
        case "NativeMsg": "Native messaging"
        case "Plugin": String(localized: "Plugin")
        case "App": String(localized: "Ứng dụng hỏng")
        case "Docker": "Docker"
        default: id
        }
    }

    // MARK: Việc sẽ làm (bảng xác nhận)

    /// Mô tả đúng việc sẽ làm với một mục.
    static func plannedAction(_ f: Finding) -> String {
        switch f.action {
        case .trashPath: return String(localized: "Chuyển vào Thùng rác")
        case .symlink: return String(localized: "Chuyển symlink gãy vào Thùng rác (ghi lại đích để tạo lại được)")
        case .pathEntry(let file, _):
            if file == "/etc/paths" || file.hasPrefix("/etc/paths.d/") {
                return String(localized: "Xóa dòng khỏi \(file) (có sao lưu)")
            }
            return String(localized: "Tắt dòng khai báo trong \(file) bằng comment (có sao lưu)")
        case .envLine(let file, _): return String(localized: "Tắt dòng khai báo trong \(file) bằng comment (có sao lưu)")
        case .launchdJob(_, let label, _): return String(localized: "Dừng job \(label) và chuyển plist vào Thùng rác (có sao lưu)")
        case .tccReset(let service, _): return String(localized: "Thu hồi quyền \"\(service)\" (tccutil reset)")
        case .lsRebuild: return String(localized: "Dựng lại CSDL LaunchServices")
        default: return String(localized: "Không thực hiện")
        }
    }

    /// Mọi mục đều chỉ chuyển vào Thùng rác (job launchd: dừng job rồi chuyển plist): được gọi là "vào Thùng rác".
    static func isTrashOnly(_ findings: [Finding]) -> Bool {
        findings.allSatisfy { [.trashPath, .symlink, .launchdJob].contains($0.kind) }
    }

    /// Việc không hoàn tác tự động được (nhắc trong bảng xác nhận).
    static func undoNote(_ f: Finding) -> String? {
        switch f.action {
        case .tccReset: String(localized: "Không khôi phục tự động: app sẽ hỏi lại quyền khi chạy.")
        case .lsRebuild: String(localized: "Không cần khôi phục: macOS tự đăng ký lại các app.")
        default: nil
        }
    }

    // MARK: Kết quả gỡ

    static func statusTitle(_ s: RemovalOutcome.Status) -> String {
        switch s {
        case .done: String(localized: "Xong")
        case .partial: String(localized: "Một phần")
        case .skipped: String(localized: "Bỏ qua")
        case .needsAdmin: String(localized: "Cần quyền quản trị")
        case .failed: String(localized: "Lỗi")
        }
    }

    static func statusSymbol(_ s: RemovalOutcome.Status) -> String {
        switch s {
        case .done: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .skipped: "arrow.uturn.right.circle"
        case .needsAdmin: "lock.circle"
        case .failed: "xmark.octagon.fill"
        }
    }

    static func statusTint(_ s: RemovalOutcome.Status) -> Color {
        switch s {
        case .done: .green
        case .partial: .teal
        case .skipped: .secondary
        case .needsAdmin: .orange
        case .failed: .red
        }
    }

    /// Thông điệp kèm kết quả (nil khi không cần thêm gì).
    static func outcomeMessage(_ o: RemovalOutcome) -> String? {
        switch o {
        case .done: nil
        case .partial(.emptiedKeptFolder): String(localized: "Đã xóa sạch nội dung; thư mục rỗng do macOS giữ lại")
        case .skipped(.reportOnly): String(localized: "Chỉ báo, không tự gỡ")
        case .skipped(.coveredBy(let target)): String(localized: "Đã nằm trong mục khác được chọn: \(target)")
        case .skipped(.cancelled): String(localized: "Đã dừng trước khi tới mục này")
        case .needsAdmin: String(localized: "Không ghi được vào thư mục chứa mục này. Chạy lệnh bên dưới trong Terminal nếu muốn tự gỡ.")
        case .failed(let failure): failureMessage(failure)
        }
    }

    static func failureMessage(_ f: RemovalFailure) -> String {
        switch f {
        case .refused(let why): String(localized: "Từ chối: \(refusal(why))")
        case .trashFailed: String(localized: "Không chuyển được vào Thùng rác")
        case .stillPresent: String(localized: "Vẫn còn (đang bị khóa?)")
        case .symlinkRemoveFailed: String(localized: "Không gỡ được symlink")
        case .changedSinceScan: String(localized: "Mục đã thay đổi từ lúc quét, không đụng tới. Hãy quét lại.")
        case .backupFailed(let file): String(localized: "Không sao lưu được \(file), không đổi gì")
        case .writeFailed(let file): String(localized: "Không ghi được \(file)")
        case .lineNotFound(let file): String(localized: "Không còn dòng nào cần sửa trong \(file)")
        case .manualEditRequired(let file):
            String(localized: "Dòng này không tắt an toàn được bằng comment (khối if, nối dòng hoặc nhiều thư mục trên một dòng). Hãy tự sửa \(file). Không đổi gì.")
        case .wouldBreakShellSyntax(let file):
            String(localized: "Sửa xong thì \(file) sẽ lỗi cú pháp shell nên không ghi. Hãy tự sửa file này.")
        case .plistTrashFailed: String(localized: "Không chuyển được plist vào Thùng rác")
        case .commandFailed(let tool): String(localized: "\(tool) thất bại")
        case .stillPresentNeedsAdmin: String(localized: "Vẫn còn (thiếu quyền? cần quyền quản trị)")
        case .notInTrash: String(localized: "Từ chối: đường dẫn không nằm trong Thùng rác")
        case .unsupportedKind(let kind): String(localized: "Kiểu gỡ chưa hỗ trợ: \(kind)")
        }
    }

    static func refusal(_ r: DeleteRefusal) -> String {
        switch r {
        case .invalidPath: String(localized: "đường dẫn không hợp lệ")
        case .criticalSystemDir: String(localized: "thư mục hệ thống trọng yếu")
        case .sipProtected: String(localized: "vùng do SIP bảo vệ")
        case .homeDir: String(localized: "chính thư mục nhà")
        case .otherUserHome: String(localized: "thư mục nhà của người dùng khác")
        case .rootLevel: String(localized: "thư mục ở gốc ổ đĩa")
        case .ownAppData: String(localized: "dữ liệu của chính MacPowerManager")
        }
    }

    // MARK: Khôi phục

    /// Việc đã làm với một mục trong manifest.
    static func entryAction(_ e: ManifestEntry) -> String {
        switch CleanKind(rawValue: e.kind) {
        case .trashPath: String(localized: "Đã chuyển vào Thùng rác")
        case .symlink: String(localized: "Đã gỡ symlink gãy")
        case .pathEntry: String(localized: "Đã sửa file cấu hình (PATH)")
        case .envLine: String(localized: "Đã tắt dòng khai báo biến môi trường")
        case .launchdJob: String(localized: "Đã gỡ job launchd")
        case .tccReset: String(localized: "Đã thu hồi quyền riêng tư")
        case .lsRebuild: String(localized: "Đã dựng lại CSDL LaunchServices")
        case .purgeAny, .purgeTrash: String(localized: "Đã xóa vĩnh viễn")
        default: e.kind
        }
    }

    static func entrySymbol(_ e: ManifestEntry) -> String {
        switch CleanKind(rawValue: e.kind) {
        case .trashPath: "trash"
        case .symlink: "link"
        case .pathEntry, .envLine: "doc.badge.gearshape"
        case .launchdJob: "gearshape.2"
        case .tccReset: "hand.raised"
        case .lsRebuild: "square.stack.3d.up"
        default: "questionmark.circle"
        }
    }

    static func restoreTitle(_ s: RestoreStatus) -> String {
        if CleanupRestoreItem.notNeeded(s) { return String(localized: "Không cần khôi phục") }
        return switch s {
        case .restored: String(localized: "Đã khôi phục")
        case .failed: String(localized: "Lỗi")
        case .manual: String(localized: "Cần làm tay")
        }
    }

    static func restoreSymbol(_ s: RestoreStatus) -> String {
        if CleanupRestoreItem.notNeeded(s) { return "minus.circle" }
        return switch s {
        case .restored: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .manual: "hand.point.up.left"
        }
    }

    static func restoreTint(_ s: RestoreStatus) -> Color {
        if CleanupRestoreItem.notNeeded(s) { return .secondary }
        return switch s {
        case .restored: .green
        case .failed: .red
        case .manual: .orange
        }
    }

    static func restoreMessage(_ s: RestoreStatus) -> String? {
        if CleanupRestoreItem.notNeeded(s) { return String(localized: "macOS tự đăng ký lại các app.") }
        return switch s {
        case .restored: nil
        case .failed(.moveFailed): String(localized: "Không chuyển về được (thiếu quyền?)")
        case .failed(.backupMissing): String(localized: "Không thấy bản sao lưu")
        case .failed(.writeFailed): String(localized: "Không ghi được về chỗ cũ")
        case .failed(.symlinkFailed): String(localized: "Không tạo lại được symlink")
        case .manual(.alreadyExists): String(localized: "Bỏ qua: chỗ cũ đã có mục khác, không ghi đè")
        case .manual(.notFoundInTrash): String(localized: "Không thấy trong Thùng rác (đã đổ Thùng rác?)")
        case .manual(.trashItemReplaced): String(localized: "Mục trong Thùng rác đã bị thay bằng mục khác cùng tên, không kéo về")
        case .manual(.permanentlyDeleted): String(localized: "Không thể: đã xóa vĩnh viễn")
        case .manual(.receiptNotReloadable(let id)): String(localized: "Biên nhận gói \"\(id)\" không nạp lại được")
        case .manual(.readdFirewallRule(let path)): String(localized: "Tự thêm lại luật tường lửa: \(path)")
        case .manual(.permissionAskedAgain(let service)): String(localized: "Quyền \"\(service)\" sẽ được hỏi lại khi app chạy")
        case .manual(.modifiedSinceCleanup): String(localized: "File đã bị sửa sau lần dọn, chưa ghi đè")
        case .manual(.notRestorable(let kind)): String(localized: "Không khôi phục được kiểu \(kind)")
        }
    }
}

// MARK: - Thành phần dùng chung

/// Nhãn mức độ: chấm màu + chữ.
struct SeverityBadge: View {
    let severity: Severity

    var body: some View {
        let tint = CleanupText.severityTint(severity)
        Text(verbatim: CleanupText.severity(severity))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Nhãn phụ nhỏ ("Cần quyền quản trị", "Chỉ báo").
struct TagBadge: View {
    let text: Text
    let symbol: String

    var body: some View {
        Label { text } icon: { Image(systemName: symbol) }
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.track, in: Capsule())
    }
}

enum CleanupActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // mục không còn (vd symlink gãy hay đường dẫn chết): mở thư mục cha
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
