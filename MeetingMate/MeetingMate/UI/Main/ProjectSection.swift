import SwiftUI

/// "Dự án": a bento grid about the current project.
/// Wide:   [ dự án này là gì ··········· ][ 3 ưu tiên ]
///         [ cập nhật gần đây ][ việc cần làm ][ tài liệu ]
///         [ thuật ngữ ······································· ]
/// Medium: 2 columns. Narrow: 1 column.
struct ProjectSection: View {
    @Bindable var app: AppState
    @ObservedObject var indexer: ProjectIndexer
    /// Measured content width; picks the grid layout.
    @State private var width: CGFloat = 1200
    /// false only for snapshot tests: ImageRenderer can't draw inside a ScrollView.
    private let scrolls: Bool

    private static let spacing: CGFloat = 16
    private static let maxContentWidth: CGFloat = 1320
    private static let documentsHeight: CGFloat = 300
    private static let glossaryHeight: CGFloat = 400

    init(app: AppState, scrolls: Bool = true) {
        self.app = app
        self.indexer = app.indexer
        self.scrolls = scrolls
    }

    var body: some View {
        Group {
            if scrolls {
                ScrollView { content }
                    .scrollIndicators(.automatic)
            } else {
                // Like a ScrollView: content takes its natural height instead of stretching.
                content.fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: buildOverviewIfMissing)
        // AppState reloads the overview on every project switch; once the new meetings are in, build it if missing.
        .onChange(of: app.meetings) { _, _ in buildOverviewIfMissing() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            if app.projectFolder == nil {
                noProject
            } else {
                grid
            }
        }
        .frame(maxWidth: Self.maxContentWidth, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(36)
        .frame(maxWidth: .infinity, alignment: .top) // centered, like the other sections
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: app.projectName)
                    .typeStyle(TypeStyle(family: .serif(italic: false), size: 28))
                    .foregroundStyle(.ink)
                HStack(spacing: 8) {
                    Text(verbatim: app.projectSubtitle)
                        .typeStyle(.caption)
                        .foregroundStyle(.ink2)
                    StatusDot(status: app.projectStatus)
                }
            }
            Spacer(minLength: 8)
            Button(app.projectFolder == nil ? "Chọn thư mục dự án…" : "Đổi thư mục…") {
                app.projectStore.chooseFolder()
            }
            .buttonStyle(.lang(.secondary))
            .disabled(because: app.switchProjectDisabledReason)
        }
    }

    private var noProject: some View {
        BentoTile(title: "bắt đầu") {
            Text("Chọn thư mục dự án. lắng sẽ đọc tài liệu trong đó và lưu cuộc họp vào thư mục .meetings bên trong.")
                .typeStyle(.body)
                .foregroundStyle(.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 520)
    }

    // MARK: Grid

    private enum Columns { case three, two, one }

    private var columns: Columns {
        width >= 1000 ? .three : width >= 640 ? .two : .one
    }

    @ViewBuilder
    private var grid: some View {
        let s = Self.spacing
        switch columns {
        case .three:
            Grid(horizontalSpacing: s, verticalSpacing: s) {
                GridRow {
                    AboutTile(app: app).gridCellColumns(2)
                    PrioritiesTile(app: app)
                }
                GridRow {
                    LatestMeetingsTile(app: app)
                    OpenTasksTile(app: app)
                    documents
                }
                GridRow {
                    glossary.gridCellColumns(3)
                }
            }
        case .two:
            Grid(horizontalSpacing: s, verticalSpacing: s) {
                GridRow { AboutTile(app: app).gridCellColumns(2) }
                GridRow {
                    PrioritiesTile(app: app)
                    OpenTasksTile(app: app)
                }
                GridRow {
                    LatestMeetingsTile(app: app)
                    documents
                }
                GridRow { glossary.gridCellColumns(2) }
            }
        case .one:
            VStack(spacing: s) {
                AboutTile(app: app)
                PrioritiesTile(app: app)
                OpenTasksTile(app: app)
                LatestMeetingsTile(app: app)
                documents
                glossary
            }
        }
    }

    private var documents: some View {
        DocumentsTile(app: app, scrolls: scrolls)
            .frame(minHeight: Self.documentsHeight)
            .frame(height: scrolls ? Self.documentsHeight : nil)
    }

    private var glossary: some View {
        GlossaryTile(app: app)
            .frame(height: Self.glossaryHeight)
    }

    // MARK: Overview

    private func buildOverviewIfMissing() {
        guard indexIsCurrent else { return }
        app.overview.buildIfMissing(store: indexer.store, projectName: app.projectName)
    }

    /// The indexer switches folder a moment after the project does; until then its files are the old project's.
    private var indexIsCurrent: Bool {
        indexer.projectFolder?.standardizedFileURL == app.projectFolder?.standardizedFileURL
    }
}
