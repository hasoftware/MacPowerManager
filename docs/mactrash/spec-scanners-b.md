# Đặc tả chuyển đổi: bộ quét Environment / Security / Shell / Plugin (nhóm B)

Nguồn: `mactrash.sh` 1.5.0 (MIT, cùng tác giả). Số dòng ghi trong ngoặc là số dòng trong file đó.
Phạm vi: `RC_FILES` + `_path_source_file` (1403-1416), `scan_path` (1418-1450), `scan_envvars` (1452-1496),
`scan_dyld` (1678-1699), `scan_certs` (1701-1722), `scan_firewall` (1724-1737), `scan_tcc` (1739-1755),
`scan_sysext` (1757-1786), `scan_symlinks` (1790-1806), `scan_lsregister` (1808-1829), `scan_nativemsg` (1831-1862),
`_bundle_broken` (1866-1877), `scan_plugins` (1879-1921), `scan_brokenapps` (1923-1930).

Giai đoạn P0: chỉ quét + mô tả cách gỡ (kind + payload). Không có UI, không có chuỗi hiển thị trong `CleanCore`.

---

## 0. Quy ước chung cho mọi bộ quét trong file này

### 0.1 Mô hình mục tìm thấy (khớp `add_finding`)

| Trường zsh | Swift | Ghi chú |
|---|---|---|
| `F_CAT` | `category: CleanCategory` | **rawValue phải đúng chuỗi zsh** (dùng trong ID) |
| `F_SEV` | `severity: .high / .medium / .info` | |
| `F_NAME` | `name: String` | thành phần ID |
| `F_TARGET` | `target: String` | thành phần ID; đường dẫn **logic** (xem 0.3) hoặc định danh |
| `F_DETAIL` | `reason: CleanReason` | enum có giá trị kèm theo, UI tự dịch (bảng ở mục 15) |
| `F_SIZE` | `sizeMB: Int` | MB nguyên, `du -sxk / 1024`, 0 nếu không đọc được (helper chung của lõi) |
| `F_KIND` | `kind: CleanKind` | |
| `F_DATA` | `payload` (kiểu riêng theo kind) | zsh nối bằng `\x1f`; Swift dùng associated values |

ID ổn định: `"\(category.rawValue)|\(name)|\(target)"` (giống `finding_id`, 1184). Không chuẩn hóa, không trim.

Category rawValue dùng trong file này (đúng chữ hoa/thường như zsh):
`Path`, `EnvVar`, `Security`, `Firewall`, `TCC`, `SysExt`, `Symlink`, `LaunchServices`, `NativeMsg`, `Plugin`, `App`.

Kind dùng trong file này: `ReportOnly`, `PathEntry`, `EnvLine`, `FirewallApp`, `TccReset`, `Symlink`, `LsRebuild`, `TrashPath`.

**Chuỗi literal nằm trong ID** (không phải chuỗi hiển thị, nhưng phải giữ nguyên byte để ignore list cũ còn khớp):
- `name` của mục PATH: `"PATH #\(i)"` (i đếm từ 1, tính cả mục rỗng).
- `target` của mục PATH rỗng: `"<rỗng>"` (tiếng Việt, cố định, kể cả khi app chạy tiếng Anh).
- `name` của mục LaunchServices: `"\(n) bản ghi ma"` (n = số bản ghi ma).
- `name` sudoers: `"sudoers.d/\(basename)"`; `name` DYLD: `"DYLD_INSERT_LIBRARIES"`.

Đặt các literal này thành hằng `FindingIDLiteral` trong CleanCore, chú thích rõ "chỉ dùng cho ID, UI không hiển thị".

### 0.2 Ngữ nghĩa glob/test của zsh → Swift

Script bật `EXTENDED_GLOB NULL_GLOB`, **không** bật `GLOB_DOTS`.

| zsh | Nghĩa | Swift |
|---|---|---|
| `"$d"/*(N)` | mọi mục, **bỏ tên bắt đầu bằng `.`**, rỗng nếu không có | `contentsOfDirectory` rồi lọc `!hasPrefix(".")` |
| `*(N.)` | chỉ file thường, **không** theo symlink (lstat) | `lstat` → `S_ISREG` |
| `*(N/)` | chỉ thư mục, **không** theo symlink | `lstat` → `S_ISDIR` |
| `*(N@)` | chỉ symlink | `lstat` → `S_ISLNK` |
| `[[ -e p ]]` | tồn tại, **có** theo symlink (symlink gãy = false) | `FileManager.fileExists(atPath:)` (đã theo symlink) |
| `[[ -d p ]]` | là thư mục, có theo symlink | `fileExists(atPath:isDirectory:)` |
| `[[ -L p ]]` | là symlink | `lstat` |
| `[[ -r f && -f f ]]` | đọc được + file thường (theo symlink) | `isReadableFile` + kiểm tra thật bằng cách mở được file |
| `${x:t}` | basename | `lastPathComponent` |
| `${x%.ext}` / `${x%.*}` | bỏ một đuôi cố định / bỏ đuôi cuối cùng | xem từng chỗ |

Thứ tự glob: zsh trả kết quả đã sắp xếp theo tên. Thứ tự chỉ ảnh hưởng tới nội dung finding ở `_path_source_file`
(file **đầu tiên** khớp thắng), nên ở đó phải sắp xếp tên tăng dần (so sánh `String <`).

### 0.3 Đường dẫn logic và vật lý (ScanEnvironment)

Mọi đường dẫn tuyệt đối trong spec này là đường dẫn **logic** (như trên máy thật: `/Library/...`, `~/...`).
Truy cập đĩa qua `env.physical(logical)`:
- nếu `logical` bắt đầu bằng `env.home.path` → dùng nguyên;
- ngược lại → `env.root` + `logical`.

`target` trong finding luôn là đường dẫn logic (production `root = /` nên trùng nhau; trong test, mục dưới home mang
tiền tố thư mục tạm, mục hệ thống thì không). Đường dẫn lấy ra từ **nội dung file hoặc output lệnh** (PATH, giá trị
biến, đích luật tường lửa, `path:` của lsregister, `"path"` trong manifest JSON) cũng là logic, kiểm tra tồn tại qua
`env.physical`.

### 0.4 Môi trường shell của người dùng (seam mới, rủi ro lớn nhất của phần này)

zsh chạy trong Terminal nên `$PATH` và các biến `JAVA_HOME`... là của shell tương tác của người dùng. App GUI do
launchd khởi chạy thì **không**: `PATH` chỉ là `/usr/bin:/bin:/usr/sbin:/sbin`, không có biến nào ở `known`. Port thẳng
`ProcessInfo.processInfo.environment` sẽ làm `scan_path`/phần 1 của `scan_envvars` gần như không báo gì.

Đề xuất: `ScanEnvironment.shellEnvironment: [String: String]?` do một loader điền trước khi quét, test tiêm thẳng.
Loader production (qua `CommandRunner`):
- Shell = `dscl . -read /Users/<user> UserShell` hoặc `$SHELL`, mặc định `/bin/zsh`.
- Chạy `<shell> -i -l -c 'printf "\n__MPM_ENV__\n"; /usr/bin/env -0'`, stdin = `/dev/null`, timeout 10 giây.
  Cần `-i` vì đa số người dùng khai báo PATH trong `~/.zshrc` (shell không tương tác không đọc file này). Marker để
  bỏ rác do `.zshrc` in ra (banner, oh-my-zsh...). Tách theo `\0`, mỗi phần `KEY=VALUE` tại dấu `=` đầu tiên.
