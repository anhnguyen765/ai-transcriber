import SwiftUI

/// Who said something. "bạn" = the person recording (mic track), "người khác" = everyone else.
enum SpeakerKind: Equatable {
    case me, others

    var color: Color { self == .me ? .water : .sandInk }
    /// Light bubble / pill fill.
    var tint: Color { self == .me ? .foam : .sand }
    /// Text on `tint`.
    var tintInk: Color { self == .me ? .deep : .sandInk }
    var label: String { self == .me ? String(localized: "bạn") : String(localized: "người khác") }

    /// Maps transcript speaker labels ("Tôi", "Người khác", …) and track names.
    init(track: TranscriptTrack) { self = track == .mic ? .me : .others }
}

/// The 7 pt dot in ProjectHeader.
enum ProjectStatus: Equatable {
    case indexed
    case indexing
    /// Index is up to date, but no document has been read (empty project or not read yet).
    case noDocuments
    case recording
    case attention(String)
    case none

    var tooltip: String {
        switch self {
        case .indexed: String(localized: "Đã đọc xong dự án, sẵn sàng để hỏi.")
        case .indexing: String(localized: "Đang đọc tài liệu dự án…")
        case .noDocuments: String(localized: "Chưa có tài liệu nào được đọc")
        case .recording: String(localized: "Đang ghi âm.")
        case .attention(let message): message
        case .none: String(localized: "Chưa chọn thư mục dự án.")
        }
    }
}
