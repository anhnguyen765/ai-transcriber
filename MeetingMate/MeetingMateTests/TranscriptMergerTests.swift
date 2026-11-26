import Testing
@testable import MeetingMate

/// Tests for the merge + cleanup rules, using fake segments (no audio or model needed).
struct TranscriptMergerTests {
    private func seg(_ start: Double, _ end: Double, _ text: String,
                     noSpeech: Double? = nil, logProb: Double? = nil) -> TranscribedSegment {
        TranscribedSegment(start: start, end: end, text: text,
                           noSpeechProbability: noSpeech, averageLogProbability: logProb)
    }

    // MARK: Ordering

    @Test func mergesTracksInTimeOrderWithLabels() {
        let lines = TranscriptMerger.merge([
            (.mic, 0, [seg(12, 14, "Ok mình bắt đầu nhé"), seg(30, 32, "Đúng rồi")]),
            (.system, 0, [seg(5, 8, "Chào mọi người"), seg(20, 25, "Hôm nay mình bàn về kế hoạch")]),
        ])
        #expect(lines.map(\.text) == [
            "Chào mọi người", "Ok mình bắt đầu nhé", "Hôm nay mình bàn về kế hoạch", "Đúng rồi",
        ])
        #expect(lines.map(\.speaker) == ["Người khác", "Tôi", "Người khác", "Tôi"])
        #expect(lines.map(\.track) == [.system, .mic, .system, .mic])
    }

    @Test func appliesTrackOffsetToGetMeetingTime() {
        let lines = TranscriptMerger.merge([(.file, 10, [seg(1, 2, "Xin chào")])])
        #expect(lines.first?.start == 11)
        #expect(lines.first?.end == 12)
        #expect(lines.first?.speaker == "Người nói")
    }

    // MARK: Echo removal

    @Test func dropsMicEchoOfSystemAudio() {
        let lines = TranscriptMerger.merge([
            (.system, 0, [seg(10, 14, "Chúng ta sẽ ra mắt sản phẩm vào tháng sau.")]),
            // Same words picked up by the mic from the speakers (different case/accents/punctuation).
            (.mic, 0, [seg(10.3, 14.2, "chung ta se ra mat san pham vao thang sau"),
                       seg(40, 42, "Mình đồng ý")]),
        ])
        #expect(lines.map(\.text) == ["Chúng ta sẽ ra mắt sản phẩm vào tháng sau.", "Mình đồng ý"])
    }

    @Test func keepsSimilarMicLineThatDoesNotOverlapInTime() {
        let lines = TranscriptMerger.merge([
            (.system, 0, [seg(10, 12, "Cảm ơn anh")]),
            (.mic, 0, [seg(30, 32, "Cảm ơn anh")]), // I said it myself, later
        ])
        #expect(lines.count == 2)
    }

    @Test func keepsOverlappingMicLineWithDifferentText() {
        let lines = TranscriptMerger.merge([
            (.system, 0, [seg(10, 14, "Bên mình đã gửi báo giá hôm qua")]),
            (.mic, 0, [seg(11, 13, "Dạ em nhận được rồi ạ")]), // talking over each other
        ])
        #expect(lines.count == 2)
    }

    // MARK: Hallucination / repetition removal

    @Test func removesSentenceRepeatedThreeTimesKeepingOne() {
        let cleaned = TranscriptMerger.removeHallucinations([
            seg(0, 2, "Vâng."), seg(2, 4, "vâng"), seg(4, 6, "Vâng!"), seg(6, 8, "Tiếp theo là gì?"),
        ])
        #expect(cleaned.map(\.text) == ["Vâng.", "Tiếp theo là gì?"])
    }

    @Test func keepsSentenceRepeatedOnlyTwice() {
        let cleaned = TranscriptMerger.removeHallucinations([seg(0, 1, "Ok"), seg(1, 2, "Ok")])
        #expect(cleaned.count == 2)
    }

    @Test func removesEmptyNoSpeechAndKnownHallucinations() {
        let cleaned = TranscriptMerger.removeHallucinations([
            seg(0, 1, "   "),
            seg(1, 2, "..."),
            seg(2, 5, "Hãy subscribe cho kênh Ghiền Mì Gõ để không bỏ lỡ những video hấp dẫn"),
            seg(5, 7, "Cảm ơn các bạn đã theo dõi"),
            seg(7, 9, "Ừm", noSpeech: 0.9, logProb: -1.5),
            seg(9, 12, "Nội dung thật", noSpeech: 0.9, logProb: -0.3), // confident text is kept
        ])
        #expect(cleaned.map(\.text) == ["Nội dung thật"])
    }

    // MARK: Paragraph joining

    @Test func joinsSameSpeakerWhenGapUnderTwoSeconds() {
        let lines = TranscriptMerger.merge([
            (.system, 0, [seg(0, 3, "Câu một."), seg(4, 6, "Câu hai."), seg(9, 11, "Câu ba.")]),
        ])
        #expect(lines.map(\.text) == ["Câu một. Câu hai.", "Câu ba."])
        #expect(lines.first?.end == 6)
    }

    @Test func doesNotJoinDifferentSpeakers() {
        let lines = TranscriptMerger.merge([
            (.system, 0, [seg(0, 2, "Anh nghĩ sao?")]),
            (.mic, 0, [seg(2.5, 4, "Em thấy ổn.")]),
        ])
        #expect(lines.count == 2)
    }

    // MARK: Sound tags

    @Test func removesSoundTagsButKeepsWords() {
        #expect(TranscriptMerger.removeSoundTags("Thật sự ấy *chúi* Mẹ tiếc") == "Thật sự ấy Mẹ tiếc")
        #expect(TranscriptMerger.removeSoundTags("[Âm nhạc] Xin chào (cười)") == "Xin chào")
        let cleaned = TranscriptMerger.removeHallucinations([seg(0, 2, "*chúi*"), seg(2, 4, "[Âm nhạc]")])
        #expect(cleaned.isEmpty)
    }

    // MARK: Leakage (loudness-based speaker check)

    /// 10 s of fake loudness, 100 ms frames:
    /// 0–4 s: only the other side talks (system 0.1, mic hears a leak of 0.05 = half as loud)
    /// 4–5 s: nobody talks (mic background noise 0.002)
    /// 5–7 s: only I talk (system silent, mic 0.08)
    /// 7–10 s: both talk at once (system 0.1, mic 0.2 = much louder than the 0.05 leak)
    private func fakeDetector() -> LeakageDetector? {
        let system = [Float](repeating: 0.1, count: 40) + [Float](repeating: 0, count: 30)
            + [Float](repeating: 0.1, count: 30)
        let mic = [Float](repeating: 0.05, count: 40) + [Float](repeating: 0.002, count: 10)
            + [Float](repeating: 0.08, count: 20) + [Float](repeating: 0.2, count: 30)
        return LeakageDetector(mic: mic, system: system)
    }

    @Test func learnsLeakGainFromRecording() throws {
        let detector = try #require(fakeDetector())
        #expect(abs(detector.leakGain - 0.5) < 0.001)
    }

    @Test func dropsMicSegmentThatIsOnlySpeakerLeak() throws {
        let detector = try #require(fakeDetector())
        #expect(detector.isLeakage(start: 0.5, end: 3.5))     // other side only
        #expect(!detector.isLeakage(start: 5.1, end: 6.9))    // me only
        #expect(!detector.isLeakage(start: 7.2, end: 9.8))    // both: I'm clearly louder than the leak
    }

    @Test func mergeUsesLeakageToFixLabels() throws {
        let detector = try #require(fakeDetector())
        let lines = TranscriptMerger.merge([
            (.system, 0, [seg(0, 4, "Bên kia nói câu này")]),
            // Whisper heard the leak slightly differently, so the text check alone would miss it.
            (.mic, 0, [seg(0.3, 3.8, "Bên kìa nói cầu nay nhé"), seg(5.1, 6.9, "Đây là tôi nói")]),
        ], leakage: detector)
        #expect(lines.map(\.speaker) == ["Người khác", "Tôi"])
        #expect(lines.map(\.text) == ["Bên kia nói câu này", "Đây là tôi nói"])
    }

    @Test func keepsLeakedTextAsOtherSideWhenSystemTrackMissedIt() throws {
        let detector = try #require(fakeDetector())
        let lines = TranscriptMerger.merge([
            (.system, 0, []), // Whisper found nothing in system.m4a here
            (.mic, 0, [seg(0.3, 3.8, "Bên kia nói câu này"), seg(5.1, 6.9, "Đây là tôi nói")]),
        ], leakage: detector)
        #expect(lines.map(\.speaker) == ["Người khác", "Tôi"])
        #expect(lines.first?.track == .mic) // the text came from the mic recording
    }

    @Test func noDetectorWithoutEnoughSystemAudio() {
        #expect(LeakageDetector(mic: [Float](repeating: 0.1, count: 100),
                                system: [Float](repeating: 0, count: 100)) == nil)
    }

    // MARK: Helpers

    @Test func normalizeRemovesCaseAccentsAndPunctuation() {
        #expect(TranscriptMerger.normalize("Đường  ĐI, Ổn chứ?") == "duong di on chu")
    }

    @Test func similarityBounds() {
        #expect(TranscriptMerger.similarity("abc", "abc") == 1)
        #expect(TranscriptMerger.similarity("abc", "xyz") == 0)
        #expect(TranscriptMerger.similarity("", "abc") == 0)
    }
}