- Thất bại/timeout → `shellEnvironment = nil`: bỏ phần 1 của `scan_envvars`; `scan_path` dùng PATH dựng từ
  `/etc/paths` + `/etc/paths.d/*` (giống `path_helper`) và đánh dấu kết quả là "nguồn môi trường dự phòng" để UI
  báo quét không đầy đủ. Không bao giờ dùng PATH của chính tiến trình app.

Chỉ biến **export** mới thấy được (zsh cũng vậy: script là tiến trình con của shell).

### 0.5 Phụ thuộc vào các phần khác (đặc tả ở file spec khác)

- `RC_FILES` (mục 1).
- `plistGet(url, keyPath) -> String?` thay `plist_get`: trả `nil` khi file không có/không đọc được/không có khóa/giá trị
  không phải chuỗi-số-bool. **Phân biệt `nil` (lỗi) với `""` (có khóa, giá trị rỗng)** vì vài chỗ xử lý khác nhau.
  Đọc bằng `PropertyListSerialization` (XML lẫn binary), khóa lồng tách bằng `.` như `plutil -extract`.
- `AppIndex` (từ `build_app_index`): `bidAlive`, `nameAlive`, `deadApps` (danh sách vỏ `.app` không hợp lệ, theo thứ
  tự phát hiện), `looksLikeBid`.
- `OrphanClassifier.check(name:path:) -> (orphan: Bool, severity, why)` (từ `orphan_check`). Các bộ quét ở đây chỉ
  dùng cờ `orphan`, **bỏ qua** severity/why của nó (xem kext và plugin).
- `sizeMB(path)`.
- `CommandRunner.run(executable, args, timeout) -> (status, stdout, stderr)`. Lệnh lỗi hoặc không có → coi như output
  rỗng (zsh luôn `2>/dev/null` và bỏ qua mã thoát ở mọi lệnh trong phần này).

### 0.6 `needsAdmin` (từ `finding_needs_sudo`, 2392-2405) cho các kind ở đây

- `FirewallApp` → luôn cần quyền admin.
- `ReportOnly`, `TccReset`, `LsRebuild` → không bao giờ.
- `PathEntry`, `EnvLine` → xét **file cấu hình** trong payload; `TrashPath`, `Symlink` → xét `target`.
  Cần admin khi thư mục cha của đường dẫn đó không ghi được (`access(W_OK)` trên `env.physical(parent)`).
  Ví dụ: `/etc/paths.d/*`, `/etc/zshrc`, `/usr/local/bin` (máy Intel không chown), `/Library/QuickLook/*`.
- Lệnh tương đương trả về khi `needsAdmin` (P0 không thực thi):
  `FirewallApp`: `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --remove '<target>'`;
  `Symlink`: `sudo rm '<link>'`; `TrashPath`: `sudo mv '<path>' ~/.Trash/`; `PathEntry`/`EnvLine`: mở file bằng
  quyền admin và comment dòng tương ứng.

### 0.7 Hủy

Mỗi bộ quét kiểm tra hủy trước mỗi thư mục và trước mỗi mục con / mỗi dòng output (lsregister có ~1.500 dòng `path:`,
TCC có thể vài trăm hàng). Khi hủy: trả những gì đã có hoặc ném `CancellationError`, thống nhất với lõi.

Thứ tự gọi trong `run_all_scans` (2147-2158): `scan_path, scan_envvars, …, scan_dyld, scan_certs, scan_firewall,
scan_tcc, scan_sysext, scan_symlinks, scan_lsregister, scan_nativemsg, scan_plugins, scan_brokenapps, …`. Thứ tự
không ảnh hưởng kết quả cuối vì sau đó lọc ignore + sắp xếp (High → Medium → Info, cùng mức thì MB giảm dần).

---

## 1. `RC_FILES` và `_path_source_file`

```
RC_FILES = [
  ~/.zshrc, ~/.zprofile, ~/.zshenv, ~/.zlogin,
  ~/.bash_profile, ~/.bashrc, ~/.profile,
  /etc/zshrc, /etc/zprofile, /etc/zshenv, /etc/profile, /etc/bashrc
]
```
Thứ tự cố định như trên. Dùng chung cho `scan_path`, `scan_envvars`, `scan_dyld`.

`_path_source_file(dir) -> String?` — "file nào khai báo thư mục này":
1. Duyệt theo thứ tự: `/etc/paths`, rồi `/etc/paths.d/*` (mọi mục không ẩn, sắp xếp tên), rồi `RC_FILES`.
2. Bỏ file không đọc được hoặc không phải file thường (`-r && -f`, theo symlink: `~/.zshrc` là symlink tới repo dotfiles
   vẫn được đọc).
3. Khớp = nội dung file **chứa chuỗi con** `dir` (so khớp chuỗi cố định, `grep -F`, phân biệt hoa thường, ở bất cứ đâu
   kể cả trong dòng comment).
4. Trả đường dẫn logic của file đầu tiên khớp; không có → `nil`.

Rủi ro (giữ nguyên hành vi, ghi chú cho rà soát): khớp chuỗi con nên `/opt/go` khớp dòng chứa `/opt/gopath/bin`;
dòng đã comment cũng khớp; PATH khai báo dạng `$HOME/x` hay `~/x` không khớp đường dẫn đã mở rộng → rơi về mục
Medium chỉ báo. **Đề xuất sửa (cần duyệt)**: yêu cầu ký tự ngay sau chuỗi khớp là hết dòng hoặc một trong
`: " ' / ` khoảng trắng `;` và bỏ dòng bắt đầu bằng `#`.

Test zsh: không có.

---

## 2. `scan_path` (phần "PATH dirs" của Environment)

Đầu vào: `PATH` từ `shellEnvironment` (0.4).

Thuật toán:
1. Tách `PATH` theo `:` **giữ cả phần tử rỗng** (`"${(@s/:/)PATH}"`): `":/a::/b:"` → `["", "/a", "", "/b", ""]`.
2. `i` đếm từ 1 cho **mọi** phần tử (kể cả rỗng). `seen: [String: Int]` nhớ chỉ số lần xuất hiện đầu.
3. Với mỗi phần tử `p`:
   - `p` rỗng → finding `Path / info / name "PATH #i" / target "<rỗng>" / reason .emptyPathEntry / ReportOnly`. `continue`.
   - `norm` = `p` bỏ **một** dấu `/` cuối (`/a/` → `/a`; `/` → `""`).
   - `norm` đã có trong `seen` → finding `Path / info / "PATH #i" / target p / .duplicatePathEntry(firstIndex) /
     ReportOnly`. **Không `continue`**: vẫn xét tiếp bước chết bên dưới (mục trùng mà chết thì ra 2 finding).
     Chưa có → `seen[norm] = i`.
   - Nếu `p` **không** phải thư mục (`! -d`, theo symlink; file thường cũng tính là chết):
     - Bỏ qua nếu `p` khớp tiền tố `/System/`, `/Library/Apple/`, `/var/run/com.apple.`, `/private/var/run/com.apple.`.
       Lý do (comment gốc): đường dẫn nội bộ của Apple (cryptex, rvictl) do `/etc/paths.d` khai báo sẵn nhưng chỉ tồn
       tại khi cryptex được mount → KHÔNG phải rác.
     - `src = _path_source_file(p)`.
     - Có `src` → `Path / high / "PATH #i" / target p / .deadPathDir(source: src) / PathEntry(file: src, dir: p)`.
     - Không → `Path / medium / "PATH #i" / target p / .deadPathDir(source: nil) / ReportOnly`.
   - Phần tử tương đối (`.`, `bin`) được kiểm tra so với thư mục hiện tại của zsh; Swift: coi phần tử không bắt đầu
     bằng `/` là tồn tại (bỏ qua) — app không có cwd ý nghĩa. (Lệch nhỏ, có chủ đích.)

