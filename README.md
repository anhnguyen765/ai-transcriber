<p align="center">
  <img src="docs/icon.png" width="128" alt="lắng">
</p>

<h1 align="center">lắng</h1>

<p align="center"><em>Lắng nghe. Rồi để mọi thứ lắng lại.</em></p>

---

## Vì sao lại là "lắng"?

Trong tiếng Việt, **lắng** có hai nghĩa.

Nghĩa thứ nhất là *lắng nghe*: nghe một cách chú tâm, không chen ngang, không vội vàng.

Nghĩa thứ hai là *lắng xuống*. Như một cốc nước đục: chỉ cần để yên một lúc, cặn sẽ chìm xuống đáy và phần nước phía trên trở nên trong vắt.

Một cuộc họp cũng giống cốc nước đục ấy. Có rất nhiều tiếng nói, ý tưởng chồng lên nhau, những câu "để em xem lại", "chốt vậy nhé", "à mà khoan". Khi cuộc họp kết thúc, điều quan trọng thường đã trôi mất giữa tất cả những âm thanh đó.

lắng được làm ra để giữ lại phần trong ấy.

## Điều lắng tin

**Bạn nên được có mặt trọn vẹn trong cuộc họp.**
Không phải vừa nghe vừa ghi chép vội, không phải sợ quên ai hứa làm gì. Hãy cứ lắng nghe, phần ghi nhớ để lắng lo.

**Tiếng Việt xứng đáng được hiểu đúng.**
Nhiều công cụ ghi chú cuộc họp được làm cho tiếng Anh trước, còn tiếng Việt thì "cũng tạm được". Dấu thanh sai, tên người viết sai, giọng miền Trung hay miền Nam bị nhận nhầm. lắng ưu tiên tiếng Việt ngay từ đầu, kể cả kiểu nói pha tiếng Anh rất quen thuộc ở chỗ làm.

**Cuộc họp của bạn là của bạn.**
Có những cuộc trò chuyện không nên rời khỏi căn phòng, như chuyện lương, chuyện khách hàng hay những ý tưởng còn đang ấp ủ. lắng chạy hoàn toàn trên máy của bạn: không gửi lên cloud, không cần tài khoản, không có bot lạ nào xin vào phòng họp.

**Một cuộc họp không đứng một mình.**
Hôm nay team chốt deadline, nhưng hai tuần trước đã chốt khác. Tài liệu dự án nói một đằng, cuộc họp nói một nẻo. lắng đọc thư mục dự án của bạn để hiểu cuộc họp nằm ở đâu trong câu chuyện lớn hơn, và nhắc bạn khi có điều gì đã thay đổi.

**Công cụ tốt không cần ồn ào.**
lắng nằm lặng lẽ trên thanh menu. Một cú nhấp để bắt đầu, một cú nhấp để dừng. Phần còn lại diễn ra trong yên tĩnh, và khi xong, mọi thứ đã lắng lại.

## lắng làm được gì

- **Ghi lại cuộc họp** chỉ với một cú nhấp hoặc `⌃⌥R`: giọng của bạn qua micro, giọng người khác qua Zoom, Google Meet hay Teams.
- **Chép lời tiếng Việt** ngay trên máy, có dấu, tách rõ *bạn* và *người khác*.
- **Tóm tắt** thành những điều thật sự cần nhớ: quyết định, việc cần làm (ai làm, khi nào), những câu hỏi còn bỏ ngỏ.
- **Gắn mỗi ý với đúng khoảnh khắc**: bấm vào là nghe lại chính câu nói đó.
- **Trả lời câu hỏi** như *"tuần này team chốt gì về deadline?"*, kèm nguồn và cả giọng nói gốc của người đã nói.
- **Nhớ theo dự án**: tài liệu, các cuộc họp cũ, và những gì đã thay đổi.

Và tất cả đều miễn phí, chạy offline, dữ liệu nằm trong chính thư mục của bạn.

---

## Bắt đầu với dự án

### Yêu cầu

