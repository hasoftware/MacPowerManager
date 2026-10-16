import XCTest
@testable import CleanCore

/// Bộ quét nhóm B, phần môi trường/bảo mật: PATH, biến môi trường, DYLD/sudoers, chứng chỉ, tường lửa, TCC.
/// Cây giả + CommandRunner giả, không chạm hệ thống.
final class ScannersBEnvironmentTests: XCTestCase {
    private func context(_ tree: FakeTree, index: AppIndex? = nil, runner: StubRunner = StubRunner(),
                         fda: Bool = false, token: CancellationToken = CancellationToken()) -> ScanContext {
        ScanContext(env: tree.env, index: index ?? AppIndex(env: tree.env), runner: runner,
                    hasFullDiskAccess: fda, cancellation: token)
    }

    private var home: String { "/Users/tester" }

    // MARK: scan_path

    func testPathEmptyDuplicateAndDeadWithSource() throws {
        let tree = FakeTree()
        tree.mkdir("/a"); tree.mkdir("/b")
        tree.write("\(home)/.zshrc", "export PATH=\"/dead:$PATH\"\n")
        tree.env.shellEnvironment = ["PATH": ":/a::/b/:/b:/System/x:/dead"]
        let fs = try EnvironmentScanner().scanPath(context(tree))
        XCTAssertEqual(fs.map(\.id), ["Path|PATH #1|<rỗng>", "Path|PATH #3|<rỗng>", "Path|PATH #5|/b", "Path|PATH #7|/dead"])
        XCTAssertEqual(fs[0].severity, .info)
        XCTAssertEqual(fs[0].reason, .emptyPathEntry)
        XCTAssertEqual(fs[0].kind, .reportOnly)
        // /b trùng /b/ (#4) sau khi bỏ một dấu / cuối
        XCTAssertEqual(fs[2].reason, .duplicatePathEntry(firstIndex: 4))
        XCTAssertEqual(fs[2].severity, .info)
        XCTAssertEqual(fs[3].severity, .high)
        XCTAssertEqual(fs[3].reason, .deadPathDir(source: "\(home)/.zshrc"))
        XCTAssertEqual(fs[3].action, .pathEntry(file: "\(home)/.zshrc", dir: "/dead"))
    }

    /// Thứ tự nguồn: /etc/paths thắng mọi file; trong /etc/paths.d thì theo tên tăng dần; rồi RC_FILES.
    func testPathSourceFileOrder() throws {
        let tree = FakeTree()
        tree.write("/etc/paths.d/b", "/dead\n")
        tree.write("/etc/paths.d/a", "/dead\n")
        tree.write("\(home)/.zshrc", "/dead")
        tree.env.shellEnvironment = ["PATH": "/dead"]
        var fs = try EnvironmentScanner().scanPath(context(tree))
        XCTAssertEqual(fs.first?.action, .pathEntry(file: "/etc/paths.d/a", dir: "/dead"))
        tree.write("/etc/paths", "/usr/bin\n/dead\n")
        fs = try EnvironmentScanner().scanPath(context(tree))
        XCTAssertEqual(fs.first?.action, .pathEntry(file: "/etc/paths", dir: "/dead"))
    }

    func testPathDeadWithoutSourceIsMediumReportOnly() throws {
        let tree = FakeTree()
        tree.env.shellEnvironment = ["PATH": "/nowhere"]
        let fs = try EnvironmentScanner().scanPath(context(tree))
        XCTAssertEqual(fs.count, 1)
        XCTAssertEqual(fs[0].severity, .medium)
        XCTAssertEqual(fs[0].reason, .deadPathDir(source: nil))
        XCTAssertEqual(fs[0].action, .reportOnly)
    }

    /// Mục trùng mà chết ra 2 finding (không `continue` sau mục trùng). File thường cũng tính là chết.
    func testPathDuplicateAndDeadGivesTwoFindings() throws {
        let tree = FakeTree()
        tree.write("/file", "x")
        tree.env.shellEnvironment = ["PATH": "/dead:/dead:/file"]
        let fs = try EnvironmentScanner().scanPath(context(tree))
        XCTAssertEqual(fs.map(\.id), ["Path|PATH #1|/dead", "Path|PATH #2|/dead", "Path|PATH #2|/dead", "Path|PATH #3|/file"])
        XCTAssertEqual(fs[1].reason, .duplicatePathEntry(firstIndex: 1))
        XCTAssertEqual(fs[2].reason, .deadPathDir(source: nil))
    }