Payload `PathEntry`: `(file, dir)`. Cách gỡ (để spec gỡ tham chiếu, 2440-2463): sao lưu file; nếu file là `/etc/paths`
hoặc `/etc/paths.d/*` → bỏ các dòng **bằng đúng** `dir`; ngược lại (file shell) → mọi dòng **chứa** `dir` và không bắt
đầu bằng `#` được thay bằng `"# MacTrash đã tắt: " + dòng` (comment, không xóa, vì dòng có thể còn logic khác).
Rủi ro gỡ: dòng `export PATH="/chet/bin:/song/bin:$PATH"` bị comment cả dòng → mất luôn `/song/bin`; chuỗi con nên
comment nhầm dòng không liên quan. Spec gỡ cần quyết định marker (giữ `MacTrash` hay đổi tên app) và xử lý file
symlink (xem mục 16).

Test zsh: chỉ có `tr_ DDupPath 7` → `'Trùng lặp với mục #7'` (kiểm tra chuỗi). Không test logic quét.

---

## 3. `scan_envvars` (biến môi trường chết, truy ra file)

Danh sách `known` (33 tên, giữ đúng thứ tự):
`JAVA_HOME GOROOT GOPATH ANDROID_HOME ANDROID_SDK_ROOT ANDROID_NDK_HOME M2_HOME MAVEN_HOME GRADLE_HOME CATALINA_HOME
PYENV_ROOT NVM_DIR RBENV_ROOT CARGO_HOME RUSTUP_HOME FLUTTER_ROOT DOTNET_ROOT SDKMAN_DIR VCPKG_ROOT LLVM_HOME NODE_PATH
SWIFT_HOME DENO_INSTALL BUN_INSTALL PNPM_HOME CONDA_PREFIX GEM_HOME COMPOSER_HOME QT_DIR CMAKE_PREFIX_PATH`

### Phần 1 — biến đang có hiệu lực
Chỉ chạy khi `shellEnvironment != nil`. Với mỗi `v` trong `known` (theo thứ tự):
- `val = shellEnvironment[v]`; rỗng/không có → bỏ.
- `val` tồn tại (`-e`, theo symlink, so khớp nguyên chuỗi, không tách `:`) → bỏ.
- Ngược lại → `EnvVar / medium / name v / target val / .envVarDead(name: v, file: nil) / ReportOnly`.

### Phần 2 — khai báo trong file cấu hình shell (gỡ được)
Với mỗi `f` trong `RC_FILES` đọc được và là file thường, đọc **từng dòng** (giữ nguyên dòng gốc `line` để làm payload):
1. Bỏ nếu dòng là comment: khớp `^[[:space:]]*#`.
2. Bỏ nếu dòng không chứa `=`.
3. `body` = dòng bỏ khoảng trắng đầu; nếu bắt đầu bằng đúng `"export "` (một dấu cách) thì bỏ tiền tố đó (chỉ một lần).
4. `name` = `body` trước dấu `=` **đầu tiên**, trim khoảng trắng hai đầu.
5. `name` phải khớp `^[A-Za-z_][A-Za-z0-9_]*$` (loại `alias x=`, `local X=`, `if [[ a == b`, `typeset -x X=`...).
6. Lọc tên: nhận nếu `name` kết thúc bằng `_HOME`, `_ROOT`, `_DIR`, `_SDK`, `_INSTALL`, `_PATH`, **hoặc** nằm trong
   `known`; ngược lại bỏ. Bỏ thêm `name == "PATH"` (PATH có module riêng; thực ra đã không qua được bước lọc).
7. `value` = `body` sau dấu `=` đầu tiên.
8. Cắt comment cuối dòng: bỏ từ **dấu `#` đầu tiên** trong `value` (cùng khoảng trắng liền trước nó) tới hết.
   (`${value%%[[:space:]]#\##*}` là "hậu tố dài nhất" nên cắt tại `#` sớm nhất, kể cả `#` không có khoảng trắng trước.)
9. Bỏ **một** ký tự `"` hoặc `'` ở đầu nếu có, và **một** ký tự `"` hoặc `'` ở cuối nếu có (độc lập, không cần cùng loại).
10. Bỏ qua (thay thế động, không đánh giá được) nếu `value` bắt đầu bằng `$`, hoặc chứa `$(`, hoặc chứa `` ` ``.
11. Bỏ qua nếu `value` không bắt đầu bằng `/` hoặc `~`.
12. `expanded` = thay **một** `~` ở đầu bằng `home.path` (`~/x` → `<home>/x`).
13. `expanded` tồn tại (`-e`) → bỏ.
14. Ngược lại → `EnvVar / high / name / target expanded / .envVarDead(name:, file: f) /
    EnvLine(file: f, line: <dòng gốc nguyên văn>)`.

Lưu ý khi đọc file: `while IFS= read -r line` của zsh **bỏ dòng cuối nếu file không kết thúc bằng `\n`**. Swift đọc
cả dòng cuối (sửa có chủ đích, an toàn hơn); khi gỡ phải giữ nguyên việc file có/không có `\n` cuối. Tách dòng theo
`\n` (không theo `\r\n`; dòng có `\r` cuối giữ nguyên `\r` trong `line` để so khớp lúc gỡ bằng nguyên văn).

Payload `EnvLine`: `(file, line)`. Cách gỡ: sao lưu, mọi dòng **bằng đúng** `line` → `"# MacTrash đã tắt: " + line`.

Trường hợp biên / rủi ro (đã đối chiếu code):
- Biến dạng danh sách (`*_PATH` như `DYLD_LIBRARY_PATH`, `CMAKE_PREFIX_PATH`, `NODE_PATH`) có giá trị `"/a:/b"` →
  kiểm tra nguyên chuỗi `/a:/b` → luôn "không tồn tại" → **báo High sai**. Phần 1 cũng vậy (Medium).
  **Đề xuất sửa (cần duyệt)**: giá trị chứa `:` → tách, chỉ báo khi **mọi** phần tử chết (hoặc bỏ qua hẳn).
- `$` ở giữa (`/opt/$VER/bin`, `"${HOME}/x"` bắt đầu bằng `$` thì đã bị bỏ) → chuỗi literal không tồn tại → **báo High
  sai**. **Đề xuất sửa**: bỏ qua mọi giá trị chứa `$`.
- Ký tự thừa sau giá trị (`FOO_DIR=/x;`, `FOO_DIR=/x && ...`, `/x)`) → báo sai. Đề xuất: cắt tại `;`, `&`, `|`, `)` không
  nằm trong ngoặc kép. (Cần duyệt; nếu giữ nguyên thì ghi vào test như hành vi đã biết.)
- `~user/x` thành `<home>user/x` → báo sai. Đề xuất: chỉ mở rộng `~` hoặc `~/`, còn lại bỏ qua.
- `#` trong đường dẫn hợp lệ (`/a#b`) bị cắt → `/a`.
- Cùng một biến xuất hiện ở phần 1 và phần 2 với cùng `target` → **cùng ID** (`EnvVar|JAVA_HOME|/x`): ẩn một là ẩn cả hai.
  Cùng dòng ở nhiều file → nhiều finding cùng ID. Giữ nguyên (ID là hợp đồng), UI nên chấp nhận ID trùng.
