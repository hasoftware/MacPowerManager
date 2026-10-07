# Changelog

Mọi thay đổi đáng chú ý của MacPowerManager được ghi ở đây.
Định dạng theo [Keep a Changelog](https://keepachangelog.com/vi/1.1.0/), version theo [Semantic Versioning](https://semver.org/lang/vi/):
**PATCH** khi sửa lỗi, **MINOR** khi thêm tính năng, **MAJOR** khi có thay đổi không tương thích.

## [Unreleased]

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

[Unreleased]: https://github.com/hasoftware/MacPowerManager/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/hasoftware/MacPowerManager/releases/tag/v0.1.0