    /// Đường dẫn nội bộ của Apple (cryptex) và phần tử tương đối không bị báo chết.
    func testPathSkipsAppleInternalAndRelative() throws {
        let tree = FakeTree()
        tree.env.shellEnvironment = ["PATH": "/System/Cryptexes/App/usr/bin:/Library/Apple/usr/bin:"
            + "/var/run/com.apple.security.cryptexd/x:/private/var/run/com.apple.y:bin:."]
        XCTAssertEqual(try EnvironmentScanner().scanPath(context(tree)), [])
    }

    /// Không có môi trường shell → PATH dựng từ /etc/paths + /etc/paths.d (không dùng PATH của app).
    func testPathFallsBackToPathHelper() throws {
        let tree = FakeTree()
        tree.mkdir("/usr/bin")
        tree.write("/etc/paths", "/usr/bin\n/gone/bin\n")
        XCTAssertTrue(tree.env.isUsingFallbackPATH)
        let fs = try EnvironmentScanner().scanPath(context(tree))
        XCTAssertEqual(fs.map(\.id), ["Path|PATH #2|/gone/bin"])
        XCTAssertEqual(fs[0].action, .pathEntry(file: "/etc/paths", dir: "/gone/bin"))
    }

    /// Không đọc được PATH nào → không báo "mục rỗng" giả.
    func testPathEmptyFallbackGivesNothing() throws {
        let tree = FakeTree()
        XCTAssertEqual(try EnvironmentScanner().scan(context(tree)), [])
    }

    // MARK: scan_envvars

    func testEnvVarsInShellFiles() throws {
        let tree = FakeTree()
        tree.mkdir("/exists"); tree.mkdir("/a"); tree.mkdir("/b")
        let lines = [
            "export JAVA_HOME=\"/x\" # comment",   // High, target /x
            "  FOO_HOME='~/nope'",                  // ~ → home
            "# export X_HOME=/x",                   // comment
            "   # A_HOME=/x",                       // comment sau khoảng trắng
            "alias X_HOME=/x",                      // tên không hợp lệ
            "typeset -x T_HOME=/x",                 // tên không hợp lệ
            "X_HOME=$HOME/x",                       // thay thế động
            "Y_HOME=$(brew --prefix)",
            "Q_HOME=/opt/`uname`",
            "Z_HOME=relative",                      // không phải đường dẫn tuyệt đối
            "MYVAR=/nope",                          // không hậu tố, không thuộc known
            "PATH=/nope",
            "EXIST_HOME=/exists",                   // còn tồn tại
            "GOPATH=/gone",                         // thuộc known
            "W_DIR=/w#frag",                        // cắt tại # đầu tiên → /w
            "CMAKE_PREFIX_PATH=/a:/b",              // hành vi đã biết: xét nguyên chuỗi → báo
            "LAST_INSTALL=/last",                   // dòng cuối không có \n vẫn được xét
        ]
        tree.write("\(home)/.zshrc", lines.joined(separator: "\n"))
        tree.write("/etc/zshenv", "export SYS_ROOT=/sysgone\n")
        let fs = try EnvironmentScanner().scanEnvVars(context(tree))
        XCTAssertEqual(fs.map(\.id), [
            "EnvVar|JAVA_HOME|/x", "EnvVar|FOO_HOME|/Users/tester/nope", "EnvVar|GOPATH|/gone", "EnvVar|W_DIR|/w",
            "EnvVar|CMAKE_PREFIX_PATH|/a:/b", "EnvVar|LAST_INSTALL|/last", "EnvVar|SYS_ROOT|/sysgone",
        ])
        XCTAssertTrue(fs.allSatisfy { $0.severity == .high && $0.kind == .envLine })
        XCTAssertEqual(fs[0].reason, .envVarDead(name: "JAVA_HOME", file: "\(home)/.zshrc"))
        // payload là dòng gốc NGUYÊN VĂN (để comment đúng dòng khi gỡ)
        XCTAssertEqual(fs[0].action, .envLine(file: "\(home)/.zshrc", line: "export JAVA_HOME=\"/x\" # comment"))
        XCTAssertEqual(fs[1].action, .envLine(file: "\(home)/.zshrc", line: "  FOO_HOME='~/nope'"))
        XCTAssertEqual(fs[6].action, .envLine(file: "/etc/zshenv", line: "export SYS_ROOT=/sysgone"))
    }

