import AppKit
import Foundation

// MARK: - Pipeline (pure logic, tested with a mock LLMClient)

/// Turns transcript lines into a MeetingSummary: one pass for short meetings,
/// two passes (notes per ~10-minute part, then merge) for long ones.
struct SummaryPipeline {
    /// Up to this many (estimated) tokens of transcript → one pass.
    static let singlePassTokenLimit = 5_000
    /// Max transcript tokens per part in pass 1 (fits num_ctx 8192 with prompt + reply).
    static let chunkTokenLimit = 4_500
    /// Max tokens of collected notes for pass 2; above this, notes are condensed first.
    static let notesTokenLimit = 5_000

    let client: LLMClient
    let model: String
    let prompts: Prompts
    let myName: String
    let language: SummaryWriter.Language
    /// Finds project documents/meetings for search queries. nil = summarize without project context.
    var retrieveContext: (([String]) async -> [RetrievedChunk])? = nil
    /// Which meeting is being summarized. Every prompt names it, so the model never mixes it up
    /// with earlier meetings or the project overview. nil = unnamed ("cuộc họp này").
    var meeting: MeetingIdentity? = nil

    /// Project context gets at most this many (estimated) tokens in the final prompt.
    static let contextTokenBudget = 2_500
    static let maxTokensPerSource = 800
    /// With project context the final prompt is bigger, so the context window grows too.
    var contextLength: Int { retrieveContext == nil ? 8_192 : 12_288 }

    /// `progress(part, total)` is called before each request.
    func summarize(_ lines: [TranscriptLine], duration: Double,
                   progress: @escaping @Sendable (Int, Int) -> Void) async throws -> MeetingSummary {
        guard !lines.isEmpty else { throw RecorderError("The transcript is empty, so there is nothing to summarize.") }

        let full = TranscriptChunker.fullText(lines, myName: myName)
        if TranscriptChunker.estimateTokens(full) <= Self.singlePassTokenLimit {
            var sources: [Source] = []
            if retrieveContext != nil {
                // Short meeting with project context: quick notes first, to know what to search for.
                progress(1, 2)
                let notes = try await requestJSON(ChunkNotes.self, prompt: chunkPrompt(
                    part: "1", total: "1", from: TranscriptWriter.timestamp(lines.first?.start ?? 0),
                    to: TranscriptWriter.timestamp(lines.last?.end ?? 0), transcript: full), schema: SummarySchema.notes)
                sources = await findContext(for: [notes])
                progress(2, 2)
            } else {
                progress(1, 1)
            }
            return try await finalSummary(input: fenced("Bản chép lời", full), inputKind: "bản chép lời",
                                          duration: duration, sources: sources)
        }

        // Pass 1: notes for each part.
        let chunks = TranscriptChunker.chunks(lines, myName: myName, maxTokens: Self.chunkTokenLimit)
        let total = chunks.count + 1
        var notes: [(label: String, notes: ChunkNotes)] = []
        for (index, chunk) in chunks.enumerated() {
            progress(index + 1, total)
            let from = TranscriptWriter.timestamp(chunk.start), to = TranscriptWriter.timestamp(chunk.end)
            let prompt = chunkPrompt(part: "\(index + 1)", total: "\(chunks.count)", from: from, to: to,
                                     transcript: chunk.text)
            let partNotes = try await requestJSON(ChunkNotes.self, prompt: prompt, schema: SummarySchema.notes)
            notes.append(("Phần \(index + 1) (\(from)–\(to))", partNotes))
        }

        // Project context, searched with what pass 1 found.
        let sources = await findContext(for: notes.map(\.notes))

        // Very long meetings: if all notes don't fit one request, merge them in pairs until they do.
        while TranscriptChunker.estimateTokens(Self.render(notes)) > Self.notesTokenLimit, notes.count > 1 {
            notes = try await condense(notes)
        }

        // Pass 2: merge the notes into the final summary.
        progress(total, total)
        return try await finalSummary(input: fenced("Ghi chú từng phần", Self.render(notes)),
                                      inputKind: "ghi chú từng phần", duration: duration, sources: sources)
    }

