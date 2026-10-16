# Đặc tả chuyển đổi: lõi dùng chung của MacTrash → `CleanCore`

Nguồn: `mactrash.sh` 1.5.0 (dòng ghi trong ngoặc là số dòng trong file gốc), `tests/mactrash_test.zsh`
(122 assertion, chạy xanh 122/122 trên máy này ngày 2026-10-16), `CHANGELOG.md`.
Phạm vi: giai đoạn **P0** trong `ROADMAP.md` — mô hình, chỉ mục app/hệ thống, heuristic mồ côi, danh sách bỏ qua,
lịch sử quét, FDA, chốt an toàn, Thùng rác, sửa file có backup, gỡ theo từng kiểu, sao lưu, `restore.sh`, khôi phục.
Các bộ quét cụ thể nằm ở spec khác; ở đây chỉ mô tả phần chúng dùng chung (`orphan_check`, `_report_orphan`,
`_scan_container`) và định dạng dữ liệu gỡ (`payload`) mà mỗi bộ quét phải sinh ra.

Quy ước trong tài liệu:
- `~` = `env.home`. Mọi đường dẫn tuyệt đối "hệ thống" (`/Applications`, `/Library/...`, `/etc/paths`, `/Volumes`,
  `/Users`...) được hiểu là `env.root + đường dẫn` (xem §2). Với máy thật `root = /`.
- "Giữ nguyên (parity)" = phải giống hệt zsh. "Khuyến nghị sửa" = lỗi/điểm yếu của bản gốc; người điều phối quyết định,
  mặc định **giữ hành vi an toàn hơn** và ghi rõ trong code comment.
- Các câu comment tiếng Việt được trích nguyên văn (*in nghiêng*) vì chúng ghi lại lỗi đã gặp thật — nên chép vào
  comment Swift tương ứng (rút gọn theo giọng `Sources/PowerCore`).

---

## 1. Mô hình dữ liệu

### 1.1 Severity
| Swift | zsh | Thứ hạng sắp xếp |
|---|---|---|
| `high` | `High` | 1 |
| `medium` | `Medium` | 2 |
| `info` | `Info` | 3 (mọi giá trị khác cũng rơi vào 3) |

### 1.2 Category — raw value PHẢI đúng chuỗi zsh (vì nằm trong finding ID)
`Path`, `EnvVar`, `AppSupport`, `Caches`, `Prefs`, `Containers`, `GroupContainer`, `SavedState`, `HTTPStorage`,
`WebKit`, `AppScripts`, `Cookies`, `Logs`, `LaunchAgent`, `LoginItem`, `Helper`, `Receipt`, `Security`, `Firewall`,
`TCC`, `SysExt`, `Symlink`, `LaunchServices`, `NativeMsg`, `Plugin`, `App`, `Docker`, `Xcode`, `DevCache`,
`Homebrew`, `Backup`, `Snapshot`, `Trash`, `AppFiles` (luồng gỡ app, P1), `Disk` (trình duyệt dung lượng, P2).
Chú ý hoa/thường: `TCC`, `HTTPStorage`, `SysExt`, `NativeMsg`, `LaunchServices`.

### 1.3 Kind (cách gỡ) và payload
zsh lưu payload trong `F_DATA`, các trường ngăn bởi `SEP=$'\x1f'`. Swift nên dùng enum có associated values; cột
"payload zsh" để đối chiếu và để ghi manifest.tsv.

| Kind (raw) | Payload Swift | Payload zsh | Ai sinh | Cần admin (non-root)? | Giai đoạn chạy được |
|---|---|---|---|---|---|
| `ReportOnly` | — | `''` | nhiều | không | không bao giờ gỡ |
| `TrashPath` | `path` | `path` (rỗng → dùng target) | orphan, Helper, Plugin, App, Docker, NativeMsg, Xcode, DevCache, Homebrew, Backup | nếu thư mục cha không ghi được | P0 |
| `Symlink` | `path` | `path` | Symlink | nếu thư mục cha không ghi được | P0 |
| `PathEntry` | `file`, `dir` | `file␟dir` | Path | nếu thư mục cha của `file` không ghi được | P0 |
| `EnvLine` | `file`, `line` (dòng nguyên văn) | `file␟line` | EnvVar | như trên | P0 |
| `LaunchdJob` | `plist`, `label`, `domain` (`gui/<uid>` hoặc `system`) | `plist␟label␟domain` | LaunchAgent | nếu thư mục cha của target không ghi được | P0 |
| `PkgReceipt` | `pkgID` | `pkg` | Receipt | **luôn** | P5 (P0 trả needsAdmin) |
| `FirewallApp` | `path` | `path` | Firewall | **luôn** | P5 (P0 trả needsAdmin) |
| `TccReset` | `service` (đã bỏ tiền tố `kTCCService`), `client` | `service␟client` | TCC | không | P0 |
| `LsRebuild` | — | `''` | LaunchServices | không | P0 |
| `Simulator` | — | `''` | Xcode | không | P3 |
| `Snapshot` | `snapshotName` | `com.apple.TimeMachine.<...>.local` | Snapshot | **luôn** | P3/P5 |
| `PurgeAny` | `path` | `path` | Disk | theo thư mục cha | P2 |
| `PurgeTrash` | `path` | `path` | Trash | theo thư mục cha | P2 |

### 1.4 Finding
Trường: `category`, `severity`, `name` (chuỗi ngắn), `target` (đường dẫn hoặc định danh, dạng chuỗi), `reason`
(enum, §1.6), `sizeMB` (Int, ≥0, mặc định 0 — xem §3.5; khuyến nghị lưu thêm `sizeBytes`), `kind`+payload, và
`needsAdmin` (tính lúc quét để UI hiện huy hiệu; **tính lại** lúc gỡ, xem §8.3).

**Finding ID** (`finding_id`, dòng 1184): `"\(category.rawValue)|\(name)|\(target)"` — đúng thứ tự, phân cách `|`,
không escape. Dùng cho ignore list và diff lịch sử. Hệ quả cần giữ:
- `name` và `target` là **dữ liệu**, không phải chuỗi giao diện, kể cả khi trông như tiếng Việt. Các tên/target cố
  định do bộ quét đặt phải giữ **nguyên văn** để ID tương thích ignore.txt cũ:
  `name = "Thùng rác"` (scan_trash), `name = "<N> bản ghi ma"` (scan_lsregister), `name = "PATH #<i>"` (scan_path,
  i là vị trí 1-based trong PATH), `target = "<rỗng>"` (mục PATH rỗng), `target = "(sfltool dumpbtm)"`,
  `name = "Background Task Management"`, `target = "simctl delete unavailable"`, `name = "<n> simulator"`,
  `name = "Homebrew cache"`, `name = "Library/Developer"`, `name = "DYLD_INSERT_LIBRARIES"`,
  `name = "sudoers.d/<file>"`, `name = "Archives/<x>"`. UI hiển thị bản dịch dựa trên `reason`/kind, không dựa trên
  `name` cho các trường hợp này.
- ID của PATH phụ thuộc vị trí (`PATH #3`): đổi thứ tự PATH là ID đổi. Giữ nguyên (parity).
- Đường dẫn chứa `|` hay xuống dòng làm ID mơ hồ / vỡ file ignore. Giữ nguyên định dạng; khi ghi ignore.txt bỏ qua
  ID chứa `\n` hoặc `\r` (khuyến nghị).

### 1.5 Sắp xếp (`sort_findings`, 2169)
Khóa: (thứ hạng severity tăng dần, `sizeMB` giảm dần, thứ tự chèn ban đầu tăng dần). Ổn định. zsh dùng khóa chuỗi
`rank + printf('%09d', 999999999 - size) + printf('%05d', index)`; tương đương với so sánh bộ ba ở trên.
Tổng dung lượng (`total_size_mb`) = tổng `sizeMB`.

### 1.6 Reason (thay cho `F_DETAIL`) — văn bản VI/EN để UI bản địa hóa
`{0}`, `{1}` là associated values theo thứ tự. VI lấy nguyên văn `_i18n_vi`, EN từ `_i18n_en`.

| Case đề xuất | Key | Tham số | VI | EN |
|---|---|---|---|---|
| `orphanBundleID(bid)` | DOrphanBid | bid đã cắt Team/group | Bundle id "{0}" không thuộc ứng dụng nào đang cài | Bundle id "{0}" does not belong to any installed app |
| `orphanName(name, days)` | DOrphanName | tên đã cắt, số ngày | Không có ứng dụng hay lệnh nào tên "{0}" (sửa lần cuối {1} ngày trước) | No installed app or command named "{0}" (last modified {1} days ago) |
| `deadDir(sourceFile?)` | DDeadDir | file khai báo (tùy chọn) | Thư mục không tồn tại *(+ " → {file}" khi có)* | Directory does not exist |
| `duplicatePath(firstIndex)` | DDupPath | chỉ số | Trùng lặp với mục #{0} | Duplicate of entry #{0} |
| `emptyPathEntry` | DEmptyPath | — | Mục rỗng (thừa dấu :) | Empty entry (stray colon) |
| `envDead(name, file?)` | DEnvDead | tên biến, file | {0} trỏ tới đường dẫn không tồn tại *(+ " ({file})")* | {0} points to a path that does not exist |
| `missingProgram(prog)` | DMissingProg | | Chương trình không tồn tại: {0} | Program does not exist: {0} |
| `ownerGone(x)` | DOwnerGone | | Ứng dụng chủ đã bị gỡ: {0} | Owning app was removed: {0} |
| `brokenSymlink(dest)` | DBrokenLink | đích hoặc `?` | Symlink gãy, trỏ tới: {0} | Broken symlink pointing to: {0} |
| `ghostLaunchServices(count)` | DGhostLS | | LaunchServices còn {0} bản ghi trỏ tới app đã xóa (gây trùng menu "Open With") | LaunchServices still holds {0} record(s) for deleted apps (duplicate "Open With" entries) |
| `nativeHostDead(path)` | DNativeDead | | Native messaging host trỏ tới file không tồn tại: {0} | Native messaging host points to a missing file: {0} |
| `pluginBroken(exe)` | DPluginBroken | | Bundle hỏng: thiếu file thực thi {0} | Broken bundle: missing executable {0} |
| `pluginOrphan(bid)` | DPluginOrphan | | Plugin của phần mềm đã gỡ ({0}) | Plugin belonging to removed software ({0}) |
| `helperOrphan` | DHelperOrphan | | Helper chạy quyền root còn sót của phần mềm đã gỡ | Root-privileged helper left behind by removed software |
| `helperNoJob` | DHelperNoJob | | Helper root không còn LaunchDaemon nào tham chiếu | Root helper is no longer referenced by any LaunchDaemon |
| `receiptOrphan` | DReceiptOrph | | Biên nhận gói cài của phần mềm đã gỡ (không còn file nào tồn tại) | Package receipt for removed software (none of its files remain) |
| `proxyRootCert(tool)` | DCertProxy | | Chứng chỉ gốc của công cụ proxy: {0} - CHỈ BÁO, tự xóa trong Keychain Access | Root certificate from a proxy tool: {0} - REPORT ONLY, remove it in Keychain Access |
| `tccOrphan(service)` | DTccOrphan | | Quyền riêng tư "{0}" còn cấp cho app đã gỡ | Privacy permission "{0}" still granted to a removed app |
| `sysExtStale(state)` | DSysExtStale | | System extension treo ở trạng thái: {0} | System extension stuck in state: {0} |
| `kextOrphan` | DKextOrphan | | Kernel extension của phần mềm đã gỡ | Kernel extension from removed software |
| `dockerGone` | DDockerGone | | Docker Desktop đã gỡ nhưng dữ liệu còn lại | Docker Desktop was removed but its data remains |
| `dyldInject(where)` | DDyldInject | | DYLD_INSERT_LIBRARIES trong {0} - kỹ thuật chèn thư viện, hãy kiểm tra | DYLD_INSERT_LIBRARIES in {0} - library injection, please review |
| `sudoers(file)` | DSudoers | | File sudoers thêm ngoài: {0} - CHỈ BÁO, tự đọc và quyết định | Third-party sudoers file: {0} - REPORT ONLY, read it and decide |
| `loginItemDead` | DLoginItemDead | | Mục khởi động trỏ tới đường dẫn không tồn tại | Login item points to a path that does not exist |
| `needAdminForBTM` | DNeedSudoBtm | | Cần sudo để đọc danh sách mục khởi động nền (sfltool dumpbtm) | sudo is required to read background login items (sfltool dumpbtm) |
| `hollowApp` | DHollowApp | | Vỏ .app rỗng: không có Info.plist lẫn file thực thi - ứng dụng đã đi, chỉ còn lại thư mục | Hollow .app shell: no Info.plist and no executable - the app is gone, only the folder is left |
| `brokenApp` | DBrokenApp | | Ứng dụng hỏng: thiếu file thực thi | Broken application: missing executable |
| `firewallDead` | DFirewallDead | | Luật tường lửa trỏ tới file không tồn tại | Firewall rule points to a missing file |
| `trashUsage(mb)` | DTrashUse | dung lượng | Thùng rác đang chiếm {0} - dùng mục "Dọn Thùng rác" để xem và chọn từng mục | Trash currently holds {0} - use the "Empty the Trash" action ... |
| P1–P3: `appBundle`, `appRelated(name)`, `xcodeDerived`, `xcodeDeviceSupport(v)`, `xcodeArchive`, `simUnavailable`, `cacheOrphan(cmd)`, `cacheActive(cmd, command)`, `brewOrphan`, `brewCache`, `snapshot(date)`, `mobileSync(date)`, `hostsBlock(domain)` | DAppBundle… | | (xem `_i18n_vi` dòng 93–276) | |

