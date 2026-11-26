import Foundation
import Testing
@testable import MeetingMate

struct GlossaryTests {
    private let doc = """
    # Thanh toán QR
    Dự án dùng WhisperKit và API của Zalopay. Hôm nay nhóm Zalopay gửi tài liệu.
    Bên Zalopay muốn tích hợp QR trên iOS 18.
    Hôm qua mình họp. Hôm kia cũng vậy.
    """
    private let meeting = """
    [00:00:05] Người khác: Anh Tùng gửi báo giá chưa?
    [00:00:09] Tôi: Chị Lan bảo anh Tùng gửi rồi, còn Phương Nguyễn thì chưa.
    [00:00:12] Người khác: Phương Nguyễn sẽ gửi sau.
    """

    @Test func collectsNamesAcronymsAndHeadings() {
        let terms = GlossarySuggester.candidates(from: [(.doc, doc), (.meeting, meeting)]).map(\.term)
        for expected in ["Thanh toán QR", "Zalopay", "WhisperKit", "API", "QR", "Tùng", "Lan", "Phương Nguyễn"] {
            #expect(terms.contains(expected), "missing \(expected)")
        }
        // Ordinary words at the start of a sentence are not names.
        #expect(!terms.contains("Hôm"))
        #expect(!terms.contains("Bên"))
        // Our own speaker labels never become terms.
        #expect(!terms.contains("Tôi") && !terms.contains("Người khác"))
    }

    @Test func codeChunksAreIgnored() {
        let terms = GlossarySuggester.candidates(from: [(.code, "let SomeVeryLongTypeName = SomeVeryLongTypeName()")])
        #expect(terms.isEmpty)
    }

    @Test func specialWordsAreDetected() {
        #expect(GlossarySuggester.isSpecial("VNG"))
        #expect(GlossarySuggester.isSpecial("WhisperKit"))
        #expect(GlossarySuggester.isSpecial("iOS18"))
        #expect(!GlossarySuggester.isSpecial("Hôm"))
        #expect(!GlossarySuggester.isSpecial("A"))
    }

    @Test func llmResultIsLimitedToRealCandidates() {
        let candidates = [
            GlossarySuggester.Candidate(term: "Zalopay", count: 3, score: 3),
            GlossarySuggester.Candidate(term: "Phương Nguyễn", count: 2, score: 6),
        ]
        let cleaned = GlossarySuggester.CleanedList(terms: [
            .init(term: "ZaloPay", kind: "product"),       // casing fixed by the model: kept
            .init(term: "Phương Nguyễn", kind: "person"),
            .init(term: "Phương Nguyễn", kind: "person"),  // duplicate: dropped
            .init(term: "Kubernetes", kind: "term"),       // not in the candidates: invented, dropped
        ])
        let result = GlossarySuggester.reconcile(cleaned, with: candidates)
        #expect(result.map(\.term) == ["ZaloPay", "Phương Nguyễn"])
        #expect(result.first?.count == 3)
    }

    @Test func savingKeepsCommentsAndRemovesUnticked() {
        let existing = "# Tên trong dự án\nZalopay\nTên Cũ\n"
        let text = GlossarySuggester.glossaryText(existing: existing, selected: ["Zalopay", "Phương Nguyễn", "zalopay"])
        #expect(text == "# Tên trong dự án\nZalopay\nPhương Nguyễn\n")
        #expect(GlossarySuggester.existingTerms(in: existing) == ["Zalopay", "Tên Cũ"])
    }
}
