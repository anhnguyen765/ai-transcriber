import Foundation

/// State of the "Hỏi lắng" window: the current chat, past chats, scope and the answering pipeline.
@MainActor
final class AskViewModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case all, meetings, documents
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "Tất cả"
            case .meetings: "Chỉ cuộc họp"
            case .documents: "Chỉ tài liệu"
            }
        }
    }

    struct PastChat: Identifiable, Equatable {
        var id: URL { url }
        let url: URL
        let title: String   // first question
        let date: Date
    }

    @Published private(set) var turns: [ChatTurn] = []
    @Published var input = ""
    @Published var scope: Scope = .all
    @Published var useDateRange = false
    @Published var dateFrom = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @Published var dateTo = Date()
    @Published private(set) var status: String?
    @Published private(set) var pastChats: [PastChat] = []
    @Published private(set) var currentChatURL: URL?

    var isAnswering: Bool { task != nil }

    private let indexer: ProjectIndexer
    private let client: LLMClient
    private var task: Task<Void, Never>?
    private var chatStarted = Date()

    init(indexer: ProjectIndexer, client: LLMClient = OllamaClient()) {
        self.indexer = indexer
        self.client = client
    }

    var projectName: String { indexer.projectFolder?.lastPathComponent ?? "Chưa chọn dự án" }
    var projectFolder: URL? { indexer.projectFolder }

    // MARK: - Chats

    func newChat() {
        stop()
        turns = []
        currentChatURL = nil
        chatStarted = Date()
        status = nil
    }

    func reloadPastChats() {
        guard let projectFolder = indexer.projectFolder else { pastChats = []; return }
        let folder = ChatExport.folder(projectFolder: projectFolder)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        pastChats = files.filter { $0.pathExtension == "md" }.compactMap { url in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let first = ChatExport.parse(text).first?.question ?? url.deletingPathExtension().lastPathComponent
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return PastChat(url: url, title: String(first.prefix(60)), date: date)
        }.sorted { $0.date > $1.date }
    }

    func open(_ chat: PastChat) {
        stop()
        let text = (try? String(contentsOf: chat.url, encoding: .utf8)) ?? ""
        turns = ChatExport.parse(text)
        currentChatURL = chat.url
        chatStarted = chat.date
        status = nil
    }

    // MARK: - Asking

    func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, task == nil else { return }
        guard let retriever = indexer.retriever else {
            status = "Chọn và đọc một thư mục dự án trước."
            return
        }
        input = ""
        turns.append(ChatTurn(question: question))
        let index = turns.count - 1
        let history: [(question: String, answer: String)] = turns.dropLast()
            .filter { $0.status == .done }
            .map { (question: $0.question, answer: $0.answer) }
        let filter = baseFilter()
        let model = AppSettings.llmModel

        task = Task {
            var holdsLock = false
            defer {
                if holdsLock { Task { await HeavyWorkLock.shared.release() } }
            }
            do {
                // Never next to WhisperKit (or a summary): wait for the shared lock.
                status = "Đang chờ chép lời/tóm tắt xong…"
                await HeavyWorkLock.shared.acquire()
                holdsLock = true
                try Task.checkCancellation()

                guard await client.isRunning() else { throw LLMError.notRunning }

                // 1. Standalone search query (+ dates like "tuần trước").
                status = "Đang hiểu câu hỏi…"
                let rewritten = await QueryRewriter(client: client, model: model)
                    .rewrite(question: question, history: Array(history))
                var searchFilter = filter
                let implied = rewritten.dateRange()
                if !useDateRange, implied.from != nil || implied.to != nil {
                    searchFilter.meetingsFrom = implied.from
                    searchFilter.meetingsTo = implied.to
                    turns[index].scopeNote = "Cuộc họp \(rewritten.meetingsFrom ?? "…") → \(rewritten.meetingsTo ?? "…")"
                }
                try Task.checkCancellation()

                // 2. Hybrid search in the chosen scope.
                status = "Đang tìm trong dự án…"
                let outcome = try await retriever.searchDetailed(queries: [rewritten.query],
                                                                 limit: AnswerService.sourceCount,
                                                                 filter: searchFilter)
                let sources = AnswerService.sources(from: outcome.chunks)
                turns[index].sources = sources

                // 3. Nothing relevant: say so, without asking the LLM (it would only guess).
                if AnswerService.isNotFound(outcome) {
                    turns[index].answer = AnswerService.notFoundReply(closest: sources, query: rewritten.query)
                    turns[index].sources = Array(sources.prefix(3))
                    turns[index].status = .notFound
                } else {
                    // 4. Answer from the sources, streamed.
                    status = "Đang trả lời…"
                    turns[index].status = .answering
                    let options = LLMChatOptions(model: model, jsonSchema: nil, contextLength: 8_192,
                                                 temperature: 0.2, keepAlive: "5m")
                    let answer = try await client.chat(
                        messages: AnswerService.messages(question: question, sources: sources, history: Array(history)),
                        options: options) { partial in
                            Task { @MainActor in
                                if self.turns.indices.contains(index), self.turns[index].status == .answering {
                                    self.turns[index].answer = partial
                                }
                            }
                        }
                    turns[index].answer = answer
                    turns[index].status = .done
                }
            } catch is CancellationError {
                turns[index].status = .stopped
            } catch let error as URLError where error.code == .cancelled {
                turns[index].status = .stopped
            } catch {
                turns[index].status = .failed(error.localizedDescription)
            }
            status = nil
            task = nil
            saveChat()
        }
    }

    func stop() {
        task?.cancel()
    }

    /// Set while a meeting's inspector asks "cuộc họp này": only that meeting's folder is searched.
    var meetingPathPrefix: String?

    private func baseFilter() -> SearchFilter {
        var filter = SearchFilter()
        filter.pathPrefix = meetingPathPrefix
        switch scope {
        case .all: break
        case .meetings: filter.sourceTypes = [.meeting]
        case .documents: filter.sourceTypes = [.doc, .code]
        }
        if useDateRange {
            let calendar = Calendar.current
            filter.meetingsFrom = calendar.startOfDay(for: dateFrom)
            filter.meetingsTo = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dateTo))
        }
        return filter
    }

    /// Writes the chat to <project>/.meetings/chats/<yyyy-MM-dd_HH-mm>.md (never indexed).
    private func saveChat() {
        guard let projectFolder = indexer.projectFolder,
              turns.contains(where: { $0.status != .searching && $0.status != .answering }) else { return }
        let url = currentChatURL ?? ChatExport.newFileURL(projectFolder: projectFolder, date: chatStarted)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ChatExport.markdown(turns, projectName: projectFolder.lastPathComponent, started: chatStarted)
                .write(to: url, atomically: true, encoding: .utf8)
            currentChatURL = url
            reloadPastChats()
        } catch {
            status = "Không lưu được chat: \(error.localizedDescription)"
        }
    }
}
