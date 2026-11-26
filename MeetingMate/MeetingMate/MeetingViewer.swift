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
    /// Playback speed (1, 1.25, 1.5, 2). Applies to the next play as well.
    @Published private(set) var rate: Float = 1

    private(set) var folder: URL?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

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
            // When the recording ends: pause and go back to the start, ready to play again.
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishPlayback() }
            }
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

    private func finishPlayback() {
        player?.pause()
        player?.seek(to: .zero)
        currentTime = 0
        isPlaying = false
    }

    func setRate(_ value: Float) {
        rate = value
        player?.defaultRate = value
        if let player, player.rate > 0 { player.rate = value }
    }

    func skip(_ seconds: Double) {
        seek(to: min(max(0, currentTime + seconds), max(duration, currentTime)))
    }

    func stop() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player = nil
        isPlaying = false
        hasAudio = false
        message = nil
    }
}
