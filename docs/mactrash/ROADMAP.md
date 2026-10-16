# Tích hợp MacTrash vào MacPowerManager

Nguồn: [hasoftware/MacTrash](https://github.com/hasoftware/MacTrash) 1.5.0, một script zsh khoảng 4.000 dòng, giấy
phép MIT, cùng tác giả. Mục tiêu là viết lại bằng Swift thành một nhóm trang **Dọn dẹp** trong bảng điều khiển, giữ
nguyên triết lý gốc:

1. **Quét là chỉ đọc.** Không mục nào được chọn sẵn, không có gì bị xóa khi người dùng chưa tick và xác nhận.
2. **Không đoán bừa.** Một mục chỉ bị đánh dấu khi không khớp bundle id, tên app, tên lệnh CLI, và không phải thành
   phần của macOS. Mỗi mục ghi rõ vì sao bị đánh dấu.
3. **Mọi thao tác xóa đều hoàn tác được.** File vào Thùng rác (không xóa cứng); file cấu hình được sao lưu trước
   khi sửa; mỗi lần dọn có manifest và khôi phục được ngay trong app. Ngoại lệ duy nhất là xóa vĩnh viễn trong Thùng
   rác, phải gõ xác nhận.
4. **Việc nguy hiểm thì chỉ báo.** Chứng chỉ gốc, kext, sudoers… được liệt kê kèm lý do, không bao giờ tự đụng vào.

## Kiến trúc

| Thành phần | Vai trò |
|---|---|
| `Sources/CleanCore` (target mới) | Toàn bộ logic, không phụ thuộc giao diện: chỉ mục app đã cài, các bộ quét, chốt an toàn, xóa vào Thùng rác, sao lưu và khôi phục, danh sách bỏ qua. Đường dẫn gốc và lệnh hệ thống tiêm được, để test chạy trong thư mục tạm. |
| `Tests/CleanCoreTests` | Gồm bộ test của MacTrash (`tests/mactrash_test.zsh`) chuyển sang XCTest, cùng test cho từng bộ quét trên cây thư mục giả. |
| `Sources/MacPowerManager/Pages/Cleanup` | Các trang SwiftUI: Quét tàn dư, Gỡ ứng dụng, Thùng rác, Dung lượng đĩa, Dữ liệu hệ thống, Lịch sử dọn. Song ngữ VI/EN. |

Một số nguyên tắc chạy:
- **Chỉ quét khi người dùng bấm.** Quét chạy nền, có tiến độ và hủy được. Không có quét định kỳ, để không làm mất
  thành quả tiết kiệm CPU/pin của v0.16.x.
- **Quyền:** app chạy quyền người dùng. Mục cần quyền quản trị (biên nhận gói, luật tường lửa, file trong `/Library`
  không ghi được) được **báo** kèm lệnh tương ứng, chưa tự dọn. Việc dọn qua helper root là giai đoạn riêng (P5) và
  cần quyết định riêng, vì helper xóa đường dẫn theo yêu cầu là bề mặt tấn công lớn.
- **Full Disk Access:** cần để đọc TCC và vài chỗ trong `~/Library`. App báo rõ đã có quyền chưa và mở đúng trang
  Cài đặt.

## Lộ trình

| Giai đoạn | Bản | Nội dung |
|---|---|---|
| **P0** | 0.17.0 | `CleanCore`: chỉ mục app/hệ thống, mô hình mục tìm thấy, chốt an toàn, Thùng rác, sao lưu/khôi phục, danh sách bỏ qua. Các bộ quét mức người dùng: tàn dư Library, LaunchAgents, mục đăng nhập, helper mồ côi (chỉ báo), biên nhận gói (chỉ báo), PATH và biến môi trường, DYLD, chứng chỉ, tường lửa (chỉ báo), TCC, system extension, symlink gãy, LaunchServices, native messaging, plugin, vỏ `.app` rỗng, Docker. Trang **Quét tàn dư** cùng lịch sử dọn và khôi phục. |
| P1 | 0.18.0 | **Gỡ ứng dụng**: chọn app, gom mọi file liên quan, xem lại từng file rồi đưa vào Thùng rác. |
| P2 | 0.19.0 | **Thùng rác** (kích thước, tuổi, xóa vĩnh viễn từng mục, phải gõ xác nhận) và **Dung lượng đĩa** (phân nhóm, đi sâu cây thư mục, danh sách cấm xóa tuyệt đối). |
| P3 | 0.20.0 | **Dữ liệu hệ thống** (đo được gì nói nấy, `?` khi cần quyền) và nhóm **Developer**: Xcode, simulator, cache toolchain, Homebrew, bản sao lưu iPhone, snapshot Time Machine. |
| P4 | 0.21.0 | Hoàn thiện: báo cáo HTML/xuất kết quả, so sánh giữa các lần quét, ảnh chụp README. |
| P5 | (cần quyết định) | Dọn mục cần quyền quản trị qua helper, với danh sách loại thao tác cho phép cố định. |

## Quy trình mỗi giai đoạn (workflow và subagent)

1. **Đặc tả:** các agent đọc từng phần của `mactrash.sh` và viết đặc tả chuyển đổi (`docs/mactrash/spec-*.md`): đầu
   vào, heuristic, trường hợp biên, test gốc tương ứng.
2. **Lõi:** một agent dựng phần dùng chung, gồm mô hình, chốt an toàn, sao lưu và test.
3. **Bộ quét:** các agent chạy song song, mỗi agent làm việc trên bản sao riêng của repo và chỉ chép về đúng các
   file được giao.
4. **Tích hợp:** build, chạy toàn bộ test, sửa lỗi ghép nối.
5. **Rà soát đối kháng:** các agent cố tìm đường xóa nhầm hoặc mất dữ liệu, hoặc lệch so với heuristic gốc. Chỉ những
   lỗi được xác nhận mới được sửa.
6. **Giao diện:** trang SwiftUI, song ngữ, ảnh chụp kiểm tra bố cục.
7. Người điều phối build, test, commit dưới tên hasoftware, nâng version MINOR và phát hành.
