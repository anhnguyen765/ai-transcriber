import SwiftUI

/// A decision or action item placed on the waveform.
struct WaveMarker: Identifiable {
    enum Kind { case decision, action }

    let kind: Kind
    let seconds: Double
    let label: String

    var id: String { "\(kind)-\(seconds)" }
}

/// Bottom bar: play, time, waveform, speed.
struct AudioBar: View {
    @ObservedObject var player: MeetingViewerModel
    let peaks: [Float]
    let barOwners: [Bool]
    let markers: [WaveMarker]

    var body: some View {
        HStack(spacing: 14) {
            Button(action: player.togglePlay) {
                Circle()
                    .fill(.deep)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .offset(x: player.isPlaying ? 0 : 1)
                    }
            }
            .buttonStyle(.plain)
            .disabled(because: player.hasAudio ? nil : String(localized: "Không có audio để nghe."))
            .accessibilityLabel(player.isPlaying ? "Tạm dừng" : "Phát")

            Text(verbatim: "\(LangFormat.clock(player.currentTime)) / \(LangFormat.clock(player.duration))")
                .typeStyle(.monoBody)
                .foregroundStyle(.ink2)
                .monospacedDigit()
                .fixedSize()

            WaveformView(peaks: peaks, barOwners: barOwners, duration: player.duration,
                         progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                         markers: markers,
                         onSeek: { seconds in player.seek(to: seconds) })
                .frame(height: 44)
                .disabled(!player.hasAudio)

            Button {
                let speeds: [Float] = [1, 1.25, 1.5, 2]
                let next = speeds.firstIndex(of: player.rate).map { speeds[($0 + 1) % speeds.count] } ?? 1
                player.setRate(next)
            } label: {
                Text(verbatim: "\(player.rate == player.rate.rounded() ? String(Int(player.rate)) : String(player.rate))×")
                    .typeStyle(.ui(11, .medium))
                    .foregroundStyle(.deep)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.foam))
            }
            .buttonStyle(.plain)
            .disabled(because: player.hasAudio ? nil : String(localized: "Không có audio để nghe."))
            .help("Đổi tốc độ phát")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.96))
        .overlay(alignment: .top) { Hairline() }
        // Space and ←/→ work when the audio bar has focus (click it first), so typing in the chat is unaffected.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            player.togglePlay()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            player.skip(-10)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            player.skip(10)
            return .handled
        }
    }
}

/// ~110 rounded bars from real audio, colored by speaker (water = me, sandInk = others).
/// Played part at 90 %, unplayed at 35 %. Diamonds = decisions, moss dots = action items.
struct WaveformView: View {
    let peaks: [Float]
    let barOwners: [Bool]
    let duration: Double
    let progress: Double
    let markers: [WaveMarker]
    let onSeek: (Double) -> Void

    private let markerLane: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = max(0, proxy.size.height - markerLane)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let count = peaks.count
                    guard count > 0 else { return }
                    let step = size.width / CGFloat(count)
                    for i in 0..<count {
                        let mine = i < barOwners.count && barOwners[i]
                        let played = Double(i) / Double(count) < progress
                        let h = max(2, CGFloat(peaks[i]) * height)
                        let rect = CGRect(x: CGFloat(i) * step + (step - 2) / 2,
                                          y: markerLane + (height - h) / 2, width: 2, height: h)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1),
                                     with: .color((mine ? Color.water : Color.sandInk)
                                        .opacity(played ? 0.9 : 0.35)))
                    }
                    let playheadX = CGFloat(progress) * size.width
                    context.fill(Path(CGRect(x: playheadX - 1, y: markerLane, width: 2, height: height)),
                                 with: .color(.deep))
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    guard width > 0, duration > 0 else { return }
                    onSeek(Double(value.location.x / width) * duration)
                })

                ForEach(markers) { marker in
                    let x = duration > 0 ? CGFloat(marker.seconds / duration) * width : 0
                    markerView(marker)
                        .position(x: x, y: markerLane / 2)
                        .onTapGesture { onSeek(marker.seconds) }
                        .help(marker.label)
                }
            }
        }
    }

    @ViewBuilder private func markerView(_ marker: WaveMarker) -> some View {
        switch marker.kind {
        case .decision:
            Rectangle().fill(.deep).frame(width: 7, height: 7).rotationEffect(.degrees(45))
        case .action:
            Circle().fill(.moss).frame(width: 6, height: 6)
        }
    }
}

#if DEBUG
#Preview("Waveform") {
    WaveformView(peaks: (0..<110).map { Float(abs(sin(Double($0) / 5))) }, barOwners: [],
                 duration: 600, progress: 0.4,
                 markers: [WaveMarker(kind: .decision, seconds: 120, label: "Quyết định"),
                           WaveMarker(kind: .action, seconds: 300, label: "Việc")]) { _ in }
        .frame(width: 600, height: 44)
        .padding(20)
        .background(.white)
}
#endif
