import Foundation

/// Suggests names and terms for .meetings/glossary.txt (which Phase 2 gives Whisper as a spelling hint).
/// 1. Collect candidates from the index: capitalized names, acronyms, headings, people in meetings.
/// 2. Ask the LLM to keep only real names/terms (and fix obvious casing).
/// 3. You tick what to keep in the Glossary window.
enum GlossarySuggester {
    struct Candidate: Equatable {
        var term: String
        var count: Int
        var score: Double
    }

    /// Words that start sentences or are too generic to help Whisper.
    static let honorifics: Set<String> = ["anh", "chị", "em", "ông", "bà", "cô", "chú", "thầy", "bạn", "con", "mr", "ms"]
    static let stopTerms: Set<String> = [
        "ok", "oke", "todo", "fyi", "the", "and", "note", "tôi", "người khác", "người nói",
        // Our own summary headings (Phase 3) must not become glossary terms.
        "tóm tắt", "điểm chính", "quyết định", "việc cần làm", "câu hỏi mở", "liên quan tới tài liệu",
        "thay đổi so với trước", "summary", "key points", "decisions", "action items", "open questions",
        "cuộc họp", "thời lượng", "project", "bản chép lời",
    ]
    static let maxCandidates = 150

    // MARK: - Step 1: candidates

    /// `chunks`: (sourceType, text). Code is skipped (identifiers are mostly noise for speech).
    static func candidates(from chunks: [(SourceType, String)], limit: Int = maxCandidates) -> [Candidate] {
        var counts: [String: (term: String, count: Int, score: Double)] = [:]
        func add(_ raw: String, weight: Double) {
            let term = raw.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            let key = term.lowercased()
            guard term.count >= 2, term.count <= 40, !stopTerms.contains(key),
                  term.rangeOfCharacter(from: .letters) != nil else { return }
            var entry = counts[key] ?? (term, 0, 0)
            entry.count += 1
            entry.score += weight
            counts[key] = entry
        }

        for (type, text) in chunks where type != .code {
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Headings of documents (not of our own meeting summaries).
                if type == .doc, trimmed.hasPrefix("#") {
                    let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                    if heading.split(separator: " ").count <= 4 { add(heading, weight: 2) }
                }
                // Drop a transcript line's "[00:01:02] Speaker:" prefix.
                var body = trimmed
                if body.hasPrefix("["), let colon = body.range(of: ": ") { body = String(body[colon.upperBound...]) }

                for sentence in body.split(whereSeparator: { ".!?;:\n".contains($0) }) {
                    for run in capitalizedRuns(in: String(sentence)) { add(run.term, weight: run.weight) }
                }
                // "anh Tùng", "chị Lan" in meetings → a person's name.
                if type == .meeting {
                    for name in honorificNames(in: body) { add(name, weight: 3) }
                }
            }
        }