- Biến nằm trong `/etc/*` → `EnvLine` cần admin (0.6).

Test zsh: không có.

---

## 4. `scan_dyld` (Security: chèn thư viện, sudoers)

Toàn bộ finding ở đây là `ReportOnly`.

A. Plist launchd: thư mục `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons` (thứ tự này).
Với mỗi `*.plist` là **file thường, không phải symlink**, không ẩn:
- `v = plistGet(f, "EnvironmentVariables.DYLD_INSERT_LIBRARIES")`; `nil` hoặc rỗng → bỏ.
- → `Security / high / name "DYLD_INSERT_LIBRARIES" / target f / .dyldInsert(location: basename(f)) / ReportOnly`.
  (Lý do mang **basename**, target mang đường dẫn đầy đủ.)
- zsh dùng `plutil -extract … raw` nên giá trị kiểu mảng/dict làm `plutil` lỗi → bị bỏ sót. Swift: chấp nhận chuỗi
  không rỗng; mảng không rỗng cũng nên báo (lệch có chủ đích, chỉ thêm cảnh báo, không gỡ gì).

B. File shell: `RC_FILES` + `/etc/launchd.conf`, đọc được và là file thường:
- Nội dung chứa chuỗi `DYLD_INSERT_LIBRARIES` ở **bất cứ đâu** (kể cả trong comment) →
  `Security / high / "DYLD_INSERT_LIBRARIES" / target f / .dyldInsert(location: f đầy đủ) / ReportOnly`.
- Mỗi file tối đa một finding.

C. sudoers bên thứ ba: mọi mục **file thường** (không symlink, không ẩn) trong `/etc/sudoers.d/`, trừ tên `README`:
- → `Security / medium / name "sudoers.d/<basename>" / target f / .thirdPartySudoers(basename) / ReportOnly`.
- Chỉ cần liệt kê thư mục (file 0440 root không đọc được nội dung, không sao). Comment gốc: sudoers do bên thứ ba thêm
  vào = quyền root không cần mật khẩu.

Test zsh: không có.

---

## 5. `scan_certs` (Security: chứng chỉ gốc của proxy HTTPS)

CHỈ BÁO (comment gốc: xóa chứng chỉ tự động là quá nguy hiểm, Keychain Access là nơi đúng để người dùng tự quyết).

Danh sách nghi vấn (thứ tự quan trọng, khớp cái đầu tiên):
`PortSwigger, Burp, Fiddler, Charles Proxy, mitmproxy, Proxyman, HTTP Toolkit, OWASP ZAP, Titanium, Reqable, Whistle`

Keychain (thứ tự): `/Library/Keychains/System.keychain`, `~/Library/Keychains/login.keychain-db`. Bỏ cái không đọc được.

Với mỗi keychain `kc`:
1. `CommandRunner`: `/usr/bin/security find-certificate -a <kc>` (đường dẫn vật lý của kc).
2. Lấy các dòng chứa `"labl"`. Nhãn = phần sau `"labl"<blob>="` tới trước dấu `"` cuối dòng
   (`sed 's/.*"labl"<blob>="//; s/"$//'`). Nếu dòng có dạng khác (nhãn không ASCII in ra `<blob>=0x…  "…"`, hoặc
   `<NULL>`), sed không khớp tiền tố → nhãn là **cả dòng thô**; vẫn đem so khớp như thường (giữ nguyên).
3. Với mỗi nhãn: so khớp **không phân biệt hoa thường, chuỗi con** với từng nghi vấn; khớp cái đầu tiên →
   `Security / high / name <nhãn> / target kc / .proxyRootCertificate(tool: <nghi vấn như trong danh sách>) / ReportOnly`.

Đã đối chiếu output thật trên máy dev: dòng có dạng `    "labl"<blob>="…"`.

Rủi ro: quét **mọi** chứng chỉ, không chỉ chứng chỉ gốc/được tin cậy; `Titanium`, `Whistle`, `Burp` là từ chung → có thể
báo nhầm (chỉ báo nên vô hại, nhưng mức High). Nhãn trùng trong cùng keychain → finding trùng ID. Có thể thay bằng
Security.framework sau này, nhưng P0 giữ `security` qua `CommandRunner` để test được.

Test zsh: không có.

---

## 6. `scan_firewall` (luật Application Firewall chết)

1. `CommandRunner`: `/usr/libexec/ApplicationFirewall/socketfilterfw --listapps`.
2. Mỗi dòng: chỉ nhận dòng khớp `^[0-9]+ : ` (một hoặc nhiều chữ số, cách, `:`, cách). Đối chiếu máy dev:
   ```
   Total number of apps = 7 
   1 : /usr/libexec/remoted 
                (Allow incoming connections)
   ```
3. `target` = phần sau lần xuất hiện **đầu tiên** của `" : "`, bỏ mọi dấu cách cuối dòng (chỉ dấu cách, không tab).
4. Bỏ nếu `target` rỗng hoặc không bắt đầu bằng `/`.
5. Bỏ nếu `target` tồn tại (`-e`, qua `env.physical`).
6. → `Firewall / medium / name basename(target) / target target / .firewallRuleDead / FirewallApp(path: target)`.
   `needsAdmin = true` luôn. Gỡ = `socketfilterfw --remove <target>` (P1+/P5). Khôi phục chỉ là thủ công.

Test zsh: không có.

---

## 7. `scan_tcc` (quyền riêng tư còn cấp cho app đã gỡ)

Điều kiện chạy: có Full Disk Access. zsh xét `[[ -r ~/Library/Application Support/com.apple.TCC/TCC.db ]]` (`check_fda`).
Lưu ý: `-r`/`access()` chỉ xét quyền POSIX; file bị TCC chặn vẫn trả "đọc được". Swift: xác định FDA bằng cách **mở
thật** file đó để đọc (`open(O_RDONLY)` thành công) — lõi cung cấp `hasFullDiskAccess`. Không có FDA → không quét,
không finding (UI tự báo thiếu quyền).

CSDL (thứ tự): `~/Library/Application Support/com.apple.TCC/TCC.db`, `/Library/Application Support/com.apple.TCC/TCC.db`.
Bỏ cái không đọc được.

Với mỗi `db`:
1. `CommandRunner`: `/usr/bin/sqlite3 "file:<db vật lý>?mode=ro" "SELECT DISTINCT service, client FROM access;"`.
   (Chỉ đọc. Không link SQLite trong P0 để giữ seam test.)
2. Mỗi dòng tách tại `|` **đầu tiên**: `service`, `client` (phần còn lại). `client` rỗng → bỏ.
3. `looksLikeBid(client)` sai → bỏ. `bidAlive(client)` đúng → bỏ.
4. `svc` = `service` bỏ tiền tố `kTCCService` (nếu có).
5. → `TCC / medium / name client / target svc / .tccOrphan(service: svc) / TccReset(service: svc, client: client)`.
   `needsAdmin = false` (theo zsh). Gỡ = `tccutil reset <svc> <client>`.