    // MARK: Steps

    private var systemPrompt: String {
        let name = myName.trimmingCharacters(in: .whitespaces)
        return prompts.fill(prompts.system, [
            "my_name": name.isEmpty ? TranscriptTrack.mic.speaker : name,
            "language": language == .english ? "English (tiếng Anh)" : "tiếng Việt",
        ])
    }

    private func chunkPrompt(part: String, total: String, from: String, to: String, transcript: String) -> String {
        prompts.fill(prompts.chunk, [
            "part": part, "total": total, "from": from, "to": to,
            "schema": SummarySchema.text(SummarySchema.notes), "transcript": transcript,
        ])
    }

    private func finalSummary(input: String, inputKind: String, duration: Double,
                              sources: [Source]) async throws -> MeetingSummary {
        let minutes = max(1, Int((duration / 60).rounded()))
        let schema = sources.isEmpty ? SummarySchema.summary : SummarySchema.summaryWithContext
        let template = Self.upgradedTemplate(prompts.final)
        let prompt = prompts.fill(template, [
            "input_kind": inputKind, "duration": "\(minutes) phút",
            "schema": SummarySchema.text(schema), "input": input,
            "meeting_header": Self.meetingHeader(meeting, minutes: minutes),
            "project_context": Self.contextBlock(sources, meeting: meeting),
        ])
        var summary = Self.validate(try await requestJSON(MeetingSummary.self, prompt: prompt, schema: schema),
                                    sources: sources)
        summary.meetingID = meeting?.id
        summary.projectName = meeting?.projectName
        return summary
    }

    /// Prompt files written before these placeholders existed (the user's own copies in
    /// Application Support) still get them — and in the right order: who this meeting is first,
    /// project reference next, and this meeting's own transcript LAST, closest to the answer.
    static func upgradedTemplate(_ template: String) -> String {
        var t = template
        if !t.contains("{{meeting_header}}") { t = "{{meeting_header}}\n\n" + t }
        if !t.contains("{{project_context}}") {
            t = t.contains("{{input}}")
                ? t.replacingOccurrences(of: "{{input}}", with: "{{project_context}}\n\n{{input}}")
                : t + "\n\n{{project_context}}"
        }
        return t
    }

    /// The meeting's own text between markers that carry its ID.
    private func fenced(_ kind: String, _ text: String) -> String {
        let id = meeting?.id ?? "này"
        return "<<< BẮT ĐẦU CUỘC HỌP \(id) — \(kind) >>>\n\(text)\n<<< KẾT THÚC CUỘC HỌP \(id) >>>"
    }

    // MARK: Meeting identity

    /// "Who" the summary is about: one meeting, with an ID, a time and a project.
    struct MeetingIdentity: Equatable {
        /// The meeting's folder name, e.g. "2026-11-28_10-05-00".
        var id: String
        var start: Date
        /// The project folder's name ("" = no project).
        var projectName: String
        /// "about" from the project's overview.json, if it was built. Shown only next to project context.
        var projectAbout: String?
    }

    static func meetingHeader(_ meeting: MeetingIdentity?, minutes: Int) -> String {
        guard let meeting else {
            return """
            CUỘC HỌP CẦN TÓM TẮT: chỉ một cuộc họp, nằm giữa hai dòng "BẮT ĐẦU CUỘC HỌP" và "KẾT THÚC CUỘC HỌP". \
            Mọi mục trong biên bản phải đến từ phần đó.
            """
        }
        var lines = [
            "CUỘC HỌP CẦN TÓM TẮT",
            "- Mã cuộc họp: \(meeting.id)",
            "- Thời gian: \(headerDateFormatter.string(from: meeting.start)), dài \(minutes) phút",
        ]
        if !meeting.projectName.isEmpty { lines.append("- Thuộc dự án: \(meeting.projectName)") }
        lines.append("""
        Biên bản chỉ nói về cuộc họp \(meeting.id). title, overview, keyPoints, decisions, actionItems và \
        openQuestions đều phải đến từ phần giữa "BẮT ĐẦU CUỘC HỌP \(meeting.id)" và "KẾT THÚC CUỘC HỌP \(meeting.id)". \
        overview là tóm tắt cuộc họp này, KHÔNG phải tổng quan dự án.
        """)
        return lines.joined(separator: "\n")
    }