    /// Phần 1: biến đang có hiệu lực trong shell người dùng; nil → không quét phần này.
    func testEnvVarsActiveInShell() throws {
        let tree = FakeTree()
        tree.mkdir("/exists")
        tree.env.shellEnvironment = ["PATH": "/exists", "JAVA_HOME": "/nope", "GOPATH": "/exists",
                                     "NVM_DIR": "", "UNKNOWN_HOME": "/nope2", "PNPM_HOME": "rel"]
        let fs = try EnvironmentScanner().scan(context(tree))
        XCTAssertEqual(fs.map(\.id), ["EnvVar|JAVA_HOME|/nope"])
        XCTAssertEqual(fs[0].severity, .medium)
        XCTAssertEqual(fs[0].reason, .envVarDead(name: "JAVA_HOME", file: nil))
        XCTAssertEqual(fs[0].action, .reportOnly)

        tree.env.shellEnvironment = nil
        tree.write("/etc/paths", "/exists\n")
        XCTAssertEqual(try EnvironmentScanner().scan(context(tree)), [])
    }

    /// File shell là symlink (repo dotfiles) vẫn được đọc; target trong finding là đường dẫn logic của symlink.
    func testEnvVarsFollowsSymlinkedRcFile() throws {
        let tree = FakeTree()
        tree.write("/dotfiles/zshrc", "export ANDROID_HOME=/sdk/gone\n")
        tree.symlink("\(home)/.zshrc", to: tree.phys("/dotfiles/zshrc"))
        let fs = try EnvironmentScanner().scanEnvVars(context(tree))
        XCTAssertEqual(fs.map(\.id), ["EnvVar|ANDROID_HOME|/sdk/gone"])
        XCTAssertEqual(fs[0].action, .envLine(file: "\(home)/.zshrc", line: "export ANDROID_HOME=/sdk/gone"))
    }