Rủi ro:
- Cột `client_type` bị bỏ qua: client kiểu đường dẫn (`client_type = 1`, vd `/opt/x/bin/tool.v1.2`) có ≥ 2 dấu chấm sẽ
  lọt `looksLikeBid` → `tccutil reset` với đường dẫn sẽ thất bại. **Đề xuất sửa**: bỏ client bắt đầu bằng `/`
  (hoặc `WHERE client_type = 0`, nhưng giữ câu SQL gốc để tương thích bảng cũ).
- Bản ghi trong CSDL **hệ thống** thường không reset được bằng quyền người dùng. Đề xuất payload ghi thêm
  `database: .user | .system` để spec gỡ quyết định (giữ `needsAdmin = false` theo quyết định cố định).
- Cùng (client, service) ở cả hai CSDL → 2 finding cùng ID. Đề xuất gộp theo ID (giữ bản đầu).
- README minh họa TCC là "Info" nhưng code là **Medium**; theo code.

Test zsh: `looks_like_bid` (com.foo.bar, io.sentry, pro.betterdisplay.X đúng; `BetterDisplay`, `default.store` sai) và
`bid_alive` (id chính xác, id anh em cùng vendor, id con, vendor khác mồ côi, `com.apple.*` luôn sống) — thuộc spec chỉ
mục nhưng là toàn bộ logic quyết định ở đây.

---

## 8. `scan_sysext` (system extension treo, kext mồ côi)

Toàn bộ `ReportOnly`, mức `medium`.

A. System extension:
1. `CommandRunner`: `/usr/bin/systemextensionsctl list`.
2. Chỉ xét dòng có `[` rồi sau đó `]`.
3. `state` = phần giữa dấu `[` **cuối cùng** và dấu `]` **cuối cùng** (`${${line##*\[}%\]*}`).
4. Nhận nếu `state` chứa `waiting to uninstall` hoặc `terminated` (phân biệt hoa thường). Dòng tiêu đề
   (`…\t[state]`) tự bị loại. `activated waiting for user` không bị báo.
5. Tách dòng theo TAB **giữ trường rỗng** (cột: enabled, active, teamID, `bundleID (version)`, name, `[state]`);
   `bid` = trường thứ 4 (1-based) cắt tại dấu cách đầu tiên. Không đủ 4 trường → `bid` rỗng.
6. → `SysExt / medium / name (bid rỗng ? "?" : bid) / target **nguyên dòng** (gồm cả TAB) / .sysExtStale(state:) /
   ReportOnly`. ID chứa TAB và version; đổi version là đổi ID (giữ nguyên).

B. Kext trong `/Library/Extensions`: comment gốc — CHỈ BÁO, trên Apple Silicon gỡ kext phải qua `kmutil` + khởi động
Recovery; tự xóa thư mục là cách sai, có thể làm máy không boot.
1. Mỗi mục không ẩn tên `*.kext` (bất kỳ loại, kể cả symlink).
2. Bỏ nếu không có thư mục `Contents/MacOS` (theo symlink). Comment gốc: macOS ship sẵn vài kext rỗng
   (HighPointIOP/RR…) chỉ có Info.plist, không có binary → không phải tàn dư của ai.
3. `bid = plistGet(k/Contents/Info.plist, "CFBundleIdentifier")`; **`nil`** → `basename` bỏ đuôi `.kext`.
   Nếu plist có khóa nhưng giá trị **rỗng** → `bid = ""` → `OrphanClassifier` trả không mồ côi → không báo (giữ).
4. `OrphanClassifier.check(name: bid, path: k)`; không mồ côi → bỏ.
5. → `SysExt / medium (cố định, bỏ severity của classifier) / name basename(k) / target k / .kextOrphan / ReportOnly`,
   `sizeMB = sizeMB(k)`.

Test zsh: không có (gián tiếp: `orphan_check` tha `com.apple.*`, `is.workflow.*`, `systemgroup.*`, `group.com.apple.*`,
`logic`).

---

## 9. `scan_symlinks` (symlink gãy)

Thư mục (thứ tự): `/usr/local/bin`, `/usr/local/sbin`, `/opt/homebrew/bin`, `/opt/homebrew/sbin`, `~/bin`, `~/.local/bin`,
`/usr/local/lib`, `/opt/homebrew/lib`, `/Library/Frameworks`, `~/Library/Frameworks`.

Với mỗi thư mục tồn tại (`-d`), mỗi mục **không ẩn, là symlink**, chỉ cấp 1 (không đệ quy):
- Bỏ nếu `-e` đúng (đích tồn tại khi đi xuyên symlink). Chuỗi symlink gãy ở giữa, hoặc vòng lặp (ELOOP), đều tính là gãy.
- `t = readlink(l)` (một cấp, chuỗi thô, có thể tương đối); lỗi → `"?"`.
- → `Symlink / high / name basename(l) / target l / .brokenSymlink(destination: t) / Symlink(path: l)`.

Gỡ (2432-2437): zsh `rm -f` symlink và ghi `target` gốc vào manifest để `restore` tạo lại bằng `ln -s` (đã có test).
Theo triết lý "mọi thao tác hoàn tác được", Swift nên `trashItem` chính symlink (không theo đích) **và** vẫn ghi đích
vào manifest. `needsAdmin` khi thư mục cha không ghi được (`/usr/local/bin` trên Intel, `/Library/Frameworks`).
Lưu ý: `/Library/Frameworks` nằm trong `NEVER_DELETE` nhưng chốt đó chỉ áp cho `TrashPath`; ở đây target là mục **bên
trong**, hợp lệ.

Test zsh: "Vòng đời gỡ + khôi phục" — tạo `bin/deadlink -> /khong/co/that`, gỡ bằng kind `Symlink`, kiểm tra symlink
mất, chạy `restore.sh` rồi `readlink` phải ra đúng `/khong/co/that`. Và "manifest giữ đúng cột khi có ô trống"
(`bk_record Symlink '/tmp/a' '' '/dich/cua/no'`) — lỗi thật: ô trống làm lệch cột, symlink từng được tạo lại với đích rỗng.

---

## 10. `scan_lsregister` (bản ghi ma trong LaunchServices)

Hằng: `LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister`.

1. Không thực thi được (`-x` trên `env.physical`) → không quét.
2. `CommandRunner`: `<LSREGISTER> -dump`. Output lớn (vài MB); đọc theo dòng, kiểm tra hủy.
3. Chỉ dòng khớp `^[[:space:]]*path:`. `p` = phần sau `path:` **đầu tiên**, bỏ khoảng trắng đầu, rồi bỏ hậu tố
   ` (0x…)` ngắn nhất ở cuối (regex `" \(0x[^)]*\)$"`). Comment gốc: dấu ngoặc trong glob zsh là toán tử nhóm, phải escape
   mới cắt được phần ` (0x80f8)` lsregister gắn cuối dòng — lỗi thật, quên escape thì không đường dẫn nào khớp.
   Đối chiếu máy dev: `path:                       /System/Library/CoreServices/Applications/About This Mac.app (0x39b0)`.
4. Bỏ nếu `p` không bắt đầu bằng `/`; bỏ nếu `p` tồn tại.
5. Gom `ghosts` theo thứ tự gặp, **không khử trùng** (n = số dòng, không phải số đường dẫn duy nhất).
6. `ghosts` rỗng → không có finding. Ngược lại đúng **một** finding:
   `LaunchServices / info / name "\(n) bản ghi ma" / target ghosts[0] / .ghostLaunchServices(count: n) / LsRebuild`.
   Comment gốc: không gỡ được từng bản ghi, cách chính thức là dựng lại toàn bộ CSDL.
   `needsAdmin = false`. Gỡ = `lsregister -kill -r -domain local -domain system -domain user` (vẫn có trong `-h` trên
   macOS 15 của máy dev).

