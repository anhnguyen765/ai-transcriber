# lắng

Ứng dụng menu bar cho macOS để ghi âm cuộc họp, chép lời và tóm tắt, chạy hoàn toàn trên máy của bạn.

- Ghi micro và âm thanh hệ thống (cuộc gọi Zoom, Meet, Teams...) vào file riêng.
- Chép lời bằng WhisperKit (chạy trên máy).
- Tóm tắt và hỏi đáp về dự án bằng Ollama (chạy trên máy).
- Lưu toàn bộ vào thư mục `.meetings` trong thư mục dự án bạn chọn.

## Yêu cầu

- macOS 15 trở lên.
- Xcode 16 trở lên.
- [Ollama](https://ollama.com) nếu muốn tóm tắt và hỏi đáp. Không có Ollama thì vẫn ghi âm và chép lời được.

## Build

1. Mở `MeetingMate/MeetingMate.xcodeproj` bằng Xcode.
2. Chọn target `MeetingMate`, tab **Signing & Capabilities**, chọn **Team** là Apple ID của bạn. Repo để trống team nên bạn phải tự chọn.
3. Bấm ⌘R để chạy, hoặc chạy test bằng ⌘U.

Lệnh build dòng lệnh (không ký, dùng để kiểm tra build):

```bash
cd MeetingMate
xcodebuild -scheme MeetingMate -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY=- build
```

Test chạy trên máy bạn có thể đọc thư mục dự án mẫu qua biến môi trường `LANG_TEST_PROJECT`. Không đặt biến này thì các test chụp giao diện vẫn chạy, chỉ bỏ qua phần dữ liệu cuộc họp thật.

## Quyền cần cấp lần đầu

- **Micro:** để ghi giọng nói của bạn.
- **Ghi màn hình và âm thanh hệ thống:** để ghi âm thanh của người khác trong cuộc gọi.

macOS sẽ hỏi khi bạn bấm Record lần đầu.

## Icon

Logo lắng là bát thủy tinh, ba lớp trầm tích và một giọt nước rơi vào. Nguồn là code: `MeetingMate/MeetingMate/LangMark.swift`, xuất bộ icon bằng `IconExporter.swift` (chỉ có trong bản Debug).

## Giấy phép

MIT. Xem [LICENSE](LICENSE).
