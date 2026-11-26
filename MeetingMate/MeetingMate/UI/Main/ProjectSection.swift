import SwiftUI

/// "Dự án": the project folder, its status, the documents the index has read, and re-reading.
struct ProjectSection: View {
    @Bindable var app: AppState
    @ObservedObject var indexer: ProjectIndexer

    init(app: AppState) {
        self.app = app
        self.indexer = app.indexer
    }

    private var documents: [IndexedFileInfo] {
        indexer.files
            .filter { $0.sourceType != .meeting && !$0.path.hasPrefix(".meetings/") }
            .sorted { $0.path < $1.path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: app.projectName)
                .typeStyle(TypeStyle(family: .serif(italic: false), size: 28))
                .foregroundStyle(.ink)
            HStack(spacing: 8) {
                Text(verbatim: app.projectSubtitle)
                    .typeStyle(.caption)
                    .foregroundStyle(.ink2)
                StatusDot(status: app.projectStatus)
            }

            HStack(spacing: 8) {
                Button("Chọn thư mục dự án…") { app.projectStore.chooseFolder() }
                    .buttonStyle(.lang(.secondary))
                Button("Đọc lại dự án") { indexer.reindex() }
                    .buttonStyle(.lang(.secondary))
                    .disabled(because: indexer.isWorking ? String(localized: "Đang đọc dự án.")
                              : app.projectStore.folderURL == nil ? String(localized: "Chọn thư mục dự án trước.")
                              : nil)
                Button("Gợi ý thuật ngữ") {
                    app.glossary.suggest(store: indexer.store, projectFolder: indexer.projectFolder)
                }
                .buttonStyle(.lang(.secondary))
                .disabled(because: indexer.store == nil ? String(localized: "Chọn thư mục dự án trước.") : nil)
            }

            SectionLabel("tài liệu đã đọc")
            if documents.isEmpty {
                Text("Chưa có tài liệu nào được đọc.")
                    .typeStyle(.body)
                    .foregroundStyle(.ink3)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(documents) { document in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.ink2)
                                .frame(width: 18)
                            Text(verbatim: document.path)
                                .typeStyle(.small)
                                .foregroundStyle(document.error == nil ? Color.ink : Color.rec)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(verbatim: document.error == nil ? "\(document.chunkCount) đoạn" : "không đọc được")
                                .typeStyle(.caption)
                                .foregroundStyle(.ink3)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .help(document.error ?? document.path)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
            }
            .scrollIndicators(.never)

            SectionLabel("thuật ngữ")
            GlossaryView(model: app.glossary)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
