import SwiftUI

/// A quoted transcript segment with a play button that plays exactly that segment.
struct SpeakerQuoteCard: View {
    enum Style {
        /// Inspector: white card, line border, 22 pt play button.
        case card
        /// Quick Ask: foam 55 %, 28 pt play button.
        case foam
    }

    let speaker: String
    var speakerKind: SpeakerKind = .others
    /// Mono line next to the name: "31:40" or "Sprint review · 26/11 · 31:40".
    let meta: String
    let quote: String
    var style: Style = .card
    let onPlay: () -> Void

    private var playSize: CGFloat { style == .card ? 22 : 28 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onPlay) {
                    Circle()
                        .fill(speakerKind.color)
                        .frame(width: playSize, height: playSize)
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(.system(size: playSize * 0.36))
                                .foregroundStyle(.white)
                                .offset(x: 1)
                        }
                }
                .buttonStyle(.plain)
                .help("Nghe đoạn này")
                .accessibilityLabel("Nghe đoạn \(speaker) nói")

                Text(verbatim: speaker)
                    .typeStyle(.ui(12, .medium))
                    .foregroundStyle(.ink)
                Text(verbatim: meta)
                    .typeStyle(.monoSmall)
                    .foregroundStyle(.ink3)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(verbatim: "“\(quote)”")
                .typeStyle(.quote)
                .foregroundStyle(.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(12)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.callout, style: .continuous)
            switch style {
            case .card: shape.fill(.white).overlay(shape.strokeBorder(.line, lineWidth: Theme.hairline))
            case .foam: shape.fill(Color.foam.opacity(0.55))
            }
        }
    }
}

#Preview("SpeakerQuoteCard") {
    VStack(spacing: 16) {
        SpeakerQuoteCard(speaker: SampleData.quote.speaker, meta: LangFormat.clock(SampleData.quote.time),
                         quote: SampleData.quote.text) {}
        SpeakerQuoteCard(speaker: SampleData.quote.speaker, meta: "Sprint review · 26/11 · 31:40",
                         quote: SampleData.quote.text, style: .foam) {}
    }
    .padding(20)
    .frame(width: 420)
    .background(Color.mist)
}
