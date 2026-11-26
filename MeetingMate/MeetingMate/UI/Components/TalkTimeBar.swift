import SwiftUI

/// "thời gian nói": 240×6 bar, water = me over a sand track.
struct TalkTimeBar: View {
    /// 0…1, the share of speaking time that is mine.
    let meShare: Double

    private var mePercent: Int { Int((min(max(meShare, 0), 1) * 100).rounded()) }

    var body: some View {
        HStack(spacing: 12) {
            SectionLabel("thời gian nói")
            ZStack(alignment: .leading) {
                Capsule().fill(.sand)
                Capsule().fill(.water).frame(width: 240 * CGFloat(mePercent) / 100)
            }
            .frame(width: 240, height: 6)
            Text("bạn \(mePercent)%")
                .typeStyle(.ui(12, .medium))
                .foregroundStyle(.deep)
            Text("người khác \(100 - mePercent)%")
                .typeStyle(.ui(12, .medium))
                .foregroundStyle(.sandInk)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thời gian nói: bạn \(mePercent) phần trăm, người khác \(100 - mePercent) phần trăm")
    }
}

#Preview("TalkTimeBar") {
    TalkTimeBar(meShare: SampleData.meShare)
        .padding(20)
        .background(.white)
}