Rủi ro: ứng dụng trên ổ ngoài chưa mount (`/Volumes/...`), DMG đã eject, bản Time Machine → bị tính là "ma". Mức Info,
không chọn sẵn, nhưng nên ghi chú. ID đổi mỗi khi `n` hoặc bản ghi đầu đổi → ignore gần như không giữ được (giữ nguyên,
ghi vào test như hành vi đã biết).

Test zsh: không có.

---

## 11. `scan_nativemsg` (native messaging host chết)

Thư mục (thứ tự):
```
~/Library/Application Support/Google/Chrome/NativeMessagingHosts
~/Library/Application Support/Google/Chrome Canary/NativeMessagingHosts
~/Library/Application Support/Chromium/NativeMessagingHosts
~/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts
~/Library/Application Support/Microsoft Edge/NativeMessagingHosts
~/Library/Application Support/Vivaldi/NativeMessagingHosts
~/Library/Application Support/Arc/User Data/NativeMessagingHosts
~/Library/Application Support/Mozilla/NativeMessagingHosts
/Library/Google/Chrome/NativeMessagingHosts
/Library/Application Support/Mozilla/NativeMessagingHosts
/Library/Application Support/Microsoft/Edge/NativeMessagingHosts
```

Với mỗi `*.json` là file thường (không symlink, không ẩn):
1. zsh: lấy **lần khớp đầu tiên** của regex `"path"[[:space:]]*:[[:space:]]*"[^"]*"` ở bất kỳ đâu trong file, giá trị
   là phần trong ngoặc kép cuối (đọc bằng grep để khỏi phụ thuộc python/jq). Swift: đọc bằng `JSONSerialization`,
   lấy khóa `path` ở **cấp gốc** nếu là chuỗi; JSON không hợp lệ → dùng lại regex như zsh (giữ tương thích). Lệch
   có chủ đích: JSON escape (`\/`) được giải đúng, nên không báo sai.
2. Rỗng/không có → bỏ.
3. Không bắt đầu bằng `/` → tương đối, tính từ chính thư mục chứa manifest: `"\(d)/\(target)"`.
4. Tồn tại → bỏ.
5. → `NativeMsg / high / name basename(j) bỏ đuôi ".json" / target j / .nativeHostDead(executable: target đã ghép) /
   TrashPath(j)`. Chỉ đưa **manifest** vào Thùng rác, không đụng gì khác. `needsAdmin` cho bản trong `/Library`.

Test zsh: không có.

---

## 12. `_bundle_broken(b) -> String?`

"Bundle khai báo file thực thi mà file đó không tồn tại → hỏng thật, chắc chắn."
1. `exe = plistGet(b/Contents/Info.plist, "CFBundleExecutable")`; `nil` (không có plist/khóa/đọc lỗi) → **không hỏng**.
2. `exe` rỗng → không hỏng.
3. `b/Contents/MacOS/<exe>` tồn tại (`-e`) → không hỏng.
4. `b/Contents/<exe>` tồn tại → không hỏng. Comment gốc: quy ước chuẩn là `Contents/MacOS/<tên>`, nhưng có app (League of
   Legends) khai `CFBundleExecutable` là đường dẫn tương đối tính từ `Contents/`; chỉ kết luận hỏng khi **cả hai** cách
   hiểu đều không ra file, nếu không sẽ báo nhầm cả app 37 GB.
5. Ngược lại → hỏng, trả `exe`.

Khác `app_bundle_valid` (thuộc chỉ mục): thiếu Info.plist ở đây là **không hỏng**; chỉ xét `Contents/` (không xét layout
iOS / `Wrapper/`). Không gộp hai hàm.

Test zsh: không trực tiếp; `app_bundle_valid` có test (Good hợp lệ, NoExe/Hollow/Empty không hợp lệ, Wrapped hợp lệ).

---

## 13. `scan_plugins`

Nhóm 1 — **gắn với ứng dụng** (app biến mất thì plugin thành rác):
```
~/Library/QuickLook, /Library/QuickLook,
~/Library/Spotlight, /Library/Spotlight,
~/Library/Services, /Library/Services,
~/Library/Screen Savers, /Library/Screen Savers   (*)
/Library/Input Methods, ~/Library/Input Methods,
~/Library/Mail/Bundles, /Library/Mail/Bundles,
~/Library/ColorPickers, /Library/ColorPickers,
~/Library/Contextual Menu Items
```
(*) **Lỗi zsh**: `/Library/Screen Savers` viết không có ngoặc kép trong mảng nên bị tách thành hai phần tử
`/Library/Screen` và `Savers` → `/Library/Screen Savers` **không bao giờ được quét**. README/CHANGELOG nói có quét
Screen Savers. Đề xuất: Swift quét đúng `/Library/Screen Savers` (sửa lỗi) và ghi chú trong code.

Nhóm 2 — **độc lập** (VST, AU…), chỉ xét bundle hỏng:
```
~/Library/Audio/Plug-Ins/{VST,VST3,Components,HAL}, /Library/Audio/Plug-Ins/{VST,VST3,Components,HAL},
~/Library/PreferencePanes, /Library/PreferencePanes,
/Library/Internet Plug-Ins, ~/Library/Internet Plug-Ins
```
Comment gốc: PreferencePanes và Internet Plug-Ins vào nhóm này vì `build_app_index` đã đăng ký chúng như phần mềm đang
cài; xét mồ côi sẽ tự khớp chính nó.

Duyệt nhóm 1 rồi nhóm 2, theo thứ tự trên. Với mỗi thư mục tồn tại, mỗi mục con **là thư mục thật** (không symlink,
không ẩn):
1. Chỉ xét bundle có đuôi. zsh kiểm tra `$b == *.*` trên **đường dẫn đầy đủ** (lỗi: home kiểu `/Users/john.doe` làm mọi
   mục đều qua). Swift: kiểm tra **basename** có chứa `.` (sửa có chủ đích).
2. `exe = _bundle_broken(b)` khác `nil` → `Plugin / high / name basename(b) / target b / .bundleBroken(executable: exe) /
   TrashPath(b)`, `sizeMB(b)`. `continue` (không xét mồ côi nữa).
3. Thư mục thuộc nhóm 2 → dừng.
4. `bid = plistGet(b/Contents/Info.plist, "CFBundleIdentifier")`; `nil` → basename bỏ **đuôi cuối cùng**
   (`Foo.bar.qlgenerator` → `Foo.bar`). Giá trị rỗng → `""` → không mồ côi (giống kext).
5. `OrphanClassifier.check(name: bid, path: b)`; không mồ côi → bỏ.
6. → `Plugin / medium (cố định) / name basename(b) / target b / .pluginOrphan(owner: bid) / TrashPath(b)`, `sizeMB(b)`.

Rủi ro (cần ghi vào rà soát đối kháng, chưa đổi hành vi):
- `~/Library/Services/*.workflow` là **Quick Action người dùng tự tạo** bằng Automator/Shortcuts, thường không có
  `CFBundleIdentifier` → tên trần ("Resize Images") → `nameAlive` sai → báo Medium "plugin của phần mềm đã gỡ", kind
  TrashPath. Đây là dữ liệu người dùng. **Đề xuất mạnh**: bỏ qua `.workflow` trong nhóm 1 (hoặc chỉ Info, ReportOnly).
