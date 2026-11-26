import SwiftUI

/// "Suggest Glossary from Project": tick the names/terms to save into .meetings/glossary.txt.
struct GlossaryView: View {
    @ObservedObject var model: GlossaryModel
    /// Inside a card of the Dự án section: the card gives the title and padding.
    var embedded = false
    @State private var newTerm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if embedded {
                // One row: the hint on the left, Select All / None on the right.
                HStack(alignment: .firstTextBaseline) {
                    hint
                    Spacer(minLength: 12)
                    selectButtons
                }
            } else {
                HStack {
                    Text(verbatim: model.projectFolder.map { "Glossary · \($0.lastPathComponent)" } ?? "Glossary")
                        .font(.headline)
                    Spacer()
                    selectButtons
                }
                hint
            }

            switch model.phase {
            case .collecting: ProgressView("Collecting names and terms from the index…")
            case .waitingForModel: ProgressView("Waiting for transcription/summary to finish…")
            case .cleaning: ProgressView("Asking \(AppSettings.llmModel) to clean the list…")
            case .failed(let message): Text(message).foregroundStyle(.red)
            case .idle, .ready: EmptyView()
            }
            if let note = model.note {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            List($model.items) { $item in
                Toggle(isOn: $item.selected) {
                    HStack {
                        Text(item.term)
                        if item.alreadyInGlossary {
                            Text("đã có").font(.caption).foregroundStyle(.green)
                        }
                        Spacer()
                        if !item.kind.isEmpty {
                            Text(item.kind).font(.caption).foregroundStyle(.secondary)
                        }
                        if item.count > 0 {
                            Text("×\(item.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: embedded ? 160 : 260)

            HStack {
                TextField("Add a term", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.addTerm(newTerm); newTerm = "" }
                Button("Add") { model.addTerm(newTerm); newTerm = "" }.disabled(newTerm.isEmpty)
                Spacer()
                Button("Save to glossary.txt") { model.save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking || model.projectFolder == nil)
            }
        }
        .padding(embedded ? 0 : 12)
        .frame(minWidth: embedded ? nil : 480, minHeight: embedded ? nil : 460)
    }

    private var hint: some View {
        Text("Ticked terms go to .meetings/glossary.txt. Whisper uses them as a spelling hint for names and jargon.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var selectButtons: some View {
        Button("Select All") { model.setAll(true) }.disabled(model.items.isEmpty)
        Button("Select None") { model.setAll(false) }.disabled(model.items.isEmpty)
    }
}

/// "Show Indexed Files": what the index contains, per file.
struct IndexedFilesView: View {
    @ObservedObject var indexer: ProjectIndexer
    @State private var sortOrder = [KeyPathComparator(\IndexedFileInfo.path)]
    @State private var filter = ""
    @State private var query = ""
    @State private var results: [RetrievedChunk] = []
    @State private var searchMessage: String?
    @State private var searching = false

    private var rows: [IndexedFileInfo] {
        let matching = filter.isEmpty
            ? indexer.files
            : indexer.files.filter { $0.path.localizedCaseInsensitiveContains(filter) }
        return matching.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(indexer.projectFolder?.lastPathComponent ?? "No project folder")
                    .font(.headline)
                Text("\(indexer.files.count) files · \(indexer.chunkCount) chunks")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button("Reindex") { indexer.reindex() }
                    .disabled(indexer.isWorking || indexer.projectFolder == nil)
            }
            if let status = indexer.statusText {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("File", value: \.path) { row in
                    VStack(alignment: .leading) {
                        Text(row.path).lineLimit(1).truncationMode(.middle)
                        if let error = row.error {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                TableColumn("Type", value: \.sourceType.rawValue) { row in
                    Text(row.sourceType.rawValue)
                }
                .width(70)
                TableColumn("Chunks", value: \.chunkCount) { row in
                    Text("\(row.chunkCount)").monospacedDigit()
                }
                .width(60)
                TableColumn("Vectors") { row in
                    Image(systemName: row.hasVectors ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(row.hasVectors ? .green : .secondary)
                        .help(row.hasVectors ? "Embedded" : "Keyword search only (no vectors yet)")
                }
                .width(55)
                TableColumn("Last indexed", value: \.indexedAt) { row in
                    Text(row.indexedAt, format: .dateTime.day().month().hour().minute())
                }
                .width(130)
            }

            // Try the hybrid search (the same one summaries use).
            Divider()
            HStack {
                TextField("Test search (e.g. a feature name or a person)", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runSearch)
                Button("Search", action: runSearch)
                    .disabled(query.isEmpty || searching || indexer.retriever == nil)
            }
            if let searchMessage {
                Text(searchMessage).font(.caption).foregroundStyle(.secondary)
            }
            if !results.isEmpty {
                List(Array(results.enumerated()), id: \.element.id) { index, result in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(index + 1). \(result.path)").fontWeight(.medium)
                            Text(result.location).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.4f", result.score))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(result.text.prefix(220).replacingOccurrences(of: "\n", with: " "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(minHeight: 180)
            }
        }
        .padding(12)
        .frame(minWidth: 640, minHeight: 420)
    }

    private func runSearch() {
        guard let retriever = indexer.retriever, !query.isEmpty else { return }
        searching = true
        searchMessage = nil
        let started = Date()
        Task {
            do {
                results = try await retriever.search(query: query, limit: 8)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                searchMessage = results.isEmpty ? "No results." : "\(results.count) results in \(ms) ms"
            } catch {
                results = []
                searchMessage = "Search failed: \(error.localizedDescription)"
            }
            searching = false
        }
    }
}
