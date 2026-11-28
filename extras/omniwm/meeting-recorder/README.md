# meeting-recorder: widget OmniWM cho lắng

Hiện trạng thái ghi âm của lắng trên thanh bar của [OmniWM](https://github.com/OmniNull/OmniWM):

- Đang ghi: ⏺ đỏ + đồng hồ (`12:34`, hoặc `1:02:03` khi quá 1 giờ).
- Đang ghi nhưng macOS báo không app nào dùng micro (sau 10 giây): ⚠️ cam.
- Không ghi: ẩn (bật *Show icon when not recording* để luôn hiện).
- Click trái: popout (trạng thái, tên cuộc họp, thời gian, micro). Click phải: mở lắng.

lắng không có IPC, nên script `lang-omniwm-status` (chạy bằng launchd mỗi 3 giây) đọc log của lắng
(`~/Library/Application Support/Lang/Logs/lang.log`) và đẩy trạng thái lên bar:

```bash
omniwmctl shell set lang.status "<off|idle|recording>|<epoch bắt đầu>|<tên cuộc họp hoặc ->"
```

## Cài đặt

Cần bật OmniWM → Settings → Advanced → **Enable IPC**. Chạy các lệnh từ thư mục gốc của repo.

```bash
omniwmctl shell init meeting-recorder
cp extras/omniwm/meeting-recorder/{init.luau,settings.toml} ~/.config/omniwm/shell/default/widgets/meeting-recorder/

mkdir -p ~/.local/bin
cp extras/omniwm/meeting-recorder/lang-omniwm-status ~/.local/bin/
chmod +x ~/.local/bin/lang-omniwm-status

sed "s|__HOME__|$HOME|" extras/omniwm/meeting-recorder/com.lang.omniwm-status.plist > ~/Library/LaunchAgents/com.lang.omniwm-status.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.lang.omniwm-status.plist
```

Rồi vào Settings → Styles & Widgets → Bar → **Add Widget…** → `meeting-recorder` (lane `trailing`).

## Kiểm tra và gỡ lỗi

```bash
~/.local/bin/lang-omniwm-status --print     # script đang thấy trạng thái gì
omniwmctl query shell-widgets               # widget có "loaded", mục "problems" có lỗi không
omniwmctl shell set lang.status "recording|$(( $(date +%s) - 75 ))|test"   # giả lập đang ghi
```

Script nền ghi đè trạng thái giả trong vòng 60 giây; tạm tắt bằng
`launchctl bootout gui/$(id -u)/com.lang.omniwm-status` khi cần thử lâu hơn.
Lỗi của launchd nằm ở `/tmp/lang-omniwm-status.err`.

## Giới hạn

- Chỉ biết ghi / chờ / tắt: lắng không ghi log khi đang chép lời hay tóm tắt.
- Chỉ nhận ra `lang.app`. Bản Debug chạy từ Xcode (`MeetingMate.app`) hiện là "off".
- Dựa vào câu log của lắng (`Recording started: `, `Recording stopped: `, `lắng started (`, `Quitting (`).
  Đổi câu log trong app thì phải sửa script.