Ghi chú: zsh có một chỗ dùng `DOrphanName` với tham số cố định (`Xcode`, `0`) cho `~/Library/Developer` — vẫn là
`orphanName(name:"Xcode", days:0)`. Nhãn picker thêm tiền tố `(chỉ báo)` cho kind `ReportOnly` — việc của UI.

---

## 2. Seam tiêm được (bắt buộc cho test)

### 2.1 `ScanEnvironment` (Sendable, bất biến)
| Trường | Ý nghĩa | Máy thật |
|---|---|---|
| `root: URL` | tiền tố cho mọi đường dẫn hệ thống | `/` |
| `home: URL` | thư mục nhà của người dùng thật | `FileManager.homeDirectoryForCurrentUser` |
| `realUserHome: URL` | = `home` ở P0 (zsh: `MT_USER_HOME`, khác `HOME` chỉ khi chạy sudo) | = home |
| `userTrash: URL` | `realUserHome/.Trash` (zsh `MT_TRASH`) | |
| `uid: uid_t`, `userName` | cho domain `gui/<uid>` và chủ sở hữu | `getuid()` |
| `isRoot: Bool` | luôn `false` ở P0; giữ cho P5 | |
| `searchPath: [URL]` | thay cho `$PATH` khi tra lệnh (`command -v`) | xem §4.7 |
| `now: Date` | cho `days_since_*` và tên thư mục backup | `Date()` |
| `dataDir: URL` | `~/Library/Application Support/MacPowerManager/Cleanup` | |

Hàm phụ: `system(_ p: String) -> URL` = `root.appending(path: p)`; `logical(_ url: URL) -> String` = đường dẫn đã phân
giải (§3.9) bỏ tiền tố `root` đã phân giải (với root = `/` là đồng nhất). **Mọi chốt an toàn so sánh trên đường dẫn
logic**, để test với root giả vẫn dùng danh sách `NEVER_DELETE` nguyên bản.
Test nên dựng `home = root/Users/<tên>` để vòng lặp `/Users/*` trong `is_deletable_path` thấy nó.

### 2.2 `CommandRunner` (protocol, Sendable)
`run(executable: String, arguments: [String], timeout:) -> (status: Int32, stdout: String, stderr: String)`.
Chạy không qua shell (không nội suy). Test dùng bản giả trả output cố định theo (executable, args).
Lệnh lõi dùng tới: `launchctl list`, `launchctl bootout <domain>/<label>`, `launchctl bootstrap <domain> <plist>`,
`pkgutil --pkgs | --pkg-info <id> | --files <id> | --forget <id>`, `/usr/libexec/ApplicationFirewall/socketfilterfw
--remove <path>`, `tccutil reset <svc> <client>`, `<LSREGISTER> -kill -r -domain local -domain system -domain user`
(`LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister`),
`xcrun simctl delete unavailable`, `tmutil deletelocalsnapshots <date>`, `sw_vers -productVersion` (log).
Không dùng `plutil`, `du`, `stat`, `cp`, `mv`, `rm`, `readlink`, `/usr/bin/trash` qua runner — làm bằng Foundation/POSIX
(nhưng giữ đúng ngữ nghĩa mô tả ở dưới).

### 2.3 Đồng hồ / tên thư mục
`backup_init` và lịch sử dùng `yyyyMMdd_HHmmss` theo giờ địa phương (`date +%Y%m%d_%H%M%S`), POSIX locale.

---

## 3. Helper

### 3.1 `norm_name` (880)
`lowercased()` rồi **xóa** mọi ký tự không thuộc `[a-z0-9]` (ASCII). Không phiên âm: chữ có dấu bị xóa hẳn.
Ví dụ đo trên máy: `"Google Chrome"→"googlechrome"`, `"riot-client_ux.v2"→"riotclientuxv2"`,
`"Tiếng Việt Ñandú 2"→"tingvitand2"`, `"ÄBC"→"bc"`. Comment gốc nói "bỏ dấu" nhưng thực tế là xóa ký tự — giữ parity
(không dùng `folding(.diacriticInsensitive)`), vì chỉ mục và tên tra cứu đều qua cùng hàm nên vẫn nhất quán.
Test: "Chuẩn hóa tên" (2).

### 3.2 `looks_like_bid` (1292)
`n = lowercased`. Không chứa `.` → false. Nếu `n` bắt đầu bằng `<tld>.` với tld ∈
`com org net io co dev app us uk de fr nl se it es ru jp kr cn tv cc me ai xyz info biz eu ch at pl br in au ca no fi
dk cz gr sh to ly group edu gov` → true. Ngược lại true nếu có **≥ 2 dấu chấm** (`*.*.*`). Còn lại false.
Đo thật: `io.sentry` true; `pro.betterdisplay.BetterDisplay` true (2 chấm); `default.store`, `a.b` false;
`com.x`, `ai.chat`, `App.v2` true; **`"foo 1.2.3"` true** (xem §11 rủi ro). Test: "Nhận dạng bundle id" (5).

### 3.3 `looks_like_uuid` (1322)
`uppercased()` khớp chính xác `^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$` (chấp nhận chữ thường
vì đã upper). Test: "Nhận dạng UUID" (2).

### 3.4 `strip_team_prefix` (1334)
1. Nếu bắt đầu đúng `group.` (phân biệt hoa thường) → bỏ một lần.
2. Nếu phần còn lại khớp `^[0-9A-Z]{10}\.` (đúng 10 ký tự **HOA hoặc số**, rồi dấu chấm) → bỏ thành phần đầu.
*"Team ID luôn là 10 ký tự HOA + số. Bắt buộc hoa để không cắt nhầm bundle id thật có thành phần đầu dài 10 ký tự
thường."* Đo thật: `group.abcdefghij.com.x → abcdefghij.com.x`; `1234567890.x → x`; `GROUP.com.x` giữ nguyên.
Test: "Tách Team ID / group." (4).

### 3.5 `size_mb` (840)
Không tồn tại (theo `-e`, tức đi xuyên symlink; symlink gãy = không tồn tại) → 0. Ngược lại tương đương
`du -sxk <p>` / 1024 (chia nguyên, làm tròn xuống):
- đếm **dung lượng cấp phát** theo KiB (`du -k`), mỗi inode hardlink tính một lần;
- **không đi xuyên điểm mount** (`-x`): bỏ mục con có `st_dev` khác gốc. *"Thiếu nó, một volume được mount vào bên
  trong thư mục (vd runtime simulator ở /Library/Developer/CoreSimulator/Volumes) sẽ bị đếm như file thật:
  /Library/Developer báo 28 GB thay vì 2,5 GB."*
- không theo symlink bên trong cây; nếu chính `p` là symlink trỏ tới thư mục thì `du -s` báo kích thước của link (≈0).
- lỗi đọc mục con → bỏ qua, không làm hỏng tổng.
Đắt: chỉ tính sau khi đã quyết định báo (như zsh). Hỗ trợ hủy.

### 3.6 `human_size` (851) — thuộc UI
`mb ≥ 1024` → `String(format: "%.1f GB", mb/1024.0)` (dấu chấm thập phân, POSIX); ngược lại `"%d MB"`.
CleanCore không chứa chuỗi giao diện → đặt ở app target; 2 test "Định dạng kích thước" chuyển sang
`MacPowerManagerTests` (hoặc helper không bản địa hóa trong CleanCore nếu người điều phối muốn giữ test ở đây).

### 3.7 `days_since_modified` (872) / `days_since_trashed` (864)
`floor((now − t) / 86400)`; `t` = `st_mtime` (modified) hoặc `st_ctime` (trashed), đọc bằng **lstat** (stat(1) không
`-L`). Không stat được → 0. *Trashed dùng ctime "đổi khi đổi tên/di chuyển" vì mtime "có thể là nhiều năm trước, nên
hoàn toàn không nói lên bỏ vào thùng rác bao lâu rồi".* Lưu ý: mtime của **thư mục** chỉ đổi khi thêm/xóa mục con
trực tiếp — đó là ngữ nghĩa gốc, giữ nguyên.

### 3.8 `plist_get` (884)
`plist_get(file, keyPath) -> String?`:
- `file` phải là file thường (`-f`, đi xuyên symlink); không → nil.
- Đọc bằng `PropertyListSerialization` (XML, binary; plutil còn đọc được JSON — nên hỗ trợ fallback
  `JSONSerialization`). Parse lỗi → nil. *"plutil in thông báo lỗi ra stdout chứ không phải stderr, nên bắt buộc phải
  xét mã thoát - nếu không, chuỗi lỗi sẽ bị nhét vào biến như thể là giá trị."* — trong Swift nghĩa là: lỗi luôn → nil,
  không bao giờ trả chuỗi lỗi.
- `keyPath` tách theo `.`: thành phần trên dict là key, trên array là chỉ số thập phân. Không có → nil. (Hệ quả của
  plutil: không truy cập được key chứa dấu chấm. Bộ quét dùng `ProgramArguments.0`,
  `EnvironmentVariables.DYLD_INSERT_LIBRARIES`.)
- Định dạng "raw" như `plutil -extract K raw` (đo thật): String → chính nó (rỗng vẫn là `""`, khác nil);
  Bool → `true`/`false`; số → dạng thập phân; Date → ISO-8601; Data → base64; **Array → số phần tử**;
  **Dict → các key nối bằng `\n`** (thứ tự sắp xếp). Mọi chỗ gọi chỉ đọc String; chỉ cần đảm bảo không crash.
- Phía gọi thường coi "rỗng" = "không có" (`[[ -n $x ]]`).
Test: "plist_get" (3).

### 3.9 Phân giải đường dẫn kiểu zsh `${p:A}` — DÙNG CHUNG CHO MỌI CHỐT AN TOÀN
Đo thật trên máy này: `:A` = (1) biến thành tuyệt đối; (2) bỏ `.` và **xử lý `..` theo từ vựng TRƯỚC**
(`/t/T/lnk/..` → `/t/T`, trong khi `realpath(3)` cho `/t/real`); (3) phân giải symlink cho phần tiền tố **đang tồn
tại** bằng realpath; (4) nối phần đuôi chưa tồn tại nguyên văn (`/tmp/nonexist/x/../y` → `/private/tmp/nonexist/y`);
(5) bỏ `/` cuối. Kết quả giữ `/private` (`/var/root/.Trash` → `/private/var/root/.Trash`, `/etc` → `/private/etc`,
`/Volumes/Macintosh HD/Users` → `/Users`).
**Không dùng `URL.resolvingSymlinksInPath()` / `standardizingPath`**: Foundation tự cắt `/private` khỏi `/private/var`,
`/private/tmp`... làm hai vế so sánh lệch nhau — đúng loại lỗi CHANGELOG 1.3.0 đã sửa. Viết hàm `resolvedPath` dùng
`realpath(3)` trên tiền tố tồn tại dài nhất + nối đuôi, theo đúng thứ tự trên. Áp dụng cho **cả hai vế** mọi phép so.

