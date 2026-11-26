import Foundation
import Testing
@testable import MeetingMate

struct MeetingLibraryTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "lang-lib-\(UUID().uuidString)")

    private func makeMeeting(_ name: String, title: String?, status: MeetingMeta.Status,
                             transcript: String? = nil, summaryMD: String? = nil) throws {
        let folder = root.appending(path: ".meetings/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try MeetingMeta(startTime: ProjectScanner.meetingDate(name)!, durationSeconds: 600, projectPath: root.path,
                        micFile: "mic.m4a", systemFile: "system.m4a", status: status).save(to: folder)
        if let title {
            try JSONEncoder().encode(MeetingSummary(title: title, overview: "o"))
                .write(to: folder.appending(path: SummaryWriter.jsonFileName))
        }
        if let summaryMD { try summaryMD.write(to: folder.appending(path: SummaryWriter.markdownFileName), atomically: true, encoding: .utf8) }
        if let transcript { try transcript.write(to: folder.appending(path: TranscriptWriter.markdownFileName), atomically: true, encoding: .utf8) }
    }

    @Test func listsMeetingsNewestFirstAndSkipsChats() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeMeeting("2026-11-20_10-00-00", title: "Họp kế hoạch", status: .summarized)
        try makeMeeting("2026-11-25_09-00-00", title: nil, status: .failed)
        try FileManager.default.createDirectory(at: root.appending(path: ".meetings/chats"), withIntermediateDirectories: true)

        let list = MeetingLibrary.load(projectFolder: root)
        #expect(list.map(\.folder.lastPathComponent) == ["2026-11-25_09-00-00", "2026-11-20_10-00-00"])
        #expect(list[1].title == "Họp kế hoạch")
        #expect(list[0].title == "Cuộc họp")
        #expect(list[0].statusText == "Lỗi chép lời")
    }

    @Test func searchWithoutIndexScansTextIgnoringAccents() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeMeeting("2026-11-20_10-00-00", title: "Họp kế hoạch", status: .summarized,
                        transcript: "[00:00:05] Người khác: Deadline thanh toán QR là 15/12")
        try makeMeeting("2026-11-21_10-00-00", title: "Ngân sách", status: .summarized)
        let all = MeetingLibrary.load(projectFolder: root)
        #expect(MeetingLibrary.search("thanh toan", in: all, store: nil).map(\.title) == ["Họp kế hoạch"])
        #expect(MeetingLibrary.search("ngân sách", in: all, store: nil).map(\.title) == ["Ngân sách"])
        #expect(MeetingLibrary.search("  ", in: all, store: nil).count == 2)
    }

    @Test func exportCombinesSummaryAndTranscript() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeMeeting("2026-11-20_10-00-00", title: "Họp kế hoạch", status: .summarized,
                        transcript: "# Cuộc họp 2026-11-20 10:00\n\nThời lượng: 10:00\n\n[00:00:05] Tôi: Chào",
                        summaryMD: "# Họp kế hoạch\n\n## Tóm tắt\n\nOk.\n")
        let meeting = try #require(MeetingLibrary.load(projectFolder: root).first)
        let md = try MeetingLibrary.exportMarkdown(meeting)
        #expect(md == "# Họp kế hoạch\n\n## Tóm tắt\n\nOk.\n\n---\n\n## Bản chép lời\n\nThời lượng: 10:00\n\n[00:00:05] Tôi: Chào\n")
        #expect(MeetingLibrary.exportFileName(meeting) == "2026-11-20 10-00 Họp kế hoạch.md")

        try makeMeeting("2026-11-21_10-00-00", title: nil, status: .recorded)
        let empty = try #require(MeetingLibrary.load(projectFolder: root).first)
        #expect(throws: (any Error).self) { try MeetingLibrary.exportMarkdown(empty) }
    }
}
