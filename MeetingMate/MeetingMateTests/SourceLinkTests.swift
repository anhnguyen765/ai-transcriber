import Foundation
import Testing
@testable import MeetingMate

struct SourceLinkTests {
    private func source(_ path: String, _ type: SourceType, location: String = "", preview: String = "") -> AnswerSource {
        AnswerSource(label: "S1", path: path, location: location, sourceType: type,
                     meetingDate: AnswerService.dateFormatter.date(from: "2026-11-20"), preview: preview)
    }

    @Test func meetingSourcesPointToTheirFolder() {
        #expect(SourceLink.meetingFolder(source(".meetings/2026-11-20_10-00-00/transcript.md", .meeting))
                == ".meetings/2026-11-20_10-00-00")
        #expect(SourceLink.meetingFolder(source("docs/plan.md", .doc)) == nil)
    }

    @Test func startTimeComesFromTheTimeRangeOrTheText() {
        #expect(SourceLink.startTime(source("x", .meeting, location: "00:03:10–00:06:00")) == 190)
        // Summary chunks have a heading as location but timestamps in the text.
        #expect(SourceLink.startTime(source("x", .meeting, location: "Quyết định",
                                            preview: "- Lùi ra mắt · [00:12:30]")) == 750)
        #expect(SourceLink.startTime(source("x", .meeting, location: "Tóm tắt", preview: "không có giờ")) == 0)
        #expect(SourceLink.timestamp(in: "lines 1–80") == nil)
    }

    @Test func citationsBecomeLinksOnlyForKnownSources() throws {
        let text = AnswerService.citations(in: "a [S1] b [S9]")
        #expect(text == ["S1", "S9"])
        let attributed = CitationText.attributed("Deadline 15/12 [S1], xem thêm [S9].", labels: ["S1"])
        let links = attributed.runs.compactMap { run in run.link.map { (String(attributed[run.range].characters), $0) } }
        #expect(links.count == 1)
        #expect(links.first?.0 == "[S1]")
        #expect(links.first?.1.absoluteString == "lang-source://S1")
    }

    @Test func tooltipShowsPathDateLocationAndPreview() {
        let tip = SourceLink.tooltip(source(".meetings/2026-11-20_10-00-00/transcript.md", .meeting,
                                            location: "00:03:00–00:06:00", preview: "Chốt\ndeadline"))
        #expect(tip == ".meetings/2026-11-20_10-00-00/transcript.md\nCuộc họp 2026-11-20\n00:03:00–00:06:00\n“Chốt deadline…”")
    }
}