- Mac chip Apple Silicon (M1 trở lên), macOS 15 trở lên
- Nên có 16 GB RAM (máy 8 GB dùng được với `qwen3:4b`)
- [Ollama](https://ollama.com) và Xcode 16 trở lên

### Cài đặt

1. **Tải các model chạy trên máy**
   ```bash
   ollama pull qwen3:8b   # tóm tắt và hỏi đáp (máy 8 GB dùng qwen3:4b)
   ollama pull bge-m3     # tìm kiếm tài liệu dự án, hỗ trợ tiếng Việt
   ```
2. **Build app**
   ```bash
   git clone https://github.com/anhnguyen765/ai-transcriber.git
   cd ai-transcriber/MeetingMate
   open MeetingMate.xcodeproj
   ```
   Chọn Apple ID của bạn ở *Signing & Capabilities* (target `MeetingMate`), rồi bấm **Run**.
3. **Lần mở đầu tiên**: chọn thư mục dự án, cho phép **Micro** và **Ghi màn hình** (cần để thu âm thanh của máy; mở lại app sau khi cấp quyền), rồi tải model chép lời.

> Mẹo: đeo tai nghe khi họp online để lắng tách giọng bạn rõ hơn.

> Đã cấp quyền mà bấm ghi âm vẫn không chạy? Nếu app được ký ad-hoc (`CODE_SIGN_IDENTITY=-`), mỗi lần build lại macOS coi là app mới nên quyền cũ không còn tác dụng. Hãy ký bằng chứng chỉ Apple Development, rồi chạy `tccutil reset Microphone com.n3rd.MeetingMate` và `tccutil reset ScreenCapture com.n3rd.MeetingMate` và cấp quyền lại một lần.

Dùng [OmniWM](https://github.com/OmniNull/OmniWM)? Có sẵn widget hiện trạng thái ghi âm trên thanh bar: [extras/omniwm/meeting-recorder](extras/omniwm/meeting-recorder).

### Phím tắt

| Việc | Phím |
|---|---|
| Bắt đầu / dừng ghi âm | `⌃⌥R` |
| Hỏi nhanh từ bất kỳ đâu | `⌃⌥Space` |
| Tìm mọi thứ | `⌘K` |

Phím tắt toàn cục có thể đổi trong Settings → Shortcuts.

### Cách lắng hoạt động

```
micro + âm thanh máy ──► Whisper (trên máy) ──► bản ghi (bạn / người khác)
                                                      │
thư mục dự án ──► chia đoạn + embedding (bge-m3) ──► SQLite
                                                      │
                                  tìm kiếm ◄──────────┘
                                      │
                    Ollama + Qwen3 ──► tóm tắt · trả lời kèm nguồn
```

Các bước chạy lần lượt để vừa với 16 GB RAM: chép lời xong, giải phóng Whisper, rồi mới tóm tắt.

### Dữ liệu của bạn

Phần lớn là file Markdown, JSON và audio đọc được, nằm ngay trong thư mục dự án:

```
dự-án-của-bạn/
└── .meetings/
    ├── glossary.txt              # tên riêng, thuật ngữ để chép lời đúng hơn
    ├── 2026-11-26_10-00-00/
    │   ├── mic.m4a  system.m4a
    │   ├── transcript.md / .json
    │   ├── summary.md / .json
    │   └── meta.json
    └── chats/
```

- Bỏ qua file khi index bằng `.langignore` ở thư mục dự án (cú pháp giống `.gitignore`).
- Prompt tóm tắt có thể chỉnh trong `~/Library/Application Support/Lang/Prompts/`.
- Index tìm kiếm nằm trong `~/Library/Application Support/Lang/`, không ghi vào thư mục dự án.

### Quyền riêng tư

lắng không gửi dữ liệu ra ngoài. Kết nối duy nhất là tới Ollama trên `localhost` và tải model một lần. Và hãy luôn báo cho mọi người biết khi bạn ghi âm cuộc họp: lưu trên máy không thay cho sự đồng ý.

### Lộ trình

- [ ] Phụ đề trực tiếp khi đang họp
- [ ] Tách giọng từng người ở đầu bên kia
- [ ] PhoWhisper cho giọng địa phương khó
- [ ] Dark mode

### Xây dựng bằng

[WhisperKit](https://github.com/argmaxinc/WhisperKit) · [Ollama](https://ollama.com) · Qwen3 · bge-m3 · [GRDB](https://github.com/groue/GRDB.swift) · [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) · SwiftUI · Newsreader & Geist Mono (SIL OFL)

---

<p align="center"><em>Dành cho những ai họp nhiều, nghe nhiều,<br>và muốn nhớ đúng điều quan trọng.</em></p>

## License

MIT © Anh Nguyen. Xem [LICENSE](LICENSE).
