# Changelog

Mọi thay đổi đáng chú ý của MacPowerManager được ghi ở đây.
Định dạng theo [Keep a Changelog](https://keepachangelog.com/vi/1.1.0/), version theo [Semantic Versioning](https://semver.org/lang/vi/):
**PATCH** khi sửa lỗi, **MINOR** khi thêm tính năng, **MAJOR** khi có thay đổi không tương thích.

## [Unreleased]

### Tính năng
- **Theo dõi hệ thống**, phần 3:
  - **Tiến trình**: bảng mọi tiến trình (% CPU, bộ nhớ, năng lượng, luồng, thời gian CPU, PID, người dùng), sắp xếp
    theo từng cột, tìm kiếm, lọc Tất cả / Ứng dụng / Của tôi / Hệ thống. Bảng chi tiết có biểu đồ CPU và bộ nhớ, số
    lần đánh thức, đọc/ghi ổ đĩa, thời điểm bắt đầu, và nút Thoát / Buộc thoát / Hiện trong Finder (chỉ với tiến trình
    của bạn).
  - Helper (root) cung cấp danh sách đầy đủ gồm cả tiến trình hệ thống (chỉ đọc); không có helper thì app chỉ thấy
    tiến trình của bạn.
  - **Năng lượng**: pin, công suất cả máy (trung bình, cao nhất), năng lượng theo ứng dụng, nhiệt độ bộ xử lý / GPU /
    pin, trạng thái nhiệt của macOS.
  - Trang CPU có "Dùng CPU nhiều nhất", trang Ổ đĩa có "Đọc ghi nhiều nhất".

### English
- System monitoring, part 3: Processes (sortable table, search, filters, detail inspector with Quit / Force Quit,
  full list via the helper) and Energy (whole-Mac power, energy by app, CPU/GPU/battery temperatures). Top CPU and
  disk users on the CPU and Disk pages.

## [0.13.0] - 2026-10-13

### Tính năng
- **Theo dõi hệ thống**, phần 2:
  - **GPU**: mức dùng Device / Renderer / Tiler, bộ nhớ GPU đang dùng và đã cấp phát, số nhân GPU.
  - **Ổ đĩa**: tốc độ đọc/ghi, tổng đã đọc/ghi từ lúc khởi động, dung lượng còn trống của từng ổ (định dạng, thiết bị).
  - **Mạng**: tốc độ tải xuống/tải lên, tổng đã nhận/gửi từ lúc khởi động, giao diện đang dùng (Wi-Fi/Ethernet, IPv4,
    IPv6, địa chỉ phần cứng).
  - Tổng quan hệ thống có thêm thẻ GPU, ổ đĩa và mạng; thanh bên hiện số liệu trực tiếp.

### English
- System monitoring, part 2: GPU (device/renderer/tiler, GPU memory), Disk (read/write speed, totals since startup,
  free space per volume) and Network (download/upload speed, totals since startup, active interface addresses).

## [0.12.0] - 2026-10-13

### Tính năng
- **Theo dõi hệ thống** (nhóm "Hệ thống" mới trên thanh bên), phần 1:
  - **Tổng quan hệ thống**: thẻ CPU, bộ nhớ và năng lượng với biểu đồ nhỏ; bấm thẻ để xem chi tiết.
  - **CPU**: tải hiện tại (người dùng / hệ thống), nhiệt độ CPU (trung bình và nóng nhất, tự tìm cảm biến trên mọi
    chip Apple Silicon), từng nhân chia theo nhân hiệu năng / tiết kiệm điện, tải 1/5/15 phút, số tiến trình,
    thời gian chạy.
  - **Bộ nhớ**: đang dùng, App / Wired / Đã nén / Cache theo cách Activity Monitor tính, áp lực bộ nhớ, swap,
    tốc độ đọc trang và đẩy ra swap.
  - Biểu đồ dạng chấm, chọn khoảng 1 phút / 5 phút / 15 phút / 1 giờ, nút tạm dừng.
  - Chỉ đo khi bảng điều khiển đang mở (mỗi giây), đóng lại là dừng hẳn để không tốn pin.
- `smc-probe` in thêm các cảm biến nhiệt độ CPU tìm được.

### English
- System monitoring, part 1: System Overview, CPU (user/system load, temperature, per-core with performance and
  efficiency cores, load averages) and Memory (App/Wired/Compressed/Cached, pressure, swap). Dot-matrix charts with
  1m/5m/15m/1h ranges. Sampling runs only while the dashboard is open.

## [0.11.0] - 2026-10-13

### Tính năng
- **Lệnh `mpm`** (cài trong Hệ thống & helper → Dòng lệnh & Phím tắt): `mpm status [--json]`, `limit`, `pause`,
  `resume`, `topup`, `discharge`, `charge-to-limit`, `calibrate`, `magsafe`. Dùng được trong script và tác vụ
  "Chạy tập lệnh shell" của Phím tắt. `mpm` gọi chính app ở chế độ dòng lệnh nên helper nhận lệnh như từ app.
- **URL `macpowermanager://`** cho tác vụ "Mở URL" của Phím tắt: `…/limit/80`, `…/pause/on`, `…/topup/4`… Xả pin và
  hiệu chuẩn chỉ chạy bằng `mpm` (URL có thể bị mở từ trang web). App vừa mở bằng URL sẽ đọc cấu hình từ helper trước
  khi áp dụng, không ghi đè cài đặt.

### English
- `mpm` command line (status, limit, pause, topup, discharge, calibrate, magsafe; `--json` for scripts) and
  `macpowermanager://` URLs for the Shortcuts app.

## [0.10.0] - 2026-10-13

### Tính năng
- **Đèn MagSafe báo trạng thái** (Thanh menu → Đèn MagSafe): khi giữ pin ở giới hạn, macOS để đèn cam vì tưởng pin
  chưa đầy. Chế độ "Báo trạng thái sạc" cho đèn cam khi đang sạc, xanh khi pin được giữ hoặc đã đầy, tắt khi đang
  xả. Có thêm chế độ "Luôn tắt" và nút "Thử màu" để kiểm tra máy có hỗ trợ không. Mặc định vẫn để macOS điều khiển;
  rút sạc hoặc gỡ helper sẽ trả đèn về cho macOS.

### Sửa lỗi
- Chú giải biểu tượng (trang Thanh menu) bị chồng chữ từ khi kiểu "phần trăm trong pin" thành mặc định; giờ chú giải
  hiện đúng theo kiểu đang chọn.

### English
- MagSafe light: amber while charging, green while held at the limit or full, off while discharging; or always off.
  Includes a "Test Color" button. Defaults to macOS control.
- Fixed the overlapping icon legend on the Menu Bar page.

## [0.9.0] - 2026-10-13

### Tính năng
- **Hiệu chuẩn pin** (trang mới "Hiệu chuẩn", Apple Silicon): một nút bấm chạy cả chu trình sạc lên 100% và giữ
  1 giờ, xả xuống 15%, sạc đầy lại, giữ 1 giờ rồi trở về giới hạn. Giúp số % và "Dung lượng tối đa" chính xác lại
  sau thời gian dài giữ pin ở 80%. Helper điều khiển cả khi app đã đóng.
  - Bước xả tự ngắt bộ sạc nếu máy hỗ trợ (giữ máy thức, gập máy thì tạm ngừng); máy không ngắt được thì app báo
    rút sạc. Pin nóng vẫn tạm dừng sạc; pin dưới 10% luôn được sạc; tự hủy sau 48 giờ nếu chưa xong.
  - Bật tạm dừng sạc hoặc xả pin thủ công sẽ hủy hiệu chuẩn; "Sạc đầy một lần" và sạc đầy theo lịch không chen
    ngang khi đang hiệu chuẩn.
- Thông báo khi cần rút sạc, khi hiệu chuẩn xong và nhắc hiệu chuẩn mỗi 2 tháng (tắt được).

### English
- Battery calibration (new Calibration page, Apple Silicon): one click charges to 100% and holds 1 hour, discharges
  to 15%, charges to full again, holds 1 hour, then returns to the limit. The helper runs it even when the app is
  closed. Notifications when unplugging is needed, when done, and a reminder every 2 months.

## [0.8.0] - 2026-10-13

### Tính năng
- **Sạc đầy theo lịch** (trang Giới hạn sạc): chọn các ngày trong tuần và giờ cần pin đầy (ví dụ 8:00 thứ Hai–thứ
  Sáu). Helper tự bắt đầu sạc sớm vừa đủ (khoảng 1 giờ từ 80%, lâu hơn nếu pin thấp), giữ 100% thêm 2 giờ rồi trở về
  giới hạn; rút sạc sau giờ hẹn cũng trả lại giới hạn. Rút sạc trước giờ hẹn rồi cắm lại thì sạc tiếp.
- Nếu máy đang ngủ và cắm sạc, helper hẹn giờ đánh thức máy (thức ngầm) để bắt đầu sạc đúng lúc.

### English
- Scheduled full charge: pick weekdays and a "full by" time; the helper starts charging early enough, keeps 100%
  for 2 more hours, then returns to the limit. It schedules a wake if the Mac is asleep and plugged in.

## [0.7.0] - 2026-10-13

### Tính năng
- **Sức khỏe pin theo thời gian** (trang Tình trạng pin): app ghi mỗi ngày một điểm (con số "Dung lượng tối đa" của
  macOS, ước tính từ IOKit và số lần sạc) và lưu lâu dài. Biểu đồ nhiều tháng cho thấy pin chai dần thế nào. Sau khoảng
  30 ngày dữ liệu, app ước tính tốc độ chai mỗi năm, còn bao lâu pin xuống dưới 80% và số lần sạc mỗi tháng.

### English
- Long-term battery health tracking: one point per day, a multi-month chart, yearly wear rate and an estimate of
  when the battery drops below 80% (after about 30 days of data).

## [0.6.0] - 2026-10-13

### Tính năng
- **Biểu tượng pin kiểu iPhone** trên thanh menu: số % nằm ngay trong viên pin, tô theo mức pin, kèm huy hiệu trạng thái
  (tia sét khi sạc, lá khi giữ mức…). Đây là kiểu mặc định mới; đổi lại trong Cài đặt → Thanh menu → Kiểu hiển thị.
- **Helper tự cập nhật cùng app, không cần mật khẩu**: helper đang chạy tự kiểm tra chữ ký Ed25519 của bản mới rồi tự thay
  mình. Áp dụng từ lần cập nhật *sau* v0.6.0 (lên v0.6.0 vẫn cần cài lại helper một lần). Nếu bản mới đổi cấu hình
  LaunchDaemon, app vẫn nhắc cài lại helper như trước.

### Bảo mật
- Helper tự cập nhật ghi file mới với chủ sở hữu root:wheel (không giữ uid/gid trong file zip), không theo symlink,
  chỉ đọc file thường trên ổ cục bộ và có giới hạn dung lượng.

### English
- iPhone-style menu bar battery with the percentage inside (new default style).
- The helper now updates itself with the app, without an admin password (from the update after v0.6.0 onward).
- Hardened helper self-update: root:wheel ownership, no symlinks, local regular files only, size cap.

## [0.5.2] - 2026-10-13

### Sửa lỗi
- Dọn thư mục tải tạm của lần tự cập nhật trước khi mở app (khoảng 3 MB mỗi lần cập nhật).

### English
- Clean up the temporary download folder left by the previous in-app update.

## [0.5.1] - 2026-10-13

### Sửa lỗi
- Thông báo lỗi khi bản cập nhật tải về không hợp lệ giờ dễ hiểu (trước đây hiện mã kỹ thuật).

### English
- Readable error messages when a downloaded update is rejected.

## [0.5.0] - 2026-10-13

### Tính năng
- **Tự động cập nhật**: bấm "Cập nhật ngay" trong cửa sổ Có gì mới, app tự tải, kiểm tra chữ ký số và cài bản mới
  rồi mở lại; không cần tải và kéo file `.dmg` nữa. Sau khi mở lại, app nhắc cài lại helper (cần mật khẩu quản trị).
- Bản cập nhật được ký bằng Ed25519; app chỉ cài bản có chữ ký hợp lệ của HASOFTWARE, đúng app và mới hơn bản đang chạy.

### English
- One-click in-app updates: download, Ed25519 signature check, install and relaunch; the app then prompts to reinstall the helper.

## [0.4.0] - 2026-10-13

### Cải tiến
- **Icon app mới** (Finder, Dock, Launchpad, ổ đĩa `.dmg`): viên pin với vạch giới hạn trên nền xanh ngọc, rõ nét ở mọi kích thước.
- Trang Giới thiệu dùng icon mới.
- README có logo, ảnh chụp giao diện (sáng/tối, tiếng Việt và tiếng Anh); thêm logo, favicon và ảnh social preview trong `docs/assets`.

### English
- New app icon (Finder, Dock, Launchpad, DMG volume), README logo and screenshots, favicon and social preview assets.

## [0.3.0] - 2026-10-12

### Tính năng
- **Giao diện mới**: cửa sổ có thanh bên (Tổng quan, Lịch sử, Tình trạng pin, Giới hạn sạc, Chống nóng, Xả pin, Khi ngủ,
  Thanh menu, Thông báo, Hệ thống & helper, Giới thiệu), bảng nhanh trên thanh menu với thanh giới hạn kéo được
  và các nút thao tác nhanh, biểu tượng pin riêng trên thanh menu có vạch giới hạn và huy hiệu trạng thái.
- **Sạc đầy một lần**: tạm bỏ giới hạn để sạc tới 100% (ví dụ trước chuyến đi); tự kết thúc khi rút sạc,
  hết hạn hoặc khởi động lại máy. **Sạc tới giới hạn ngay**: bỏ qua khoảng sạc lại một lần.
- **Xác minh hiệu lực**: sau khi chặn sạc, helper đo dòng điện vào pin và cảnh báo nếu pin vẫn nhận sạc.
- **Tự dò phương thức điều khiển**: phát hiện key bị firmware khóa và chuyển sang phương thức dự phòng.
- **Phát hiện ứng dụng điều khiển sạc khác** (AlDente, batt, Battery Toolkit…) và key SMC bị ghi đè từ bên ngoài.
- **Lịch sử liền mạch 30 ngày**: helper ghi lịch sử mỗi phút kể cả khi app đã thoát; biểu đồ nối liền,
  đoạn máy ngủ hoặc tắt vẽ bằng nét đứt.
- **Kiểm tra cập nhật**: lúc mở app và mỗi 24 giờ, app đọc bản phát hành mới nhất trên GitHub (yêu cầu mạng duy nhất,
  không kèm dữ liệu cá nhân, tắt được ở trang Giới thiệu). Có bản mới thì hiện banner, thông báo và cửa sổ **Có gì mới**.
- **Giao diện tiếng Việt và tiếng Anh**, chọn được ngay trong app (Theo hệ thống / Tiếng Việt / English).
- Trang Giới thiệu có thông tin tác giả HASOFTWARE (GitHub, Telegram, Facebook).

### Sửa lỗi
- Sức khỏe pin hiển thị đúng con số "Maximum Capacity" của macOS thay vì số đo tức thời.
- Trạng thái "đang sạc" cập nhật ngay sau khi đổi giới hạn (đọc dòng điện pin trực tiếp từ SMC).
- Ba nút nhanh ở trang Tổng quan bị lệch.

### An toàn
- Helper chỉ nhận lệnh từ đúng bản app đã cài nó (ghim cdhash). **Sau mỗi lần cập nhật app, hãy bấm "Cài lại helper"**
  (app sẽ nhắc).
- Xả pin có giới hạn 6 giờ, chỉ ngắt adapter khi đang cắm sạc, tự hủy nếu lệnh ngắt adapter không có hiệu lực.
- Pin ≤ 10% luôn được sạc, kể cả khi ứng dụng khác đã ngắt adapter.
- Trạng thái (giữ mức, sạc đầy một lần) được nhớ khi helper khởi động lại và xóa khi máy khởi động lại.
- Máy đời cũ: chỉ điều khiển `CH0C`, để `CH0B` cho tính năng sạc tối ưu của macOS.

### English
- New sidebar UI, redesigned menu bar popover and a custom menu bar icon.
- Full Charge Once, Charge to Limit Now, effect verification, automatic method fallback.
- Detection of other charge controllers and external SMC writes.
- Continuous 30-day history recorded by the helper.
- Update checker with a What's New window.
- English and Vietnamese UI with an in-app language picker.
- macOS battery health figure, instant charging state.
- The helper now only accepts the exact app build that installed it: **reinstall the helper after every app update**.

## [0.2.0] - 2026-10-07

### Tính năng
- **Điều khiển sạc trên máy Intel (thử nghiệm)** cho MacBook 2018–2020 (chip T2) qua key `BCLM`:
  giới hạn sạc 50–100%, tạm dừng sạc và bảo vệ nhiệt (giữ ở mức pin hiện tại, tối thiểu 50%).
  Firmware tự giữ giới hạn cả khi máy ngủ hoặc tắt; pin có thể vượt khoảng 3%.
  Xả pin chưa hỗ trợ trên Intel. Helper xác minh mỗi lần ghi và tự ghi lại nếu giá trị bị thay đổi.
  Gỡ helper trả giới hạn về 100%; tắt máy không xóa giới hạn. Nếu chưa trả được, helper được giữ lại kèm lệnh khôi phục.
- Tự phát hiện khi app chạy từ file `.dmg` hoặc vị trí tạm của macOS (App Translocation) và đề nghị chuyển vào
  Applications, mở lại bản ở đó rồi thoát (có tùy chọn "Không hỏi lại"; ổ đĩa ngoài ghi được không bị coi là vị trí tạm).

### Sửa lỗi
- Sau khi app yêu cầu khôi phục để gỡ helper, vòng điều khiển không còn ghi đè lại giới hạn trước khi helper dừng.
- README: hướng dẫn gỡ thủ công chạy `--restore-defaults` (bắt buộc trên Intel).

### Cải tiến
- `smc-probe` hiển thị trạng thái `BCLM` và phần trăm pin phần cứng trên máy Intel.

## [0.1.1] - 2026-10-07

### Sửa lỗi
- Nhiệt độ từ IOKit bị đọc sai đơn vị (đúng là 0,1 K, không phải 0,01 °C). Tab Tổng quan hiển thị thấp hơn thực tế 4–8 °C, và trên máy không có cảm biến SMC, bảo vệ nhiệt kích hoạt muộn.
- Pin có thể sạc vượt giới hạn trong lúc máy ngủ: vòng lặp định kỳ có thể bật lại sạc ngay trước khi ngủ hoặc khi máy thức ngầm (dark wake). Helper giờ chỉ được "siết lại" (tắt sạc, bật adapter) trong các giai đoạn này.
- Giới hạn 100% vẫn bị chặn sạc khi máy ngủ.
- Helper không nhận sự kiện cắm/rút sạc mà chỉ dựa vào vòng lặp 10 giây.
- Thêm trường cấu hình mới làm reset toàn bộ cài đặt khi nâng cấp.
- Giải mã sai một số SMC key (thứ tự byte); lỗi SMC luôn bị báo là "không có quyền".
- "Hệ thống tiêu thụ" tính cả phần điện đang sạc vào pin.
- Thời gian sạc được ước tính tới 100% thay vì tới mức giới hạn.
- Thông báo cùng loại chồng lên nhau; công tắc "Mở cùng macOS" không đồng bộ với System Settings.

### An toàn
- Helper cài handler tín hiệu trước tiên và bật lại adapter ngay khi khởi động (phòng trường hợp lần chạy trước bị dừng giữa lúc xả pin).
- Gỡ cài đặt chạy `PowerHelper --restore-defaults` (dùng helper đi kèm app, có giới hạn thời gian) để xóa mọi key ngắt adapter và xác minh. Nếu không xác minh được, app báo rõ và hướng dẫn khởi động lại máy.
- Pin ≤ 10% luôn được sạc, kể cả khi máy đang ngủ; bảo vệ nhiệt cho phép sạc lại khi pin nguội trong lúc máy ngủ (nếu không bật giữ mức pin).
- LaunchDaemon dùng `ProcessType = Adaptive` để macOS không hạn chế nhịp của vòng điều khiển.

### Cải tiến
- `smc-probe` in thêm thông tin máy, firmware, thuộc tính key và nhiều key hơn để cộng đồng gửi báo cáo (đặc biệt máy Intel).

## [0.1.0] - 2026-10-07

Bản phát hành đầu tiên.

### Tính năng
- App menu bar (popover điều khiển nhanh) và cửa sổ chi tiết: Tổng quan, Điều khiển sạc, Lịch sử, Cài đặt.
- Thông tin pin: %, dung lượng, sức khỏe, chu kỳ, điện áp, dòng, công suất, nhiệt độ (SMC + IOKit), adapter.
- Giới hạn sạc với khoảng sailing, tạm dừng sạc (chỉ dùng adapter), xả pin khi đang cắm sạc.
- Bảo vệ nhiệt: dừng sạc khi pin nóng, sạc lại khi đã nguội.
- Lịch sử 7 ngày (biểu đồ % pin, nhiệt độ, công suất) và thông báo.
- Helper nền (LaunchDaemon) giữ giới hạn sạc cả khi app đã thoát; xử lý khi máy ngủ/thức.
- Bản build universal: chạy trên cả Apple Silicon và Intel. Trên Intel hiện chỉ xem thông tin (điều khiển sạc đang thử nghiệm).

### An toàn
- Pin ≤ 10% luôn được sạc; helper khôi phục mặc định khi bị dừng/gỡ; luôn bật lại adapter trước khi ngủ.
- Helper chỉ nhận kết nối XPC từ client có identifier của app. App đang ký ad-hoc nên đây chưa phải xác thực chữ ký đầy đủ (xem "Giới hạn đã biết" trong README).

### Phát hành
- Version theo SemVer (`VERSION`), CHANGELOG, lệnh `make bump-patch|minor|major`.
- GitHub Actions tự build bản universal, đóng gói `.dmg`/`.zip`, checksum và build provenance attestation khi đẩy tag.

[Unreleased]: https://github.com/hasoftware/MacPowerManager/compare/v0.13.0...HEAD
[0.13.0]: https://github.com/hasoftware/MacPowerManager/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/hasoftware/MacPowerManager/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/hasoftware/MacPowerManager/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/hasoftware/MacPowerManager/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/hasoftware/MacPowerManager/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/hasoftware/MacPowerManager/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/hasoftware/MacPowerManager/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/hasoftware/MacPowerManager/compare/v0.5.2...v0.6.0
[0.5.2]: https://github.com/hasoftware/MacPowerManager/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/hasoftware/MacPowerManager/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/hasoftware/MacPowerManager/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/hasoftware/MacPowerManager/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/hasoftware/MacPowerManager/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/hasoftware/MacPowerManager/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/hasoftware/MacPowerManager/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/hasoftware/MacPowerManager/releases/tag/v0.1.0
