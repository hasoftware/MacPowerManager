import Foundation

/// `scan_path` + `scan_envvars`: mục PATH rỗng/trùng/chết và biến môi trường trỏ tới đường dẫn không tồn tại (spec B §1-3).
public struct EnvironmentScanner: Scanner {
    public init() {}

    public var id: String { "Environment" }

    /// Biến công cụ phát triển hay gặp (thứ tự giữ như zsh).
    static let knownVariables: [String] = [
        "JAVA_HOME", "GOROOT", "GOPATH", "ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_NDK_HOME",
        "M2_HOME", "MAVEN_HOME", "GRADLE_HOME", "CATALINA_HOME", "PYENV_ROOT", "NVM_DIR", "RBENV_ROOT",
        "CARGO_HOME", "RUSTUP_HOME", "FLUTTER_ROOT", "DOTNET_ROOT", "SDKMAN_DIR", "VCPKG_ROOT",
        "LLVM_HOME", "NODE_PATH", "SWIFT_HOME", "DENO_INSTALL", "BUN_INSTALL", "PNPM_HOME",
        "CONDA_PREFIX", "GEM_HOME", "COMPOSER_HOME", "QT_DIR", "CMAKE_PREFIX_PATH",
    ]

    /// Hậu tố tên biến được xét ở file cấu hình shell.
    static let variableSuffixes = ["_HOME", "_ROOT", "_DIR", "_SDK", "_INSTALL", "_PATH"]

    /// Đường dẫn nội bộ của Apple (cryptex, rvictl): /etc/paths.d khai báo sẵn nhưng chỉ tồn tại khi cryptex được
    /// mount -> KHÔNG phải rác.
    static let appleInternalPrefixes = ["/System/", "/Library/Apple/", "/var/run/com.apple.", "/private/var/run/com.apple."]

    public func scan(_ context: ScanContext) throws -> [Finding] {
        var out = try scanPath(context)
        out += try scanEnvVars(context)
        return out
    }

    // MARK: scan_path

    func scanPath(_ context: ScanContext) throws -> [Finding] {
        let env = context.env
        var out: [Finding] = []
        var seen: [String: Int] = [:]
        // Không có PATH shell -> PATH dựng từ /etc/paths* (UI báo quét không đầy đủ qua env.isUsingFallbackPATH),
        // không bao giờ dùng PATH của app. PATH rỗng hẳn (không đọc được gì) -> không báo "mục rỗng #1" giả.
        let path = env.userPATH
        guard !path.isEmpty else { return [] }
        // Giữ phần tử rỗng: "a::b:" -> a, "", b, ""
        for (offset, p) in ScanEnvironment.splitPATH(path).enumerated() {
            try context.checkCancelled()
            let i = offset + 1
            let name = FindingLiteral.pathEntryName(i)
            if p.isEmpty {
                out.append(Finding(category: .path, severity: .info, name: name, target: FindingLiteral.emptyPathTarget,
                                   reason: .emptyPathEntry, action: .reportOnly))
                continue
            }
            let norm = p.hasSuffix("/") ? String(p.dropLast()) : p   // ${p%/}: bỏ đúng MỘT dấu /
            if let first = seen[norm] {
                // không continue: mục trùng mà chết thì ra 2 finding (như zsh)
                out.append(Finding(category: .path, severity: .info, name: name, target: p,
                                   reason: .duplicatePathEntry(firstIndex: first), action: .reportOnly))
            } else {
                seen[norm] = i
            }
            // Phần tử tương đối (".", "bin") zsh xét theo cwd của shell; app không có cwd ý nghĩa -> coi là còn
            // (lệch có chủ đích).
            guard p.hasPrefix("/"), !env.isDirectory(p) else { continue }
            // Không xem được (EACCES/TCC) hoặc ổ ngoài chưa mount: không kết luận là chết.
            if env.existence(p) == .unknown { continue }
            if EnvironmentScanner.appleInternalPrefixes.contains(where: { p.hasPrefix($0) }) { continue }
            if let src = env.pathSourceFile(for: p) {
                out.append(Finding(category: .path, severity: .high, name: name, target: p,
                                   reason: .deadPathDir(source: src), action: .pathEntry(file: src, dir: p)))
            } else {
                out.append(Finding(category: .path, severity: .medium, name: name, target: p,
                                   reason: .deadPathDir(source: nil), action: .reportOnly))
            }
        }
        return out
    }

    // MARK: scan_envvars

