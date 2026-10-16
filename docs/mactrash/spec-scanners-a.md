# Spec A: Library leftover and startup scanners (P0)

Port spec for one slice of MacTrash 1.5.0 (`mactrash.sh`) into `Sources/CleanCore`. It is written from the
zsh source itself, not the README. Line numbers refer to `/tmp/mactrash-src/repo/mactrash.sh`.

Covered here: `_report_orphan`, `_scan_container`, `scan_path` (+ `_path_source_file`), `scan_appsupport`,
`scan_caches`, `scan_prefs`, `scan_containers`, `scan_state` (Saved Application State, HTTPStorages, WebKit,
Application Scripts, Cookies), `scan_logs`, `_launchd_program`, `scan_launchd`, `scan_loginitems`,
`scan_helpers`, `scan_receipts`, `scan_docker`, and the orchestration in `run_all_scans`.

Not covered (owned by other specs, only their contract is restated in §2): the app/system index
(`build_app_index`, `build_sys_index`, `bid_alive`, `name_alive`), the finding store, ignore list, backup and
removal engine.

Do not write Swift from memory of the README: every rule below is what the zsh does, including its quirks.
Where the zsh is buggy, this spec says so in a **Deviation / decision** box; the default is still parity.

---

## 1. Shared conventions for every scanner in this file

### 1.1 Logical paths, test root, and finding IDs

- Every path in a finding (`target`, kind payload) is the **logical** path as it would read on the real
  machine: `"<home>/Library/Caches/com.foo"`, `/Library/LaunchDaemons/x.plist`. The `ScanEnvironment` maps a
  logical path to the physical one (root prefix for `/…`, `home` for the user home) only when touching the
  file system. Findings never contain the test root prefix.
- Paths are built by plain string concatenation exactly like zsh: no symlink resolution, no `/private`
  prefixing, no trailing slash, no tilde. `home` is the unresolved `$HOME` string (`/Users/<name>`).
- Finding ID = `"\(category.rawValue)|\(name)|\(target)"` (`finding_id`, line 1184). For ignore-list
  compatibility the **raw category strings, names and targets must be byte-identical to MacTrash**. Category
  raw values used here: `Path`, `AppSupport`, `Caches`, `Prefs`, `Containers`, `GroupContainer`, `SavedState`,
  `HTTPStorage`, `WebKit`, `AppScripts`, `Cookies`, `Logs`, `LaunchAgent`, `LoginItem`, `Helper`, `Receipt`,
  `Docker`. (Note `LaunchAgent` is used for LaunchDaemons too; `HTTPStorage` is singular while the folder is
  `HTTPStorages`.)
- A few names/targets are literal strings that leak into IDs and must be kept verbatim even in English UI:
  `"PATH #<i>"`, target `"<rỗng>"` (Vietnamese, for an empty PATH entry), `"Background Task Management"`,
  `"(sfltool dumpbtm)"`.

### 1.2 Directory listing semantics (zsh globs)

The script runs with `EXTENDED_GLOB NULL_GLOB`, no `GLOB_DOTS`. Port glob qualifiers precisely:

| zsh | Meaning to port |
|---|---|
| `"$dir"/*(N/)` | direct children that are **real directories** (lstat: a symlink to a directory is NOT matched), names not starting with `.`; missing/unreadable dir yields nothing |
| `"$dir"/*.plist(N.)` | direct children that are **regular files** (lstat: symlinks excluded), not dot-files, name ends with `.plist` (case-sensitive) |
| `"$dir"/*(N)` | every non-dot child of any type (files, dirs, symlinks, dangling symlinks) |
| `[[ -d x ]]`, `[[ -e x ]]`, `[[ -f x ]]` | stat (follows symlinks); dangling symlink = does not exist |
| `[[ -L x ]]` | lstat: is a symlink |

zsh sorts glob results by name; iterate children sorted by name (byte order is fine). Order only matters as
the final tiebreaker in sorting (§4).

### 1.3 Helpers the scanners rely on

