import Foundation
import Testing
@testable import MeetingMate

struct PipelineStatusTests {
    private func input(recorder: Recorder.State = .idle,
                       transcription: TranscriptionService.Phase = .idle,
                       summary: SummaryService.Phase = .idle,
                       docs: Int? = nil, done: PipelineDone? = nil,
                       started: Date? = nil, now: Date = Date()) -> PipelineStatus.Inputs {
        PipelineStatus.Inputs(recorder: recorder, transcription: transcription, summary: summary,
                              contextDocuments: docs, folder: URL(fileURLWithPath: "/tmp/m"),
                              title: "Sprint review", stepStartedAt: started, done: done, now: now)
    }

    private func progress(_ status: PipelineStatus) -> PipelineProgress? {
        if case .processing(let p) = status { p } else { nil }
    }

    @Test func idleAndRecording() {
        #expect(PipelineStatus.derive(input()) == .idle)
        #expect(PipelineStatus.derive(input(recorder: .recording)) == .recording)
        #expect(PipelineStatus.derive(input(recorder: .starting)) == .recording)
    }

    @Test func savingIsTheRecordStep() {
        #expect(progress(PipelineStatus.derive(input(recorder: .stopping)))?.step == .record)
    }

    @Test func transcribingShowsPercentAndProgress() throws {
        let p = try #require(progress(PipelineStatus.derive(input(transcription: .transcribing(0.5)))))
        #expect(p.step == .transcribe)
        #expect(p.detail.contains("50%"))
        #expect(abs(p.fraction - 0.4) < 0.001)
    }

    @Test func summarizingPartsAndDocuments() throws {
        let p = try #require(progress(PipelineStatus.derive(
            input(summary: .summarizing(part: 2, total: 3), docs: 6))))
        #expect(p.step == .summarize)
        #expect(p.detail == "đang tóm tắt phần 2/3 · dùng 6 tài liệu dự án")
        #expect(p.fraction > 0.7 && p.fraction < 1)
    }

    /// Summary waits for the transcription lock: the card keeps showing transcription.
    @Test func summaryWaitingDoesNotHideTranscription() {
        let status = PipelineStatus.derive(input(transcription: .transcribing(0.2), summary: .waitingForTranscription))
        #expect(progress(status)?.step == .transcribe)
    }

    @Test func doneShowsThenExpires() {
        let done = PipelineDone(folder: URL(fileURLWithPath: "/tmp/m"), title: "Sprint review",
                                actionItemCount: 3, at: Date())
        #expect(PipelineStatus.derive(input(done: done)) == .done(done))
        let later = Date().addingTimeInterval(PipelineStatus.doneLifetime + 1)
        #expect(PipelineStatus.derive(input(done: done, now: later)) == .idle)
        // A new recording always wins over a finished one.
        #expect(PipelineStatus.derive(input(recorder: .recording, done: done)) == .recording)
    }

    @Test func etaFromElapsedTime() {
        let now = Date()
        #expect(PipelineStatus.eta(fractionDone: 0.5, since: now.addingTimeInterval(-120), now: now) == "~2 phút")
        #expect(PipelineStatus.eta(fractionDone: 0.9, since: now.addingTimeInterval(-90), now: now) == "<1 phút")
        #expect(PipelineStatus.eta(fractionDone: 0.01, since: now, now: now) == nil)
    }
}
