#if DEBUG
import CleanCore
import Foundation

/// Dữ liệu giả cho ảnh chụp các trang Dọn dẹp (`--render-snapshots`, MPM_SNAPSHOT_FILTER=cleanup).
@MainActor
enum CleanupMock {
    /// Backend không làm gì: ảnh chụp không chạm đĩa.
    struct Backend: CleanupBackend {
        var fullDiskAccess = true
        var sessionList: [CleanupSession] = []
        var entryMap: [URL: [ManifestEntry]] = [:]

        func hasFullDiskAccess() -> Bool { fullDiskAccess }
        func scan(cancellation: CancellationToken,
                  progress: @escaping @Sendable (CleanupScanStatus) -> Void) throws -> CleanupScanOutput {
            CleanupScanOutput(findings: [], ignoredCount: 0, hasFullDiskAccess: fullDiskAccess, scannerErrors: [:])
        }
        func remove(_ findings: [Finding], cancellation: CancellationToken,
                    progress: @escaping @Sendable (Int, Int) -> Void) -> CleanupRemovalRun {
            CleanupRemovalRun(backupDirectory: nil, items: [], sessionFailed: false, cancelled: false)
        }
        func adminCommand(for finding: Finding) -> String { "" }
        func ignore(_ ids: [String]) throws {}
        func unignore(_ ids: Set<String>) throws {}
        func ignoreFileURL() -> URL { URL(fileURLWithPath: "/dev/null") }
        func sessions() -> [CleanupSession] { sessionList }
        func entries(of session: URL) -> [ManifestEntry]? { entryMap[session] }
        func restore(_ session: URL, overwriteModifiedFiles: Bool, onlyEntries: Set<Int>?) -> CleanupRestoreRun {
            CleanupRestoreRun(manifestFound: true, items: [])
        }
        func saveRestore(_ run: CleanupRestoreRun, in session: URL) {}
    }

    static let home = "/Users/appleseed"
    static let mb: Int64 = 1_048_576