### 3.10 Tra lệnh (`command -v`)
zsh `command -v X` đúng khi X là file thực thi trong `$PATH` **hoặc** builtin / từ khóa / hàm / alias của zsh. Swift:
- `X` chứa `/` → kiểm tra trực tiếp file thực thi.
- Ngược lại: true nếu `X` ∈ tập builtin + reserved word của zsh (danh sách đo được, giữ để không báo nhầm nhiều hơn
  bản gốc): `- : . [ alias autoload bg bindkey break builtin bye cd chdir command compadd comparguments compcall
  compctl compdescribe compfiles compgroups compquote compset comptags comptry compvalues continue declare dirs disable
  disown echo echotc echoti emulate enable eval exec exit export false fc fg float functions getln getopts hash history
  integer jobs kill let limit local log logout noglob popd print printf private pushd pushln pwd r read readonly
  rehash return sched set setopt shift source suspend test times trap true ttyctl type typeset ulimit umask unalias
  unfunction unhash unlimit unset unsetopt vared wait whence where which zcompile zformat zle zmodload zparseopts
  zregexparse zstyle ! [[ { } case coproc do done elif else end esac fi for foreach function if nocorrect repeat
  select then time until while`;
  hoặc tồn tại file thực thi (`access(X_OK)`, không phải thư mục) tên `X` trong một thư mục của `env.searchPath`.
- Tên chứa khoảng trắng vẫn tra bình thường (thường không thấy).

---

## 4. Chỉ mục app và hệ thống

Kết quả là một struct bất biến `AppIndex` (Sendable) dựng một lần mỗi lượt quét, chia sẻ cho mọi bộ quét:
`bundleIDs: [String: String]` (bid thường hóa → đường dẫn app hoặc `"pkg:<id>"`), `prefixes: Set<String>`,
`tokens: Set<String>`, `words: Set<String>`, `sysTokens: Set<String>`, `validApps: [URL]`, `deadApps: [URL]`,
cộng tham chiếu tra lệnh (§3.10).

### 4.1 `app_info_plist(app)` (897)
Trả file đầu tiên tồn tại (file thường) theo thứ tự: `app/Contents/Info.plist`, `app/Info.plist`,
`app/WrappedBundle/Info.plist`, rồi `app/Wrapper/*.app/Info.plist` (glob, thứ tự tên tăng dần, lấy cái đầu).
*"App iOS chạy trên Apple Silicon được bọc thành Wrapper/<Tên>.app/Info.plist (layout iOS, không có thư mục
Contents). Đọc thiếu layout này thì bundle id không bao giờ vào chỉ mục."* Không có → nil.

### 4.2 `bundle_id_of_app(app)` (908)
`plist_get(app_info_plist(app), "CFBundleIdentifier")`; không có plist → nil.
Test: 2 assertion `bundle_id_of_app` trong "Nhận dạng bundle ứng dụng".

