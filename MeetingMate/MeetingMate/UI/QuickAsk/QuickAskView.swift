import AppKit
import SwiftUI

/// Quick Ask: type a question, or "ghi" to start recording, or a meeting name to jump there.
struct QuickAskView: View {
    @Bindable var app: AppState
    @ObservedObject var ask: AskViewModel
    let close: () -> Void
    @FocusState private var focused: Bool

    init(app: AppState, close: @escaping () -> Void) {
        self.app = app
        self.ask = app.ask
        self.close = close
    }
    private var trimmed: String { ask.input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isRecordCommand: Bool { trimmed.lowercased() == "ghi" }

    /// Meetings whose titles match what you typed (only for short, name-like input).
    private var meetingMatches: [MeetingInfo] {
        guard !trimmed.isEmpty, trimmed.count <= 40, !isRecordCommand else { return [] }
        return Array(MeetingList.filter(app.meetings, query: trimmed) { app.displayTitle($0) }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Query row
            HStack(spacing: 12) {
                WaterDropTile(size: 30)
                TextField("Hỏi về dự án…", text: $ask.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19))
                    .foregroundStyle(.ink)
                    .focused($focused)
                    .onSubmit(submit)
                KeyCap("esc")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)

            if !ask.turns.isEmpty || !meetingMatches.isEmpty || isRecordCommand {
                Hairline().padding(.horizontal, 18)
            }

            // Body
            VStack(alignment: .leading, spacing: 14) {
                if isRecordCommand {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill").foregroundStyle(.rec)
                        Text("Nhấn ↵ để bắt đầu ghi âm")
                            .typeStyle(.body)
                            .foregroundStyle(.ink)
                    }
                }
                ForEach(meetingMatches) { meeting in
                    Button {
                        // Opens the meeting itself in the main window (not the chat).
                        app.router.openMeeting(meeting.folder)
                        close()
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(.water).frame(width: 8, height: 8)
                            Text(verbatim: app.displayTitle(meeting))
                                .typeStyle(.bodyMedium)
                                .foregroundStyle(.ink)
                                .lineLimit(1)
                            Spacer()
                            Text(verbatim: LangFormat.relative(meeting.date))
                                .typeStyle(.caption)
                                .foregroundStyle(.ink2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRowStyle())
                }
                if let turn = ask.turns.last {
                    if !ask.turns.isEmpty {
                        ScopeChips(options: AskViewModel.Scope.allCases.map { ($0, $0.title) },
                                   selection: $ask.scope)
                    }
                    answer(turn)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, ask.turns.isEmpty && meetingMatches.isEmpty && !isRecordCommand ? 0 : 20)

            // Footer
            HStack(spacing: 14) {
                Button { openMain() } label: {
                    Text("↵ mở trong lắng")
                }
                .buttonStyle(.plain)
                .disabled(because: ask.turns.isEmpty ? String(localized: "Hỏi một câu trước.") : nil)
                Text("⌘C chép câu trả lời")
                    .foregroundStyle(ask.turns.isEmpty ? .ink3 : .ink2)
                Spacer()
                Image(systemName: "mic.fill").foregroundStyle(.rec)
                Text("gõ “ghi” để bắt đầu ghi âm")
            }
            .typeStyle(.caption)
            .foregroundStyle(.ink2)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.mist.opacity(0.6))
        }
        .frame(width: QuickAskController.width)
        .panelBackground(radius: Theme.Radius.quickAsk, fill: 0.8)
        // Light appearance (spec: light mode first), so the panel never turns dark grey with faded text.
        .preferredColorScheme(.light)
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .quickAskShown)) { _ in focused = true }
        .onExitCommand(perform: close)
        // ⌘C copies the answer when the query box is empty; otherwise it copies text as usual.
        .background {
            Button("") { copyAnswer() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(ask.turns.last?.answer.isEmpty != false || !ask.input.isEmpty)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }

    @ViewBuilder private func answer(_ turn: ChatTurn) -> some View {
        switch turn.status {
        case .searching where turn.answer.isEmpty:
            Text("Đang tìm trong dự án…")
                .typeStyle(.body)
                .foregroundStyle(.ink3)
        case .notFound:
            Text("Không tìm thấy trong dự án.")
                .typeStyle(.body)
                .foregroundStyle(.ink2)
        case .failed(let message):
            Text(verbatim: message)
                .typeStyle(.body)
                .foregroundStyle(.rec)
        default:
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: turn.answer)
                    .typeStyle(.quickAnswer)
                    .foregroundStyle(.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !turn.sources.isEmpty {
                    LegacySourceChips(answer: turn.answer, sources: turn.sources, open: openSource)
                    SourceQuotes(sources: turn.sources, projectFolder: app.projectFolder, router: app.router)
                }
            }
        }
    }

    private func submit() {
        if isRecordCommand {
            ask.input = ""
            close()
            app.toggleRecording()
            return
        }
        guard !trimmed.isEmpty else { return }
        // A name that matches a meeting (not a question) opens that meeting.
        if let first = meetingMatches.first, !trimmed.contains("?") {
            app.router.openMeeting(first.folder)
            close()
            return
        }
        ask.send()
    }

    private func copyAnswer() {
        guard let answer = ask.turns.last?.answer, !answer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }

    /// Opens the chat in the main window's Hỏi section.
    private func openMain() {
        app.section = .ask
        app.router.open(windowID: "main")
        close()
    }

    private func openSource(_ source: AnswerSource) {
        SourceOpener.open(source, projectFolder: app.projectFolder, router: app.router)
        close()
    }
}
