import AVFoundation
import Observation
import SwiftUI

/// Everything the meeting detail screen shows, read from one meeting folder.
/// Edits (title, checked action items) are saved to summary.json and summary.md.
@MainActor
@Observable
final class MeetingDetailModel {
    let folder: URL
    @ObservationIgnored let player = MeetingViewerModel()

    private(set) var meta: MeetingMeta?
    private(set) var summary: MeetingSummary?
    private(set) var lines: [TranscriptLine] = []
    /// One loudness value (0…1) per waveform bar, from the real audio.
    private(set) var peaks: [Float] = []
    /// For each waveform bar: true if my (mic) voice is the one at that moment. Computed once.
    private(set) var barOwnersMe: [Bool] = []
    private(set) var errorMessage: String?

    init(folder: URL) {
        self.folder = folder
    }

    var startDate: Date { meta?.startTime ?? Date() }
    var duration: Double { meta?.durationSeconds ?? player.duration }
    var hasSummary: Bool { summary != nil }
    var hasContent: Bool { summary != nil || !lines.isEmpty }
    var actionItems: [ActionItem] { summary?.actionItems ?? [] }

    /// Same rules as the sidebar: summary title, imported file name, or "Cuộc họp 14:08".
    var title: String {
        if let title = summary?.title, !title.isEmpty { return title }
        if let source = meta?.sourceFile {
            return URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
        }
        return String(localized: "Cuộc họp \(LangFormat.time(startDate))")
    }

    var speakerCount: Int { Set(lines.map(\.speaker)).count }

    /// The transcript was saved after the summary, so the summary may not match it any more.
    var summaryIsStale: Bool {
        let fm = FileManager.default
        guard hasSummary,
              let summaryDate = try? fm.attributesOfItem(atPath: folder.appending(path: SummaryWriter.jsonFileName).path)[.modificationDate] as? Date,
              let transcriptDate = try? fm.attributesOfItem(atPath: folder.appending(path: TranscriptWriter.jsonFileName).path)[.modificationDate] as? Date
        else { return false }
        return transcriptDate > summaryDate
    }

    /// Share of talking time that is mine (mic track), 0…1. Nil without a transcript.
    var meShare: Double? {
        let total = lines.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        guard total > 0 else { return nil }
        let mine = lines.filter { $0.track == .mic }.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        return mine / total
    }

    var info: MeetingInfo {
        MeetingInfo(folder: folder, date: startDate, title: title, duration: duration, status: meta?.status,
                    hasTranscript: FileManager.default.fileExists(
                        atPath: folder.appending(path: TranscriptWriter.markdownFileName).path),
                    hasSummary: FileManager.default.fileExists(
                        atPath: folder.appending(path: SummaryWriter.markdownFileName).path))
    }

    func load() async {
        meta = try? MeetingMeta.load(from: folder)
        summary = (try? Data(contentsOf: folder.appending(path: SummaryWriter.jsonFileName)))
            .flatMap { try? JSONDecoder().decode(MeetingSummary.self, from: $0) }
        lines = (try? Data(contentsOf: folder.appending(path: TranscriptWriter.jsonFileName)))
            .flatMap { try? JSONDecoder().decode([TranscriptLine].self, from: $0) } ?? []
        let files = audioFiles()
        peaks = await Task.detached(priority: .utility) { WaveformPeaks.compute(files: files, bars: 110) }.value
        let total = max(duration, 1)
        barOwnersMe = (0..<peaks.count).map { i in
            let t = (Double(i) + 0.5) / Double(peaks.count) * total
            return lines.first { $0.start <= t && t < $0.end }?.track == .mic
        }
        await player.load(MeetingRef(folderPath: folder.path, time: 0))
        player.seek(to: 0, play: false) // opening a meeting should not start playing
    }

    /// Replaces one transcript line's text and saves transcript.json and transcript.md.
    /// The summary is not regenerated; re-summarize to refresh it.
    func editLine(_ index: Int, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lines.indices.contains(index), !trimmed.isEmpty, let meta else { return }
        lines[index].text = trimmed
        do {
            try TranscriptWriter.write(lines, meetingStart: meta.startTime, duration: meta.durationSeconds,
                                       projectName: URL(fileURLWithPath: meta.projectPath).lastPathComponent,
                                       to: folder)
        } catch {
            errorMessage = String(localized: "Không lưu được bản chép lời: \(error.localizedDescription)")
        }
    }

    /// Renames the meeting (summary.json title). Empty names are ignored.
    func setTitle(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate { $0.title = trimmed }
    }

    /// Checks or unchecks action item `index` and saves it.
    func setDone(_ index: Int, _ value: Bool) {
        mutate { summary in
            guard summary.actionItems.indices.contains(index) else { return }
            summary.actionItems[index].done = value
        }
    }

    func markdownForExport() throws -> String {
        try MeetingLibrary.exportMarkdown(info)
    }

    var exportFileName: String { MeetingLibrary.exportFileName(info) }

    private func mutate(_ change: (inout MeetingSummary) -> Void) {
        guard var updated = summary, let meta else { return }
        change(&updated)
        do {
            _ = try SummaryWriter.write(updated, meetingStart: meta.startTime, duration: meta.durationSeconds,
                                        projectName: URL(fileURLWithPath: meta.projectPath).lastPathComponent,
                                        language: AppSettings.summaryLanguage, to: folder)
            summary = updated
        } catch {
            errorMessage = String(localized: "Không lưu được: \(error.localizedDescription)")
        }
    }

    private func audioFiles() -> [URL] {
        [meta?.micFile, meta?.systemFile, meta?.audioFile].compactMap { $0 }
            .map { folder.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Reads the real audio and keeps the loudest value of each bar.
enum WaveformPeaks {
    static func compute(files: [URL], bars: Int) -> [Float] {
        var result = [Float](repeating: 0, count: bars)
        for url in files {
            guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { continue }
            let total = Double(file.length)
            let format = file.processingFormat
            let chunk: AVAudioFrameCount = 1 << 16
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { continue }
            var position = 0.0
            while position < total {
                do { try file.read(into: buffer, frameCount: chunk) } catch { break }
                let frames = Int(buffer.frameLength)
                if frames == 0 { break }
                guard let data = buffer.floatChannelData else { break }
                let channels = Int(format.channelCount)
                for i in 0..<frames {
                    var peak: Float = 0
                    for c in 0..<channels { peak = max(peak, abs(data[c][i])) }
                    let bar = min(bars - 1, Int((position + Double(i)) / total * Double(bars)))
                    result[bar] = max(result[bar], peak)
                }
                position += Double(frames)
            }
        }
        let loudest = result.max() ?? 0
        return loudest > 0 ? result.map { $0 / loudest } : result
    }
}