    // MARK: Project context

    /// One retrieved chunk with its [S#] label.
    struct Source: Equatable {
        let label: String
        let chunk: RetrievedChunk
    }

    /// Searches the project with the meeting's decisions and key points, then fits the
    /// best chunks into the context budget.
    func findContext(for notes: [ChunkNotes]) async -> [Source] {
        guard let retrieveContext else { return [] }
        var queries: [String] = []
        for text in notes.flatMap({ $0.decisions.map(\.text) }) + notes.flatMap({ $0.keyPoints.map(\.text) })
            where !queries.contains(text) {
            queries.append(String(text.prefix(300)))
        }
        let chunks = await retrieveContext(Array(queries.prefix(12)))

        var sources: [Source] = []
        var used = 0
        for chunk in chunks where Self.usableAsContext(chunk.path, meetingID: meeting?.id) {
            let text = String(chunk.text.prefix(Int(Double(Self.maxTokensPerSource) * 2.5)))
            let trimmed = RetrievedChunk(id: chunk.id, path: chunk.path, sourceType: chunk.sourceType,
                                         location: chunk.location, text: text, meetingDate: chunk.meetingDate,
                                         score: chunk.score)
            let source = Source(label: "S\(sources.count + 1)", chunk: trimmed)
            let tokens = TranscriptChunker.estimateTokens(Self.describe(source))
            if used + tokens > Self.contextTokenBudget { continue } // try smaller ones that may still fit
            used += tokens
            sources.append(source)
        }
        return sources
    }

    /// Earlier meetings are used only through their summary.md: a raw transcript of another meeting
    /// looks exactly like this one's, and small models then summarize the wrong meeting.
    /// The meeting being summarized is never its own context.
    static func usableAsContext(_ path: String, meetingID: String?) -> Bool {
        guard path.hasPrefix(".meetings/") else { return true }
        if let meetingID, path.hasPrefix(".meetings/\(meetingID)/") { return false }
        return !path.hasSuffix("/\(TranscriptWriter.markdownFileName)")
    }

    /// The other meeting's ID for a path like ".meetings/2026-11-01_09-00-00/summary.md".
    static func meetingID(inPath path: String) -> String? {
        let parts = path.split(separator: "/")
        return parts.count == 3 && parts[0] == ".meetings" ? String(parts[1]) : nil
    }

    /// "[S1] tài liệu dự án · docs/plan.md — Timeline" or
    /// "[S2] CUỘC HỌP KHÁC (mã 2026-11-01_09-00-00, ngày 2026-11-01) · .meetings/…/summary.md", then the text.
    static func describe(_ source: Source) -> String {
        let c = source.chunk
        var header = "[\(source.label)] "
        if let other = meetingID(inPath: c.path) {
            let day = c.meetingDate.map { ", ngày \(contextDateFormatter.string(from: $0))" } ?? ""
            header += "CUỘC HỌP KHÁC (mã \(other)\(day)) · \(c.path)"
        } else {
            header += "tài liệu dự án · \(c.path)"
        }
        if !c.location.isEmpty { header += " — \(c.location)" }
        return header + "\n" + c.text
    }