### 4.3 `app_bundle_valid(app)` (921) — câu hỏi quan trọng nhất
1. Không có Info.plist ở đâu (§4.1) → **không hợp lệ** (vỏ rỗng).
2. `d` = thư mục chứa plist đó. `exe = plist_get(p, "CFBundleExecutable")`; nil hoặc rỗng → **hợp lệ** ("không khai báo
   thì tha").
3. Hợp lệ nếu tồn tại (`-e`, đi xuyên symlink) `d/MacOS/<exe>` hoặc `d/<exe>` (exe có thể là đường dẫn tương đối,
   layout iOS). Ngược lại không hợp lệ.
Comment cần giữ: *"Chỉ vì thư mục .app còn nằm đó KHÔNG có nghĩa ứng dụng còn được cài: trình gỡ cài đặt tồi, iCloud
Drive gỡ tải, hay xóa dở dang đều để lại cái vỏ rỗng. Nếu coi cái vỏ đó là 'app còn sống', toàn bộ tàn dư của nó sẽ
bị xem là hợp lệ và MacTrash im lặng - đúng lúc đáng lẽ nó phải lên tiếng nhất."*
Test: "Nhận dạng bundle ứng dụng" (5 assertion về hợp lệ), "Vỏ .app rỗng KHÔNG che giấu tàn dư" (3).

### 4.4 `_reg_bundle(bid, path)` (945)
`b = bid.lowercased()`; rỗng → bỏ. `bundleIDs[b] = path`. Rồi đăng ký **mọi tiền tố có ≥ 2 thành phần**: bỏ dần
thành phần cuối, mỗi lần còn chứa `.` thì thêm vào `prefixes` (vd `com.surfshark.vpnclient.macos` → thêm
`com.surfshark.vpnclient`, `com.surfshark`; không thêm `com`). *"Nhờ vậy container/cache mang id anh em
(com.surfshark.vpn) vẫn được coi là còn sống. Tiền tố 1 thành phần (com, org...) bị loại vì nó khớp mọi thứ."*

### 4.5 `_reg_token(name)` (976) và STOP_WORD
- `t = norm_name(name)`; `t.count ≥ 3` → thêm vào `tokens`.
- Từng từ: lấy `name.lowercased()`, thay mỗi ký tự không thuộc `[a-z0-9]` bằng khoảng trắng, tách theo khoảng trắng
  (bỏ phần rỗng); từ dài **≥ 4** và **không** thuộc STOP_WORD → thêm vào `words`.
  *"'Client Riot.app' -> riot. Nhờ vậy thư mục 'Riot Client' hay 'riot-client-ux' vẫn nhận ra là của phần mềm đang cài."*
- STOP_WORD (nguyên văn, 1 tập): `client server helper update updater tool tools manager service services agent
  launcher installer uninstaller setup desktop studio player viewer editor cloud mobile sync core base common shared
  data cache caches plugin plugins framework library driver support assistant browser engine monitor control center
  media audio video photo photos mail chat game games app apps main free pro plus lite home office work user users
  system config settings preference preferences default defaults temp tmp new old backup`.
  *"Từ quá chung: nếu nhận làm bằng chứng 'app còn sống' thì mọi thư mục tên 'Something Helper/Updater/Client' đều
  được tha -> bỏ sót thật sự."*
Test: "Từ chung không được coi là bằng chứng" (2).

### 4.6 `_reg_sys(name)` (994) và `build_sys_index` (999)
`_reg_sys`: `t = norm_name(name)`, `t.count ≥ 3` → `sysTokens`. *"Rất nhiều thư mục trong ~/Library/Application
Support và ~/Library/Caches là do các tiến trình này đẻ ra chứ không phải app nào cả - không có chỉ mục này thì chúng
bị báo nhầm hàng loạt."* (CHANGELOG: 113 kết quả rác so với 19 thật.)
Nguồn, theo thứ tự (mọi đường dẫn dưới `env.root`):
1. `/System/Library/LaunchAgents/*.plist`, `/System/Library/LaunchDaemons/*.plist`: `n` = tên file bỏ `.plist`;
   đăng ký `n` sau dấu chấm cuối (`com.apple.stickersd` → `stickersd`) và cả `n`.
2. `launchctl list` (qua runner): mỗi dòng tách theo khoảng trắng, lấy trường thứ 3 trở đi làm `lbl` (zsh
   `read -r _ _ lbl` — phần còn lại của dòng); rỗng → bỏ; đăng ký phần sau dấu chấm cuối và cả `lbl`.
   Parity: dòng tiêu đề `PID Status Label` cũng bị đọc → token `label` vào sysTokens (vô hại, giữ hoặc bỏ đều được;
   ghi rõ lựa chọn).
3. `/usr/libexec/*` và `/usr/libexec/*/*`: tên mục (mọi loại).
4. `/System/Library/CoreServices/*`: tên bỏ đuôi `.app`.
5. `/System/Library/PrivateFrameworks/*.framework`, `/System/Library/Frameworks/*.framework`: tên bỏ `.framework`.
6. `/System/Library/PrivateFrameworks/*/Support/*` (chỉ **file thường**) và
   `/System/Library/PrivateFrameworks/*/XPCServices/*` (mọi loại): tên bỏ đuôi `.xpc`.
Glob zsh không khớp file ẩn (tên bắt đầu `.`) — bỏ qua dotfile ở mọi glob trong spec này trừ khi nói khác.

### 4.7 `build_app_index` (1041)
1. Thư mục tìm app (theo thứ tự, bỏ cái không tồn tại): `/Applications`, `~/Applications`, `/System/Applications`,
   `/Applications/Utilities`, `/System/Applications/Utilities`, `/Applications/Setapp`, `/Users/Shared`,
   `/Library/Application Support/JetBrains/Toolbox/apps`, `/opt/homebrew/Caskroom`, `/usr/local/Caskroom`.
2. Trong mỗi thư mục: tương đương `find <d> -maxdepth 4 -name '*.app' -prune` — mọi mục (kể cả **symlink**) có tên
   kết thúc `.app` ở độ sâu 1…4, **không đi vào bên trong** một `.app`; `find` không theo symlink khi duyệt. Giữ mục
   nếu `-d` (đi xuyên symlink) là thư mục. *"KHÔNG lọc -type d: nhiều game/launcher đặt trong /Applications một symlink
   trỏ tới bundle thật ở /Users/Shared. Lọc -type d là mất hẳn app đó khỏi chỉ mục -> mọi thư mục dữ liệu của nó bị
   báo nhầm là mồ côi."* Symlink gãy bị loại hẳn (không vào deadApps). Trùng lặp (Utilities nằm trong /Applications)
   được phép; khuyến nghị khử trùng theo đường dẫn.
   `find` có phân biệt hoa thường với `-name '*.app'` → chỉ đuôi `.app` thường.
3. Với từng app: `app_bundle_valid` sai → `deadApps` (*"Vỏ .app rỗng đi vào DEAD_APPS để scan_brokenapps báo, đồng thời
   KHÔNG che giấu tàn dư của nó"*); đúng → `validApps`, `_reg_bundle(bundle_id_of_app)` nếu có, `_reg_token(tên file bỏ
   .app)` (tên **bên ngoài**, kể cả với app Wrapper).
4. `pkgutil --pkgs` (runner): mỗi dòng không rỗng → `_reg_bundle(pkg, "pkg:<pkg>")`. *"nhiều phần mềm không có .app
   nhưng vẫn 'đang cài'"*. (Xem rủi ro §11 #1.)
5. `/opt/homebrew/Cellar/*/`, `/usr/local/Cellar/*/` (chỉ thư mục): `_reg_token(tên)`.
6. `/Library/PreferencePanes`, `~/Library/PreferencePanes`, `/Library/Internet Plug-Ins`, `~/Library/Internet Plug-Ins`:
   mỗi mục (mọi loại) `ext`: `bid = plist_get(ext/Contents/Info.plist, CFBundleIdentifier)` → nếu không rỗng
   `_reg_bundle(bid, ext)`; luôn `_reg_token(tên bỏ đuôi cuối cùng)`.
7. TOOLCHAIN_PREFIX: nếu lệnh tồn tại (§3.10) thì thêm tiền tố vào `prefixes`:
   `org.swift→swift, org.python→python3, org.llvm→clang, org.nodejs→node, org.rust→cargo, org.gradle→gradle,
   org.apache→mvn, org.cocoapods→pod, org.videolan→vlc, org.mozilla→firefox, org.cups→lp, org.gnu→make,
   com.docker→docker, io.podman→podman, com.google.android→adb, sh.brew→brew`.
8. `build_sys_index`.

**`env.searchPath`** — điểm khác biệt lớn nhất với bản gốc: script chạy trong Terminal có `$PATH` đầy đủ của shell
đăng nhập; app GUI chỉ có `/usr/bin:/bin:/usr/sbin:/sbin`. PATH hẹp → `name_alive` và TOOLCHAIN báo **nhầm nhiều hơn**
(vd tàn dư `~/.cargo`, `Homebrew`...). Khuyến nghị dựng searchPath = hợp của: PATH tiến trình; `/etc/paths` +
`/etc/paths.d/*`; PATH của shell đăng nhập (`$SHELL -l -c 'print -r -- $PATH'` hoặc `printenv PATH`, qua runner, có
timeout, lỗi thì bỏ qua); danh sách dự phòng `/opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin /usr/local/sbin
~/.local/bin ~/bin ~/.cargo/bin ~/go/bin ~/.bun/bin ~/.deno/bin`. Test dùng searchPath giả.

### 4.8 `bid_alive(bid)` (1118)
`b = bid.lowercased()`. Theo thứ tự:
1. rỗng → **false**.
2. bắt đầu `com.apple.` | `apple.` | `group.com.apple.` → true (*"Apple: không bao giờ đụng"*).
3. `bundleIDs[b]` → true.
4. Vòng tổ tiên: `t = b`; lặp khi `t` chứa `.`: bỏ thành phần cuối; nếu `t` không còn `.` → dừng; nếu `bundleIDs[t]`
   hoặc `prefixes ∋ t` → true. (*"Là helper/thành phần con của một app đang cài? com.foo.bar.helper -> com.foo.bar"*)
5. `prefixes ∋ b` → true (bid chính là một tiền tố vendor đã đăng ký).
6. `last = norm_name(phần sau dấu chấm cuối)`; `last.count ≥ 4` và `tokens ∋ last` → true (*"vd: com.foo.Slack"*).
7. false.
Test: "Chỉ mục ứng dụng" (5 assertion bid_alive).

### 4.9 `name_alive(name)` (1142)
1. `n = norm_name(name)`; `n.count < 3` → **true** (*"tên quá ngắn -> không đủ tin cậy, coi như còn sống"*).
2. `sysTokens ∋ n` → true; `tokens ∋ n` → true.
3. Với mọi token `t` có `t.count ≥ 4`: `n` chứa `t` **hoặc** `t` chứa `n` → true (*"'GoogleChrome' chứa 'chrome', hoặc
   app 'Docker' nằm trong 'DockerDesktop'"*). Chỉ xét `tokens`, không xét `sysTokens`.
4. Tách từ của `name` như §4.5 (≥4 ký tự, không STOP_WORD); có từ thuộc `words` → true.
5. Lệnh tên `name.lowercased()` (nguyên chuỗi, chưa chuẩn hóa) tồn tại (§3.10) → true (*"Còn binary cùng tên trong
   PATH -> phần mềm CLI vẫn còn"*).
6. false.
Test: "Chỉ mục ứng dụng" (4 assertion name_alive), "Vỏ .app rỗng..." (2).

### 4.10 SYS_KEEP (1306) — thư mục do macOS/Apple quản lý, không bao giờ đánh dấu
So khớp **chính xác** với `norm_name(...)` (83 phần tử, `crashreporter` lặp 2 lần; dòng comment bên trong mảng không
phải phần tử — đã kiểm tra): `addressbook addressbooksourcesync animoji appstore appstored applemediaservices biome
callhistorydb callhistorytransactions cloudartifacts clouddocs cloudkit coresimulator crashreporter developer dock
facetime fileprovider findmy homekit icdd icloud knowledge mail mobilesync notes personalizationportrait quicklook
safari screensharing siri sms spotlight storekit syncedpreferences syncservices textinput translation ubiquity
weather apple appleintelligence containers caches preferences logs fonts keychains cookies webkit httpstorages audio
scripts services widgets accountpolicy assistant autofill logic proapps ilifemediabrowser garageband finalcut motion
compressor amsdatamigratortool btserver desktoppictures installation mobiledevice provisioningprofiles
sharedfilelist iconservices bookkeeping databases webpush mediakeys baseband privacypreservingmeasurement
diagnosticreports powerlog networkserviceproxy`.
Comment cần giữ: *"Tài nguyên dùng chung của bộ Pro/iLife: GarageBand và Logic xài chung thư mục 'Logic'/'ProApps' -
gỡ nhầm là mất hàng GB thư viện âm thanh."*

---

## 5. Heuristic mồ côi dùng chung

### 5.1 `orphan_check(name, path) -> Verdict` (1343)
Kết quả: `alive` hoặc `orphan(severity, reason)`. Thuật toán:
1. `name` rỗng → alive.
2. `norm_name(name) ∈ SYS_KEEP` → alive.
3. `looks_like_uuid(name)` → alive (*"container tạm, profile... không suy ra được chủ sở hữu"*).
4. `base = strip_team_prefix(name)`.
5. `base.lowercased()` khớp một trong các mẫu (glob, `.` là ký tự thường) → alive:
   `*com.apple.*` (ở **bất kỳ vị trí nào**, vd `group.com.apple.x`), `apple*`, `.*` (tên ẩn), `systemgroup.*`,
   `*.appleinternal.*`, `is.workflow.*`, `swift-playgrounds*`.
6. `norm_name(base) ∈ SYS_KEEP` → alive.
7. Nếu `looks_like_bid(base)`: `bid_alive(base)` → alive; ngược lại **orphan(high, orphanBundleID(base))**.
   (*"chỉ báo High khi có bằng chứng mạnh (bundle id rõ ràng, không khớp gì cả)"*)
8. Ngược lại: `name_alive(base)` → alive; ngược lại `d = days_since_modified(path)`; severity = `d ≥ 90 ? medium : info`;
   **orphan(sev, orphanName(base, d))**. (*"tên trần chỉ là suy đoán -> Medium/Info"*)
Lưu ý: reason dùng `base` (đã cắt), còn finding dùng `name` gốc.
Test: "orphan_check tha thư mục hệ thống" (5).

### 5.2 `_report_orphan(name, path, category)` (1373)
`orphan_check`; alive → không làm gì, trả false. Ngược lại `mb = size_mb(path)`; nếu `mb == 0` và sev là high → hạ
xuống **medium** (comment gốc ghi "hạ xuống mức thông tin" nhưng code hạ về Medium — giữ code; và "== 0" nghĩa là
**< 1 MiB cấp phát**, không phải rỗng). Thêm finding `(category, sev, name, target: path, reason, mb, .trashPath(path))`.

### 5.3 `_scan_container(dir, category, stripSuffix?)` (1386)
Thư mục không tồn tại → bỏ. Duyệt mục con là **thư mục** (glob `*(N/)`: đi xuyên symlink khi xét là thư mục, không
lấy dotfile), bỏ mục là symlink (*"symlink: để scanner symlink lo"*), bỏ file rời (*"file rời nằm ở gốc (default.store,
*.json, *.png) là dữ liệu của tiến trình khác, không suy ra được chủ sở hữu -> báo là chỉ tạo nhiễu"*). `name` = tên
mục, cắt hậu tố `stripSuffix` nếu có (vd `.savedState`). Gọi `_report_orphan(name, mục, category)`.
Hủy được giữa các mục.

---

## 6. Danh sách bỏ qua, lịch sử, FDA

### 6.1 Ignore list (1196–1224, 2114)
- File: `dataDir/ignore.txt` (zsh: `$MT_HOME/mactrash.ignore.txt`). Văn bản thuần, mỗi dòng một finding ID.
  *"Cố tình KHÔNG dùng JSON: sẽ phải gọi python3, mà /usr/bin/python3 trên máy chưa cài Command Line Tools sẽ bật hộp
  thoại cài đặt."* (Lý do không còn áp dụng cho Swift nhưng giữ định dạng để tương thích.)
- **load**: không có file → rỗng. Bỏ dòng rỗng và dòng bắt đầu `#`. Không trim (parity); khuyến nghị bỏ `\r` cuối dòng.
- **save(ids)**: hợp = cũ + mới, **khử trùng giữ lần xuất hiện đầu** (zsh `(u)`), ghi đè file: dòng 1 là header
  comment (zsh: `# MacTrash - các mục đã ẩn vĩnh viễn (xóa dòng để hiện lại)`; Swift dùng header tương đương với tên
  app — là nội dung file, không phải chuỗi UI), rồi từng ID một dòng. Ghi nguyên tử. Lỗi ghi → nuốt (zsh `2>/dev/null`);
  Swift nên trả lỗi cho UI.
- **apply**: sau khi mọi bộ quét chạy xong, **trước** khi sắp xếp: loại finding có ID ∈ ignore; `ignoredCount` = số
  bị loại. Ghi ignore xảy ra cả khi người dùng thoát picker bằng Esc (UI).
- Thứ tự trong `run_all_scans` (2140): reset → load ignore → check FDA → build index → các bộ quét → apply ignore →
  sort. Không có quét định kỳ.
Test: "Danh sách bỏ qua" (3).

### 6.2 `save_history_and_diff` (1226) — dữ liệu cho P4, lõi viết ở P0
- Thư mục `dataDir/ScanHistory/` (đề xuất; zsh `$MT_HOME/ScanHistory`). Tạo không được → bỏ qua lặng lẽ.
- `prev` = file `scan_*.txt` có tên lớn nhất theo thứ tự chuỗi **trước khi** ghi file mới. *"CẨN THẬN: script bật
  NULL_GLOB ... `ls -1` trần khi chưa có lịch sử -> liệt kê thư mục hiện tại và script đem so chính nó"* — trong Swift:
  liệt kê thư mục, lọc theo mẫu tên, rỗng là rỗng.
- Ghi `scan_<yyyyMMdd_HHmmss>.txt`: dòng 1 `# yyyy-MM-dd HH:mm`, sau đó mỗi finding ID một dòng (danh sách **sau** khi
  áp ignore, theo thứ tự đã sắp).
- Diff (bỏ dòng 1 của cả hai): `new = cur − prev`, `gone = prev − cur` (zsh `comm` trên dữ liệu đã sort = phép trừ đa
  tập; dùng Set là đủ vì ID hiếm khi trùng). Trả về `prevDate` (dòng 1 bỏ `# `), `newCount`, `goneCount`,
  `newIDs` (UI hiện tối đa 10, sắp theo thứ tự `sort` byte, rồi "... và {n−10} mục nữa"). Không có prev → `firstScan`.
- Giữ tối đa **12** file mới nhất, xóa các file cũ hơn.
- Chỉ gọi ở luồng quét đầy đủ và luồng dọn (không gọi ở devscan).
- Biên: hai lần quét trong cùng một giây → file mới ghi đè file cũ cùng tên và `prev` chính là nó → diff 0/0. Khuyến
  nghị thêm hậu tố khi trùng tên.
Chuỗi UI: DiffFirst / DiffNew `So với lần quét {0}: +{1} mục mới, {2} mục đã biến mất` / DiffMore.

### 6.3 `check_fda` (1280)
zsh: có FDA ⇔ đọc được (`-r`) `~/Library/Application Support/com.apple.TCC/TCC.db`. Trong Swift, `access(R_OK)` có thể
trả "được" dù TCC chặn lúc `open()`. Khuyến nghị: thử `open(O_RDONLY)` + đọc 1 byte (hoặc `FileHandle(forReadingFrom:)`),
thành công mới là có FDA. Kết quả `hasFullDiskAccess` truyền vào bộ quét (TCC chỉ chạy khi có). Kiểm tra cho chính
tiến trình MacPowerManager, không phải Terminal. UI mở `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.

---

## 7. Chốt an toàn

### 7.1 `is_sip_path(p)` (832)
True nếu `p` (logic, đã phân giải) bắt đầu bằng một trong: `/System/`, `/usr/lib/`, `/usr/libexec/`, `/bin/`,
`/sbin/`, `/usr/bin/`, `/usr/sbin/` (mẫu `X/*`: bản thân `/System` **không** khớp — đã có trong NEVER_DELETE).
`/usr/local` không phải SIP.

### 7.2 `NEVER_DELETE` (2328, nguyên văn)
`/ /System /Library /Users /Applications /private /var /etc /tmp /opt /usr /bin /sbin /cores /Volumes /home /net /dev
/private/var /private/etc /private/tmp /private/var/db /private/var/folders /usr/local /usr/bin /usr/sbin /usr/lib
/usr/libexec /usr/share /Library/Apple /Library/Developer /Library/Frameworks /Library/Keychains /Library/Preferences
"/Library/Application Support" /Library/LaunchDaemons /Library/LaunchAgents /Library/Extensions /Library/Security`

### 7.3 `is_deletable_path(p) -> Result<Void, DeleteRefusal>` (2318)
Comment: *"Trình duyệt dung lượng cho phép xóa BẤT KỲ thứ gì nó thấy, khác hẳn các module quét (chỉ đụng vào mục do
chính chúng tìm ra). Nên ở đây phải có một danh sách cấm rõ ràng: xóa nhầm /Library hay ~ là hỏng máy, không phải 'dọn
rác'."* Áp dụng cho cả TrashPath (*"chuyển /Library vào Thùng rác cũng hỏng máy y như xóa thẳng"*) lẫn PurgeAny.
Thứ tự (trả lý do đầu tiên gặp):
1. `p` rỗng hoặc không bắt đầu `/` → `invalidPath` ("đường dẫn không hợp lệ").
2. `rp = resolved(p)` (§3.9). Với mỗi `n` trong NEVER_DELETE: `p == n` (chuỗi thô) **hoặc** `rp == resolved(n)` →
   `criticalSystemDir` ("thư mục hệ thống trọng yếu"). (Với root giả: so trên đường dẫn logic.)
3. `is_sip_path(rp)` → `sipProtected` ("vùng do SIP bảo vệ").
4. `rp == resolved(realUserHome)` hoặc `rp == resolved(home)` → `homeDir` ("chính thư mục nhà").
5. Với mỗi thư mục `/Users/*` (đi xuyên symlink, không dotfile): `rp == resolved(u)` → `otherUserHome` ("thư mục nhà
   của người dùng khác") — bao gồm `/Users/Shared`.
6. `rp` bỏ `/` đầu mà không còn `/` nào (chỉ một cấp dưới gốc) → `rootLevel` ("thư mục ở gốc ổ đĩa").
7. OK.
Ghi chú: comment gốc nói "mọi thư mục CHA của thư mục nhà" nhưng code chỉ so bằng; cha của `/Users/x` là `/Users` và
`/` đã nằm trong danh sách. Nếu home ở chỗ khác (vd `/Volumes/Data/Users/x`) thì cha không được che — xem §11 #13.
Test: "is_deletable_path" (15), "PurgeAny từ chối đường dẫn hệ thống" (2).

### 7.4 `is_trash_path(p)` (2274) — chốt duy nhất cho xóa vĩnh viễn (P2, nhưng thuộc lõi)
*"Phân giải THƯ MỤC CHA (không phải chính mục đó) để vừa chặn được '..' vừa không đi xuyên qua symlink nằm trong Thùng
rác - dùng ${p:A} thẳng trên mục sẽ trả về đích của symlink, tức một chỗ nằm ngoài Thùng rác, và mục đó vĩnh viễn
không xóa được. Bản thân thư mục gốc Thùng rác cũng bị từ chối: chỉ xóa được thứ BÊN TRONG."*
1. `p` rỗng hoặc không bắt đầu `/` → false.
2. `tail` = thành phần cuối của `p` sau khi bỏ `/` cuối (zsh `:t`; `"/a/.Trash/"` → `.Trash`, `"/"` → `""`).
   `tail ∈ {"", ".", ".."}` → false.
3. `dir = resolved(parent(p))` (parent = zsh `:h`, theo từ vựng).
4. Roots: `userTrash`, `home/.Trash`; thêm `/var/root/.Trash` **chỉ khi** `isRoot`. Mỗi root `t` bỏ qua nếu rỗng, rồi
   `t = resolved(t)` — *"PHẢI phân giải cả hai vế. Trên macOS /var là symlink tới /private/var ... chốt an toàn sẽ từ
   chối nhầm chính những mục hợp lệ"* (thực tế: 67/67 mục bị từ chối). `dir == t` hoặc `dir` bắt đầu `t + "/"` → true.
5. `dir` khớp glob `/Volumes/*/.Trashes/*` (trong đó `*` khớp cả `/`) → true. (Mục nằm thẳng trong `.Trashes/<uid>`
   được chấp nhận; chính `.Trashes/<uid>` thì không.)
6. false.
Test: "is_trash_path" (13), "PurgeTrash từ chối mọi thứ ngoài Thùng rác" (6).

### 7.5 `is_precious_path(p)` (2348) — dùng cho cảnh báo ở P1/P2
`rp = resolved(p)`, `h = resolved(realUserHome)`. True nếu `rp == h/D` hoặc nằm dưới `h/D/` với `D ∈ {Documents,
Desktop, Pictures, Movies, Music, Downloads}`, hoặc `rp` **bắt đầu chuỗi** `h/Library/Mobile Documents` (không cần
`/`, iCloud Drive). Test: "is_precious_path" (4).

### 7.6 `_dir_is_empty(dir)` (2407)
Rỗng ⇔ không có mục con nào, **kể cả dotfile** (bỏ `.` và `..`). Test: "_dir_is_empty" (3).

---

## 8. Gỡ

### 8.1 `to_trash(p)` (2360)
1. `p` không tồn tại và cũng không phải symlink (lstat thất bại) → **thành công** (*"đã biến mất = coi như xong"*).
2. Không phải root: zsh dùng `/usr/bin/trash`. Swift: `FileManager.trashItem(at:resultingItemURL:)`; thành công →
   trả về **URL thực tế trong Thùng rác** (có thể đã bị đổi tên, hoặc nằm ở `.Trashes` của ổ khác). Ghi URL này vào
   manifest (cải tiến so với bản gốc, xem §9.5).
3. Dự phòng (khi trashItem lỗi, hoặc root): `mkdir -p userTrash`; `dest = userTrash/<tên>`; nếu `dest` tồn tại/là
   symlink → `dest = "<dest> HHmmss"`; `rename`/move. Root (P5): `chown -R` về người dùng thật. *"/usr/bin/trash bỏ vào
   Thùng rác của NGƯỜI ĐANG CHẠY. Dưới sudo đó là root, nghĩa là /var/root/.Trash: Finder không hiện, người dùng tưởng
   mất trắng."*
4. Lỗi → thất bại.
Không đi xuyên symlink: trash chính cái link.

### 8.2 `_rewrite_file(f, lines)` (2381)
zsh: ghi `lines` (mỗi dòng + `\n`) vào `f.mactrash.tmp`, `chmod` theo quyền gốc (`stat -f %Lp`), rồi `mv -f` đè `f`.
Hệ quả của bản gốc (đọc bằng `while IFS= read -r line`):
- **Dòng cuối không có `\n` bị MẤT** (đã kiểm tra: file `a\nb` chỉ đọc được 1 dòng). Có backup nên khôi phục được,
  nhưng là lỗi thật.
- Nếu `f` là **symlink** (dotfiles quản lý bằng repo), `mv` thay symlink bằng file thường.
- Chủ sở hữu/xattr/ACL không giữ.
Swift (khuyến nghị sửa, ghi comment): đọc toàn bộ nội dung UTF-8 (không đọc được UTF-8 → thất bại, không sửa), tách
dòng giữ nguyên kiểu xuống dòng và trạng thái có/không có `\n` cuối; nếu `f` là symlink thì sửa **file đích đã phân
giải**; ghi file tạm cùng thư mục, áp quyền (mode) gốc, `rename` nguyên tử. Không đổi gì nếu nội dung không đổi
(và báo `noChange` thay vì OK — xem §11 #7).

### 8.3 `finding_needs_sudo` → `needsAdmin(finding)` (2392)
1. `isRoot` → false.
2. kind ∈ {`PkgReceipt`, `FirewallApp`, `Snapshot`} → true.
3. kind ∈ {`ReportOnly`, `TccReset`, `LsRebuild`, `Simulator`} → false.
4. `t` = target; với `PathEntry`/`EnvLine` thì `t` = file trong payload. `t` rỗng → false.
5. Thư mục cha của `t` ghi được (`access(W_OK)`) → false; ngược lại true.
   (*"Không ghi được vào thư mục cha nghĩa là không xóa/sửa được mục đó"*.) Với LaunchdJob target = plist.
Đánh giá lúc gỡ (zsh); Swift tính cả lúc quét để hiện huy hiệu, và tính lại lúc gỡ.

**Lệnh tương đương trả về cho UI ở P0 (không chạy)** — đề xuất, quote bằng single-quote có escape:
| Kind | Lệnh |
|---|---|
| PkgReceipt | `sudo pkgutil --forget '<pkg>'` |
| FirewallApp | `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --remove '<path>'` |
| TrashPath / Symlink (cha không ghi được) | `sudo mv '<path>' '<home>/.Trash/'` (symlink: `sudo rm '<path>'`) |
| LaunchdJob (`/Library/...`) | `sudo launchctl bootout <domain>/<label>; sudo mv '<plist>' '<home>/.Trash/'` |
| PathEntry (`/etc/paths`, `/etc/paths.d/*`) | `sudo sed -i '' '\|^<dir>$|d' '<file>'` (hoặc hướng dẫn sửa tay) |
| EnvLine (`/etc/zshrc`...) | hướng dẫn comment dòng thủ công |
| Snapshot (P3) | `sudo tmutil deletelocalsnapshots <date>` |

### 8.4 `remove_one(finding) -> Outcome` (2415)
zsh trả 0 = xong, 1 = lỗi, 2 = chỉ báo nên bỏ qua, 3 = xong một phần; thông điệp ở `ERRMSG`. Swift `Outcome`:
`.done`, `.partial(note)`, `.skippedReportOnly`, `.needsAdmin(command)`, `.failed(RemovalFailure)`.
Mỗi kind (ghi manifest bằng `bk_record(kind, orig, rel, extra)` — §9.2):

**ReportOnly** → `.skippedReportOnly` ("chỉ báo, không tự gỡ"). Test: "Mục chỉ báo không bao giờ bị gỡ" (1).

**TrashPath**
1. `target = payload.path` (zsh: data nếu không rỗng, ngược lại target).
2. `is_deletable_path(target)` sai → `.failed(.refused(reason))` ("TỪ CHỐI: <lý do>"). *"Phòng thủ nhiều lớp - nếu sau
   này có module quét nào lỡ sinh ra một đường dẫn nguy hiểm, nó bị chặn ở đây."*
3. Ghi lại chủ sở hữu `user:group` (lstat, tên) **trước** khi chuyển. *"khôi phục bằng sudo mà không có thông tin này
   thì file quay về dưới quyền root, và app do người dùng tự kéo vào /Applications sẽ không tự cập nhật được nữa."*
4. `to_trash` lỗi → `.failed` ("không chuyển được vào Thùng rác").
5. Sau đó `target` vẫn tồn tại (`-e`) → `.failed` ("vẫn còn (đang bị khóa?)").
6. Ghi manifest `TrashPath, target, "", owner|"-"` (+ trashedPath trong JSON). `.done`.

**Symlink**
1. `dest = readlink(target)` (có thể rỗng).
2. zsh: `rm -f target` (không chốt, không vào Thùng rác). **Khuyến nghị sửa**: trước khi xóa, `lstat` xác nhận target
   **vẫn là symlink** (và vẫn gãy); nếu không → `.failed(.changedSinceScan)`. Lý do: `rm -f` lên một file thường mà
   người dùng tạo lại sau lần quét là xóa vĩnh viễn.
3. Lỗi → "không xóa được symlink". Ghi `Symlink, target, "", dest`. `.done`.
Test: "Vòng đời gỡ + khôi phục" (2).

**PathEntry** (payload `file`, `dir`)
1. `bk_save_file(file)` lỗi → `.failed` ("không backup được <file>"). Giữ `rel`.
2. Nếu `file == /etc/paths` hoặc dưới `/etc/paths.d/` (đường dẫn logic): bỏ hẳn **mọi** dòng bằng đúng `dir` (*"Định
   dạng 'mỗi dòng một thư mục'"*).
   Ngược lại (file cấu hình shell): mọi dòng **chứa chuỗi con** `dir` và **không bắt đầu** bằng `#` (không bỏ khoảng
   trắng đầu) → thay bằng `"# MacTrash đã tắt: " + dòng`; dòng khác giữ nguyên. *"comment lại, KHÔNG xóa (dòng có thể
   còn logic khác)"*.
3. `_rewrite_file` lỗi → `.failed` ("không ghi được <file>").
4. Ghi `PathEntry, file, rel, dir`. `.done`.
Tiền tố comment `# MacTrash đã tắt: ` là nội dung file; khuyến nghị giữ nguyên văn (người dùng tìm được bằng grep,
không code nào đọc lại nó) — hoặc đổi thành `# MacPowerManager đã tắt: ` nếu người điều phối muốn, nhưng một hằng số.

**EnvLine** (payload `file`, `line`)
Như PathEntry: backup; mọi dòng **bằng đúng** `line` (so nguyên văn, kể cả khoảng trắng) → comment với cùng tiền tố;
rewrite; ghi `EnvLine, file, rel, ""` (zsh ghi extra rỗng → `-`).

**LaunchdJob** (payload `plist`, `label`, `domain`)
1. `bk_save_file(plist)` — **lỗi bị bỏ qua** trong zsh (rel có thể rỗng → restore sẽ báo LỖI). Khuyến nghị: lỗi backup →
   `.failed`, vì không có backup thì không hoàn tác được (đúng triết lý). Ghi rõ là sai khác.
2. `launchctl bootout <domain>/<label>` — bỏ qua lỗi (*"bootout hay báo lỗi khi job vốn không được nạp - không coi là
   lỗi"*).
3. `to_trash(plist)` lỗi → `.failed` ("không chuyển được plist vào Thùng rác"). (zsh không gọi `is_deletable_path` ở
   đây; Swift nên gọi — plist nằm trong `~/Library/LaunchAgents/…` luôn qua chốt.)
4. Ghi `LaunchdJob, plist, rel, "<domain>/<label>"`. `.done`.

**PkgReceipt** (P0: `.needsAdmin`; mô tả cho P5) — ghi `pkgutil --pkg-info` vào `files/receipt_<pkg>.info`,
`pkgutil --files` vào `files/receipt_<pkg>.files`; `pkgutil --forget <pkg>` lỗi → "pkgutil --forget thất bại";
ghi `PkgReceipt, pkg, files/receipt_<pkg>.files, ""`.

**FirewallApp** (P0: `.needsAdmin`) — `socketfilterfw --remove <target>`; lỗi → "socketfilterfw --remove thất bại";
ghi `FirewallApp, target, "", ""`.

**TccReset** (payload `service`, `client`) — `tccutil reset <service> <client>`; exit ≠ 0 → "tccutil reset thất bại";
ghi `TccReset, client, "", service`. Ghi chú: mục đến từ TCC.db hệ thống (`/Library/...`) có thể không reset được
bằng quyền người dùng — chấp nhận `.failed` và báo.

**LsRebuild** — `<LSREGISTER> -kill -r -domain local -domain system -domain user`; lỗi → "dựng lại LaunchServices thất
bại"; ghi `LsRebuild, "LaunchServices", "", "đã dựng lại CSDL"`.

**Simulator** (P3) — `xcrun simctl delete unavailable`; lỗi → "simctl delete unavailable thất bại"; ghi
`Simulator, "simulators", "", ""`.

**Snapshot** (P3) — zsh lấy `snap = phần sau dấu chấm cuối của payload` rồi `tmutil deletelocalsnapshots <snap>`; ghi
`Snapshot, payload, "", ""`. **Lỗi bản gốc**: tên dạng `com.apple.TimeMachine.2024-01-15-123456.local` cho `snap =
"local"`; phải lấy phần ngày `2024-01-15-123456` (bỏ tiền tố `com.apple.TimeMachine.` và hậu tố `.local`). Lỗi tương
tự ở reason `DSnapshot` của bộ quét.

**PurgeAny** (P2) — *"nguy hiểm nhất trong cả chương trình vì nó không bị giới hạn trong Thùng rác. Chốt chặn phải
nằm ngay sát lệnh xóa"*: `is_deletable_path` sai → `.failed(refused)`; không tồn tại (cả lstat) → `.done`; xóa đệ quy
(không theo symlink); nếu vẫn còn: là thư mục và `_dir_is_empty` → `.partial(emptied)` + ghi `PurgeAny, t, "",
"đã dọn sạch nội dung, giữ lại thư mục rỗng"` (*"/Library/Caches ... Đó là kết quả TỐT NHẤT có thể đạt được - báo 'lỗi'
là sai sự thật"*); ngược lại `.failed` ("vẫn còn (thiếu quyền? thử sudo)"). Xóa hết → ghi `PurgeAny, t, "", "xóa vĩnh
viễn - không hoàn tác được"`, `.done`.
Ghi chú Swift: `FileManager.removeItem` dừng ở lỗi đầu tiên, không "xóa hết những gì xóa được" như `rm -rf`. Để giữ
ngữ nghĩa "một phần", tự duyệt cây từ dưới lên, xóa từng mục, bỏ qua lỗi, rồi kiểm tra lại.
Test: "Xóa được nội dung nhưng không gỡ được vỏ" (2), "PurgeAny từ chối" (2).

**PurgeTrash** (P2) — *"Đây là NƠI DUY NHẤT trong cả chương trình gọi rm -rf, và là thao tác duy nhất không hoàn tác
được"*: `is_trash_path` sai → `.failed` ("TỪ CHỐI: đường dẫn không nằm trong Thùng rác"); không tồn tại → `.done`;
xóa đệ quy **không theo symlink** (xóa link, không đụng đích); còn → `.failed` ("vẫn còn (đang bị khóa?)"); ghi
`PurgeTrash, t, "", "xóa vĩnh viễn - không hoàn tác được"`. Test: "PurgeTrash ..." (6).

**Kind khác** → `.failed(.unsupportedKind)` ("kiểu gỡ chưa hỗ trợ: <kind>").

Danh sách `RemovalFailure` (VI nguyên văn cho UI): `refused(DeleteRefusal)` "TỪ CHỐI: …", `trashFailed` "không chuyển
được vào Thùng rác", `stillPresent` "vẫn còn (đang bị khóa?)", `symlinkRemoveFailed` "không xóa được symlink",
`backupFailed(file)` "không backup được …", `writeFailed(file)` "không ghi được …", `plistTrashFailed`, `commandFailed
(tool)` "<tool> thất bại", `stillPresentNeedsAdmin` "vẫn còn (thiếu quyền? thử sudo)", `notInTrash`, `unsupportedKind`.
`partial` note: `ResEmptied` "đã xóa sạch nội dung; thư mục rỗng do macOS giữ lại".

### 8.5 `remove_selected(findings)` (2591)
1. `backup_init` lỗi → hủy toàn bộ, không gỡ gì ("Không tạo được thư mục backup").
2. Duyệt theo **thứ tự được truyền vào**; kiểm tra hủy giữa các mục (P0: cho phép dừng giữa chừng, các mục đã làm vẫn
   ghi manifest).
3. `needsAdmin` (§8.3) → không gọi remove_one; outcome `.needsAdmin(command)`; log `SUDO  <cat> | <name> | <target>`.
4. Ngược lại `remove_one`; log: `.done` → `OK    <cat> | <name> | <target>`; `.partial` → `MỘT PHẦN <cat> | <name> |
   <msg>`; `.skippedReportOnly` → `SKIP  …| <msg>`; `.failed` → `LỖI   … | <msg>`.
5. Đếm: ok (gồm partial), fail, skipSudo, skipInfo. Trả danh sách kết quả từng mục (`status`, `name`, `target`, `msg`)
   — UI xếp `fail, sudo, part, skip, ok` (test "Bảng kết quả..." thuộc UI).
6. Cuối cùng `write_restore_script` (luôn, kể cả khi không mục nào thành công).
Khuyến nghị bổ sung (không có trong zsh): trước khi chạy, bỏ các finding TrashPath có target là **con cháu** của một
TrashPath khác cũng được chọn (xem §11 #9), và khử trùng target giống hệt.

---

## 9. Sao lưu, manifest, khôi phục

### 9.1 `backup_init` (2219)
- Thư mục: `dataDir/<yyyyMMdd_HHmmss>/` (zsh `$MT_HOME/MacTrashBackups/<ts>`), con `files/`.
  Biên: zsh `mkdir -p` dùng lại thư mục cùng giây rồi **truncate manifest** → mất manifest của lần dọn trước. Swift: nếu
  đã tồn tại thì thêm hậu tố `_2`, `_3`… (vẫn bắt đầu bằng chữ số để lọc danh sách).
- `manifest.tsv` rỗng, `log.txt` 3 dòng: `MacTrash <ver> - <yyyy-MM-dd HH:mm:ss>` (Swift: `MacPowerManager <ver> - …`),
  `macOS <sw_vers> root=yes|no`, dòng trống. Swift thêm `manifest.json`.
- Reset bộ đếm seq và map đã-backup (theo phiên).

### 9.2 `bk_record(kind, orig, rel, extra)` (2236)
Một dòng TSV 4 cột; **ô trống ghi `-`**. *"TAB là ký tự khoảng trắng của IFS, nên `IFS=$'\t' read -r a b c d` GỘP hai
tab liền nhau thành một -> các cột sau bị dồn lên, và restore đọc nhầm cột (symlink từng được tạo lại với đích rỗng)."*
Swift ghi đồng thời:
- `manifest.json` (nguồn sự thật cho app): `{ "format": 1, "createdAt", "app", "appVersion", "macOS", "isRoot",
  "entries": [ { "kind", "original", "backupRel"?, "extra"?, "owner"?, "trashedPath"?, "findingID"?, "at" } ] }` —
  ghi lại (nguyên tử) sau mỗi entry để dừng giữa chừng vẫn còn manifest.
- `manifest.tsv` cùng dữ liệu (cho `restore.sh`, giống hệt định dạng zsh, kể cả `-`). Trường chứa TAB/xuống dòng:
  không ghi entry đó vào TSV (chỉ JSON) và ghi log.
Ý nghĩa `extra` theo kind: TrashPath = `user:group` gốc; Symlink = đích; PathEntry = dir; EnvLine = rỗng;
LaunchdJob = `domain/label`; TccReset = service; LsRebuild = "đã dựng lại CSDL"; Purge* = ghi chú.
Test: "manifest giữ đúng cột khi có ô trống" (4).

### 9.3 `bk_save_file(src) -> rel?` (2251)
- `src` không tồn tại → nil.
- Đã backup trong phiên này (khóa = chuỗi `src` nguyên văn) → trả lại `rel` cũ, **không chép lại**. *"Mỗi file chỉ chép
  MỘT lần, ở trạng thái trước mọi thay đổi."* Comment cần giữ (ý): *bản zsh trả kết quả qua biến toàn cục vì gọi bằng
  $(...) chạy trong subshell làm mất BK_SEQ/BK_SAVED; khi đó hai mục cùng sửa ~/.zshrc nhận cùng tên file backup và lần
  chép thứ hai GHI ĐÈ bản gốc bằng nội dung đã sửa -> mất khả năng hoàn tác.* Swift: trạng thái nằm trong một đối tượng
  phiên (class/actor), không copy theo giá trị.
- `seq += 1`; `safe` = tên file với mọi ký tự ngoài `[A-Za-z0-9._-]` thay bằng `_` (mỗi ký tự Unicode → một `_`);
  `rel = "files/" + String(format: "%03d", seq) + "_" + safe`.
- Chép `cp -a` (giữ quyền, thời gian; **symlink chép thành symlink**). Swift: nếu `src` là symlink (dotfile), khuyến
  nghị chép **nội dung file đích** (để backup tự đứng được) và ghi chú trong JSON; ngược lại `copyItem`. Lỗi → nil.
Test: "Backup không ghi đè bản gốc" (2).

### 9.4 `write_restore_script` (2749)
Sinh `restore.sh` (chmod +x) cạnh manifest.tsv, chạy độc lập bằng `zsh restore.sh`. Chép nguyên logic zsh (dòng
2751–2833), chỉ đổi chữ ký "MacTrash" nếu muốn. Hành vi:
- `cd` vào thư mục chứa script; thiếu manifest.tsv → thoát 1.
- Mỗi dòng (`IFS=$'\t' read -r kind orig rel extra`), bỏ kind rỗng, `-` → rỗng.
- PathEntry/EnvLine: `rel` tồn tại và `cp -a rel orig` → OK; ngược lại LỖI.
- LaunchdJob: như trên + `launchctl bootstrap <extra trước '/'> orig` (bỏ lỗi).
- Symlink: `ln -s extra orig` (không kiểm tra tồn tại trước; đã có → LỖI).
- TrashPath: ứng viên theo thứ tự `$HOME/.Trash/<tên>`, `/Users/$SUDO_USER/.Trash/<tên>` (nếu có SUDO_USER),
  `/var/root/.Trash/<tên>`. `orig` đã tồn tại → "BỎ QUA" (đếm manual) — *"không bao giờ ghi đè thứ đã được tạo lại sau
  lần dọn"*; có ứng viên → `mkdir -p` cha, `mv` về; chown -R theo **chủ thư mục cha** nếu không phải root; lỗi → LỖI;
  không thấy → "THỦ CÔNG".
  Swift cải tiến (tùy chọn): dùng `trashedPath` làm ứng viên **đầu tiên**. **Không** thêm cột thứ 5 vào manifest.tsv:
  `read -r kind orig rel extra` dồn mọi phần thừa (kể cả TAB) vào `extra`, làm hỏng đích symlink / owner. Nếu muốn,
  nhúng bảng `orig → trashedPath` dạng mảng kết hợp zsh ngay trong `restore.sh`. Tối thiểu: giữ nguyên bản gốc.
- PkgReceipt/FirewallApp/TccReset → THỦ CÔNG; PurgeTrash/PurgeAny → "KHÔNG THỂ"; khác → "BỎ QUA".
- Cuối: `Xong: <ok> khôi phục, <fail> lỗi, <manual> cần làm tay.`
Test: "Vòng đời gỡ + khôi phục" — restore.sh tạo lại symlink đúng đích.

### 9.5 `restore_from_manifest(dir)` (2673) — khôi phục trong app
*"flow_restore cố ý gọi hàm này thay vì thực thi restore.sh nằm trong thư mục backup: bản backup cũ vì thế tự động
hưởng mọi bản vá sau này."* Swift đọc `manifest.json` (thiếu → đọc `manifest.tsv` để mở được backup cũ của chính app).
Kết quả mỗi entry: `.restored`, `.failed(msg)`, `.manual(msg)`; tổng ok/fail/manual. Theo kind:
- **TrashPath** (zsh gộp chung nhánh với PurgeTrash/PurgeAny):
  - `orig` đã tồn tại (hoặc là symlink) → manual "BỎ QUA đã có ở chỗ cũ".
  - Tìm nguồn: (Swift) `trashedPath` nếu còn tồn tại; rồi `userTrash/<tên>`, `home/.Trash/<tên>`, `/var/root/.Trash/<tên>`.
  - Có → tạo thư mục cha, move về; thành công → chủ sở hữu: `extra` chứa `:` → dùng nó; ngược lại chủ thư mục cha nếu
    không phải root; `chown -R` (P0 chạy quyền người dùng: chỉ thử, lỗi bỏ qua — thường chủ đã đúng). Lỗi move →
    failed "thiếu quyền? thử sudo".
  - Không thấy → manual "KHÔNG THẤY trong Thùng rác nào (đã đổ?)".
  - **Rủi ro bản gốc**: tra theo **tên cuối** nên có thể kéo nhầm một mục khác trùng tên mà người dùng bỏ vào Thùng
    rác sau này, và `trashItem` có thể đã đổi tên (`foo 2`) nên không thấy. Dùng `trashedPath` khắc phục cả hai; chỉ
    lùi về tra theo tên khi không có `trashedPath` (manifest cũ).
- **PurgeTrash** → manual "KHÔNG THỂ đã xóa vĩnh viễn".
- **PurgeAny** → zsh rơi vào nhánh TrashPath (lỗi: có thể kéo một mục trùng tên trong Thùng rác về chỗ đã bị xóa
  vĩnh viễn). Swift: xử lý như PurgeTrash (manual "KHÔNG THỂ"), giống `restore.sh`.
- **PathEntry/EnvLine**: `backupRel` có và file backup tồn tại → chép đè `orig` → restored; ngược lại failed.
  Khuyến nghị: nếu `orig` đã bị sửa sau lần dọn (so hash với nội dung ngay sau khi MacPowerManager ghi, lưu trong JSON)
  thì báo cho UI xác nhận trước khi đè — tránh mất chỉnh sửa mới của người dùng.
- **LaunchdJob**: như trên rồi `launchctl bootstrap <domain> <orig>` (domain = `extra` trước `/`, bỏ lỗi).
- **Symlink**: `orig` đã tồn tại → manual "BỎ QUA đã có"; `symlink(extra, orig)` thành công → restored; lỗi → failed.
- **PkgReceipt** → manual "biên nhận gói '<orig>' không nạp lại được"; **FirewallApp** → manual "thêm lại luật tường
  lửa: <orig>"; **TccReset** → manual "quyền '<extra>' sẽ được hỏi lại khi app chạy".
- Khác (LsRebuild, Simulator, Snapshot) → manual "BỎ QUA <kind> <orig>".
Chuỗi tổng: `RestoreDone` "Khôi phục xong: {0} OK, {1} lỗi." + "({manual} cần làm tay)".

### 9.6 Liệt kê bản backup (`flow_restore`, 3878)
Các thư mục con của `dataDir` có tên bắt đầu bằng chữ số (zsh `[0-9]*(N/)`), **mới nhất trước** (sắp chuỗi giảm dần);
số mục = số dòng không rỗng của manifest (Swift: số entry). Không có → "Chưa có bản backup nào". Thư mục `ScanHistory`
và file `ignore.txt` nằm cùng `dataDir` nhưng không bắt đầu bằng chữ số nên không lẫn.

---

## 10. Đồng thời, hủy, quyền
- `AppIndex`, `ScanEnvironment`, `Finding` là value type Sendable. Bộ quét là hàm đồng bộ `scan(index, env, runner,
  isCancelled) -> [Finding]`, chạy ngoài main thread; kiểm tra hủy giữa các mục và trước mỗi `size_mb`.
- Phiên gỡ (`BackupSession`) giữ trạng thái `seq`/map backup — một đối tượng tham chiếu, dùng tuần tự.
- P0 không bao giờ gọi `sudo`, không `chown` người khác; mọi nhánh `isRoot` để sẵn cho P5.
- Không tự động quét; không ghi gì ra đĩa khi chỉ quét, ngoài file lịch sử (§6.2).

---

## 11. Heuristic và điểm yếu cần lưu ý (đã kiểm chứng trên code/máy)

| # | Vấn đề | Hệ quả | Đề xuất |
|---|---|---|---|
| 1 | `build_app_index` đăng ký **mọi** id từ `pkgutil --pkgs` vào `bundleIDs`; `scan_receipts` lại duyệt đúng danh sách đó rồi gọi `orphan_check` → id luôn "còn sống" khi trông giống bundle id | Bộ quét biên nhận gói gần như **không bao giờ** báo (chỉ id không giống bid mới lọt) | Bộ quét Receipt phải kiểm tra mồ côi với chỉ mục **không có** nguồn pkgutil (ví dụ `AppIndex` giữ cờ nguồn cho mỗi bid). Báo người điều phối; không âm thầm đổi. |
| 2 | Tiền tố vendor: một app `com.google.*` / `com.microsoft.*` làm mọi id cùng vendor sống; pkg id cũng đăng ký tiền tố | Bỏ sót (an toàn, đúng triết lý "không đoán bừa") | Giữ parity. |
| 3 | `name_alive` so chuỗi con hai chiều (`t` chứa `n` với `n` chỉ 3 ký tự) | Bỏ sót nhiều với tên ngắn | Giữ parity. |
| 4 | `command -v` của zsh tính cả builtin/từ khóa; app GUI có PATH hẹp | PATH hẹp → **báo nhầm** tàn dư CLI còn dùng | §3.10 + §4.7 searchPath mở rộng. Rủi ro lớn nhất khi port. |
| 5 | `looks_like_bid` coi mọi tên có ≥ 2 dấu chấm là bundle id (`"Foo 1.2.3"`, `"file.tar.gz"`) và tên bắt đầu `app.`/`me.`/`in.`… | Báo nhầm ở mức **High** (vì nhánh bid) | Giữ parity; ghi test mô tả hành vi. Có thể cân nhắc yêu cầu không có khoảng trắng (cần quyết định). |
| 6 | `norm_name` xóa ký tự có dấu/CJK | Tên app tiếng Việt/Nhật bị rút ngắn; nếu < 3 ký tự thì coi là còn sống (an toàn) | Giữ parity. |
| 7 | `_rewrite_file`: mất dòng cuối không có `\n`; thay symlink dotfile bằng file thường; PathEntry comment **mọi** dòng chứa chuỗi con `dir` (có thể là dòng `if [ -d dir ]; then` → hỏng cú pháp shell, hoặc dòng thêm nhiều thư mục cùng lúc); `_path_source_file` có thể trỏ vào file chỉ nhắc `dir` trong comment → ghi lại không đổi mà vẫn báo OK | Hỏng file khởi động shell (có backup) | §8.2 sửa mất dòng & symlink; báo `noChange` khi không dòng nào đổi. Cân nhắc chỉ comment dòng có dạng gán `PATH=`/`export PATH`/`path+=` — cần quyết định vì lệch heuristic gốc. |
| 8 | Kind `Symlink` dùng `rm -f` không kiểm tra lại | Xóa vĩnh viễn file thật nếu người dùng tạo lại sau khi quét | §8.4: xác nhận vẫn là symlink gãy. |
| 9 | Chọn cả cha lẫn con TrashPath (vd Docker + Containers cùng trỏ `~/Library/Containers/com.docker.docker`, hoặc lồng nhau) | Con được trash trước thì khi khôi phục, `mkdir -p` tạo lại cha rỗng → cha bị "BỎ QUA đã có", nội dung kẹt trong Thùng rác | §8.5: bỏ con cháu và trùng lặp trước khi chạy. |
| 10 | Khôi phục TrashPath tra theo tên cuối; PurgeAny bị khôi phục qua nhánh Thùng rác | Kéo nhầm mục trùng tên | §9.5 `trashedPath`; PurgeAny = không khôi phục. |
| 11 | Thư mục backup trùng giây → truncate manifest cũ | Mất khả năng hoàn tác lần trước | §9.1 hậu tố. |
| 12 | `${p:A}` xử lý `..` theo từ vựng trước symlink; Foundation cắt `/private` | Chốt an toàn lệch | §3.9 hàm riêng, test với `/var`→`/private/var` và symlink giữa đường dẫn. |
| 13 | `is_deletable_path` không chặn `~/Library`, `~/Library/Application Support`, `~/Library/Caches`, `~/Documents`, `~/.ssh`… (chỉ chặn đúng `~`) | Lớp phòng thủ cuối không chặn được nếu một bộ quét sinh nhầm các đường dẫn này | Khuyến nghị thêm danh sách cấm theo home (`~/Library` và các thư mục gốc Library mà bộ quét duyệt, `~/Documents`… , `~/.Trash`) chỉ cho TrashPath từ bộ quét; giữ test gốc vẫn xanh. Cần quyết định. |
| 14 | `check_fda` bằng `-r` | `access()` có thể nói dối với TCC | §6.3 thử mở thật. |
| 15 | `_report_orphan` hạ High → Medium khi `< 1 MiB` (comment nói "thông tin"); orphan theo tên dùng mtime thư mục | Mức độ hơi khác cảm nhận | Giữ code, sửa comment cho đúng. |
| 16 | `lsregister -kill` có thể bị bỏ/khác trên macOS mới; dựng lại CSDL tốn thời gian và làm mới "Open With" | Lệnh thất bại | Coi exit ≠ 0 là failed, không retry. |
| 17 | `Snapshot`: `${s##*.}` = `local` | Xóa snapshot luôn hỏng; reason hiện "local" | Sửa ở P3 (§8.4). |
| 18 | `launchctl list` header → sys token `label` | Thư mục tên "Label" không bao giờ bị báo | Vô hại; chọn và ghi rõ. |

---

## 12. Danh mục test zsh (122 assertion) → XCTest

Cột "P": giai đoạn chứa code được test. "Ghi chú port" nêu cách dựng tương đương trong Swift (cây giả dưới `env.root`,
runner giả). Tất cả test gốc chỉ đụng `/tmp`; bản Swift dùng thư mục tạm riêng mỗi test.

### 12.1 Chuẩn hóa tên — P0 (`norm_name`)
1. `"Google Chrome"` → `googlechrome`.
2. `"riot-client_ux.v2"` → `riotclientuxv2`.

### 12.2 Nhận dạng bundle id — P0 (`looks_like_bid`)
3. `com.foo.bar` → true. 4. `io.sentry` → true. 5. `pro.betterdisplay.BetterDisplay` → true.
6. `BetterDisplay` → false. 7. `default.store` → false (1 dấu chấm, TLD lạ).

### 12.3 Tách Team ID / group. — P0 (`strip_team_prefix`)
8. `YHUG37CKN8.com.surfshark.vpn` → `com.surfshark.vpn`.
9. `group.com.facebook.family` → `com.facebook.family`.
10. `group.UBF8T346G9.com.ms.rdc` → `com.ms.rdc`.
11. `sourceforge.app.x` → giữ nguyên (thành phần đầu 10 ký tự thường).

### 12.4 Nhận dạng UUID — P0
12. `0A2F4E1B-363A-41F8-BFA9-7706E6A02950` → true. 13. `com.foo.bar` → false.

### 12.5 Chỉ mục ứng dụng — P0
Dựng chỉ mục rỗng rồi: `_reg_bundle("com.surfshark.vpnclient.macos", "/Applications/Surfshark.app")`,
`_reg_token("Client Riot")`, `_reg_sys("stickersd")`. Searchpath giả rỗng (không có lệnh nào).
14. `bid_alive com.surfshark.vpnclient.macos` → true (chính xác).
15. `bid_alive com.surfshark.vpn` → true (anh em cùng vendor, qua tiền tố `com.surfshark`).
16. `bid_alive com.surfshark.vpnclient.macos.helper` → true (con).
17. `bid_alive com.evilcorp.thing` → false.
18. `bid_alive com.apple.whatever` → true.
19. `name_alive "Riot Client"` → true (khớp từ `riot`).
20. `name_alive "riot-client-ux"` → true.
21. `name_alive "stickersd"` → true (sys token).
22. `name_alive "ZzzKhongCoThatDau"` → false (cần searchPath giả không chứa lệnh này).

### 12.6 Từ chung không được coi là bằng chứng — P0
Xóa `words`, `_reg_token("Some Client")`.
23. `words` không chứa `client`. 24. `words` chứa `some`.

### 12.7 orphan_check tha thư mục hệ thống — P0
Path là một thư mục tạm có thật. Chỉ mục: trạng thái còn lại từ 12.5/12.6 (không ảnh hưởng kết quả).
25. `com.apple.Safari` → alive. 26. `is.workflow.my.app` → alive. 27. `systemgroup.com.apple.x` → alive.
28. `group.com.apple.x` → alive (com.apple lồng bên trong). 29. `logic` → alive (SYS_KEEP, tài nguyên Pro).

### 12.8 plist_get — P0
File XML có `Label = com.test.job`.
30. key `Label` → `com.test.job`. 31. key `KhongCo` → rỗng/nil. 32. file không tồn tại → rỗng/nil (không chứa thông báo
lỗi).

### 12.9 Backup không ghi đè bản gốc — P0
`backup_init` trong thư mục tạm; file `cfg.txt` nội dung `dòng gốc`; `bk_save_file` → rel1; sửa file thành `ĐÃ BỊ SỬA`;
`bk_save_file` lần 2 → rel2.
33. rel2 == rel1. 34. nội dung `<backupDir>/<rel1>` == `dòng gốc`.

### 12.10 manifest giữ đúng cột khi có ô trống — P0
Manifest rỗng, `bk_record(Symlink, "/tmp/a", "", "/dich/cua/no")`, đọc lại dòng 1 tách TAB.
35. kind = `Symlink`. 36. orig = `/tmp/a`. 37. rel = `-`. 38. extra = `/dich/cua/no` (không bị dồn cột).
Swift: kiểm tra cả manifest.tsv (y hệt) và manifest.json (rel nil, extra đúng).

### 12.11 Vòng đời gỡ + khôi phục — P0
`<tmp>/bin/deadlink` → symlink tới `/khong/co/that`; finding `(T, High, dead, target, ..., Symlink, path)`; remove_one.
39. `deadlink` không còn là symlink.
`write_restore_script`, chạy `zsh restore.sh` (test Swift: chạy `/bin/zsh` trên thư mục tạm qua `Process` — chỉ đụng
thư mục tạm; đồng thời test `restoreFromManifest` của Swift).
40. `readlink(deadlink)` == `/khong/co/that`.
Lưu ý: test gốc dùng category `T` (không thuộc enum) — Swift dùng category bất kỳ.

### 12.12 Mục chỉ báo không bao giờ bị gỡ — P0
41. ReportOnly → remove_one trả 2 (`.skippedReportOnly`).

### 12.13 Sắp xếp kết quả — P0
Thêm theo thứ tự: (Info, `nho`, 5), (High, `to`, 100), (High, `rat_to`, 900), (Medium, `giua`, 50).
42. [1] = `rat_to`. 43. [2] = `to`. 44. [3] = `giua`. 45. [4] = `nho`.

### 12.14 Danh sách bỏ qua — P0
ignore file tạm; findings `giu`, `bo_di` (cùng cat `C`, target `t`); `save_ignore(id(bo_di))`; load; apply.
46. còn 1 finding. 47. finding còn lại là `giu`. 48. `ignoredCount` == 1.
Swift thêm: file có header `#` và dòng rỗng bị bỏ qua; ID trùng không bị ghi 2 lần.

### 12.15 Định dạng kích thước — UI (`human_size`)
49. 512 → `512 MB`. 50. 2048 → `2.0 GB`.

### 12.16 Thay tham số i18n — UI (`tr_`)
51. `tr_ DDupPath 7` → `Trùng lặp với mục #7`. (Port thành test bản địa hóa của app: reason `duplicatePath(7)` → chuỗi VI.)

### 12.17 Nhận dạng bundle ứng dụng — P0
Dựng: `Good.app` (Contents/Info.plist với `CFBundleIdentifier=com.test.Good`, `CFBundleExecutable=run`, có
`Contents/MacOS/run`); `NoExe.app` (plist như trên, `com.test.NoExe`, không có `run`); `Hollow.app/Contents` (không
plist); `Empty.app` (rỗng); `Wrapped.app/Wrapper/Inner.app/Info.plist` với `CFBundleIdentifier=vn.test.Wrapped`, không
có CFBundleExecutable.
52. Good → hợp lệ. 53. NoExe → không hợp lệ. 54. Hollow → không hợp lệ. 55. Empty → không hợp lệ.
56. Wrapped → hợp lệ. 57. `bundle_id_of_app(Wrapped)` = `vn.test.Wrapped`. 58. `bundle_id_of_app(Good)` = `com.test.Good`.

### 12.18 Vỏ .app rỗng KHÔNG che giấu tàn dư — P0
Chỉ mục rỗng; với Good và Hollow: hợp lệ → `_reg_token(tên)`, không → deadApps. (Swift: chạy `build_app_index` thật
trên `root/Applications` chứa hai app này, runner giả trả `pkgutil --pkgs` rỗng, `launchctl list` rỗng.)
59. `name_alive Good` → true. 60. `name_alive Hollow` → false. 61. `deadApps.count` == 1.

### 12.19 collect_app_files — P1 (luồng gỡ app; port khi làm P1)
HOME giả có `Library/Caches/com.demo.App`, `Library/Application Support/DemoApp`, `Library/Caches/com.khac.KhongLienQuan`,
`Library/Preferences/com.demo.App.helper.plist`; `collect_app_files("com.demo.App", "DemoApp")`.
62. gom đúng 3 mục (theo bid, id con, theo tên). 63. không gom `KhongLienQuan`.

### 12.20 is_trash_path — lõi (dùng ở P2), port ngay ở P0
HOME giả: `.Trash/sub/`, `quantrong/khong-duoc-xoa.txt`, `.Trash/rac.txt`, `.Trash/link-ra-ngoai` → symlink tới
`$HOME/quantrong`.
64. `.Trash/rac.txt` → true. 65. `.Trash/sub/x` (không tồn tại) → true. 66. `.Trash/link-ra-ngoai` → true.
67. `$HOME/.Trash` → false. 68. `$HOME/.Trash/../quantrong` → false. 69. `$HOME/quantrong` → false.
70. `$HOME` → false. 71. `/` → false. 72. `/Applications/Safari.app` → false. 73. `rac.txt` (tương đối) → false.
74. `""` → false.
Alias: `<tmp>/varlink/real/.Trash`, `<tmp>/varlink/alias` → symlink tới `real`; đặt `userTrash = .../alias/.Trash`.
75. `.../real/.Trash/x` → true. 76. `.../alias/.Trash/x` → true.
Swift thêm (khuyến nghị): thư mục tạm của test nằm dưới `/var/folders` → bản thân đã thử `/var`→`/private/var`.

### 12.21 PurgeTrash từ chối mọi thứ ngoài Thùng rác — lõi (P2)
77. PurgeTrash `$HOME/quantrong` → mã 1. 78. `quantrong/khong-duoc-xoa.txt` còn nguyên.
79. PurgeTrash `.Trash/rac.txt` → mã 0. 80. `rac.txt` đã biến mất.
81. (PurgeTrash `.Trash/link-ra-ngoai`) symlink đã bị xóa. 82. đích `quantrong/khong-duoc-xoa.txt` còn nguyên.

### 12.22 _dir_is_empty — lõi
83. thư mục rỗng → true. 84. có file → false. 85. chỉ có file ẩn `.an` → false.

### 12.23 Xóa được nội dung nhưng không gỡ được vỏ — lõi (P2)
`<tmp>/cha/con/f`, `chmod 500 cha`; PurgeAny `cha/con`; khôi phục `chmod 700`.
86. mã 3 (`.partial`) chứ không phải 1. 87. `cha/con` rỗng.
(Swift: bỏ qua test khi chạy bằng root, vì root bỏ qua quyền thư mục.)

### 12.24 Bảng kết quả xếp mục cần chú ý lên trước — UI
Kết quả: ok `xong1`, fail `hongA` ("không ghi được"), ok `xong2`, part `motphan` ("còn vỏ rỗng"); hiển thị tối đa 10 ok.
88. dòng `hongA` đứng trước `xong1`. 89. có in "không ghi được". 90. có in "còn vỏ rỗng".
Port: test thuần cho hàm sắp xếp kết quả (`fail, sudo, part, skip, ok`) — có thể đặt hàm này ở CleanCore (không chuỗi).

### 12.25 Bảng kết quả gộp bớt — UI
20 ok + 1 fail, tối đa 5 ok.
91. vẫn có mục hỏng. 92. có dòng "15 mục thành công nữa" (= 20 − 5).

### 12.26 is_deletable_path — P0
93. `/` → false. 94. `/Library` → false. 95. `/Users` → false. 96. `/Applications` → false.
97. `/System/Library` → false (SIP). 98. `/usr/local` → false. 99. `/private/var/db` → false.
100. `/Library/Developer` → false. 101. `$HOME` → false. 102. `/khongcothat` → false (một cấp ở gốc).
103. `abc/def` → false. 104. `""` → false. 105. `$HOME/Library/Caches/foo` → true.
106. `/Applications/Foo.app` → true. 107. `/Library/Developer/CoreSimulator/Caches` → true.
Swift: chạy một lần với root `/` (chỉ so chuỗi, không ghi gì) và một lần với root giả.

### 12.27 is_precious_path — lõi
108. `~/Documents/x` → true. 109. `~/Pictures/y` → true. 110. `~/Library/Mobile Documents/z` → true.
111. `~/Library/Caches/z` → false.

### 12.28 PurgeAny từ chối đường dẫn hệ thống — lõi (P2)
112. PurgeAny `/Library` → mã 1. 113. `/Library` vẫn tồn tại.
(Swift: dùng root giả có `Library/`; guard phải từ chối trước khi đụng tới đĩa.)

### 12.29 Gom mục System Data — P3 (`_sd_add`)
`_sd_add('Có thật', dir có file, del)`, `('Không có', không tồn tại, del)`, `('Chỉ báo', không tồn tại, info, 'ghi chú')`.
114. còn 2 mục (bỏ mục 0 byte kiểu del, giữ mục info). 115. [1] = `Có thật`. 116. [2] = `Chỉ báo`.

### 12.30 Bảng màu biểu đồ — UI terminal (không port)
117. có màu. 118. mọi mã màu nguyên vẹn. (Đặc thù ANSI; SwiftUI không cần.)

### 12.31 Gom nhóm dung lượng — P2 (`_disk_add`)
`To` 5000 KB, `Nhỏ` 100 KB, `Vừa` 2048 KB (không path).
119. chỉ nhận nhóm ≥ 1 MB (2 nhóm). 120. [1] = `To`. 121. [2] = `Vừa` (nhóm không có thư mục vẫn nhận).

### 12.32 Thanh biểu đồ — UI terminal (P2, chỉ giữ ý tưởng)
122. tổng số khối = đúng chiều rộng (tính theo vị trí tích lũy, sai số không dồn). Port nếu SwiftUI vẽ thanh tỉ lệ
bằng phép chia rời rạc.

### 12.33 Test Swift bổ sung khuyến nghị cho P0 (không có trong zsh)
- `resolvedPath`: `..` qua symlink theo từ vựng; đuôi không tồn tại; `/var`→`/private/var`; bỏ `/` cuối.
- `orphan_check`: bid lạ → high `orphanBundleID`; tên trần lạ mtime cũ 100 ngày → medium; mới → info; UUID → alive;
  tên ẩn `.foo` → alive; `YHUG37CKN8.com.apple.x` → alive.
- `_report_orphan`: high + < 1 MiB → medium.
- `_scan_container`: bỏ file rời, bỏ symlink, cắt `.savedState`.
- `build_app_index`: symlink `.app` trong `/Applications` trỏ tới `/Users/Shared/Game.app` được nhận; symlink gãy bị bỏ;
  không đi vào trong `.app`; độ sâu 5 bị bỏ; Cellar/PrefPane đăng ký token; TOOLCHAIN với searchPath giả.
- `build_sys_index` với runner giả `launchctl list`.
- PathEntry: `/etc/paths.d/x` bỏ đúng dòng; `.zshrc` comment dòng chứa dir, giữ dòng `#`; file không có `\n` cuối không
  mất dòng; `.zshrc` là symlink → file đích được sửa, symlink còn nguyên; hai finding cùng file → một backup bản gốc.
- EnvLine: chỉ dòng bằng đúng.
- LaunchdJob: runner giả nhận `bootout gui/<uid>/<label>`; plist vào Thùng rác (dùng trash giả/thư mục fallback); restore
  gọi `bootstrap`.
- needsAdmin: PkgReceipt/FirewallApp luôn; TrashPath trong thư mục `chmod 555` → needsAdmin kèm lệnh; ReportOnly/TccReset
  không.
- remove_selected: thứ tự đếm ok/fail/sudo/skip; luôn sinh restore.sh; con cháu TrashPath bị loại.
- Backup dir trùng giây → thư mục thứ hai có hậu tố, manifest đầu còn nguyên.
- restore: TrashPath dùng `trashedPath`; `orig` đã tồn tại → manual; PurgeAny → manual; Symlink đã tồn tại → manual.
- Ignore round-trip với file ignore do MacTrash ghi (header tiếng Việt).
- History: lần đầu → firstScan; lần hai → new/gone đúng; giữ 12 file.