- `size_mb(p)` (line 840): `du -sxk p` → KiB / 1024, integer floor; `0` when `p` does not exist or `du`
  fails. `-x` = do not cross mount points (CHANGELOG 1.4.0: simulator runtimes mounted under
  `/Library/Developer/CoreSimulator/Volumes` were counted, 28 GB vs 2.5 GB). Port: allocated size of the
  tree, not following symlinks, skipping any child on a different volume (`volumeIdentifier` differs from the
  root's). Unreadable children contribute 0.
- `days_since_modified(p)` (line 872): `(now - stat -f %m p) / 86400`, integer; `0` if stat fails. This is the
  mtime of the item itself (for a directory: last time an entry was added/removed, not deep content).
- `plist_get(file, keypath)` (line 884): `plutil -extract <keypath> raw`; returns "absent" when the file is
  not a regular file, plutil exits non-zero, or the key is missing. **Why (keep the comment):** plutil prints
  its error message on stdout, so without checking the exit status the error text would be used as the value.
  Port with `PropertyListSerialization` (XML, binary and JSON plists), and `raw` means: string → the string;
  number/bool → its textual form; dict/array → absent. Keypath `ProgramArguments.0` = first array element.
- `command_exists(name)` (`command -v`): true when `name` resolves as a command. In zsh this also matches
  builtins, reserved words and functions defined in mactrash.sh; port: (a) a name containing `/` → that path
  is an executable file; (b) otherwise an executable regular file `<dir>/<name>` exists for some `dir` in the
  **command search path** of the ScanEnvironment (see §6, risk R1: the GUI app's own `PATH` is not the user's).
  Optionally also accept the zsh builtin/reserved-word set (`echo`, `test`, `time`, `type`, …) for parity;
  it only matters for folder names equal to a builtin.

---

## 2. Dependency contract: the orphan heuristic (restated from the core spec)

These are owned by the core/index spec. They are restated because every scanner here depends on their exact
behavior.

### 2.1 `norm_name(s)` (line 880)
Lowercase, then delete every char not in `[a-z0-9]`. Note: lowercase happens first, so non-ASCII letters
(`é`, `đ`) are simply removed, not transliterated. `"Google Chrome"` → `googlechrome`,
`"riot-client_ux.v2"` → `riotclientuxv2`.

### 2.2 `looks_like_bid(n)` (line 1292)
`n` lowercased. False if it contains no `.`. True if it starts with one of these TLD-like components followed
by `.`: `com org net io co dev app us uk de fr nl se it es ru jp kr cn tv cc me ai xyz info biz eu ch at pl br
in au ca no fi dk cz gr sh to ly group edu gov`. Otherwise true iff it contains at least two dots.
Tests: `com.foo.bar`, `io.sentry`, `pro.betterdisplay.BetterDisplay` → true; `BetterDisplay`,
`default.store` → false.

### 2.3 `looks_like_uuid(n)` (line 1322)
Uppercased `n` matches exactly `HEX{8}-HEX{4}-HEX{4}-HEX{4}-HEX{12}` (whole string).

### 2.4 `strip_team_prefix(b)` (line 1334)
1. If `b` starts with `group.` remove that prefix.
2. If (the result) matches `[0-9A-Z]{10}\..*` (exactly 10 **uppercase** letters/digits, then a dot), remove
   up to and including the first dot. Uppercase is mandatory so a real bundle id whose first component is 10
   lowercase chars is not cut (`sourceforge.app.x` stays).
Tests: `YHUG37CKN8.com.surfshark.vpn` → `com.surfshark.vpn`; `group.com.facebook.family` →
`com.facebook.family`; `group.UBF8T346G9.com.ms.rdc` → `com.ms.rdc`.

### 2.5 `SYS_KEEP` (line 1305) — normalized names never flagged
```
addressbook addressbooksourcesync animoji appstore appstored applemediaservices
biome callhistorydb callhistorytransactions cloudartifacts clouddocs cloudkit
coresimulator crashreporter developer dock facetime fileprovider findmy homekit
icdd icloud knowledge mail mobilesync notes personalizationportrait quicklook
safari screensharing siri sms spotlight storekit syncedpreferences syncservices
textinput translation ubiquity weather apple appleintelligence containers
caches preferences logs fonts keychains cookies webkit httpstorages
audio scripts services widgets accountpolicy assistant autofill
logic proapps ilifemediabrowser garageband finalcut motion compressor
amsdatamigratortool btserver desktoppictures installation mobiledevice
provisioningprofiles sharedfilelist iconservices bookkeeping
databases webpush mediakeys baseband privacypreservingmeasurement
diagnosticreports crashreporter powerlog networkserviceproxy
```
Keep comment: shared resources of the Pro/iLife suite ("GarageBand và Logic xài chung thư mục Logic/ProApps -
gỡ nhầm là mất hàng GB thư viện âm thanh").

### 2.6 `orphan_check(n, p)` → `(isOrphan, severity, reason)` (line 1343)
Default result: not orphan. Steps, in order (any "keep" returns not-orphan):
1. `n` empty → keep.
2. `norm_name(n)` ∈ SYS_KEEP → keep.
3. `looks_like_uuid(n)` → keep (cannot infer an owner).
4. `base = strip_team_prefix(n)`; `lb = lowercase(base)`. Keep if `lb` matches any of:
   `*com.apple.*` (anywhere), `apple*`, `.*`, `systemgroup.*`, `*.appleinternal.*`, `is.workflow.*`,
   `swift-playgrounds*`.
5. `norm_name(base)` ∈ SYS_KEEP → keep.
6. If `looks_like_bid(base)`: `bid_alive(base)` → keep; else **orphan, High**, reason
   `orphanBundleID(base)`.
7. Else: `name_alive(base)` → keep; else **orphan**, `d = days_since_modified(p)`, severity **Medium if
   d ≥ 90 else Info**, reason `orphanName(base, days: d)`.

Principle (keep as comment): only High with strong evidence (a clear bundle id that matches nothing); a bare
name is a guess → Medium/Info.
Tests: `com.apple.Safari`, `is.workflow.my.app`, `systemgroup.com.apple.x`, `group.com.apple.x`, `logic` →
not orphan.

`bid_alive` / `name_alive` summary (full rules in the core spec): `bid_alive` keeps `com.apple.*`, `apple.*`,
`group.com.apple.*`, exact registered bundle ids, any multi-component ancestor that is a registered bid or a
registered prefix, the id itself being a registered prefix, and ids whose last component (normalized, ≥ 4
chars) is an app token. `name_alive` keeps names whose normalized form is < 3 chars, is a system token, is an
app token, contains/is contained in an app token of length ≥ 4, shares a non-stop-word word (≥ 4 chars) with
an installed app name, or `command_exists(lowercase(name))`. **Important:** the index registers every
`pkgutil --pkgs` id (and all its multi-component prefixes) as a live bundle, and only registers *valid* app
bundles (Info.plist + executable present); hollow `.app` shells go to `deadApps` and do not keep anything alive.

### 2.7 `_report_orphan(name, path, category)` (line 1373)
1. Run `orphan_check(name, path)`; not orphan → no finding (returns false).
2. `mb = size_mb(path)`.
3. If `mb == 0` and severity is High → downgrade to **Medium** ("Rỗng thì hạ xuống mức thông tin - vô hại
   nhưng vẫn là rác"; the code downgrades to Medium, not Info, despite the comment).
4. Emit: category, severity, **name = `name` as passed** (not the team-stripped base), target = `path`,
   reason from orphan_check, size `mb`, kind `trashPath(path)`.

### 2.8 `_scan_container(dir, category, stripSuffix?)` (line 1386)
1. `dir` not a directory (stat) → nothing.
2. For each child from `dir/*(N/)` (real directories only, no dot-dirs, sorted):
   - skip if it is a symlink (redundant with the glob, keep the check: "symlink: để scanner symlink lo");
   - `name` = child's last path component; if `stripSuffix` given, remove it **once from the end if present**
     (`${name%$strip}`);
   - `_report_orphan(name, child, category)`.
3. Keep the WHY comment: only directories are considered. Loose files at the container root
   (`default.store`, `*.json`, `*.png`) are data of other processes, no owner can be inferred, reporting them is
   noise.

Cancellation: check between children.

---

## 3. Scanners

Unless stated otherwise: scanners read only, emit findings in the order described, and missing directories
are silently skipped. `H` = `home`.

### 3.1 `scan_path` (line 1418) + `_path_source_file` (line 1409)

**Input.** The user's `PATH` string (see risk R1: must be the user's shell PATH, supplied by the environment,
not `ProcessInfo` of the GUI app). Rc-file list `RC_FILES`, in this order:
`H/.zshrc H/.zprofile H/.zshenv H/.zlogin H/.bash_profile H/.bashrc H/.profile /etc/zshrc /etc/zprofile
/etc/zshenv /etc/profile /etc/bashrc`.

**Algorithm.**
1. Split `PATH` on `:` **keeping empty fields** (leading, middle and trailing: `"a::b:"` → 4 parts:
   `a`, ``, `b`, ``). `i` = 1-based index over all parts including empty ones.
2. For each part `p` at index `i`:
   - **Empty** → finding `Path / Info / name "PATH #i" / target "<rỗng>" / reason emptyPathEntry / size 0 /
     reportOnly`; continue with next part.
   - `norm` = `p` with **one** trailing `/` removed (`/usr/bin/` → `/usr/bin`; `/` → empty string).
     If `norm` was seen before at index `j` → finding `Path / Info / "PATH #i" / target p /
     duplicatePathEntry(firstIndex: j) / reportOnly`. **No `continue`**: a duplicate still goes through the
     existence check. Otherwise remember `seen[norm] = i`.
   - If `p` is not a directory (stat, follows symlinks; a regular file counts as dead):
     - If `p` matches `/System/*`, `/Library/Apple/*`, `/var/run/com.apple.*`, `/private/var/run/com.apple.*`
       → skip. Keep comment: Apple-internal paths (cryptex, rvictl) declared in `/etc/paths.d`, only exist
       while a cryptex is mounted, not junk.
     - `src = _path_source_file(p)`:
       - found → `Path / High / "PATH #i" / target p / deadPathDir(source: src) / size 0 /
         pathEntry(file: src, dir: p)`.
       - not found → `Path / Medium / "PATH #i" / target p / deadPathDir(source: nil) / reportOnly`.
3. `_path_source_file(dir)`: iterate `/etc/paths`, then `/etc/paths.d/*` (all non-dot children, sorted), then
   `RC_FILES`; take the first that is a readable regular file and **contains `dir` as a plain substring
   anywhere** (`grep -qF`, including comment lines and longer paths that merely start with `dir`).

**Reason text.** `DDeadDir` = "Thư mục không tồn tại" / "Directory does not exist"; when a source exists the
detail is rendered `"<DDeadDir> → <src>"`. `DDupPath` = "Trùng lặp với mục #{0}" / "Duplicate of entry #{0}".
`DEmptyPath` = "Mục rỗng (thừa dấu :)" / "Empty entry (stray colon)".

**Edge cases / notes.**
- A dead duplicate yields two findings with the **same ID** (`Path|PATH #i|p`); ignoring one hides both.
  Parity: keep (ID compatibility). UI should de-duplicate by ID when listing.
- Relative entries (`.`, `bin`) are tested relative to the process cwd in zsh (the user's shell cwd). In a GUI
  app cwd is `/`. **Deviation / decision:** skip the existence check for entries not starting with `/` (emit
  nothing for them beyond empty/duplicate). Recommended.
- Removal of `pathEntry` (from `remove_one`, for reference): back up the file first; for `/etc/paths` and
  `/etc/paths.d/*` delete lines **exactly equal** to `dir`; for shell rc files comment out (`# MacTrash đã tắt:
  <line>`) every non-comment line containing `dir` as substring — never delete rc lines ("dòng có thể còn logic
  khác"). Preserve file mode. Files under `/etc` → needsAdmin in P0.

**Tests.** zsh: only `tr_ DDupPath 7` → "Trùng lặp với mục #7". No scanner test. New XCTest: empty
middle/trailing entries and their indices; duplicate with trailing slash; dead duplicate gives 2 findings with
equal IDs; dead dir with source in a fake `.zshrc` (High, pathEntry) vs no source (Medium, reportOnly); Apple
cryptex path skipped; relative entry skipped.

### 3.2 `scan_appsupport` (line 1500)
`_scan_container(H/Library/Application Support, AppSupport)` then
`_scan_container(/Library/Application Support, AppSupport)`.
Notes: system-level children are mostly root-owned → their `trashPath` is needsAdmin (parent not writable).

### 3.3 `scan_caches` (line 1506)
`_scan_container(H/Library/Caches, Caches)` then `_scan_container(/Library/Caches, Caches)`.

### 3.4 `scan_prefs` (line 1512)
Directories in order: `H/Library/Preferences`, `H/Library/Preferences/ByHost`, `/Library/Preferences`.
For each regular `*.plist` file (no symlinks, no dot-files):
1. `name` = file name without `.plist`.
2. If the directory's last component is `ByHost`: remove the shortest suffix matching `\.[0-9A-Fa-f-]+$`
   (i.e. from the **last** dot, if everything after it is hex digits or `-`). Comment: "ByHost gắn thêm UUID
   phần cứng ở cuối: com.foo.bar.<UUID>.plist". Also strips old MAC-address suffixes
   (`.001122aabbcc`). Quirk: a bid whose last component is pure hex is also cut (`com.foo.cafe` → `com.foo`).
3. Skip if `name` starts with `.GlobalPreferences` or `GlobalPreferences`.
4. Skip unless `looks_like_bid(name)` ("chỉ xét file mang bundle id").
5. `_report_orphan(name, file, Prefs)` — target is the plist file, size from `size_mb` (usually 0 →
   High downgraded to Medium).

Note: name for the ID is the ByHost-stripped name, target the full file path, so two ByHost files of the same
domain have distinct IDs.

### 3.5 `scan_containers` (line 1528)
1. For each real directory child `c` of `H/Library/Containers` (no dot-dirs, no symlinks; note: no explicit
   `-L` check here, the glob already excludes symlinks):
   - `name` = last component.
   - If not `looks_like_bid(name)`: read `c/.com.apple.containermanager.metadata.plist` key
     `MCMMetadataIdentifier`; if present and non-empty, `name` = that id. Comment: container folder names are
     usually the bundle id, but some are generated strings; then the real id is in the container manager
     metadata.
   - `_report_orphan(name, c, Containers)`. The ID therefore uses the resolved bundle id as name.
2. `_scan_container(H/Library/Group Containers, GroupContainer)`; `orphan_check` strips `group.` and Team ID
   (`TEAMID.com.foo`, `group.com.foo`).
There is no `/Library/Containers` scan.

Risk: on macOS 14+ reading inside another app's container (metadata plist, and `size_mb`) may be denied or
trigger the "access data from other apps" TCC prompt for a GUI app (see R6).

### 3.6 `scan_state` (line 1547)
In order:
1. `_scan_container(H/Library/Saved Application State, SavedState, stripSuffix: ".savedState")`.
2. `_scan_container(H/Library/HTTPStorages, HTTPStorage)` (directories only; the sibling
   `*.binarycookies` files there are ignored).
3. `_scan_container(H/Library/WebKit, WebKit)`.
4. `_scan_container(H/Library/Application Scripts, AppScripts)` (names are often `TEAMID.com.foo` /
   `group.com.foo`, handled by `strip_team_prefix`).
5. Cookies: each regular file `H/Library/Cookies/*.binarycookies` (no symlinks): `name` = file name without
   `.binarycookies`; skip unless `looks_like_bid(name)` (so Safari's `Cookies.binarycookies` is skipped);
   `_report_orphan(name, file, Cookies)`.

### 3.7 `scan_logs` (line 1561)
`_scan_container(H/Library/Logs, Logs)` only. `/Library/Logs` is not scanned. `DiagnosticReports`,
`CrashReporter`, `PowerLog` etc. are protected by SYS_KEEP / the system index.

### 3.8 `_launchd_program(plist)` (line 1569)
Return `Program` if present and non-empty, else `ProgramArguments.0` if present and non-empty, else absent.
`Program` wins even if `ProgramArguments[0]` differs. `BundleProgram` is not consulted.

### 3.9 `scan_launchd` (line 1576)
Directories, in order: `H/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`.
`/System/Library/Launch*` are never scanned (SIP).
Domain per directory: home → `gui/<uid>`; `/Library/LaunchDaemons` → `system`; `/Library/LaunchAgents` →
`gui/<uid>`. `<uid>` = the running user's uid (`getuid()`; zsh used `$UID`).
For each regular `*.plist` (no symlinks, no dot-files), sorted:
1. `label` = `Label` from the plist; if absent/empty → file name without `.plist`.
2. `prog = _launchd_program(f)`; absent → **skip the file** (unreadable or malformed plists are silently
   ignored; plists with only `BundleProgram` are skipped too).
3. If `prog` does not start with `/` (bare command, relative path, `~/…`): if `command_exists(prog)` → keep;
   else finding `LaunchAgent / High / name label / target f / missingProgram(prog) / size 0 /
   launchdJob(plist: f, label: label, domain: domain)`.
4. Else if `prog` does not exist (stat; dangling symlink = missing) → same High finding.
5. Keep comment verbatim in spirit: **deliberately no guessing from the job label**. Labels often differ from
   the real bundle id (Riot Client: bid `com.riotgames.RiotGames.RiotClient`, label `com.riot.riotclient.*`),
   so label-based guesses only produce false positives. A plist whose program still exists is left alone; "the
   binary does not exist" is the only evidence.

Reason: `DMissingProg` = "Chương trình không tồn tại: {0}" / "Program does not exist: {0}".
Removal reference (`remove_one LaunchdJob`): back up the plist, `launchctl bootout <domain>/<label>`
(errors ignored: job may not be loaded), move plist to Trash, record. P0: `H/Library/LaunchAgents` is
executable as the user; `/Library/*` → needsAdmin (parent not writable), command
`sudo launchctl bootout <domain>/<label>` + move plist to Trash.

### 3.10 `scan_loginitems` (line 1609)
- **Not root (always the case in P0):** emit exactly one finding: `LoginItem / Info / name
  "Background Task Management" / target "(sfltool dumpbtm)" / needRootForBackgroundTasks / size 0 /
  reportOnly`. Reason `DNeedSudoBtm` = "Cần sudo để đọc danh sách mục khởi động nền (sfltool dumpbtm)" /
  "sudo is required to read background login items (sfltool dumpbtm)". The UI should word this as "requires
  administrator" rather than "sudo".
- **Root (P5, spec for later):** parse `sfltool dumpbtm` line by line: a line containing `Name:` sets
  `name` = text after the first `": "`; a line containing `Executable Path:` sets `exe` likewise, then if
  `exe` is non-empty, absolute and does not exist → `LoginItem / Medium / name (or exe if name empty) /
  target exe / loginItemDead / reportOnly`; reset `name` and `exe` after every `Executable Path:` line.
  Bug to fix when porting: `*Name:*` also matches `Developer Name:` lines, so the developer name can overwrite
  the item name; match lines whose trimmed text starts with `Name:`.

### 3.11 `scan_helpers` (line 1631)
For every non-dot child `h` of `/Library/PrivilegedHelperTools` (any type), sorted; `name` = last component:
1. `orphan_check(name, h)`. Orphan → `Helper / High / name / h / helperOrphan / size_mb(h) / trashPath(h)`.
   Note: severity is always High here (orphan_check's Medium/Info and the empty-size downgrade do not apply),
   and the reason is the helper text, not the orphan text. Comment: a root helper left behind is a security
   problem, not just junk.
2. Else if `/Library/LaunchDaemons/<name>.plist` is not a file (stat) → `Helper / Medium / name / h /
   helperNoJob / size_mb(h) / trashPath(h)`.
Reasons: `DHelperOrphan` = "Helper chạy quyền root còn sót của phần mềm đã gỡ" / "Root-privileged helper left
behind by removed software"; `DHelperNoJob` = "Helper root không còn LaunchDaemon nào tham chiếu" / "Root
helper is no longer referenced by any LaunchDaemon".
P0: `/Library/PrivilegedHelperTools` is root-owned → always needsAdmin. The ROADMAP says helpers are report-
only in P0: emit kind `trashPath` (parity, for P5) but the removal API returns needsAdmin.

### 3.12 `scan_receipts` (line 1648)
For each id in `pkgutil --pkgs` (non-empty lines):
1. Skip if lowercased id starts with `com.apple.`.
2. `orphan_check(id, "/var/db/receipts")` (the mtime used for name-shaped ids is that of `/var/db/receipts`,
   shared by all). Not orphan → skip.
3. `pkgutil --pkg-info <id>`: `loc` = value of the `location:` line, `vol` = value of `volume:` (default `/`),
   each with **one** leading space removed.
4. `pkgutil --files <id>`, first **40** lines: for each non-empty `f`, `full = trimTrailingSlash(vol) + "/" +
   (loc.isEmpty ? "" : loc + "/") + f`; if `full` exists (stat) → the package still has files → skip.
   (Paths may contain `//`; that is harmless for an existence test.)
5. None found → `Receipt / Medium / name id / target "/var/db/receipts/<id>" (synthetic, not a real file) /
   receiptOrphan / size 0 / pkgReceipt(id)`.
Reason `DReceiptOrph` = "Biên nhận gói cài của phần mềm đã gỡ (không còn file nào tồn tại)" / "Package receipt
for removed software (none of its files remain)". Kind is always needsAdmin; command
`sudo pkgutil --forget <id>` (MacTrash also saves `--pkg-info` and `--files` output to the backup first).

**Confirmed parity bug (see R2):** because the index registers every `pkgutil --pkgs` id as a live bundle, step 2
always says "alive" for every bundle-id-shaped receipt; verified by sourcing mactrash.sh:
`_reg_bundle com.foo.pkg.thing pkg:…; orphan_check com.foo.pkg.thing` → `ORPH=0`. In MacTrash 1.5.0 this
scanner can only ever fire for receipts whose id is not bundle-id-shaped. Decision needed (§6).

### 3.13 `scan_docker` (line 1932)
Runs only when Docker Desktop is gone:
1. If `/Applications/Docker.app` is a directory (stat; **any** directory, even a hollow shell) → return.
2. If `command_exists("docker")` → return (another engine such as colima/OrbStack/brew CLI uses the files).
3. For each of these paths, in this order, that exists (stat; dangling symlinks skipped):
   ```
   H/Library/Containers/com.docker.docker
   H/Library/Containers/com.docker.helper
   H/Library/Group Containers/group.com.docker
   H/Library/Application Support/Docker Desktop
   H/Library/Caches/com.docker.docker
   H/.docker
   /Library/PrivilegedHelperTools/com.docker.vmnetd
   /Library/PrivilegedHelperTools/com.docker.socket
   /Library/LaunchDaemons/com.docker.vmnetd.plist
   /Library/LaunchDaemons/com.docker.socket.plist
   ```
   emit `Docker / High / name = last path component / target p / dockerGone / size_mb(p) / trashPath(p)`.
Reason `DDockerGone` = "Docker Desktop đã gỡ nhưng dữ liệu còn lại" / "Docker Desktop was removed but its data
remains". The `/Library/…` items are needsAdmin. Removing the LaunchDaemon plist via trashPath does not boot
the job out (parity).
Note: the same paths are typically also reported by `scan_containers`, `scan_appsupport`, `scan_caches`,
`scan_helpers` under other categories (different IDs, same target) — see R5.

---

## 4. Orchestration: `run_all_scans(mode)` (line 2140) and role gating

1. Reset findings, load ignore list, check Full Disk Access (TCC.db at
   `H/Library/Application Support/com.apple.TCC/TCC.db` readable), build the app + system index **once**; all
   scanners share it.
2. If `mode != dev` run, in this exact order:
   `scan_path, scan_envvars, scan_appsupport, scan_caches, scan_prefs, scan_containers, scan_state, scan_logs,
   scan_launchd, scan_loginitems, scan_helpers, scan_receipts, scan_dyld, scan_certs, scan_firewall,
   scan_tcc, scan_sysext, scan_symlinks, scan_lsregister, scan_nativemsg, scan_plugins, scan_brokenapps,
   scan_docker, scan_mobilesync, scan_snapshots, scan_trash`.
3. If `mode == dev` **or** role == Developer: `scan_xcode, scan_devcache, scan_homebrew` (P3, not P0).
   So: role User + full → no dev scanners; role Developer + full → everything; mode dev → only dev scanners
   (no user-level scanners, no FDA notice). Every scanner in this spec is user-level, i.e. runs in `full`
   mode regardless of role; none is role-gated.
4. Remove ignored findings (ID in ignore list, exact string compare); count them (`IGNORED_COUNT`).
5. Sort: severity rank High(1) < Medium(2) < anything else(3); then size descending; then original emission
   order (stable). Test: (Info 5, High 100, High 900, Medium 50) → High 900, High 100, Medium 50, Info 5.

Swift shape suggestion (no code here): each scanner = a `Sendable` type with a synchronous
`scan(env, index, cancel) -> [Finding]`; the orchestrator runs them in the order above (order matters only for
the sort tiebreak), checks cancellation between scanners and between items, and reports progress with the
scanner's identifier (zsh showed "Đang quét: Caches" etc.). Findings from the P0 scanners not in this spec are
interleaved at their positions.

---

## 5. Reason enum and kinds emitted by this slice

| Reason case | Payload | vi (`_i18n_vi`) | en |
|---|---|---|---|
| `orphanBundleID` | bid | Bundle id "{0}" không thuộc ứng dụng nào đang cài | Bundle id "{0}" does not belong to any installed app |
| `orphanName` | name, days | Không có ứng dụng hay lệnh nào tên "{0}" (sửa lần cuối {1} ngày trước) | No installed app or command named "{0}" (last modified {1} days ago) |
| `emptyPathEntry` | – | Mục rỗng (thừa dấu :) | Empty entry (stray colon) |
| `duplicatePathEntry` | firstIndex | Trùng lặp với mục #{0} | Duplicate of entry #{0} |
| `deadPathDir` | source file? | Thư mục không tồn tại [→ src] | Directory does not exist [→ src] |
| `missingProgram` | program | Chương trình không tồn tại: {0} | Program does not exist: {0} |
| `needRootForBackgroundTasks` | – | Cần sudo để đọc danh sách mục khởi động nền (sfltool dumpbtm) | sudo is required to read background login items (sfltool dumpbtm) |
| `loginItemDead` | – | Mục khởi động trỏ tới đường dẫn không tồn tại | Login item points to a path that does not exist |
| `helperOrphan` | – | Helper chạy quyền root còn sót của phần mềm đã gỡ | Root-privileged helper left behind by removed software |
| `helperNoJob` | – | Helper root không còn LaunchDaemon nào tham chiếu | Root helper is no longer referenced by any LaunchDaemon |
| `receiptOrphan` | – | Biên nhận gói cài của phần mềm đã gỡ (không còn file nào tồn tại) | Package receipt for removed software (none of its files remain) |
| `dockerGone` | – | Docker Desktop đã gỡ nhưng dữ liệu còn lại | Docker Desktop was removed but its data remains |

Kinds: `trashPath(path)`, `pathEntry(file, dir)`, `launchdJob(plist, label, domain)`, `pkgReceipt(id)`,
`reportOnly`. needsAdmin rule (`finding_needs_sudo`, line 2392, non-root): `pkgReceipt` → always;
`reportOnly` → never; `pathEntry` → parent dir of `file` not writable; `trashPath` / `launchdJob` → parent dir
of the target not writable. In addition every `trashPath` must pass `is_deletable_path` at removal time
(defence in depth: a scanner bug must never trash `/Library`, a home dir, or a first-level dir).

| Scanner | Category | Severity | Kind |
|---|---|---|---|
| scan_path | Path | Info (empty, dup), High (dead + source), Medium (dead, no source) | reportOnly / pathEntry |
| scan_appsupport, caches, containers, state, logs, prefs | AppSupport, Caches, Containers, GroupContainer, SavedState, HTTPStorage, WebKit, AppScripts, Cookies, Logs, Prefs | High (bid; Medium if 0 MB), Medium (name, ≥ 90 days), Info (name, < 90 days) | trashPath |
| scan_launchd | LaunchAgent | High | launchdJob |
| scan_loginitems | LoginItem | Info (non-root), Medium (root, dead) | reportOnly |
| scan_helpers | Helper | High (orphan), Medium (no daemon plist) | trashPath (needsAdmin) |
| scan_receipts | Receipt | Medium | pkgReceipt (needsAdmin) |
| scan_docker | Docker | High | trashPath |

---

## 6. Risky heuristics and open decisions

- **R1. PATH of a GUI app (high impact).** `name_alive`'s `command -v`, `scan_launchd`'s bare commands,
  `scan_docker`'s `docker` check and `scan_path` itself all use the shell's `PATH`. An app launched from Finder
  gets launchd's `/usr/bin:/bin:/usr/sbin:/sbin`, without `/opt/homebrew/bin`, `/usr/local/bin`,
  `~/.cargo/bin`, … Using it would flag caches of installed CLI tools as orphans and make `scan_path` meaningless.
  Decision: `ScanEnvironment` carries `userPath: [String]` obtained once by the app layer via `CommandRunner`
  (login shell, e.g. `$SHELL -l -i -c 'printf "%s" "$PATH"'` with a timeout and sentinel markers, falling back
  to `/usr/libexec/path_helper` output + `/opt/homebrew/bin` + `/usr/local/bin`). Tests inject it directly.
- **R2. `scan_receipts` is dead code in MacTrash** (verified, §3.12). Options: (a) parity (never fires for
  bid-shaped receipts); (b) for receipts, run `orphan_check` against an index built **without** the pkg-receipt
  registrations (apps, plugins, toolchain, system only), then keep the file-existence guard. Recommend (b); it is
  report/needsAdmin in P0 anyway. Related: the 40-file guard counts directories such as `Applications` or
  `usr/local` that always exist, so most receipts look alive; consider `pkgutil --only-files --files` (decision).
- **R3. Version-like names become High.** `looks_like_bid` returns true for any name with two dots, so
  `node-v18.17.0`, `Foo 2.0.1`, `pip-21.3.1` take the bundle-id branch and are reported **High** "bundle id …"
  (verified). Parity keeps this; consider requiring the first component to be alphabetic or the name to have no
  spaces before treating it as a bid. Decision needed.
- **R4. Substring matching in `_path_source_file`** (`grep -F`): a dead `/opt/x` is attributed to a file that
  only mentions `/opt/xyz` or mentions it in a comment, and the rc-file removal comments out every line
  containing the substring. Mitigated by backup + comment-not-delete; consider matching on path boundaries.
- **R5. Duplicate targets across scanners** (Docker vs Containers/Caches/AppSupport/Helper; PATH dup+dead with
  equal ID). Removal of the second copy finds the path gone: zsh treats that as success and records it twice in
  the manifest. Port: de-duplicate by target at removal time, and never record a TrashPath whose source did not
  exist.
- **R6. TCC side effects in a GUI app.** Reading `.com.apple.containermanager.metadata.plist` and computing
  `size_mb` inside `~/Library/Containers/*` / `Group Containers/*` can be denied (giving size 0 → severity
  downgraded, `days` 0 → Info) or raise the macOS 14+ "access data from other apps" prompt per app. Without
  FDA, consider computing sizes lazily or skipping size inside foreign containers, and show the FDA banner.
- **R7. `-e` false negatives on missing volumes/permissions.** `scan_launchd` flags a program on an unmounted
  `/Volumes/X` or inside an unreadable location as missing → High, and removal trashes the plist (undoable).
  Consider downgrading to Medium when the program lives under `/Volumes/` and that volume is not mounted.
- **R8. Helper without a same-named daemon plist** → Medium "no LaunchDaemon references it", although the
  daemon plist may have a different file name. Medium + needsAdmin in P0 makes this low impact.
- **R9. Docker check uses `-d /Applications/Docker.app`**, not `app_bundle_valid`: a hollow Docker.app shell
  hides Docker leftovers (the shell itself is reported by `scan_brokenapps`). Inconsistent with the philosophy;
  parity unless decided otherwise. `~/.docker` holds credentials/contexts; it is only reported when no `docker`
  command exists.
- **R10. Size downgrade on unreadable dirs.** `size_mb` returns 0 when it cannot read, which downgrades High to
  Medium; and `days_since_modified` of a directory reflects entry changes, not content age.
- **R11. `apple*` keep rule** spares any third-party folder whose name starts with "apple" (e.g. a product named
  "AppleJuice"). Only a false negative; keep.
- **R12. `sfltool dumpbtm` `Name:` parsing** (root only, later): `Developer Name:` overwrites the name. Fix
  when ported.
- Parity quirks to keep consciously: ByHost hex-suffix strip also cuts hex-looking last components; the 0 MB
  downgrade is High → Medium (not Info); helper severity ignores orphan_check's severity.

---

## 7. Test mapping

Existing zsh tests (`tests/mactrash_test.zsh`) relevant to this slice, all to be ported to XCTest:
- "Chuẩn hóa tên": `norm_name`.
- "Nhận dạng bundle id": `looks_like_bid` (5 cases).
- "Tách Team ID / group.": `strip_team_prefix` (4 cases).
- "Nhận dạng UUID": `looks_like_uuid` (2 cases).
- "Chỉ mục ứng dụng" / "Từ chung…": `bid_alive`, `name_alive`, stop words.
- "orphan_check tha thư mục hệ thống": 5 keep cases.
- "plist_get": present key, missing key, missing file → empty.
- "Vỏ .app rỗng KHÔNG che giấu tàn dư của chính nó".
- "Sắp xếp kết quả", "Danh sách bỏ qua", "Thay tham số trong chuỗi i18n" (`DDupPath 7`).
- "Mục chỉ báo không bao giờ bị gỡ" (reportOnly → skipped outcome).

**No zsh test exercises any `scan_*` function directly.** New XCTest cases on a fake tree (temp root + fake
home, stub `CommandRunner`, injected `userPath`), at least:
1. `_scan_container`: dirs only; loose files, dot-dirs and symlinked dirs ignored; suffix strip for
   `.savedState`; UUID name ignored; `com.apple.*`/SYS_KEEP ignored; orphan bid → High with size; empty orphan
   bid dir → Medium; bare unknown name with mtime 100 days ago → Medium, 10 days ago → Info; name matching an
   installed app word → none; hollow `.app` does not protect its leftovers.
2. Group Containers / Application Scripts with `TEAMID.` and `group.` prefixes, name in finding keeps the
   prefix, reason uses the stripped id.
3. `scan_containers` metadata fallback for a non-bid folder name.
4. `scan_prefs`: ByHost UUID strip, GlobalPreferences skipped, non-bid name skipped, root `/Library/Preferences`.
5. Cookies: `Cookies.binarycookies` skipped, `com.gone.app.binarycookies` reported.
6. `scan_launchd`: missing absolute program → High with correct domain per directory; existing program →
   none; bare command present in `userPath` → none, absent → High; `Program` preferred over
   `ProgramArguments`; label fallback to file name; plist without program skipped; symlinked plist ignored.
7. `scan_loginitems` non-root → the single Info finding with the exact ID
   `LoginItem|Background Task Management|(sfltool dumpbtm)`.
8. `scan_helpers`: orphan → High; alive without daemon plist → Medium; alive with plist → none.
9. `scan_receipts` with stub `pkgutil`: com.apple skipped; files still present → none; no files → Medium
   (under the chosen R2 option).
10. `scan_docker`: Docker.app present → none; `docker` in path → none; otherwise each existing leftover → High.
11. `scan_path` cases listed in §3.1.
12. ID stability: a finding's ID equals the MacTrash string for the same logical path (no test-root prefix).