    static func contextBlock(_ sources: [Source], meeting: MeetingIdentity? = nil) -> String {
        guard !sources.isEmpty else { return "" }
        let id = meeting?.id ?? "này"
        var project = ""
        if let meeting, !meeting.projectName.isEmpty {
            project = "Dự án \"\(meeting.projectName)\""
            if let about = meeting.projectAbout?.trimmingCharacters(in: .whitespacesAndNewlines), !about.isEmpty {
                project += " — tổng quan: \(about)"
            }
            project += "\n\n"
        }
        return """
        <<< THAM KHẢO DỰ ÁN — KHÔNG phải nội dung cuộc họp \(id) >>>
        PROJECT CONTEXT — tài liệu và các cuộc họp KHÁC trong dự án. Đây CHỈ là thông tin nền.

        \(project)\(sources.map(describe).joined(separator: "\n\n"))
        <<< HẾT THAM KHẢO DỰ ÁN >>>

        Quy tắc khi dùng PROJECT CONTEXT:
        - Bản chép lời (hoặc ghi chú) của cuộc họp \(id) là nguồn DUY NHẤT cho những gì được nói trong cuộc họp này.
        - Việc cần làm, quyết định và câu hỏi của "CUỘC HỌP KHÁC" hay tổng quan dự án KHÔNG thuộc cuộc họp \(id); không chép sang.
        - Chỉ dùng context để: làm rõ tên người và thuật ngữ, liệt kê tài liệu liên quan (relatedDocs), và phát hiện quyết định khác với trước (changesFromBefore).
        - Không bao giờ viết một điều chỉ có trong context như thể nó đã được nói trong cuộc họp.
        - relatedDocs: chỉ những nguồn thật sự liên quan tới nội dung cuộc họp. source là nhãn như "S1", reason ngắn gọn.
        - changesFromBefore: chỉ khi cuộc họp này chốt điều KHÁC với một quyết định hoặc tài liệu trước. previousSource là nhãn của nguồn cũ, timestamp lấy từ bản chép lời.
        - sourceRefs (không bắt buộc): nhãn các nguồn liên quan tới một điểm chính hoặc quyết định.
        - Nếu không có gì phù hợp thì để mảng rỗng.
        """
    }

    /// Keeps only references to sources that really exist, and takes paths from our list (not from the model).
    static func validate(_ summary: MeetingSummary, sources: [Source]) -> MeetingSummary {
        var s = summary
        let byLabel = Dictionary(uniqueKeysWithValues: sources.map { ($0.label, $0) })
        func label(_ raw: String) -> String? {
            let cleaned = raw.uppercased().filter { $0.isLetter || $0.isNumber }
            return byLabel[cleaned] == nil ? nil : cleaned
        }
        var seenPaths = Set<String>()
        s.relatedDocs = s.relatedDocs.compactMap { doc in
            guard let l = label(doc.source), let source = byLabel[l], seenPaths.insert(source.chunk.path).inserted
            else { return nil }
            return RelatedDoc(source: l, path: source.chunk.path, reason: doc.reason)
        }
        s.changesFromBefore = s.changesFromBefore.compactMap { change in
            guard let l = label(change.previousSource) else { return nil }
            return ChangeFromBefore(text: change.text, previousSource: l, timestamp: change.timestamp)
        }
        func cleanRefs(_ items: [SummaryItem]) -> [SummaryItem] {
            items.map { item in
                var copy = item
                let refs = (item.sourceRefs ?? []).compactMap(label)
                copy.sourceRefs = refs.isEmpty ? nil : refs
                return copy
            }
        }
        s.keyPoints = cleanRefs(s.keyPoints)
        s.decisions = cleanRefs(s.decisions)
        s.sources = sources.map {
            ContextSource(label: $0.label, path: $0.chunk.path, location: $0.chunk.location,
                          meetingDate: $0.chunk.meetingDate)
        }
        return s
    }

    /// Project context is used only when the meeting really relates to the project: if even the
    /// closest match is weak (a meeting recorded into the wrong project, or about something new),
    /// the summary is written from the transcript alone. Same bar as the Ask window's "not found".
    static func relevantContext(_ outcome: SearchOutcome) -> [RetrievedChunk] {
        if let best = outcome.bestSimilarity, best < AnswerService.minSimilarity { return [] }
        return outcome.chunks
    }

