import Foundation

/// `scan_plugins`: plugin hỏng hoặc của phần mềm đã gỡ (spec B §12-13).
public struct PluginScanner: Scanner {
    public init() {}

    public var id: String { "Plugin" }

    /// Nhóm 1: plugin GẮN VỚI ứng dụng - app biến mất thì plugin thành rác.
    /// zsh viết `/Library/Screen Savers` không có ngoặc kép nên bị tách làm hai phần tử và thư mục này không bao
    /// giờ được quét, dù README/CHANGELOG nói có. Ở đây quét đúng (sửa có chủ đích).
    static func attachedDirs(home h: String) -> [String] {
        ["\(h)/Library/QuickLook", "/Library/QuickLook",
         "\(h)/Library/Spotlight", "/Library/Spotlight",
         "\(h)/Library/Services", "/Library/Services",
         "\(h)/Library/Screen Savers", "/Library/Screen Savers",
         "/Library/Input Methods", "\(h)/Library/Input Methods",
         "\(h)/Library/Mail/Bundles", "/Library/Mail/Bundles",
         "\(h)/Library/ColorPickers", "/Library/ColorPickers",
         "\(h)/Library/Contextual Menu Items"]
    }

    /// Nhóm 2: plugin ĐỘC LẬP (VST, AU...) - không thuộc app nào, chỉ xét bundle hỏng.
    /// PreferencePanes và Internet Plug-Ins cũng vào nhóm này vì build_app_index đã đăng ký chúng như phần mềm
    /// đang cài (nếu xét mồ côi sẽ tự khớp chính nó).
    static func standaloneDirs(home h: String) -> [String] {
        ["\(h)/Library/Audio/Plug-Ins/VST", "\(h)/Library/Audio/Plug-Ins/VST3",
         "\(h)/Library/Audio/Plug-Ins/Components", "\(h)/Library/Audio/Plug-Ins/HAL",
         "/Library/Audio/Plug-Ins/VST", "/Library/Audio/Plug-Ins/VST3",
         "/Library/Audio/Plug-Ins/Components", "/Library/Audio/Plug-Ins/HAL",
         "\(h)/Library/PreferencePanes", "/Library/PreferencePanes",
         "/Library/Internet Plug-Ins", "\(h)/Library/Internet Plug-Ins"]
    }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        let env = context.env
        let attached = PluginScanner.attachedDirs(home: env.homePath)
        let dirs = attached.map { ($0, true) } + PluginScanner.standaloneDirs(home: env.homePath).map { ($0, false) }
        var out: [Finding] = []
        for (d, isAttached) in dirs {
            try context.checkCancelled()
            guard env.isDirectory(d) else { continue }
            for b in env.list(d, .realDirectories) {
                try context.checkCancelled()
                let base = PathResolver.tail(b)
                // chỉ xét bundle có đuôi. zsh xét `*.*` trên đường dẫn ĐẦY ĐỦ (home kiểu /Users/john.doe làm mọi
                // mục đều qua); ở đây xét basename (sửa có chủ đích).
                guard base.contains(".") else { continue }
                if let exe = env.bundleBrokenExecutable(b) {
                    out.append(Finding(category: .plugin, severity: .high, name: base, target: b,
                                       reason: .bundleBroken(executable: exe), sizeBytes: context.sizeBytes(b),
                                       action: .trashPath(path: b)))
                    continue
                }
                guard isAttached else { continue }   // nhóm độc lập: dừng ở đây
                // Quick Action/workflow do người dùng tự tạo trong Automator: nội dung của NGƯỜI DÙNG, không phải
                // tàn dư của app nào (lệch bản gốc có chủ đích).
                if base.hasSuffix(".workflow") { continue }
                // Không có bundle id thì không có bằng chứng chủ sở hữu (zsh đoán theo tên file -> báo nhầm). Khóa có
                // mà rỗng -> "" -> orphan_check coi là còn sống (giữ như zsh).
                guard let bid = env.plistString("\(b)/Contents/Info.plist", "CFBundleIdentifier") else { continue }
                // Chỉ dùng cờ mồ côi; mức cố định Medium.
                guard context.orphanCheck(name: bid, path: b).isOrphan else { continue }
                out.append(Finding(category: .plugin, severity: .medium, name: base, target: b,
                                   reason: .pluginOrphan(owner: bid), sizeBytes: context.sizeBytes(b),
                                   action: .trashPath(path: b)))
            }
        }
        return out
    }
}