    /// Đủ mọi mức độ, mục cần quản trị, mục chỉ báo, đường dẫn dài, nhiều nhóm.
    static let findings: [Finding] = {
        let lib = home + "/Library"
        let longContainer = lib + "/Group Containers/UBF8T346G9.com.microsoft.teams.shared.experimental.preview.channel/Library/Application Support/Logs"
        let list: [Finding] = [
            Finding(category: .docker, severity: .high, name: "Docker Desktop", target: lib + "/Containers/com.docker.docker",
                    reason: .dockerGone, sizeBytes: 18_400 * mb, action: .trashPath(path: lib + "/Containers/com.docker.docker")),
            Finding(category: .appSupport, severity: .high, name: "com.adobe.acc.installer",
                    target: lib + "/Application Support/com.adobe.acc.installer",
                    reason: .orphanBundleID("com.adobe.acc.installer"), sizeBytes: 820 * mb,
                    action: .trashPath(path: lib + "/Application Support/com.adobe.acc.installer")),
            Finding(category: .launchAgent, severity: .high, name: "com.zoom.us.ZoomUpdater",
                    target: lib + "/LaunchAgents/com.zoom.us.ZoomUpdater.plist",
                    reason: .missingProgram("/Applications/zoom.us.app/Contents/Frameworks/ZoomUpdater.app/Contents/MacOS/ZoomUpdater"),
                    action: .launchdJob(plist: lib + "/LaunchAgents/com.zoom.us.ZoomUpdater.plist",
                                        label: "com.zoom.us.ZoomUpdater", domain: "gui/501")),
            Finding(category: .helper, severity: .high, name: "com.paragon-software.ntfs.helper",
                    target: "/Library/PrivilegedHelperTools/com.paragon-software.ntfs.helper",
                    reason: .helperOrphan, sizeBytes: 2 * mb,
                    action: .trashPath(path: "/Library/PrivilegedHelperTools/com.paragon-software.ntfs.helper"),
                    needsAdmin: true),
            Finding(category: .path, severity: .high, name: FindingLiteral.pathEntryName(4), target: "/opt/old-toolchain/bin",
                    reason: .deadPathDir(source: home + "/.zshrc"),
                    action: .pathEntry(file: home + "/.zshrc", dir: "/opt/old-toolchain/bin")),
            Finding(category: .caches, severity: .medium, name: "Sketch", target: lib + "/Caches/Sketch",
                    reason: .orphanName("Sketch", days: 214), sizeBytes: 1_240 * mb,
                    action: .trashPath(path: lib + "/Caches/Sketch")),
            Finding(category: .groupContainer, severity: .medium,
                    name: "UBF8T346G9.com.microsoft.teams.shared.experimental.preview.channel",
                    target: longContainer, reason: .orphanBundleID("com.microsoft.teams.shared.experimental.preview.channel"),
                    sizeBytes: 96 * mb, action: .trashPath(path: longContainer)),
            Finding(category: .receipt, severity: .medium, name: "com.paragon-software.pkg.ntfs",
                    target: "com.paragon-software.pkg.ntfs", reason: .receiptOrphan,
                    action: .pkgReceipt(id: "com.paragon-software.pkg.ntfs"), needsAdmin: true),
            Finding(category: .symlink, severity: .medium, name: "python3", target: "/usr/local/bin/python3",
                    reason: .brokenSymlink(destination: "/usr/local/Cellar/python@3.9/3.9.13/bin/python3"),
                    action: .symlink(path: "/usr/local/bin/python3")),
            Finding(category: .tcc, severity: .medium, name: "us.zoom.xos", target: "Camera",
                    reason: .tccOrphan(service: "Camera"), action: .tccReset(service: "Camera", client: "us.zoom.xos")),
            Finding(category: .envVar, severity: .medium, name: "JAVA_HOME", target: "/Library/Java/JavaVirtualMachines/jdk-11.jdk/Contents/Home",
                    reason: .envVarDead(name: "JAVA_HOME", file: home + "/.zprofile"),
                    action: .envLine(file: home + "/.zprofile", line: "export JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-11.jdk/Contents/Home")),
            Finding(category: .nativeMsg, severity: .medium, name: "com.1password.1password",
                    target: lib + "/Application Support/Google/Chrome/NativeMessagingHosts/com.1password.1password.json",
                    reason: .nativeHostDead(executable: "/Applications/1Password 7.app/Contents/Library/LoginItems/1Password Extension Helper.app"),
                    action: .trashPath(path: lib + "/Application Support/Google/Chrome/NativeMessagingHosts/com.1password.1password.json")),
            Finding(category: .security, severity: .info, name: "Charles Proxy CA", target: "Charles Proxy CA (12 Mar 2023)",
                    reason: .proxyRootCertificate(tool: "Charles"), action: .reportOnly),
            Finding(category: .path, severity: .info, name: FindingLiteral.pathEntryName(9), target: "/usr/local/bin",
                    reason: .duplicatePathEntry(firstIndex: 2), action: .reportOnly),
            Finding(category: .path, severity: .info, name: FindingLiteral.pathEntryName(11), target: FindingLiteral.emptyPathTarget,
                    reason: .emptyPathEntry, action: .reportOnly),
            Finding(category: .launchServices, severity: .info, name: FindingLiteral.ghostRecordsName(37), target: "lsregister",
                    reason: .ghostLaunchServices(count: 37), action: .lsRebuild),
            Finding(category: .loginItem, severity: .info, name: FindingLiteral.backgroundTaskName,
                    target: FindingLiteral.backgroundTaskTarget, reason: .needRootForBackgroundTasks, action: .reportOnly),
            Finding(category: .prefs, severity: .info, name: "com.figma.Desktop", target: lib + "/Preferences/com.figma.Desktop.plist",
                    reason: .orphanName("figma", days: 1), sizeBytes: 1 * mb,
                    action: .trashPath(path: lib + "/Preferences/com.figma.Desktop.plist")),
            Finding(category: .firewall, severity: .info, name: "Steam", target: "/Applications/Steam.app",
                    reason: .firewallRuleDead, action: .firewallApp(path: "/Applications/Steam.app"), needsAdmin: true),
            Finding(category: .sysExt, severity: .info, name: "com.cisco.anyconnect.macos.acsockext",
                    target: "com.cisco.anyconnect.macos.acsockext",
                    reason: .sysExtStale(state: "terminated waiting to uninstall on reboot"), action: .reportOnly),
            Finding(category: .plugin, severity: .medium, name: "Grammarly.safariextz", target: lib + "/Internet Plug-Ins/Grammarly.plugin",
                    reason: .pluginOrphan(owner: "com.grammarly.ProjectLlama"), sizeBytes: 14 * mb,
                    action: .trashPath(path: lib + "/Internet Plug-Ins/Grammarly.plugin")),
        ]
        return list.sortedForReport()
    }()

    static var selected: Set<String> {
        Set(findings.filter { ["Docker Desktop", "Sketch", "com.zoom.us.ZoomUpdater", "python3"].contains($0.name) }.map(\.id))
    }

    static func model(_ phase: CleanupModel.Phase, findings: [Finding] = [], selection: Set<String> = [],
                      fullDiskAccess: Bool = true, progress: CleanupProgress? = nil,
                      filter: CleanupModel.SeverityFilter = .all) -> CleanupModel {
        let m = CleanupModel(backend: Backend(fullDiskAccess: fullDiskAccess))
        m.setPreview(phase: phase, findings: findings, selection: selection, hasFullDiskAccess: fullDiskAccess,
                     hiddenByIgnoreList: findings.isEmpty ? 0 : 3, progress: progress, filter: filter)
        return m
    }

    /// Mục chọn có cả việc không hoàn tác được (thu hồi quyền) và sửa file cấu hình.
    static var mixedSelection: Set<String> {
        Set(findings.filter { ["Docker Desktop", "us.zoom.xos", "JAVA_HOME"].contains($0.name) }.map(\.id))
    }

    static func items(_ ids: Set<String>) -> [CleanupItem] {
        CleanupModel.makeItems(findings).filter { ids.contains($0.id) }
    }