        // Keep terms seen twice, or strong signals (headings, names after anh/chị…) seen once.
        return counts.values
            .filter { $0.count >= 2 || $0.score >= 2 }
            .map { Candidate(term: $0.term, count: $0.count, score: $0.score) }
            .sorted { ($0.score, $0.term) > ($1.score, $1.term) }
            .prefix(limit)
            .map { $0 }
    }

    /// Runs of 1–4 capitalized words. A single ordinary word at the start of a sentence is skipped
    /// ("Hôm nay…"), but acronyms (QR, VNG), CamelCase (WhisperKit) and words with digits (iOS 18) count.
    static func capitalizedRuns(in sentence: String) -> [(term: String, weight: Double)] {
        let words = sentence.split(whereSeparator: { $0.isWhitespace || ",()\"“”'«»".contains($0) }).map(String.init)
        var result: [(String, Double)] = []
        var run: [String] = []
        var runStart = 0

        func flush() {
            defer { run = [] }
            var parts = run
            // "Anh Tùng" → "Tùng": drop leading honorifics.
            while let first = parts.first, honorifics.contains(first.lowercased()) { parts.removeFirst() }
            guard !parts.isEmpty else { return }
            let atSentenceStart = runStart == 0 && parts.count == run.count
            if parts.count == 1, atSentenceStart, !isSpecial(parts[0]) { return }
            // Acronyms/CamelCase are strong signals (one mention is enough); multi-word names a bit less.
            result.append((parts.joined(separator: " "), isSpecial(parts[0]) ? 2 : parts.count > 1 ? 1.5 : 1))
        }

        for (index, word) in words.enumerated() {
            if let first = word.first, first.isUppercase, first.isLetter, run.count < 4 {
                if run.isEmpty { runStart = index }
                run.append(word)
            } else {
                if !run.isEmpty { flush() }
                if isSpecial(word) { result.append((word, 2)) } // e.g. "iOS", "macOS15"
            }
        }
        if !run.isEmpty { flush() }
        return result
    }

    /// Acronym, CamelCase or letters+digits: almost always a name or a term.
    static func isSpecial(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        let upper = letters.filter(\.isUppercase).count
        let allCaps = upper == letters.count && letters.count <= 10
        let camel = upper >= 2 && upper < letters.count && word.first?.isLetter == true
        let digits = word.contains(where: \.isNumber) && word.first?.isLetter == true
        return allCaps || camel || digits
    }

    static func honorificNames(in text: String) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace || ",.!?;:()\"".contains($0) }).map(String.init)
        var names: [String] = []
        for (i, word) in words.enumerated() where honorifics.contains(word.lowercased()) && i + 1 < words.count {
            var name: [String] = []
            for next in words[(i + 1)...].prefix(3) {
                guard let first = next.first, first.isUppercase, first.isLetter else { break }
                name.append(next)
            }
            if !name.isEmpty { names.append(name.joined(separator: " ")) }
        }
        return names
    }

    // MARK: - Step 2: LLM cleanup

    struct CleanedList: Codable {
        struct Term: Codable { var term: String; var kind: String? }
        var terms: [Term]
    }

    static let schema: [String: Any] = [
        "type": "object",
        "properties": ["terms": ["type": "array", "items": [
            "type": "object",
            "properties": ["term": ["type": "string"], "kind": ["type": "string"]],
            "required": ["term", "kind"],
        ] as [String: Any]]],
        "required": ["terms"],
    ]

    static func cleanupPrompt(_ candidates: [Candidate]) -> String {
        """
        Đây là danh sách từ được trích tự động từ tài liệu và các cuộc họp của một dự án.
        Danh sách này sẽ giúp phần mềm chép lời (Whisper) viết đúng tên riêng và thuật ngữ.

        Hãy giữ lại CHỈ: tên người, tên công ty/sản phẩm/dự án, tên tính năng, thuật ngữ chuyên môn, từ viết tắt.
        Bỏ: từ thông thường, câu, cụm từ chung chung, tiêu đề chung chung.
        Chỉ sửa chính tả hoặc viết hoa khi chắc chắn; không thêm từ mới không có trong danh sách.
        kind là một trong: person, product, company, term, acronym.

        JSON schema:
        \(SummarySchema.text(schema))

        Danh sách (từ — số lần xuất hiện):
        \(candidates.map { "- \($0.term) — \($0.count)" }.joined(separator: "\n"))
        """
    }

    /// Keeps only LLM terms that match a candidate (so it can't invent words), with the candidate's count.
    static func reconcile(_ cleaned: CleanedList, with candidates: [Candidate]) -> [(term: String, count: Int, kind: String)] {
        var seen = Set<String>()
        var result: [(String, Int, String)] = []
        for item in cleaned.terms {
            let term = item.term.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = TranscriptMerger.normalize(term)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let match = candidates.first { candidate in
                let c = TranscriptMerger.normalize(candidate.term)
                return c == key || TranscriptMerger.similarity(c, key) >= 0.75
            }
            guard let match else { continue } // invented by the model
            result.append((term, match.count, item.kind ?? "term"))
        }
        return result
    }

    // MARK: - Step 3: glossary.txt

    static func glossaryURL(projectFolder: URL) -> URL {
        projectFolder.appending(path: ".meetings", directoryHint: .isDirectory).appending(path: "glossary.txt")
    }

    /// Terms already in glossary.txt (comments and blank lines skipped).
    static func existingTerms(in text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// New file content: the existing comment lines, then the selected terms (no duplicates).
    static func glossaryText(existing: String, selected: [String]) -> String {
        let comments = existing.components(separatedBy: .newlines).filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        var seen = Set<String>()
        let terms = selected
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return (comments + terms).joined(separator: "\n") + "\n"
    }
}

// MARK: - Window state

