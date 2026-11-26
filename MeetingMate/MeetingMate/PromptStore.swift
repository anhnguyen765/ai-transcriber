import Foundation

/// The prompts as editable .txt files in ~/Library/Application Support/Lang/Prompts/.
/// Placeholders like {{transcript}} are filled in by SummaryService.
struct Prompts: Equatable {
    var system: String
    var chunk: String   // pass 1: notes for one part of a long meeting
    var final: String   // pass 2 (or the single pass): the final summary

    func fill(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { text, pair in text.replacingOccurrences(of: "{{\(pair.key)}}", with: pair.value) }
    }
}

enum PromptStore {
    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Lang/Prompts", directoryHint: .isDirectory)
    }

    private static let files: [(name: String, keyPath: WritableKeyPath<Prompts, String>)] = [
        ("system.txt", \.system),
        ("pass1_chunk.txt", \.chunk),
        ("pass2_final.txt", \.final),
    ]

    /// Creates any missing prompt file with the default text (called at launch).
    static func createMissingDefaults() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files where !FileManager.default.fileExists(atPath: folder.appending(path: file.name).path) {
            try? defaults[keyPath: file.keyPath].write(to: folder.appending(path: file.name),
                                                       atomically: true, encoding: .utf8)
        }
    }

    /// Settings → "Reset prompts to default".
    static func resetToDefaults() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try defaults[keyPath: file.keyPath].write(to: folder.appending(path: file.name),
                                                      atomically: true, encoding: .utf8)
        }
    }

    /// Current prompts; a missing or empty file falls back to the default.
    static func load() -> Prompts {
        var prompts = defaults
        for file in files {
            if let text = try? String(contentsOf: folder.appending(path: file.name), encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prompts[keyPath: file.keyPath] = text
            }
        }
        return prompts
    }

    // MARK: - Defaults

    static let defaults = Prompts(
        system: """
        Bạn là trợ lý viết biên bản cuộc họp. Bạn nhận bản chép lời tự động của một cuộc họp; bản chép lời có thể có lỗi chính tả.

        Quy tắc:
        - Chỉ dùng thông tin có trong bản chép lời. Không bao giờ bịa tên người, con số, ngày tháng hay hạn chót.
        - Người phụ trách (owner) chỉ ghi khi trong cuộc họp có người được nêu tên hoặc tự nhận việc. Nếu không rõ, ghi đúng "Chưa rõ". Hạn chót (deadline) cũng vậy.
        - "{{my_name}}" là người dùng (người ghi âm). "Người khác" là những người còn lại trong cuộc gọi.
        - Viết bằng {{language}}. Nếu viết tiếng Việt thì phải đúng dấu.
        - Giữ nguyên các thuật ngữ tiếng Anh như người nói đã dùng.
        - Chỉ sửa lỗi chính tả do chép lời khi bạn chắc chắn (ví dụ tên sản phẩm bị nghe sai).
        - timestamp lấy từ dòng liên quan trong bản chép lời, dạng hh:mm:ss.
        - Bỏ qua chuyện phiếm không liên quan đến nội dung chính.
        - Chỉ trả lời bằng JSON đúng schema được yêu cầu, không thêm chữ nào khác.
        """,
        chunk: """
        Đây là phần {{part}}/{{total}} của một cuộc họp (từ {{from}} đến {{to}}).
        Hãy rút ra từ RIÊNG phần này:
        - keyPoints: các điểm chính (tối đa 8)
        - decisions: các quyết định đã được chốt
        - actionItems: việc cần làm (task, owner, deadline)
        - openQuestions: câu hỏi còn bỏ ngỏ
        Mỗi mục kèm timestamp. Mục nào không có thì để mảng rỗng.

        JSON schema:
        {{schema}}

        Bản chép lời:
        {{transcript}}
        """,
        final: """
        Dưới đây là {{input_kind}} của một cuộc họp dài {{duration}}.
        Hãy viết biên bản cuối cùng:
        - title: tiêu đề ngắn (tối đa 10 từ)
        - overview: tóm tắt 3–5 câu về nội dung chính
        - keyPoints: các điểm chính
        - decisions: các quyết định đã được chốt
        - actionItems: việc cần làm (task, owner, deadline)
        - openQuestions: câu hỏi còn bỏ ngỏ
        Gộp các mục trùng nhau (giữ timestamp sớm nhất). Mỗi mục kèm timestamp. Mục nào không có thì để mảng rỗng.

        JSON schema:
        {{schema}}

        {{project_context}}

        {{input}}
        """
    )
}
