import SwiftUI

/// Quote cards for the meeting sources of an answer: the cited words, with a play button that
/// opens the meeting at that moment. Document sources are shown as chips only.
struct SourceQuotes: View {
    let sources: [AnswerSource]
    let projectFolder: URL?
    let router: Router

    private var quotable: [AnswerSource] {
        sources.filter { $0.sourceType == .meeting && !$0.preview.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(2).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(quotable) { source in
                let (speaker, text) = split(source.preview)
                SpeakerQuoteCard(speaker: speaker,
                                 speakerKind: speaker == "Tôi" ? .me : .others,
                                 meta: SourceLink.shortName(source),
                                 quote: text) {
                    SourceOpener.open(source, projectFolder: projectFolder, router: router)
                }
            }
        }
    }

    /// "Tôi: nội dung" → ("Tôi", "nội dung"). Without a speaker prefix, the speaker is "Cuộc họp".
    private func split(_ preview: String) -> (String, String) {
        let cleaned = preview.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let limited = String(cleaned.prefix(240))
        if let colon = limited.firstIndex(of: ":"),
           limited.distance(from: limited.startIndex, to: colon) <= 20 {
            let name = String(limited[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(limited[limited.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !rest.isEmpty { return (name, rest) }
        }
        return (String(localized: "Cuộc họp"), limited)
    }
}
