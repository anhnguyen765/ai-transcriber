import SwiftUI

/// "Hỏi lắng": chat over the project's documents and past meetings.
struct AskWindow: View {
    @ObservedObject var model: AskViewModel
    @ObservedObject var projectStore: ProjectStore
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                messages
                Divider()
                inputArea
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            model.reloadPastChats()
            inputFocused = true
        }
        .onExitCommand { dismissWindow(id: "ask") } // Esc closes the window
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List {
            Button {
                model.newChat()
                inputFocused = true
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(.plain)
            Section("Chats") {
                ForEach(model.pastChats) { chat in
                    Button { model.open(chat) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chat.title).lineLimit(2)
                            Text(chat.date, format: .dateTime.day().month().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                    .listRowBackground(chat.url == model.currentChatURL ? Color.accentColor.opacity(0.15) : nil)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Image(systemName: "folder")
            Text(model.projectName).font(.headline)
            Button("Đổi…") { projectStore.chooseFolder() }
                .controlSize(.small)
                .disabled(model.isAnswering)
            Spacer()
            if let status = model.status {
                ProgressView().controlSize(.small)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    // MARK: Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.turns.isEmpty {
                        Text("Hỏi bất cứ điều gì về tài liệu và các cuộc họp của dự án.\nVí dụ: “Tuần trước team đã chốt gì về deadline?”")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                    ForEach(model.turns) { turn in
                        TurnView(turn: turn, open: open).id(turn.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: model.turns.last?.answer) {
                if let last = model.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: model.turns.count) {
                if let last = model.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    // MARK: Opening sources

    /// Document → its default app; meeting → the meeting viewer at the cited time; ⌥-click → Finder.
    private func open(_ source: AnswerSource) {
        guard let project = model.projectFolder else { return }
        let url = SourceLink.fileURL(source, projectFolder: project)
        if NSEvent.modifierFlags.contains(.option) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let folder = SourceLink.meetingFolder(source) {
            openWindow(id: "meeting", value: MeetingRef(folderPath: project.appending(path: folder).path,
                                                        time: SourceLink.startTime(source)))
        } else if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSSound.beep() // the file was moved or deleted since it was indexed
        }
    }

    // MARK: Input

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Phạm vi", selection: $model.scope) {
                    ForEach(AskViewModel.Scope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                Toggle("Khoảng ngày họp", isOn: $model.useDateRange)
                    .toggleStyle(.checkbox)
                if model.useDateRange {
                    DatePicker("", selection: $model.dateFrom, displayedComponents: .date).labelsHidden()
                    Text("→")
                    DatePicker("", selection: $model.dateTo, displayedComponents: .date).labelsHidden()
                }
                Spacer()
            }
            .controlSize(.small)

            HStack(alignment: .bottom) {
                TextEditor(text: $model.input)
                    .font(.body)
                    .frame(minHeight: 38, maxHeight: 110)
                    .fixedSize(horizontal: false, vertical: true)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                    .focused($inputFocused)
                    // Enter sends; Shift+Enter makes a new line.
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        model.send()
                        return .handled
                    }
                if model.isAnswering {
                    Button { model.stop() } label: { Image(systemName: "stop.fill") }
                        .help("Stop")
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { model.send() } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Send (Enter)")
                }
            }
        }
        .padding(10)
    }
}

/// One question and its answer.
private struct TurnView: View {
    let turn: ChatTurn
    let open: (AnswerSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 80)
                Text(turn.question)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.15)))
                    .textSelection(.enabled)
            }
            if let note = turn.scopeNote {
                Label(note, systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
            }
            switch turn.status {
            case .searching where turn.answer.isEmpty:
                ProgressView().controlSize(.small)
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            default:
                EmptyView()
            }
            if !turn.answer.isEmpty {
                CitationText(text: turn.answer, sources: turn.sources, open: open)
                    .foregroundStyle(turn.status == .notFound ? .secondary : .primary)
            }
            if turn.status == .stopped {
                Text("Đã dừng.").font(.caption).foregroundStyle(.secondary)
            }
            if !turn.sources.isEmpty, turn.status != .searching, turn.status != .answering {
                SourceChips(answer: turn.answer, sources: turn.sources, open: open)
            }
        }
    }
}
