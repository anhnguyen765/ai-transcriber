import SwiftUI

/// "Hỏi" in the main window: the whole chat in the window (no separate Ask window).
struct AskSection: View {
    @Bindable var app: AppState
    @ObservedObject var ask: AskViewModel

    init(app: AppState) {
        self.app = app
        self.ask = app.ask
    }

    private let suggestions = ["Ai lo việc gì tuần này?", "Quyết định gần nhất về sản phẩm là gì?", "Có điều gì đổi so với trước?"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Hỏi")
                    .typeStyle(TypeStyle(family: .serif(italic: false), size: 28))
                    .foregroundStyle(.ink)
                Spacer()
                if !ask.turns.isEmpty {
                    Button("Cuộc trò chuyện mới") { ask.newChat() }
                        .buttonStyle(.lang(.pill, radius: Theme.Radius.pill))
                }
            }
            ScopeChips(options: AskViewModel.Scope.allCases.map { ($0, $0.title) }, selection: $ask.scope)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if ask.turns.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(suggestions, id: \.self) { text in
                                SuggestionChip(text: text) {
                                    ask.input = text
                                    ask.send()
                                }
                            }
                        }
                        .padding(.top, 20)
                    }
                    ForEach(ask.turns) { turn in
                        AskTurn(turn: turn, projectFolder: app.projectStore.folderURL, router: app.router)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            HStack(spacing: 8) {
                TextField("Hỏi về dự án…", text: $ask.input)
                    .textFieldStyle(.plain)
                    .typeStyle(.body)
                    .foregroundStyle(.ink)
                    .onSubmit(send)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.input, style: .continuous).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.input, style: .continuous)
                        .strokeBorder(.line, lineWidth: Theme.hairline))
                Button(action: send) {
                    Circle()
                        .fill(.deep)
                        .frame(width: 30, height: 30)
                        .overlay {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        }
                }
                .buttonStyle(.plain)
                .disabled(because: ask.input.trimmingCharacters(in: .whitespaces).isEmpty
                          ? String(localized: "Gõ câu hỏi trước.") : nil)
            }
            .frame(maxWidth: 680)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func send() {
        guard !ask.input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        ask.send()
    }
}

/// One question (water bubble, right) and its answer (serif, with sources).
private struct AskTurn: View {
    let turn: ChatTurn
    let projectFolder: URL?
    let router: Router

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 80)
                Text(verbatim: turn.question)
                    .typeStyle(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14,
                                                       bottomTrailingRadius: 4, topTrailingRadius: 14)
                        .fill(Color.water))
            }
            if turn.status == .searching && turn.answer.isEmpty {
                Text("Đang tìm trong dự án…")
                    .typeStyle(.caption)
                    .foregroundStyle(.ink3)
            } else if turn.status == .notFound {
                Text("Không tìm thấy trong dự án.")
                    .typeStyle(.body)
                    .foregroundStyle(.ink2)
            } else if !turn.answer.isEmpty {
                Text(verbatim: turn.answer)
                    .typeStyle(.summary)
                    .foregroundStyle(.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: 630, alignment: .leading)
                if !turn.sources.isEmpty {
                    LegacySourceChips(answer: turn.answer, sources: turn.sources) { source in
                        SourceOpener.open(source, projectFolder: projectFolder, router: router)
                    }
                    SourceQuotes(sources: turn.sources, projectFolder: projectFolder, router: router)
                }
            }
        }
    }
}
