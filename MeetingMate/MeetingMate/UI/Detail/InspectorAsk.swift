import AppKit
import SwiftUI

/// Right side panel: "Hỏi về cuộc họp này". Uses the same Ask model as the Hỏi section.
/// "Cuộc họp này" searches only this meeting's folder; "cả dự án" searches the whole project.
struct InspectorAsk: View {
    @ObservedObject var ask: AskViewModel
    /// The project folder, to open the sources.
    let projectFolder: URL?
    let router: Router
    /// The meeting this panel is about (its folder under .meetings).
    let meetingFolder: URL
    @State private var meetingScope = true

    private let suggestions = ["Ai lo việc này?", "Quyết định chính là gì?", "Có điều gì đổi so với trước?"]

    private var meetingPrefix: String { ".meetings/\(meetingFolder.lastPathComponent)/" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hỏi về cuộc họp này")
                .typeStyle(.ui(13, .semibold))
                .foregroundStyle(.ink)

            ScopeChips(options: [(true, "cuộc họp này"), (false, "cả dự án")], selection: scopeBinding)
            Text(verbatim: meetingScope ? "Đang tìm trong cuộc họp này" : "Đang tìm trong cả dự án")
                .typeStyle(.caption)
                .foregroundStyle(.ink3)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(ask.turns) { turn in
                        TurnView(turn: turn, open: open)
                    }
                    if ask.turns.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(suggestions, id: \.self) { text in
                                SuggestionChip(text: text) {
                                    ask.input = text
                                    send()
                                }
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.never)

            HStack(spacing: 8) {
                TextField("Hỏi một câu…", text: $ask.input)
                    .textFieldStyle(.plain)
                    .typeStyle(.small)
                    .foregroundStyle(.ink)
                    .onSubmit(send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.input, style: .continuous).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.input, style: .continuous)
                        .strokeBorder(.line, lineWidth: Theme.hairline))
                Button(action: send) {
                    Circle()
                        .fill(.deep)
                        .frame(width: 28, height: 28)
                        .overlay {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                }
                .buttonStyle(.plain)
                .disabled(because: ask.input.trimmingCharacters(in: .whitespaces).isEmpty
                          ? String(localized: "Gõ câu hỏi trước.") : nil)
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.mist.opacity(0.75))
        .overlay(alignment: .leading) { Rectangle().fill(.line).frame(width: Theme.hairline) }
        .onAppear { ask.meetingPathPrefix = meetingScope ? meetingPrefix : nil }
        // Leaving the meeting must not leave the Hỏi section searching only this meeting.
        .onDisappear { ask.meetingPathPrefix = nil }
    }

    /// Changing the scope updates the search filter right away.
    private var scopeBinding: Binding<Bool> {
        Binding(
            get: { meetingScope },
            set: { now in
                meetingScope = now
                ask.meetingPathPrefix = now ? meetingPrefix : nil
            })
    }

    private func send() {
        guard !ask.input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        ask.send()
    }

    private func open(_ source: AnswerSource) {
        SourceOpener.open(source, projectFolder: projectFolder, router: router)
    }
}

/// One question and its answer. The question is a water bubble with a 4 pt bottom-right corner.
private struct TurnView: View {
    let turn: ChatTurn
    let open: (AnswerSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 30)
                Text(verbatim: turn.question)
                    .typeStyle(.small)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14,
                                                       bottomTrailingRadius: 4, topTrailingRadius: 14)
                        .fill(Color.water))
            }
            if turn.status == .searching && turn.answer.isEmpty {
                Text("Đang tìm trong dự án…")
                    .typeStyle(.caption)
                    .foregroundStyle(.ink3)
            } else if !turn.answer.isEmpty {
                Text(verbatim: turn.answer)
                    .typeStyle(.answer)
                    .foregroundStyle(.ink)
                    .textSelection(.enabled)
                if !turn.sources.isEmpty {
                    LegacySourceChips(answer: turn.answer, sources: turn.sources, open: open)
                }
            }
        }
    }
}
