import SwiftUI

/// "Tóm tắt" tab (overview, change, decisions, action items, related) and the "Việc cần làm" tab.
struct SummaryTab: View {
    enum Section { case summary, tasks }

    let model: MeetingDetailModel
    let section: Section
    let play: (Double) -> Void
    /// Opens a file from the project, given its path relative to the project folder.
    let openFile: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if section == .summary {
                if let summary = model.summary {
                    Text(verbatim: summary.overview)
                        .typeStyle(.summary)
                        .foregroundStyle(.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: 630, alignment: .leading)

                    if let change = summary.changesFromBefore.first {
                        ChangeCallout(text: change.text,
                                      sourceTitle: sourceTitle(change.previousSource),
                                      sourceNumber: change.previousSource) {
                            openFile(sourcePath(change.previousSource))
                        }
                    }

                    if !summary.decisions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("quyết định")
                            ForEach(Array(summary.decisions.enumerated()), id: \.offset) { _, item in
                                DecisionRow(text: item.text,
                                            seconds: LangFormat.seconds(fromClock: item.timestamp),
                                            onTimestamp: play)
                            }
                        }
                    }
                } else {
                    Text("Chưa có bản tóm tắt cho cuộc họp này.")
                        .typeStyle(.body)
                        .foregroundStyle(.ink3)
                }
            }

            if !model.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("việc cần làm")
                    ForEach(Array(model.actionItems.enumerated()), id: \.offset) { index, item in
                        ActionItemRow(text: item.task,
                                      isDone: Binding(get: { model.actionItems[index].done ?? false },
                                                      set: { model.setDone(index, $0) }),
                                      owner: ownerText(item),
                                      ownerIsMe: isMine(item),
                                      seconds: LangFormat.seconds(fromClock: item.timestamp),
                                      onTimestamp: play)
                    }
                }
            } else if section == .tasks {
                Text("Cuộc họp này không có việc cần làm.")
                    .typeStyle(.body)
                    .foregroundStyle(.ink3)
            }

            if section == .summary, let related = model.summary?.relatedDocs, !related.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("liên quan")
                    FlowLayout(spacing: 6) {
                        ForEach(Array(related.enumerated()), id: \.offset) { _, doc in
                            SourceChip(number: doc.source, icon: "doc.text", title: fileName(doc.path),
                                       tooltip: doc.reason) {
                                openFile(doc.path)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    /// "bạn · 02/12": owner plus deadline when known. "Chưa rõ" owners show no pill.
    private func ownerText(_ item: ActionItem) -> String? {
        guard item.owner != ActionItem.unknown else { return nil }
        guard item.deadline != ActionItem.unknown else { return item.owner }
        return "\(item.owner) · \(item.deadline)"
    }

    private func isMine(_ item: ActionItem) -> Bool {
        MeetingList.myNames().contains(MeetingList.normalizeOwner(item.owner))
    }

    private func sourcePath(_ label: String) -> String {
        model.summary?.sources.first { $0.label == label }?.path ?? ""
    }

    private func sourceTitle(_ label: String) -> String {
        let path = sourcePath(label)
        return path.isEmpty ? label : fileName(path)
    }

    private func fileName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return name.isEmpty ? path : name
    }
}
