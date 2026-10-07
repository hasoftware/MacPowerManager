# Changelog

Mọi thay đổi đáng chú ý của MacPowerManager được ghi ở đây.
Định dạng theo [Keep a Changelog](https://keepachangelog.com/vi/1.1.0/), version theo [Semantic Versioning](https://semver.org/lang/vi/):
**PATCH** khi sửa lỗi, **MINOR** khi thêm tính năng, **MAJOR** khi có thay đổi không tương thích.

## [Unreleased]

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

[Unreleased]: https://github.com/hasoftware/MacPowerManager/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/hasoftware/MacPowerManager/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/hasoftware/MacPowerManager/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/hasoftware/MacPowerManager/releases/tag/v0.1.0