    private static let headerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let contextDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func condense(_ notes: [(label: String, notes: ChunkNotes)]) async throws
        -> [(label: String, notes: ChunkNotes)] {
        var result: [(label: String, notes: ChunkNotes)] = []
        for start in stride(from: 0, to: notes.count, by: 2) {
            let group = Array(notes[start..<min(start + 2, notes.count)])
            guard group.count == 2 else { result += group; continue }
            let label = "\(group[0].label) + \(group[1].label)"
            let prompt = prompts.fill(prompts.chunk, [
                "part": label, "total": "\(notes.count)", "from": "", "to": "",
                "schema": SummarySchema.text(SummarySchema.notes), "transcript": Self.render(group),
            ])
            result.append((label, try await requestJSON(ChunkNotes.self, prompt: prompt, schema: SummarySchema.notes)))
        }
        return result
    }

    /// Asks for JSON; if the reply can't be parsed, asks once more to fix it.
    func requestJSON<T: Decodable>(_ type: T.Type, prompt: String, schema: [String: Any]) async throws -> T {
        let options = LLMChatOptions(model: model, jsonSchema: schema, contextLength: contextLength)
        let reply = try await client.chat(messages: [.system(systemPrompt), .user(prompt)], options: options) { _ in }
        do {
            return try SummarySchema.parse(T.self, from: reply)
        } catch {
            // Retry with just the broken reply (not the whole transcript again, so it fits the context).
            let fix = """
            Câu trả lời sau không phải JSON hợp lệ theo schema (\(error.localizedDescription)).
            Hãy sửa lại và trả lời CHỈ bằng JSON hợp lệ đúng schema, giữ nguyên nội dung.

            JSON schema:
            \(SummarySchema.text(schema))

            Câu trả lời cần sửa:
            \(reply)
            """
            let fixed = try await client.chat(messages: [.system(systemPrompt), .user(fix)], options: options) { _ in }
            return try SummarySchema.parse(T.self, from: fixed)
        }
    }

    /// Notes as compact text for the next pass.
    static func render(_ notes: [(label: String, notes: ChunkNotes)]) -> String {
        func items(_ title: String, _ list: [SummaryItem]) -> String {
            list.isEmpty ? "" : "\(title):\n" + list.map { "- [\($0.timestamp)] \($0.text)" }.joined(separator: "\n") + "\n"
        }
        return notes.map { label, n in
            "### \(label)\n"
                + items("Điểm chính", n.keyPoints)
                + items("Quyết định", n.decisions)
                + (n.actionItems.isEmpty ? "" : "Việc cần làm:\n" + n.actionItems
                    .map { "- [\($0.timestamp)] \($0.task) — \($0.owner) — \($0.deadline)" }
                    .joined(separator: "\n") + "\n")
                + items("Câu hỏi mở", n.openQuestions)
        }.joined(separator: "\n")
    }
}

// MARK: - Service (queue, Ollama checks, files, menu status)