@MainActor
final class GlossaryModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        var id: String { term.lowercased() }
        var term: String
        var count: Int
        var kind: String
        var selected: Bool
        var alreadyInGlossary: Bool
    }

    enum Phase: Equatable {
        case idle
        case collecting
        case waitingForModel
        case cleaning
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var items: [Item] = []
    @Published var note: String?
    @Published private(set) var projectFolder: URL?

    private let client: LLMClient

    init(client: LLMClient = OllamaClient()) {
        self.client = client
    }

    var isWorking: Bool {
        [.collecting, .waitingForModel, .cleaning].contains(phase)
    }

    /// The project changed: drop the old project's list. A suggestion still running for the old project
    /// finishes in the background and is thrown away (see `suggest`).
    func reset(for projectFolder: URL?) {
        guard projectFolder?.standardizedFileURL != self.projectFolder?.standardizedFileURL else { return }
        self.projectFolder = projectFolder
        items = []
        note = nil
        if !isWorking { phase = .idle }
    }

    /// Builds suggestions for the indexer's current project.
    func suggest(store: IndexStore?, projectFolder: URL?) {
        guard !isWorking else { return }
        guard let store, let projectFolder else {
            phase = .failed("Choose and index a project folder first.")
            return
        }
        self.projectFolder = projectFolder
        note = nil
        items = []
        phase = .collecting

        Task {
            // Existing glossary entries stay ticked.
            let existingText = (try? String(contentsOf: GlossarySuggester.glossaryURL(projectFolder: projectFolder),
                                             encoding: .utf8)) ?? ""
            let existing = GlossarySuggester.existingTerms(in: existingText)

            let candidates = await Task.detached(priority: .utility) { () -> [GlossarySuggester.Candidate] in
                var chunks: [(SourceType, String)] = []
                try? store.forEachChunk { _, type, text in chunks.append((type, text)) }
                return GlossarySuggester.candidates(from: chunks)
            }.value

            var suggested: [(term: String, count: Int, kind: String)] = candidates.map { ($0.term, $0.count, "") }
            if candidates.isEmpty {
                note = "No names or terms found in the index yet."
            } else if let cleaned = await cleanWithLLM(candidates) {
                suggested = GlossarySuggester.reconcile(cleaned, with: candidates)
            } else {
                note = "Ollama or the model isn't available, so this list wasn't cleaned by the LLM. Untick what you don't need."
            }

            // The project was switched while we worked: these terms belong to the old one.
            guard self.projectFolder == projectFolder else {
                note = nil
                phase = .idle
                return
            }

            let existingKeys = Set(existing.map { $0.lowercased() })
            items = existing.map { Item(term: $0, count: 0, kind: "", selected: true, alreadyInGlossary: true) }
                + suggested.filter { !existingKeys.contains($0.term.lowercased()) }.map {
                    Item(term: $0.term, count: $0.count, kind: $0.kind, selected: !$0.kind.isEmpty,
                         alreadyInGlossary: false)
                }
            phase = .ready
        }
    }

    /// Asks the summary LLM to clean the list; nil if Ollama/the model isn't available.
    private func cleanWithLLM(_ candidates: [GlossarySuggester.Candidate]) async -> GlossarySuggester.CleanedList? {
        let model = AppSettings.llmModel
        guard await client.isRunning(),
              let installed = try? await client.installedModels(),
              installed.contains(model) || installed.contains("\(model):latest") else { return nil }

        phase = .waitingForModel
        await HeavyWorkLock.shared.acquire() // never next to WhisperKit or another LLM job
        phase = .cleaning
        defer {
            Task {
                await client.unload(model: model)
                await HeavyWorkLock.shared.release()
            }
        }
        let options = LLMChatOptions(model: model, jsonSchema: GlossarySuggester.schema, temperature: 0.1)
        guard let reply = try? await client.chat(
            messages: [.system("Bạn giúp lọc danh sách tên riêng và thuật ngữ. Chỉ trả lời bằng JSON."),
                       .user(GlossarySuggester.cleanupPrompt(candidates))],
            options: options, onProgress: { _ in }) else { return nil }
        return try? SummarySchema.parse(GlossarySuggester.CleanedList.self, from: reply)
    }

    func addTerm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !items.contains(where: { $0.id == trimmed.lowercased() }) else { return }
        items.insert(Item(term: trimmed, count: 0, kind: "", selected: true, alreadyInGlossary: false), at: 0)
    }

    func setAll(_ selected: Bool) {
        for i in items.indices { items[i].selected = selected }
    }

    /// Writes the ticked terms to .meetings/glossary.txt (keeping its # comment lines).
    func save() {
        guard let projectFolder else { return }
        let url = GlossarySuggester.glossaryURL(projectFolder: projectFolder)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let text = GlossarySuggester.glossaryText(existing: existing, selected: items.filter(\.selected).map(\.term))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            let count = items.filter(\.selected).count
            note = "Saved \(count) terms to .meetings/glossary.txt. They're used from the next transcription."
            for i in items.indices { items[i].alreadyInGlossary = items[i].selected }
        } catch {
            note = "Could not save: \(error.localizedDescription)"
        }
    }
}
