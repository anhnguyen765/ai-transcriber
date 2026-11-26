import Foundation
import Observation

/// "Tổng quan" at the top of the Dự án section:
/// - what the project is about (LLM, from the project's documents and recent meetings),
/// - the top 3 priorities right now (LLM, from the recent meetings' to-dos, decisions and questions),
/// - the latest meetings and their open to-dos (read straight from summary.json, no LLM).
/// The LLM part is saved to .meetings/overview.json so it isn't rebuilt every time.
struct ProjectOverview: Codable, Equatable {
    struct Priority: Codable, Equatable {
        var title: String
        var reason: String
        /// Folder name of the meeting it comes from (e.g. "2026-11-26_19-31-00"), if any.
        var meetingFolder: String?
    }

    var about: String
    var priorities: [Priority]
    var generatedAt: Date
    /// Folder names of the meetings the LLM saw; a newer meeting means the overview is out of date.
    var basedOnMeetings: [String]
}

/// Pure logic (no UI, no network), so it is unit tested.
enum ProjectOverviewBuilder {
    static let recentMeetingCount = 3
    static let maxPriorities = 3
    static let documentBudget = 4_000

    /// A recent meeting with its summary.
    struct RecentMeeting: Equatable {
        let folder: URL
        let date: Date
        let summary: MeetingSummary

        var folderName: String { folder.lastPathComponent }
    }

    /// An action item that isn't ticked yet, with where it lives (so it can be ticked from the overview).
    struct OpenTask: Identifiable, Equatable {
        let folder: URL
        let meetingTitle: String
        let index: Int
        let item: ActionItem
        var id: String { "\(folder.path)#\(index)" }
    }

    // MARK: - Recent meetings and to-dos (no LLM)

    /// The newest meetings that have a summary, newest first.
    static func recentMeetings(_ meetings: [MeetingInfo], limit: Int = recentMeetingCount) -> [RecentMeeting] {
        var result: [RecentMeeting] = []
        for meeting in meetings.sorted(by: { $0.date > $1.date }) where result.count < limit {
            guard let summary = loadSummary(in: meeting.folder) else { continue }
            result.append(RecentMeeting(folder: meeting.folder, date: meeting.date, summary: summary))
        }
        return result
    }

    static func loadSummary(in folder: URL) -> MeetingSummary? {
        guard let data = try? Data(contentsOf: folder.appending(path: SummaryWriter.jsonFileName)) else { return nil }
        return try? JSONDecoder().decode(MeetingSummary.self, from: data)
    }

    /// Unticked action items of these meetings, for anyone (meeting order kept).
    static func openTasks(in recent: [RecentMeeting]) -> [OpenTask] {
        recent.flatMap { meeting in
            meeting.summary.actionItems.enumerated().compactMap { index, item in
                item.done == true ? nil
                    : OpenTask(folder: meeting.folder, meetingTitle: meeting.summary.title, index: index, item: item)
            }
        }
    }

    /// Without the LLM: the first open to-dos (those with a deadline first) stand in for priorities.
    static func fallbackPriorities(from tasks: [OpenTask]) -> [ProjectOverview.Priority] {
        let withDeadline = tasks.filter { $0.item.deadline != ActionItem.unknown }
        let rest = tasks.filter { $0.item.deadline == ActionItem.unknown }
        return (withDeadline + rest).prefix(maxPriorities).map { task in
            var reason = task.meetingTitle
            if task.item.deadline != ActionItem.unknown { reason += " · hạn \(task.item.deadline)" }
            return ProjectOverview.Priority(title: task.item.task, reason: reason,
                                            meetingFolder: task.folder.lastPathComponent)
        }
    }

    /// True when a meeting newer than those the overview was built from now has a summary.
    static func isStale(_ overview: ProjectOverview, recent: [RecentMeeting]) -> Bool {
        guard let newest = recent.first else { return false }
        return !overview.basedOnMeetings.contains(newest.folderName)
    }

    // MARK: - Project documents

