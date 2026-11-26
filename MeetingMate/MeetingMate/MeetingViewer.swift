import AVFoundation
import SwiftUI

/// Loads a meeting and plays its audio (mic + system mixed) from a timestamp.
@MainActor
final class MeetingViewerModel: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var subtitle = ""
    @Published private(set) var lines: [TranscriptLine] = []
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var hasAudio = false
    @Published private(set) var message: String?
    /// The line to scroll to (set when jumping, not on every tick).
    @Published var jumpTarget: Int?

    private(set) var folder: URL?
    private var player: AVPlayer?
    private var timeObserver: Any?

    /// Index of the line being played (or the line at the start time).
    var currentLine: Int? {
        lines.lastIndex { $0.start <= currentTime + 0.25 }
    }

    func load(_ ref: MeetingRef) async {
        stop()
        let folder = URL(fileURLWithPath: ref.folderPath)
        self.folder = folder
        let meta = try? MeetingMeta.load(from: folder)
        let summary = (try? Data(contentsOf: folder.appending(path: SummaryWriter.jsonFileName)))
            .flatMap { try? JSONDecoder().decode(MeetingSummary.self, from: $0) }
        title = summary?.title ?? folder.lastPathComponent
        if let meta {
            let f = DateFormatter()
            f.locale = Locale(identifier: "vi_VN")
            f.dateFormat = "dd/MM/yyyy HH:mm"
            subtitle = "\(f.string(from: meta.startTime)) · \(TranscriptWriter.formatDuration(meta.durationSeconds))"
            duration = meta.durationSeconds
        }

        if let data = try? Data(contentsOf: folder.appending(path: TranscriptWriter.jsonFileName)),
           let decoded = try? JSONDecoder().decode([TranscriptLine].self, from: data) {
            lines = decoded
        } else {
            lines = []
            message = "Cuộc họp này chưa có transcript."
        }

        // Audio: mic + system played together (or the imported audio.m4a).
        let names = [meta?.micFile, meta?.systemFile, meta?.audioFile].compactMap { $0 }
        let urls = names.map { folder.appending(path: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let item = await Self.mixedItem(urls) {
            let player = AVPlayer(playerItem: item)
            self.player = player
            hasAudio = true
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    self?.currentTime = time.seconds
                    self?.isPlaying = player.rate > 0
                }
            }
            if duration == 0, let seconds = try? await item.asset.load(.duration).seconds { duration = seconds }
        } else {
            hasAudio = false
            if message == nil { message = "Không có audio (có thể đã bị xóa). Vẫn xem được transcript." }
        }

        seek(to: ref.time, play: hasAudio)
    }

    /// Several audio files laid on top of each other from time zero, so they play mixed.
    private static func mixedItem(_ urls: [URL]) async -> AVPlayerItem? {
        let composition = AVMutableComposition()
        var added = 0
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let length = try? await asset.load(.duration),
                  let target = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            do {
                try target.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: .zero)
                added += 1
            } catch {
                composition.removeTrack(target)
            }
        }
        return added > 0 ? AVPlayerItem(asset: composition) : nil
    }

    func seek(to seconds: Double, play: Bool? = nil) {
        currentTime = max(0, seconds)
        jumpTarget = currentLine
        guard let player else { return }
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        if play == true { player.play() }
        if play == false { player.pause() }
    }

    func togglePlay() {
        guard let player else { return }
        player.rate > 0 ? player.pause() : player.play()
        isPlaying = player.rate > 0
    }

    func skip(_ seconds: Double) {
        seek(to: min(max(0, currentTime + seconds), max(duration, currentTime)))
    }

    func stop() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player = nil
        isPlaying = false
        hasAudio = false
        message = nil
    }
}

/// Small meeting viewer: transcript scrolled to the cited moment + mini audio player.
struct MeetingViewer: View {
    let ref: MeetingRef
    @StateObject private var model = MeetingViewerModel()
    @State private var follow = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.hasAudio { player.padding(10); Divider() }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary).padding(10)
            }
            transcript
        }
        .frame(minWidth: 560, minHeight: 480)
        .task(id: ref) { await model.load(ref) }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.headline).lineLimit(1)
                Text(model.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let folder = model.folder {
                Button("Summary") { NSWorkspace.shared.open(folder.appending(path: SummaryWriter.markdownFileName)) }
                    .disabled(!FileManager.default.fileExists(atPath: folder.appending(path: SummaryWriter.markdownFileName).path))
                Button("Folder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
        }
        .controlSize(.small)
        .padding(10)
    }

    private var player: some View {
        HStack(spacing: 10) {
            Button { model.skip(-15) } label: { Image(systemName: "gobackward.15") }
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            Button { model.skip(15) } label: { Image(systemName: "goforward.15") }
            Text(TranscriptWriter.timestamp(model.currentTime)).monospacedDigit().font(.caption)
            Slider(value: Binding(get: { model.currentTime }, set: { model.seek(to: $0) }),
                   in: 0...max(model.duration, 1))
            Text(TranscriptWriter.timestamp(model.duration)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
            Toggle("Theo dõi", isOn: $follow).toggleStyle(.checkbox).controlSize(.small)
                .help("Tự cuộn theo đoạn đang phát")
        }
        .buttonStyle(.borderless)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            List(Array(model.lines.enumerated()), id: \.offset) { index, line in
                Button { model.seek(to: line.start, play: true) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(TranscriptWriter.timestamp(line.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.speaker).font(.caption.weight(.semibold))
                                .foregroundStyle(line.track == .mic ? Color.accentColor : .orange)
                            Text(line.text).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .listRowBackground(index == model.currentLine ? Color.accentColor.opacity(0.15) : nil)
                .id(index)
            }
            .onChange(of: model.jumpTarget) {
                if let target = model.jumpTarget { withAnimation { proxy.scrollTo(target, anchor: .center) } }
            }
            .onChange(of: model.currentLine) {
                if follow, model.isPlaying, let line = model.currentLine { proxy.scrollTo(line, anchor: .center) }
            }
        }
    }
}