@MainActor
final class SummaryService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case waitingForTranscription
        case checking
        case summarizing(part: Int, total: Int)
        case downloadingModel(Double)
    }

    /// Something the user has to fix before summaries can run.
    enum Problem: Equatable {
        case ollamaNotRunning
        case modelMissing(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var problem: Problem?
    @Published var errorMessage: String?
    @Published private(set) var lastSummaryURL: URL?

    var isBusy: Bool { phase != .idle }

    var statusText: String? {
        switch phase {
        case .idle: nil
        case .waitingForTranscription: "Đang chờ chép lời xong…"
        case .checking: "Đang kiểm tra Ollama…"
        case .summarizing(let part, let total): total > 1 ? "Đang tóm tắt… (phần \(part)/\(total))" : "Đang tóm tắt…"
        case .downloadingModel(let p): "Đang tải model… \(Int(p * 100))%"
        }
    }

    var progressValue: Double? {
        switch phase {
        case .summarizing(let part, let total) where total > 1: Double(part - 1) / Double(total)
        case .downloadingModel(let p): p
        default: nil
        }
    }

    private let client: LLMClient
    /// Gives the project index search for a project path (nil if that project isn't indexed).
    var retrieverProvider: (String) -> ProjectRetriever? = { _ in nil }
    private var queue: [URL] = []
    /// Meetings that couldn't be summarized because of a Problem; retried when it's fixed.
    private var pending: [URL] = []
    private var runner: Task<Void, Never>?
    /// The meeting being summarized right now (shown in the popover's pipeline card).
    @Published private(set) var currentFolder: URL?
    /// How many project documents the current summary is using (nil = not known yet / no context).
    @Published private(set) var contextDocumentCount: Int?

    init(client: LLMClient = OllamaClient()) {
        self.client = client
    }

    // MARK: Actions

    func summarizeMeeting(at folder: URL) {
        guard !queue.contains(folder), folder != currentFolder else { return }
        errorMessage = nil
        queue.append(folder)
        startRunnerIfNeeded()
    }

    func summarizeLastMeeting(projectFolder: URL?) {
        guard let folder = latestMeeting(in: projectFolder, containing: TranscriptWriter.jsonFileName) else {
            errorMessage = "No transcribed meeting found. Transcribe one first."
            return
        }
        summarizeMeeting(at: folder)
    }

    func openLastSummary(projectFolder: URL?) {
        if let url = lastSummaryURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else if let folder = latestMeeting(in: projectFolder, containing: SummaryWriter.markdownFileName) {
            NSWorkspace.shared.open(folder.appending(path: SummaryWriter.markdownFileName))
        } else {
            errorMessage = "No summary yet."
        }
    }

    /// Retry the meetings that were blocked by a problem (e.g. after starting Ollama).
    func retry() {
        problem = nil
        errorMessage = nil
        let folders = pending
        pending = []
        folders.forEach(summarizeMeeting(at:))
    }

    /// Opens the Ollama app (or its download page), then retries once it is running.
    func openOllama() {
        let app = URL(fileURLWithPath: "/Applications/Ollama.app")
        if FileManager.default.fileExists(atPath: app.path) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            Task {
                for _ in 0..<30 { // wait up to ~30 s for the server to come up
                    if await client.isRunning() { retry(); return }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } else {
            NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
        }
    }

    /// Downloads the missing model (with progress), then retries.
    func downloadModel() {
        guard case .modelMissing(let model) = problem, phase == .idle else { return }
        phase = .downloadingModel(0)
        Task {
            do {
                try await client.pull(model: model) { p in
                    Task { @MainActor in
                        if case .downloadingModel = self.phase { self.phase = .downloadingModel(p) }
                    }
                }
                phase = .idle
                retry()
            } catch {
                phase = .idle
                if case LLMError.notRunning = error { problem = .ollamaNotRunning }
                errorMessage = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    /// Called when the app quits mid-summary, so meta.json doesn't stay "summarizing".
    func markInterrupted() {
        guard let folder = currentFolder, var meta = try? MeetingMeta.load(from: folder) else { return }
        meta.status = .summaryFailed
        meta.summaryError = "Interrupted: the app quit while summarizing. Use Summarize Last Meeting."
        try? meta.save(to: folder)
    }

    // MARK: Queue

    private func startRunnerIfNeeded() {
        guard runner == nil else { return }
        runner = Task {
            // Wait until WhisperKit is finished and unloaded: never both models in memory.
            phase = .waitingForTranscription
            await HeavyWorkLock.shared.acquire()
            let model = AppSettings.llmModel
            while !queue.isEmpty {
                let folder = queue.removeFirst()
                currentFolder = folder
                await run(folder: folder, model: model)
                currentFolder = nil
                if problem != nil { // Ollama off / model missing: keep the rest for later
                    pending += queue
                    queue = []
                }
            }
            await client.unload(model: model) // free the LLM's memory now instead of after keep_alive
            await HeavyWorkLock.shared.release()
            phase = .idle
            runner = nil
        }
    }

    private func run(folder: URL, model: String) async {
        phase = .checking
        contextDocumentCount = nil
        let began = Date()
        guard var meta = try? MeetingMeta.load(from: folder) else {
            errorMessage = "Can't read meta.json in \(folder.lastPathComponent)."
            return
        }
        func fail(_ message: String, problem newProblem: Problem? = nil) {
            if let newProblem {
                problem = newProblem
                pending.append(folder)
            }
            meta.status = .summaryFailed
            meta.summaryError = message
            meta.summarySeconds = (Date().timeIntervalSince(began) * 10).rounded() / 10
            try? meta.save(to: folder) // the transcript files are never touched
            errorMessage = newProblem == nil ? "Summary failed (\(folder.lastPathComponent)): \(message)" : nil
        }

        let lines: [TranscriptLine]
        do {
            let data = try Data(contentsOf: folder.appending(path: TranscriptWriter.jsonFileName))
            lines = try JSONDecoder().decode([TranscriptLine].self, from: data)
        } catch {
            fail("No readable transcript.json. Transcribe this meeting first.")
            return
        }

        // Health check: is Ollama running, and is the model installed?
        guard await client.isRunning() else {
            fail(LLMError.notRunning.localizedDescription, problem: .ollamaNotRunning)
            return
        }
        let installed = (try? await client.installedModels()) ?? []
        guard installed.contains(model) || installed.contains("\(model):latest") else {
            fail(LLMError.modelMissing(model).localizedDescription, problem: .modelMissing(model))
            return
        }
        problem = nil

        meta.status = .summarizing
        meta.summaryModel = model
        meta.summaryError = nil
        try? meta.save(to: folder)

        let language = AppSettings.summaryLanguage
        var pipeline = SummaryPipeline(client: client, model: model, prompts: PromptStore.load(),
                                       myName: AppSettings.myName, language: language)
        let projectFolder = URL(fileURLWithPath: meta.projectPath)
        pipeline.meeting = SummaryPipeline.MeetingIdentity(
            id: folder.lastPathComponent, start: meta.startTime,
            projectName: meta.projectPath.isEmpty ? "" : projectFolder.lastPathComponent,
            projectAbout: meta.projectPath.isEmpty ? nil : ProjectOverviewBuilder.load(projectFolder: projectFolder)?.about)
        // Phase 4: search the project's index for related docs and earlier meetings.
        if AppSettings.useProjectContext, let retriever = retrieverProvider(meta.projectPath) {
            let thisMeeting = ".meetings/\(folder.lastPathComponent)/" // never cite the meeting itself
            pipeline.retrieveContext = { queries in
                let outcome = try? await retriever.searchDetailed(queries: queries, limit: 8,
                                                                  excludingPathPrefix: thisMeeting)
                let found = outcome.map(SummaryPipeline.relevantContext) ?? []
                let documents = Set(found.map(\.path)).count
                await MainActor.run { self.contextDocumentCount = documents }
                return found
            }
        }
        do {
            phase = .summarizing(part: 1, total: 1)
            let summary = try await pipeline.summarize(lines, duration: meta.durationSeconds) { part, total in
                Task { @MainActor in self.phase = .summarizing(part: part, total: total) }
            }
            let projectName = projectFolder.lastPathComponent
            let url = try SummaryWriter.write(summary, meetingStart: meta.startTime, duration: meta.durationSeconds,
                                              projectName: projectName, language: language, to: folder)
            meta.status = .summarized
            meta.summarySeconds = (Date().timeIntervalSince(began) * 10).rounded() / 10
            try? meta.save(to: folder)
            lastSummaryURL = url
            Notifier.post(title: "Đã tóm tắt xong", body: "\(summary.title) — bấm để mở summary.md", open: url)
        } catch LLMError.notRunning {
            fail(LLMError.notRunning.localizedDescription, problem: .ollamaNotRunning)
        } catch LLMError.modelMissing(let missing) {
            fail(LLMError.modelMissing(missing).localizedDescription, problem: .modelMissing(missing))
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func latestMeeting(in projectFolder: URL?, containing fileName: String) -> URL? {
        guard let projectFolder else { return nil }
        let meetings = projectFolder.appending(path: ".meetings", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: meetings, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: fileName).path) }
            .max { $0.lastPathComponent < $1.lastPathComponent } // names are timestamps
    }
}