    /// File names that usually describe the whole project; they go first.
    static let introNames = ["readme", "index", "overview", "tong quan", "tổng quan", "charter", "gioi thieu", "giới thiệu"]

    /// The start of each project document (not code, not meetings), intro files first, within `budget` characters.
    static func documentExcerpt(from chunks: [(path: String, type: SourceType, text: String)],
                                budget: Int = documentBudget) -> String {
        var firstChunk: [String: String] = [:]
        var order: [String] = []
        for chunk in chunks where chunk.type == .doc && !chunk.path.hasPrefix(".meetings/") {
            if firstChunk[chunk.path] == nil {
                firstChunk[chunk.path] = chunk.text
                order.append(chunk.path)
            }
        }
        func isIntro(_ path: String) -> Bool {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
            return introNames.contains { name.contains($0) }
        }
        let sorted = order.filter(isIntro).sorted() + order.filter { !isIntro($0) }.sorted()

        var result = ""
        for path in sorted {
            let room = budget - result.count
            guard room > 200 else { break }
            let text = firstChunk[path, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            let length = min(1_200, room - path.count - 10)
            guard length > 0 else { break }
            result += "### \(path)\n\(text.prefix(length))\n\n"
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - LLM

    struct Reply: Codable {
        struct Item: Codable { var title: String; var reason: String; var meeting: String? }
        var about: String
        var priorities: [Item]
    }

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "about": ["type": "string"],
            "priorities": ["type": "array", "maxItems": maxPriorities, "items": [
                "type": "object",
                "properties": ["title": ["type": "string"], "reason": ["type": "string"], "meeting": ["type": "string"]],
                "required": ["title", "reason", "meeting"],
            ] as [String: Any]],
        ] as [String: Any],
        "required": ["about", "priorities"],
    ]

    static func prompt(projectName: String, documents: String, recent: [RecentMeeting],
                       language: SummaryWriter.Language) -> String {
        let meetingsText = recent.enumerated().map { index, meeting in
            let s = meeting.summary
            var lines = ["## M\(index + 1) · \(meeting.date.formatted(.iso8601.year().month().day())) · \(s.title)",
                         String(s.overview.prefix(600))]
            let open = s.actionItems.filter { $0.done != true }.prefix(10)
            if !open.isEmpty {
                lines.append("Việc cần làm:")
                lines += open.map { "- \($0.task) (người làm: \($0.owner), hạn: \($0.deadline))" }
            }
            if !s.decisions.isEmpty {
                lines.append("Quyết định:")
                lines += s.decisions.prefix(6).map { "- \($0.text)" }
            }
            if !s.openQuestions.isEmpty {
                lines.append("Câu hỏi mở:")
                lines += s.openQuestions.prefix(5).map { "- \($0.text)" }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")

        let outputLanguage = language == .english ? "English" : "tiếng Việt"
        return """
        Dự án: \(projectName)

        Hãy viết:
        1. about: 2–3 câu giải thích dự án này là gì, làm cho ai, đang ở giai đoạn nào. Dựa vào tài liệu và các cuộc họp bên dưới.
        2. priorities: tối đa 3 việc ưu tiên nhất lúc này, quan trọng nhất trước. Chọn từ việc cần làm, quyết định và câu hỏi mở của các cuộc họp gần đây. title ngắn (dưới 12 từ), reason là một câu nói vì sao nó quan trọng. meeting là nhãn cuộc họp (M1, M2…) mà việc đó đến từ.
        Chỉ dùng thông tin có bên dưới, không bịa. Nếu không có cuộc họp nào, priorities để trống.
        Viết bằng \(outputLanguage).

        JSON schema:
        \(SummarySchema.text(schema))

        # Tài liệu dự án
        \(documents.isEmpty ? "(chưa có)" : documents)

        # Cuộc họp gần đây (M1 là mới nhất)
        \(meetingsText.isEmpty ? "(chưa có)" : meetingsText)
        """
    }

    /// Turns the model's reply into an overview: at most 3 priorities, "M2" mapped to that meeting's folder.
    static func overview(from reply: Reply, recent: [RecentMeeting], now: Date = Date()) -> ProjectOverview {
        let priorities = reply.priorities
            .filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(maxPriorities)
            .map { item -> ProjectOverview.Priority in
                var folder: String?
                if let label = item.meeting?.trimmingCharacters(in: .whitespaces).uppercased(), label.hasPrefix("M"),
                   let number = Int(label.dropFirst()), recent.indices.contains(number - 1) {
                    folder = recent[number - 1].folderName
                }
                return ProjectOverview.Priority(title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                reason: item.reason.trimmingCharacters(in: .whitespacesAndNewlines),
                                                meetingFolder: folder)
            }
        return ProjectOverview(about: reply.about.trimmingCharacters(in: .whitespacesAndNewlines),
                               priorities: Array(priorities), generatedAt: now,
                               basedOnMeetings: recent.map(\.folderName))
    }

    // MARK: - overview.json

    static func fileURL(projectFolder: URL) -> URL {
        projectFolder.appending(path: ".meetings", directoryHint: .isDirectory).appending(path: "overview.json")
    }

    static func load(projectFolder: URL) -> ProjectOverview? {
        guard let data = try? Data(contentsOf: fileURL(projectFolder: projectFolder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProjectOverview.self, from: data)
    }

    static func save(_ overview: ProjectOverview, projectFolder: URL) throws {
        let url = fileURL(projectFolder: projectFolder)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(overview).write(to: url, options: .atomic)
    }
}

// MARK: - State for the Dự án section

@MainActor
@Observable
final class ProjectOverviewModel {
    enum Phase: Equatable {
        case idle
        case waitingForModel
        case writing
    }

    private(set) var phase: Phase = .idle
    /// From overview.json (or nil if never built).
    private(set) var overview: ProjectOverview?
    private(set) var recent: [ProjectOverviewBuilder.RecentMeeting] = []
    private(set) var openTasks: [ProjectOverviewBuilder.OpenTask] = []
    /// A short message under the overview (LLM not available, saved, …).
    private(set) var note: String?

    @ObservationIgnored private let client: LLMClient
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var projectFolder: URL?
    /// Projects we already tried to build automatically (so a missing Ollama doesn't retry on every visit).
    @ObservationIgnored private var autoTried = Set<URL>()

    init(client: LLMClient = OllamaClient()) {
        self.client = client
    }

    var isWorking: Bool { phase != .idle }

    var isStale: Bool {
        guard let overview else { return false }
        return ProjectOverviewBuilder.isStale(overview, recent: recent)
    }

    /// What to show as the 3 priorities: the LLM's, or the first open to-dos without it.
    var priorities: [ProjectOverview.Priority] {
        if let overview, !overview.priorities.isEmpty { return overview.priorities }
        return ProjectOverviewBuilder.fallbackPriorities(from: openTasks)
    }

    /// Reads overview.json and the latest meetings. Cheap: call whenever the meetings change.
    func reload(projectFolder: URL?, meetings: [MeetingInfo]) {
        if projectFolder != self.projectFolder {
            stop(silently: true)
            note = nil
        }
        self.projectFolder = projectFolder
        guard let projectFolder else {
            overview = nil
            recent = []
            openTasks = []
            return
        }
        overview = ProjectOverviewBuilder.load(projectFolder: projectFolder)
        recent = ProjectOverviewBuilder.recentMeetings(meetings)
        openTasks = ProjectOverviewBuilder.openTasks(in: recent)
    }

    /// Builds the overview once per project when there is none yet and there is something to read.
    func buildIfMissing(store: IndexStore?, projectName: String) {
        guard overview == nil, !isWorking, let projectFolder, !autoTried.contains(projectFolder),
              store != nil || !recent.isEmpty else { return }
        autoTried.insert(projectFolder)
        refresh(store: store, projectName: projectName)
    }

    /// Asks the LLM for "about" and the top 3 priorities, and saves them to .meetings/overview.json.
    func refresh(store: IndexStore?, projectName: String) {
        guard !isWorking, let projectFolder else { return }
        let recent = recent
        note = nil
        phase = .waitingForModel

        work = Task {
            let documents = await Task.detached(priority: .utility) { () -> String in
                var chunks: [(path: String, type: SourceType, text: String)] = []
                try? store?.forEachChunk { path, type, text in
                    if type == .doc { chunks.append((path, type, text)) }
                }
                return ProjectOverviewBuilder.documentExcerpt(from: chunks)
            }.value
            guard !Task.isCancelled else { return }

            let result = await askLLM(projectName: projectName, documents: documents, recent: recent)
            guard !Task.isCancelled else { return }

            switch result {
            case .success(let overview):
                self.overview = overview
                do {
                    try ProjectOverviewBuilder.save(overview, projectFolder: projectFolder)
                } catch {
                    note = String(localized: "Không lưu được overview.json: \(error.localizedDescription)")
                }
            case .failure(let message):
                note = message
            }
            phase = .idle
            work = nil
        }
    }

    /// Stops a running build; what was shown before stays.
    func stop(silently: Bool = false) {
        guard isWorking else { return }
        work?.cancel()
        work = nil
        phase = .idle
        if !silently { note = String(localized: "Đã dừng. Bấm Cập nhật để thử lại.") }
    }

    /// Ticks an open to-do (saved to that meeting's summary.json) and drops it from the list.
    func tick(_ task: ProjectOverviewBuilder.OpenTask) {
        MeetingList.setActionItemDone(folder: task.folder, index: task.index, done: true)
        openTasks.removeAll { $0.id == task.id }
    }

    private enum Outcome {
        case success(ProjectOverview)
        case failure(String)
    }

    private func askLLM(projectName: String, documents: String,
                        recent: [ProjectOverviewBuilder.RecentMeeting]) async -> Outcome {
        let model = AppSettings.llmModel
        let unavailable = String(localized: "Chưa dùng được Ollama hoặc model \(model), nên chưa viết được tổng quan. Ưu tiên bên dưới lấy tạm từ việc cần làm.")
        guard await client.isRunning(),
              let installed = try? await client.installedModels(),
              installed.contains(model) || installed.contains("\(model):latest") else { return .failure(unavailable) }

        await HeavyWorkLock.shared.acquire() // never next to WhisperKit or another LLM job
        guard !Task.isCancelled else {
            await HeavyWorkLock.shared.release()
            return .failure("")
        }
        phase = .writing
        let llm = client
        defer {
            Task {
                await llm.unload(model: model)
                await HeavyWorkLock.shared.release()
            }
        }

        let prompt = ProjectOverviewBuilder.prompt(projectName: projectName, documents: documents, recent: recent,
                                                   language: AppSettings.summaryLanguage)
        let options = LLMChatOptions(model: model, jsonSchema: ProjectOverviewBuilder.schema, temperature: 0.2)
        let messages: [LLMMessage] = [.system("Bạn tóm tắt tình hình một dự án cho người mới. Chỉ trả lời bằng JSON."),
                                      .user(prompt)]
        do {
            let reply = try await Self.withTimeout(seconds: 240) {
                try await llm.chat(messages: messages, options: options, onProgress: { _ in })
            }
            let parsed = try SummarySchema.parse(ProjectOverviewBuilder.Reply.self, from: reply)
            return .success(ProjectOverviewBuilder.overview(from: parsed, recent: recent))
        } catch {
            return .failure(String(localized: "Chưa viết được tổng quan: \(error.localizedDescription)"))
        }
    }

    /// Runs `work`, but throws if it hasn't finished after `seconds`. Cancels `work` on timeout.
    private static func withTimeout<T>(seconds: Double, _ work: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LLMError.server(String(localized: "Model mất hơn \(Int(seconds)) giây."))
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}