    static func results() -> CleanupModel {
        let m = model(.results, findings: findings, selection: selected)
        m.setPreviewIgnored([Finding(category: .logs, severity: .info, name: "Spotify", target: home + "/Library/Logs/Spotify",
                                     reason: .orphanName("Spotify", days: 30), action: .trashPath(path: home + "/Library/Logs/Spotify"))])
        return m
    }

    static var selectedItems: [CleanupItem] { items(selected) }

    static var removalRun: CleanupRemovalRun {
        let byName = Dictionary(findings.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        func item(_ name: String, _ outcome: RemovalOutcome) -> CleanupItemOutcome {
            let f = byName[name]!
            return CleanupItemOutcome(findingID: f.id, category: f.category, name: f.name, target: f.target, outcome: outcome)
        }
        return CleanupRemovalRun(
            backupDirectory: URL(fileURLWithPath: home + "/Library/Application Support/MacPowerManager/Cleanup/20261016_101500"),
            items: [
                item("Docker Desktop", .done),
                item("Sketch", .done),
                item("com.zoom.us.ZoomUpdater", .done),
                item("python3", .failed(.changedSinceScan)),
                item(FindingLiteral.pathEntryName(4), .failed(.manualEditRequired(file: home + "/.zshrc"))),
                item("JAVA_HOME", .failed(.wouldBreakShellSyntax(file: home + "/.zprofile"))),
                item("com.paragon-software.ntfs.helper",
                     .needsAdmin(command: "sudo mv -n '/Library/PrivilegedHelperTools/com.paragon-software.ntfs.helper' '/Users/appleseed/.Trash/com.paragon-software.ntfs.helper' && sudo chown -R 'appleseed' '/Users/appleseed/.Trash/com.paragon-software.ntfs.helper'")),
                item("Grammarly.safariextz", .skipped(.coveredBy(target: home + "/Library/Internet Plug-Ins"))),
            ],
            sessionFailed: false, cancelled: false)
    }

    static func history() -> CleanupModel {
        let base = URL(fileURLWithPath: home + "/Library/Application Support/MacPowerManager/Cleanup")
        let names = ["20261016_101500", "20261012_084211", "20260930_221003_2"]
        let sessions = [
            CleanupSession(directory: base.appendingPathComponent(names[0]), name: names[0],
                           date: CleanupSession.date(fromName: names[0]), entryCount: 7, bytes: 19_650 * mb),
            CleanupSession(directory: base.appendingPathComponent(names[1]), name: names[1],
                           date: CleanupSession.date(fromName: names[1]), entryCount: 2, bytes: 340 * mb),
            CleanupSession(directory: base.appendingPathComponent(names[2]), name: names[2],
                           date: CleanupSession.date(fromName: names[2]), entryCount: 1, bytes: nil),
        ]
        let lib = home + "/Library"
        let at = Date()
        let entries = [
            ManifestEntry(kind: CleanKind.trashPath.rawValue, original: lib + "/Containers/com.docker.docker",
                          owner: "appleseed:staff", trashedPath: home + "/.Trash/com.docker.docker", at: at),
            ManifestEntry(kind: CleanKind.trashPath.rawValue, original: lib + "/Caches/Sketch",
                          trashedPath: home + "/.Trash/Sketch", at: at),
            ManifestEntry(kind: CleanKind.launchdJob.rawValue, original: lib + "/LaunchAgents/com.zoom.us.ZoomUpdater.plist",
                          backupRel: "files/001_com.zoom.us.ZoomUpdater.plist", extra: "gui/501/com.zoom.us.ZoomUpdater", at: at),
            ManifestEntry(kind: CleanKind.pathEntry.rawValue, original: home + "/.zshrc", backupRel: "files/002_.zshrc",
                          extra: "/opt/old-toolchain/bin", at: at),
            ManifestEntry(kind: CleanKind.symlink.rawValue, original: "/usr/local/bin/python3",
                          extra: "/usr/local/Cellar/python@3.9/3.9.13/bin/python3", at: at),
            ManifestEntry(kind: CleanKind.tccReset.rawValue, original: "us.zoom.xos", extra: "Camera", at: at),
            ManifestEntry(kind: CleanKind.lsRebuild.rawValue, original: "LaunchServices", at: at),
        ]
        let statuses: [RestoreStatus] = [.restored, .manual(.notFoundInTrash), .restored, .manual(.modifiedSinceCleanup),
                                         .manual(.alreadyExists), .manual(.permissionAskedAgain(service: "Camera")),
                                         .manual(.notRestorable(kind: CleanKind.lsRebuild.rawValue))]
        let run = CleanupRestoreRun(manifestFound: true, items: zip(entries.indices, statuses).map {
            CleanupRestoreItem(index: $0, entry: entries[$0], status: $1)
        }, date: Date(timeIntervalSince1970: 1_792_150_000))
        let m = CleanupModel(backend: Backend(sessionList: sessions, entryMap: [sessions[0].directory: entries]))
        m.setPreview(phase: .idle, findings: [], hasFullDiskAccess: true, sessions: sessions,
                     entries: [sessions[0].directory: entries], restoreRuns: [sessions[0].directory: run])
        return m
    }
}
#endif