    func scanEnvVars(_ context: ScanContext) throws -> [Finding] {
        let env = context.env
        var out: [Finding] = []
        let known = Set(EnvironmentScanner.knownVariables)

        // 1) Biến đang có hiệu lực trong shell của người dùng (không phải môi trường của app GUI).
        // Không lấy được môi trường shell -> bỏ phần này.
        if let shell = env.shellEnvironment {
            for v in EnvironmentScanner.knownVariables {
                try context.checkCancelled()
                guard let val = shell[v], !val.isEmpty else { continue }
                // zsh xét giá trị tương đối theo cwd của shell; ở đây bỏ qua (lệch có chủ đích, như PATH).
                // Giá trị dạng danh sách "/a:/b" vẫn xét nguyên chuỗi như zsh (hành vi đã biết).
                guard val.hasPrefix("/"), env.existence(val) == .missing else { continue }
                out.append(Finding(category: .envVar, severity: .medium, name: v, target: val,
                                   reason: .envVarDead(name: v, file: nil), action: .reportOnly))
            }
        }

        // 2) Khai báo nằm trong file cấu hình shell -> gỡ được (comment dòng đó lại)
        for f in env.rcFiles where env.isReadableFile(f) {
            try context.checkCancelled()
            guard let data = FileManager.default.contents(atPath: env.physicalPath(f)) else { continue }
            // Giải mã lỏng: file lẫn byte không phải UTF-8 vẫn được xét (zsh đọc byte thô). Dòng cuối không có
            // \n vẫn được xét (zsh `while read` bỏ sót - sửa có chủ đích).
            for line in TextLines(String(decoding: data, as: UTF8.self)).lines {
                guard let (name, expanded) = EnvironmentScanner.deadDeclaration(line, known: known, env: env) else {
                    continue
                }
                out.append(Finding(category: .envVar, severity: .high, name: name, target: expanded,
                                   reason: .envVarDead(name: name, file: f), action: .envLine(file: f, line: line)))
            }
        }
        return out
    }

    /// Một dòng file shell: trả (tên, đường dẫn đã mở `~`) nếu là khai báo biến trỏ tới đường dẫn không tồn tại.
    /// Từng bước khớp đúng chuỗi xử lý tham số của zsh trong `scan_envvars` (kể cả các ca báo nhầm đã biết:
    /// `$` ở giữa giá trị, danh sách `/a:/b`, ký tự thừa `;` sau giá trị, `~user`).
    static func deadDeclaration(_ line: String, known: Set<String>, env: ScanEnvironment) -> (String, String)? {
        // [[ $line == [[:space:]]#\#* ]] -> comment
        let lead = line.drop(while: isZshSpace)
        if lead.hasPrefix("#") { return nil }
        guard line.contains("=") else { return nil }
        var body = Substring(lead)
        if body.hasPrefix("export ") { body = body.dropFirst("export ".count) }   // ${body#export }: một lần
        guard let eq = body.firstIndex(of: "=") else { return nil }
        let name = trimZshSpace(body[..<eq])
        guard isIdentifier(name) else { return nil }   // loại alias x=, local X=, if [[ a == b...
        guard variableSuffixes.contains(where: { name.hasSuffix($0) }) || known.contains(name) else { return nil }
        if name == "PATH" { return nil }                // PATH đã có module riêng

        var value = body[body.index(after: eq)...]
        // ${value%%[[:space:]]#\##*}: cắt từ dấu # ĐẦU TIÊN (cùng khoảng trắng liền trước) tới hết
        if let hash = value.firstIndex(of: "#") {
            var cut = hash
            while cut > value.startIndex {
                let prev = value.index(before: cut)
                guard isZshSpace(value[prev]) else { break }
                cut = prev
            }
            value = value[..<cut]
        }
        // ${${value#[\"\']}%[\"\']}: bỏ MỘT dấu nháy đầu và MỘT dấu nháy cuối, độc lập
        if let c = value.first, c == "\"" || c == "'" { value = value.dropFirst() }
        if let c = value.last, c == "\"" || c == "'" { value = value.dropLast() }
        let v = String(value)
        // có thay thế động, bỏ qua
        if v.hasPrefix("$") || v.contains("$(") || v.contains("`") { return nil }
        guard v.hasPrefix("/") || v.hasPrefix("~") else { return nil }
        // ${value/#\~/$HOME}
        let expanded = v.hasPrefix("~") ? env.homePath + v.dropFirst() : v
        // chỉ "chắc chắn không có" mới tính (không xem được / ổ chưa mount -> bỏ qua)
        if env.existence(expanded) != .missing { return nil }
        return (name, expanded)
    }

    /// `[[:space:]]` của zsh (ASCII).
    static func isZshSpace(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\r\n" || c == "\u{0B}" || c == "\u{0C}"
    }

    static func trimZshSpace(_ s: Substring) -> String {
        var t = s.drop(while: isZshSpace)
        while let c = t.last, isZshSpace(c) { t = t.dropLast() }
        return String(t)
    }

    /// `[A-Za-z_][A-Za-z0-9_]#`.
    static func isIdentifier(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        func letter(_ u: Unicode.Scalar) -> Bool { (u >= "A" && u <= "Z") || (u >= "a" && u <= "z") || u == "_" }
        guard letter(first) else { return false }
        return s.unicodeScalars.allSatisfy { letter($0) || ($0 >= "0" && $0 <= "9") }
    }
}
