# MacPowerManager

App mã nguồn mở, miễn phí, để quản lý pin và sạc trên MacBook Apple Silicon: giới hạn sạc, xả pin, bảo vệ nhiệt, lịch sử pin và thông báo.
Đây là dự án vì cộng đồng, là một lựa chọn thay thế miễn phí cho các app giới hạn sạc trả phí.

*A free, open-source battery & charging manager for Apple Silicon MacBooks: charge limiter, discharge, heat protection, history and notifications. [English summary below](#english).*

> ⚠️ **Lưu ý:** App điều khiển sạc bằng cách ghi vào các SMC key không được Apple công bố.
> Đã thử nghiệm trên MacBook Pro M2 Pro, macOS 15.5. Hãy dùng với sự hiểu biết về rủi ro (xem [Giấy phép](#giấy-phép), phần không bảo hành).

## Tính năng

- **Thông tin pin**: %, dung lượng (mAh), sức khỏe, chu kỳ, điện áp, dòng, công suất, nhiệt độ (SMC + IOKit), adapter.
- **Giới hạn sạc**: dừng sạc ở X% và chỉ sạc lại khi pin giảm dưới `X - gap` (sailing), tránh bật/tắt sạc liên tục.
- **Tạm dừng sạc**: máy chạy hoàn toàn bằng adapter, pin giữ nguyên.
- **Xả pin**: ngắt adapter bằng phần mềm để xả về mức mục tiêu dù vẫn cắm sạc, sau đó tự tắt.
- **Bảo vệ nhiệt**: dừng sạc khi pin ≥ ngưỡng nóng và sạc lại khi đã nguội (hysteresis).
  Apple Silicon không cho phần mềm chỉnh dòng sạc, nên đây là cách giảm công suất và nhiệt khi sạc.
- **Lịch sử & thông báo**: biểu đồ % / nhiệt độ / công suất trong 7 ngày; thông báo khi đạt giới hạn, pin nóng, xả xong, pin yếu.
- **Giao diện**: menu bar (popover điều khiển nhanh) và cửa sổ chi tiết.

Vòng điều khiển chạy trong một helper nền (LaunchDaemon), nên giới hạn sạc vẫn có hiệu lực khi app đã thoát.

## Yêu cầu

- MacBook Apple Silicon (M1 trở lên)
- macOS 14 Sonoma trở lên
- Xcode 16+ để build từ mã nguồn

## Cài đặt (build từ mã nguồn)

```sh
git clone https://github.com/hasoftware/MacPowerManager.git
cd MacPowerManager
make install        # build và copy MacPowerManager.app vào /Applications
open /Applications/MacPowerManager.app
```

Lần đầu mở app, bấm **Cài helper** và nhập mật khẩu quản trị. Helper cần quyền root để ghi SMC.

> **Không chạy song song với AlDente, batt hoặc app giới hạn sạc khác.** Chúng ghi cùng SMC key nên sẽ xung đột.
> Hãy gỡ helper của app kia trước.

### Các lệnh khác

```sh
make run       # build và mở app từ thư mục build/
make test      # chạy unit test
make probe     # xem các SMC key liên quan tới sạc trên máy
```

## Gỡ cài đặt

1. Mở app → **Cài đặt** → **Gỡ helper**, hoặc chạy `make uninstall-helper`. Sạc sẽ trở về mặc định của macOS.
2. Xóa `/Applications/MacPowerManager.app` và `~/Library/Application Support/MacPowerManager`.

## Kiến trúc

| Target | Vai trò |
|---|---|
| `CSMC` | C: đọc/ghi SMC qua IOKit `AppleSMC` |
| `PowerCore` | Model, `ChargeController` (logic thuần, có unit test), đọc pin, giao thức XPC |
| `PowerHelper` | LaunchDaemon (root): vòng điều khiển 10s, ghi SMC, xử lý ngủ/thức, XPC |
| `MacPowerManager` | App SwiftUI: `MenuBarExtra` và cửa sổ chi tiết |
| `smc-probe` | CLI chẩn đoán SMC key |

SMC key được dò theo firmware: `CHTE`/`CHIE` (mới) hoặc `CH0B`+`CH0C`/`CH0I` (cũ).

### Cơ chế an toàn
- Pin ≤ 10% thì luôn bật adapter và cho phép sạc.
- Helper nhận SIGTERM (gỡ, `launchctl bootout`) thì khôi phục sạc + adapter về mặc định.
- Trước khi ngủ luôn bật lại adapter. Chế độ xả không được khôi phục sau khi helper khởi động lại.
- Helper chỉ nhận kết nối XPC từ app có identifier `com.hasoftware.MacPowerManager`.
  App được ký ad-hoc nên requirement này chỉ kiểm tra identifier. Nếu có Developer ID, có thể build với
  `SIGN_ID="Developer ID Application: …" make app` và thêm điều kiện Team ID vào `Sources/PowerHelper/XPCService.swift`.

## Đóng góp

Rất hoan nghênh issue và pull request!
- Chạy `make test` trước khi gửi PR. CI sẽ tự build và test trên macOS.
- Khi sửa code helper, hãy tăng `PowerConstants.helperVersion` để app nhắc người dùng cài lại helper.
- Nếu máy của bạn khác (M1/M3/M4, macOS khác), gửi kết quả `make probe` trong issue để mở rộng hỗ trợ.

## English

MacPowerManager is a free, open-source (GPL-3.0) menu bar app for Apple Silicon MacBooks. Features:
- charge limiter with sailing range
- pause charging (run from the adapter)
- discharge while plugged in
- heat protection (pause charging above a temperature threshold)
- battery details and history charts
- notifications

A root LaunchDaemon helper writes the SMC charging keys (`CHTE`/`CHIE`, or `CH0B`/`CH0C`/`CH0I` on older firmware) and keeps enforcing the limit when the app is closed.
Build with `make install`, open the app, then click **Install helper**. Don't run it alongside other charge limiters. The UI is currently in Vietnamese.

## Giấy phép

[GNU General Public License v3.0](LICENSE). Phần mềm được cung cấp "nguyên trạng", không có bất kỳ bảo hành nào.

MacPowerManager là dự án độc lập, không liên kết với Apple Inc. hay AppHouseKitchen (AlDente).