- Plugin độc lập phát hành riêng (screen saver `.saver`, QuickLook `.qlgenerator` cài bằng brew cask, color picker,
  input method) không có app chủ → luôn bị coi là mồ côi (Medium). Không chọn sẵn nên chấp nhận được, nhưng đáng ghi.
- `/Library/...` → TrashPath cần admin trong P0.

Test zsh: không có.

---

## 14. `scan_brokenapps` (vỏ `.app` rỗng/hỏng)

Đầu vào: `AppIndex.deadApps` — những `.app` tìm thấy khi dựng chỉ mục (find `-maxdepth 4 -name '*.app' -prune` trong
`/Applications`, `~/Applications`, `/System/Applications`, `/Applications/Utilities`, `/System/Applications/Utilities`,
`/Applications/Setapp`, `/Users/Shared`, `/Library/Application Support/JetBrains/Toolbox/apps`,
`/opt/homebrew/Caskroom`, `/usr/local/Caskroom`; có đi xuyên symlink `.app` → thư mục) mà `app_bundle_valid` sai:
không tìm thấy Info.plist ở `Contents/`, gốc bundle, `WrappedBundle/` hay `Wrapper/*.app/`; **hoặc** plist khai
`CFBundleExecutable` không rỗng mà không có `<dirOfPlist>/MacOS/<exe>` lẫn `<dirOfPlist>/<exe>`.
(Plist không có khóa `CFBundleExecutable` hoặc đọc lỗi → coi là hợp lệ.)

Với mỗi `a` theo thứ tự:
- Bỏ nếu `a` bắt đầu bằng `/System/`.
- → `App / high / name basename(a) / target a / reason / TrashPath(a)`, `sizeMB(a)`.

Reason: zsh luôn dùng `DHollowApp` ("không có Info.plist lẫn file thực thi"), kể cả khi plist có mà chỉ thiếu file
thực thi — mô tả sai cho trường hợp đó; chuỗi `DBrokenApp` ("Ứng dụng hỏng: thiếu file thực thi") có trong i18n nhưng
không dùng. Swift: `.hollowApp` khi không có Info.plist, `.brokenApp(executable:)` khi chỉ thiếu file thực thi
(không ảnh hưởng ID).

Vì sao quan trọng (comment gốc ở `app_bundle_valid`, lỗi sửa ở 1.1.0): thư mục `.app` còn nằm đó không có nghĩa app còn
cài — trình gỡ tồi, iCloud gỡ tải, xóa dở đều để lại vỏ. Nếu coi vỏ là "app sống", mọi tàn dư của nó bị xem là hợp lệ
và MacTrash im lặng đúng lúc cần lên tiếng nhất. Vì vậy vỏ rỗng **không** vào `APP_BID/APP_TOKEN` và được báo High.

`.app` là symlink trong `/Applications` trỏ ra `/Users/Shared` (game/launcher): `target` là đường dẫn symlink;
`trashItem` phải chuyển **chính symlink** (cần test xác nhận `FileManager.trashItem` không theo đích).
`TrashPath` đi qua chốt `is_deletable_path` của lõi khi gỡ (`/Applications/Foo.app` hợp lệ).

Rủi ro: app đang được App Store/Sparkle cập nhật dở có thể tạm thời thiếu binary → bị báo High. Không chọn sẵn.

Test zsh: "Nhận dạng bundle ứng dụng" (Good/NoExe/Hollow/Empty/Wrapped, đọc bundle id ở `Contents/` và `Wrapper/`) và
"Vỏ .app rỗng KHÔNG che giấu tàn dư của chính nó" (`name_alive Good` đúng, `name_alive Hollow` sai, `DEAD_APPS` có 1 mục).

---

## 15. `CleanReason` cho nhóm B (VI/EN lấy từ `_i18n_vi` / `_i18n_en`)

| Case Swift (đề xuất) | Khóa zsh | VI | EN |
|---|---|---|---|
| `.emptyPathEntry` | DEmptyPath | Mục rỗng (thừa dấu :) | Empty entry (stray colon) |
| `.duplicatePathEntry(firstIndex: Int)` | DDupPath | Trùng lặp với mục #{0} | Duplicate of entry #{0} |
| `.deadPathDir(source: String?)` | DDeadDir | Thư mục không tồn tại (+ ` → {src}` nếu có nguồn) | Directory does not exist |
| `.envVarDead(name:, file: String?)` | DEnvDead | {0} trỏ tới đường dẫn không tồn tại (+ ` ({file})`) | {0} points to a path that does not exist |
| `.dyldInsert(location:)` | DDyldInject | DYLD_INSERT_LIBRARIES trong {0} - kỹ thuật chèn thư viện, hãy kiểm tra | DYLD_INSERT_LIBRARIES in {0} - library injection, please review |
| `.thirdPartySudoers(file:)` | DSudoers | File sudoers thêm ngoài: {0} - CHỈ BÁO, tự đọc và quyết định | Third-party sudoers file: {0} - REPORT ONLY, read it and decide |
| `.proxyRootCertificate(tool:)` | DCertProxy | Chứng chỉ gốc của công cụ proxy: {0} - CHỈ BÁO, tự xóa trong Keychain Access | Root certificate from a proxy tool: {0} - REPORT ONLY, remove it in Keychain Access |
| `.firewallRuleDead` | DFirewallDead | Luật tường lửa trỏ tới file không tồn tại | Firewall rule points to a missing file |
| `.tccOrphan(service:)` | DTccOrphan | Quyền riêng tư "{0}" còn cấp cho app đã gỡ | Privacy permission "{0}" still granted to a removed app |
| `.sysExtStale(state:)` | DSysExtStale | System extension treo ở trạng thái: {0} | System extension stuck in state: {0} |
| `.kextOrphan` | DKextOrphan | Kernel extension của phần mềm đã gỡ | Kernel extension from removed software |
| `.brokenSymlink(destination:)` | DBrokenLink | Symlink gãy, trỏ tới: {0} | Broken symlink pointing to: {0} |
| `.ghostLaunchServices(count:)` | DGhostLS | LaunchServices còn {0} bản ghi trỏ tới app đã xóa (gây trùng menu "Open With") | LaunchServices still holds {0} record(s) for deleted apps (duplicate "Open With" entries) |
| `.nativeHostDead(executable:)` | DNativeDead | Native messaging host trỏ tới file không tồn tại: {0} | Native messaging host points to a missing file: {0} |
| `.bundleBroken(executable:)` | DPluginBroken | Bundle hỏng: thiếu file thực thi {0} | Broken bundle: missing executable {0} |
| `.pluginOrphan(owner:)` | DPluginOrphan | Plugin của phần mềm đã gỡ ({0}) | Plugin belonging to removed software ({0}) |
| `.hollowApp` | DHollowApp | Vỏ .app rỗng: không có Info.plist lẫn file thực thi - ứng dụng đã đi, chỉ còn lại thư mục | Hollow .app shell: no Info.plist and no executable - the app is gone, only the folder is left |
| `.brokenApp(executable:)` | DBrokenApp | Ứng dụng hỏng: thiếu file thực thi | Broken application: missing executable |

