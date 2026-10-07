
---

### Cài đặt
1. Tải **MacPowerManager-x.y.z.dmg** ở phần *Assets* bên dưới.
2. *(Tùy chọn)* Kiểm tra file: tải thêm `SHA256SUMS.txt` vào cùng thư mục và chạy
   `shasum -a 256 -c --ignore-missing SHA256SUMS.txt` (phải hiện `OK`).
   Xác minh file do GitHub Actions của repo này build: `gh attestation verify MacPowerManager-x.y.z.dmg --repo hasoftware/MacPowerManager`
3. Mở file `.dmg` và kéo **MacPowerManager** vào **Applications**.
4. Mở app. Vì app chưa được ký bằng Apple Developer ID, macOS sẽ chặn lần đầu:
   vào **System Settings → Privacy & Security**, kéo xuống và bấm **Open Anyway**, rồi xác nhận.
5. Bấm biểu tượng pin trên thanh menu → **Cài helper** và nhập mật khẩu quản trị.
   Khi cập nhật lên bản mới, app sẽ nhắc **cài lại helper**.

> ⚠️ Không chạy song song với AlDente, batt hoặc app giới hạn sạc khác. Hãy gỡ helper của app kia trước.
> Máy Intel: hiện chỉ xem thông tin pin, điều khiển sạc đang thử nghiệm.

**Gỡ cài đặt:** vào app → **Cài đặt → Gỡ helper** *trước khi* xóa app, nếu không helper vẫn giữ giới hạn sạc.
Nếu đã lỡ xóa app, xem mục [Gỡ cài đặt](https://github.com/hasoftware/MacPowerManager#gỡ-cài-đặt) trong README.

### Install (English)
1. Download the `.dmg` and drag the app to Applications.
2. Open the app and allow it in **System Settings → Privacy & Security → Open Anyway** (not notarized yet).
3. Click the menu bar icon → **Cài helper** (Install helper).

Requires macOS 14+. Charge control works on Apple Silicon only for now. To uninstall, use **Cài đặt → Gỡ helper** (Settings → Uninstall helper) before deleting the app.