    func testEnvironmentScannerHonoursCancellation() {
        let tree = FakeTree()
        tree.env.shellEnvironment = ["PATH": "/a"]
        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(try EnvironmentScanner().scan(context(tree, token: token))) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    // MARK: scan_dyld

    func testDyldInLaunchdPlistsShellFilesAndSudoers() throws {
        let tree = FakeTree()
        let agent = tree.plist("\(home)/Library/LaunchAgents/com.evil.agent.plist",
                               ["Label": "com.evil.agent", "EnvironmentVariables": ["DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"]])
        tree.plist("/Library/LaunchDaemons/com.arr.plist",
                   ["EnvironmentVariables": ["DYLD_INSERT_LIBRARIES": ["/a.dylib"]]])   // mảng: plutil raw → "1"
        tree.plist("/Library/LaunchDaemons/com.empty.plist", ["EnvironmentVariables": ["DYLD_INSERT_LIBRARIES": ""]])
        tree.plist("/Library/LaunchDaemons/com.clean.plist", ["EnvironmentVariables": ["FOO": "bar"]])
        tree.symlink("/Library/LaunchAgents/com.link.plist", to: tree.phys(agent))   // symlink: bỏ
        tree.write("\(home)/.zshrc", "# export DYLD_INSERT_LIBRARIES=/x\n")      // kể cả trong comment
        tree.write("/etc/launchd.conf", "setenv DYLD_INSERT_LIBRARIES /y")
        tree.write("/etc/sudoers.d/README", "x")
        tree.write("/etc/sudoers.d/foo", "x")
        tree.write("/etc/sudoers.d/.hidden", "x")
        tree.mkdir("/etc/sudoers.d/dir")
        tree.symlink("/etc/sudoers.d/link", to: tree.phys("/etc/sudoers.d/foo"))

        let fs = try DyldScanner().scan(context(tree))
        XCTAssertEqual(fs.map(\.id), [
            "Security|DYLD_INSERT_LIBRARIES|\(home)/Library/LaunchAgents/com.evil.agent.plist",
            "Security|DYLD_INSERT_LIBRARIES|/Library/LaunchDaemons/com.arr.plist",
            "Security|DYLD_INSERT_LIBRARIES|\(home)/.zshrc",
            "Security|DYLD_INSERT_LIBRARIES|/etc/launchd.conf",
            "Security|sudoers.d/foo|/etc/sudoers.d/foo",
        ])
        XCTAssertTrue(fs.allSatisfy { $0.kind == .reportOnly })
        // plist: lý do mang basename; file shell: đường dẫn đầy đủ
        XCTAssertEqual(fs[0].reason, .dyldInsert(location: "com.evil.agent.plist"))
        XCTAssertEqual(fs[0].severity, .high)
        XCTAssertEqual(fs[2].reason, .dyldInsert(location: "\(home)/.zshrc"))
        XCTAssertEqual(fs[4].severity, .medium)
        XCTAssertEqual(fs[4].reason, .thirdPartySudoers(file: "foo"))
    }

    // MARK: scan_certs

    func testProxyCertificates() throws {
        let tree = FakeTree()
        let sys = tree.write("/Library/Keychains/System.keychain", "kc")
        let login = tree.write("\(home)/Library/Keychains/login.keychain-db", "kc")
        let runner = StubRunner()
        runner.set("\(Tool.security) find-certificate -a \(tree.phys(sys))", stdout: """
            keychain: "/Library/Keychains/System.keychain"
            attributes:
                "alis"<blob>="PortSwigger CA"
                "labl"<blob>="PortSwigger CA"
                "labl"<blob>="Apple Root CA"

            """)
        runner.set("\(Tool.security) find-certificate -a \(tree.phys(login))", stdout: """
                "labl"<blob>="charles proxy CA (1 Jan 2026, host)"
                "labl"<blob>=0x4275727020C3A9  "Burp \\303\\251"
                "labl"<blob>=<NULL>
                "labl"<blob>="Whistle Burp"

            """)
        let fs = try CertificatesScanner().scan(context(tree, runner: runner))
        XCTAssertEqual(fs.map(\.name), ["PortSwigger CA", "charles proxy CA (1 Jan 2026, host)",
                                        "    \"labl\"<blob>=0x4275727020C3A9  \"Burp \\303\\251", "Whistle Burp"])
        XCTAssertEqual(fs.map(\.target), [sys, login, login, login])
        // tool là chuỗi trong danh sách (không phải nhãn), khớp cái ĐẦU TIÊN theo thứ tự danh sách
        XCTAssertEqual(fs.map(\.reason), [.proxyRootCertificate(tool: "PortSwigger"),
                                          .proxyRootCertificate(tool: "Charles Proxy"),
                                          .proxyRootCertificate(tool: "Burp"),
                                          .proxyRootCertificate(tool: "Burp")])
        XCTAssertTrue(fs.allSatisfy { $0.severity == .high && $0.kind == .reportOnly })
    }

    func testCertificatesSkipsUnreadableKeychain() throws {
        let tree = FakeTree()
        let runner = StubRunner()
        XCTAssertEqual(try CertificatesScanner().scan(context(tree, runner: runner)), [])
        XCTAssertTrue(runner.calls.isEmpty)
    }

    // MARK: scan_firewall

    func testFirewallDeadRules() throws {
        let tree = FakeTree()
        tree.write("/usr/libexec/remoted", "bin")
        let runner = StubRunner()
        runner.set("\(Tool.socketfilterfw) --listapps", stdout: """
            Total number of apps = 5

            1 : /usr/libexec/remoted
                         (Allow incoming connections)
            2 : /Applications/Gone.app
                         (Block incoming connections)
            3 : relative/thing
            x : /Applications/NotNumbered.app
             4 : /Applications/Indented.app
            12 : /Applications/Also Gone.app/Contents/MacOS/x

            """)
        let fs = try FirewallScanner().scan(context(tree, runner: runner))
        XCTAssertEqual(fs.map(\.id), ["Firewall|Gone.app|/Applications/Gone.app",
                                      "Firewall|x|/Applications/Also Gone.app/Contents/MacOS/x"])
        XCTAssertEqual(fs[0].severity, .medium)
        XCTAssertEqual(fs[0].reason, .firewallRuleDead)
        XCTAssertEqual(fs[0].action, .firewallApp(path: "/Applications/Gone.app"))
        XCTAssertTrue(Remover.needsAdmin(fs[0], env: tree.env))
    }

    // MARK: scan_tcc

    func testTCCRequiresFullDiskAccess() throws {
        let tree = FakeTree()
        tree.write("\(home)/Library/Application Support/com.apple.TCC/TCC.db", "db")
        let runner = StubRunner()
        XCTAssertEqual(try TCCScanner().scan(context(tree, runner: runner, fda: false)), [])
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testTCCOrphanGrants() throws {
        let tree = FakeTree()
        let userDB = tree.write("\(home)/Library/Application Support/com.apple.TCC/TCC.db", "db")
        let sysDB = tree.write("/Library/Application Support/com.apple.TCC/TCC.db", "db")
        var idx = AppIndex(env: tree.env)
        idx.registerBundle("com.alive.app", path: "/Applications/Alive.app")
        let query = "SELECT DISTINCT service, client FROM access;"
        let runner = StubRunner()
        runner.set("\(Tool.sqlite3) file:\(tree.phys(userDB))?mode=ro \(query)", stdout: """
            kTCCServiceAccessibility|com.dead.app
            kTCCServiceCamera|com.apple.Safari
            kTCCServiceMicrophone|/usr/bin/x
            kTCCServiceCamera|com.alive.helper
            kTCCServiceCamera|
            kTCCServiceListenEvent|BetterDisplay
            SystemPolicyAllFiles|io.gone.tool

            """)
        runner.set("\(Tool.sqlite3) file:\(tree.phys(sysDB))?mode=ro \(query)",
                   stdout: "kTCCServiceAccessibility|com.dead.app\nkTCCServiceScreenCapture|com.sysonly.app\n")
        let fs = try TCCScanner().scan(context(tree, index: idx, runner: runner, fda: true))
        // cùng hàng ở cả hai CSDL → MỘT finding (lệch zsh: zsh ra 2 finding cùng ID)
        XCTAssertEqual(fs.map(\.id), ["TCC|com.dead.app|Accessibility", "TCC|io.gone.tool|SystemPolicyAllFiles",
                                      "TCC|com.sysonly.app|ScreenCapture"])
        // chỉ có trong CSDL hệ thống: `tccutil` quyền người dùng không gỡ được → chỉ báo (P5 mới làm)
        XCTAssertEqual(fs[2].action, .reportOnly)
        XCTAssertEqual(fs[0].severity, .medium)
        XCTAssertEqual(fs[0].reason, .tccOrphan(service: "Accessibility"))
        XCTAssertEqual(fs[0].action, .tccReset(service: "Accessibility", client: "com.dead.app"))
        XCTAssertFalse(Remover.needsAdmin(fs[0], env: tree.env))
    }

    /// Hành vi đã biết (giữ như zsh): client kiểu đường dẫn có ≥ 2 dấu chấm lọt `looks_like_bid`.
    func testTCCPathClientWithDotsKnownBehaviour() throws {
        let tree = FakeTree()
        let userDB = tree.write("\(home)/Library/Application Support/com.apple.TCC/TCC.db", "db")
        let runner = StubRunner()
        runner.set("\(Tool.sqlite3) file:\(tree.phys(userDB))?mode=ro SELECT DISTINCT service, client FROM access;",
                   stdout: "kTCCServiceCamera|/opt/x/bin/tool.v1.2\n")
        let fs = try TCCScanner().scan(context(tree, runner: runner, fda: true))
        XCTAssertEqual(fs.map(\.name), ["/opt/x/bin/tool.v1.2"])
    }
}