Chuỗi trên thuộc lớp UI (P0 không đưa vào CleanCore). Chuỗi gốc trong zsh là "vì sao bị đánh dấu" và nối thêm phần
nguồn (`→ src`, `(file)`); UI ghép tương tự từ associated values.

---

## 16. Tóm tắt kind/payload và điểm cần spec gỡ quyết định

| Kind | Payload | Do bộ quét | needsAdmin |
|---|---|---|---|
| `ReportOnly` | — | Path (rỗng/trùng/chết không rõ nguồn), EnvVar phần 1, Security, SysExt | không, gỡ trả "chỉ báo" |
| `PathEntry` | `file, dir` | scan_path | cha của `file` không ghi được |
| `EnvLine` | `file, line` | scan_envvars phần 2 | cha của `file` không ghi được |
| `FirewallApp` | `path` | scan_firewall | luôn |
| `TccReset` | `service, client` (+ đề xuất `database`) | scan_tcc | không |
| `Symlink` | `path` (đích đọc lại lúc gỡ) | scan_symlinks | cha không ghi được |
| `LsRebuild` | — | scan_lsregister | không |
| `TrashPath` | `path` | nativemsg, plugins, brokenapps | cha không ghi được |

Điểm mở cho spec gỡ (ngoài phạm vi file này nhưng phát sinh từ đây):
1. File shell là **symlink** (dotfiles): `_rewrite_file` của zsh ghi file tạm rồi `mv` đè lên → **thay symlink bằng file
   thường**, phá repo dotfiles. Swift phải sửa file **đích đã phân giải**, sao lưu file đích.
2. zsh `read` bỏ dòng cuối không có `\n` → khi viết lại file, **dòng đó mất**. Swift phải giữ mọi dòng và giữ trạng thái
   `\n` cuối file.
3. Marker comment `"# MacTrash đã tắt: "`: giữ nguyên hay đổi sang tên app (để người dùng tìm được). Không ảnh hưởng ID.
4. Mỗi file chỉ sao lưu **một lần**, ở trạng thái trước mọi thay đổi (lỗi thật ở zsh: subshell làm mất trạng thái, bản sao
   lưu thứ hai ghi đè bản gốc bằng nội dung đã sửa). Nhiều finding cùng file trong một lần dọn phải dùng chung bản sao.

---

## 17. Test

### Test zsh liên quan (cần chuyển sang XCTest, phần lớn thuộc spec chỉ mục/lõi)
- `looks_like_bid` (5 ca), `bid_alive` (5 ca), `name_alive` (4 ca), `orphan_check` tha hệ thống (5 ca) — quyết định của
  TCC, kext, plugin.
- `plist_get` (khóa có, khóa không có → rỗng, file không có → rỗng, không nhét thông báo lỗi của plutil vào giá trị).
- `app_bundle_valid` / `bundle_id_of_app` / `DEAD_APPS` (Good, NoExe, Hollow, Empty, Wrapped) — scan_brokenapps.
- Vòng đời `Symlink` gỡ + `restore.sh` tạo lại đúng đích; manifest ô trống ghi `-`.
- `ReportOnly` không bao giờ bị gỡ (zsh trả mã 2).
- `tr_ DDupPath 7`.

Không có test zsh nào chạy trực tiếp một hàm `scan_*` trong phạm vi này.

### XCTest đề xuất (cây giả + `CommandRunner` giả, không chạm hệ thống)
- **Path** (`/a`, `/b` có thật trong cây giả): `":/a::/b/:/b:/System/x:/dead"` → mục rỗng #1, #3 (Info, target `<rỗng>`);
  `/b` (#5) trùng #4 sau khi bỏ `/` cuối; `/System/x` (#6) không báo; `/dead` (#7) có trong `~/.zshrc` → High PathEntry nguồn `.zshrc`; có trong `/etc/paths.d/b` và
  `/etc/paths.d/a` → nguồn là `a` (thứ tự tên); `/etc/paths` thắng mọi file khác; không file nào → Medium ReportOnly;
  mục trùng **và** chết → 2 finding; ID đúng `Path|PATH #7|/dead`.
- **EnvVar phần 2**: `export JAVA_HOME="/x" # c` → High, target `/x`; `  FOO_HOME='~/nope'` → target `<home>/nope`;
  `# export X_HOME=/x` bỏ; `alias X_HOME=/x` bỏ; `X_HOME=$HOME/x` bỏ; `X_HOME=$(brew --prefix)` bỏ; `X_HOME=relative` bỏ;
  `MYVAR=/nope` bỏ (không hậu tố, không trong known); `PATH=/nope` bỏ; giá trị tồn tại bỏ; dòng cuối không có `\n` vẫn
  được xét; payload `line` là dòng gốc nguyên văn. Ca hành vi đã biết (theo quyết định duyệt): `CMAKE_PREFIX_PATH=/a:/b`.
- **EnvVar phần 1**: `shellEnvironment = ["JAVA_HOME": "/nope", "GOPATH": "<tồn tại>"]` → 1 Medium; `nil` → không quét.
- **DYLD**: plist trong `~/Library/LaunchAgents` có `EnvironmentVariables.DYLD_INSERT_LIBRARIES` → High, reason mang
  basename; plist symlink bị bỏ; `.zshrc` chứa chuỗi trong comment → vẫn High; `/etc/sudoers.d/{README,foo}` → chỉ `foo`.
- **Certs**: output giả có nhãn `PortSwigger CA`, `charles proxy CA…`, `Apple Root` và dòng `<blob>=0x…` → 2 finding,
  tool là chuỗi trong danh sách (không phải nhãn).
- **Firewall**: output thật mẫu ở mục 6 + một đường dẫn không tồn tại + dòng không đánh số → 1 finding `FirewallApp`,
  `needsAdmin`.
- **TCC**: không FDA → 0; output `kTCCServiceAccessibility|com.dead.app`, `…|com.apple.x`, `…|/usr/bin/x`, `…|alive.bid` →
  1 finding target `Accessibility`; cùng hàng ở cả hai CSDL (theo quyết định gộp).
- **SysExt**: output có tiêu đề, dòng `[activated enabled]`, dòng `[terminated waiting to uninstall on reboot]` với cột
  enabled rỗng → 1 finding, name = bundle id đúng cột 4; kext có/không có `Contents/MacOS`, plist thiếu/rỗng bundle id.
- **Symlink**: symlink gãy, symlink vòng, symlink tốt, file thường, `.hidden` gãy (bị bỏ) trong `~/.local/bin`.
- **LaunchServices**: output có `path: /x.app (0x1a2b)` tồn tại/không tồn tại, dòng không phải `path:` → 1 finding
  `"2 bản ghi ma"`, target là ma đầu tiên; không có ma → 0.
- **NativeMsg**: `path` tuyệt đối chết, tương đối chết (ghép theo thư mục manifest), tương đối sống, JSON có `\/`, file
  không phải JSON có `"path": "/x"`.
- **Plugins/_bundle_broken**: `Contents/MacOS/exe` có; exe tương đối `Contents/Game/run` có (ca League of Legends); thiếu
  cả hai → High; không Info.plist → không hỏng; thư mục không đuôi bị bỏ; VST hỏng báo, VST không hỏng không xét mồ côi;
  QuickLook có bid vendor lạ → Medium; `/Library/Screen Savers` được quét.
- **Brokenapps**: `deadApps` có `/System/Applications/X.app` (bỏ) và `/Applications/Hollow.app` (High, TrashPath).
