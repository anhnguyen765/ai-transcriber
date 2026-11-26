import AppKit
import Foundation
import IOKit.ps
import ServiceManagement
import SwiftUI

// MARK: - Launch at login

/// Starts lắng when you log in (SMAppService). Only works reliably for the copy in /Applications,
/// so a build running from Xcode's DerivedData is never registered automatically.
@MainActor
enum LaunchAtLogin {
    static let key = "launchAtLogin"

    static var isInstalledInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    /// The setting (default on).
    static var wanted: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// Called at launch: makes the login item match the setting.
    static func applySetting() {
        guard isInstalledInApplications else { return }
        set(wanted)
    }

    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled, status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Settings rows for launch at login.
struct LaunchAtLoginSettings: View {
    @AppStorage(LaunchAtLogin.key) private var enabled = true
    @State private var message: String?
    @State private var status = LaunchAtLogin.status

    var body: some View {
        Toggle("Open lắng at login", isOn: $enabled)
            .onChange(of: enabled) {
                message = LaunchAtLogin.isInstalledInApplications ? LaunchAtLogin.set(enabled) : nil
                status = LaunchAtLogin.status
            }
        if !LaunchAtLogin.isInstalledInApplications {
            Text("Works only for the copy of lắng in /Applications (this one runs from \(Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent)).")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if status == .requiresApproval {
            HStack {
                Text("macOS needs your approval in Login Items.").font(.caption).foregroundStyle(.orange)
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
            }
        }
        if let message {
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }
}

// MARK: - Crash recovery

struct StuckMeeting: Equatable {
    let folder: URL
    let status: MeetingMeta.Status
}

/// Finds meetings left "recording"/"transcribing"/"summarizing" by a crash or force quit.
enum CrashRecovery {
    static let stuckStatuses: Set<MeetingMeta.Status> = [.recording, .transcribing, .summarizing]

    /// Call at launch, before any new work starts (then nothing can legitimately be in progress).
    static func findStuck(projectFolder: URL) -> [StuckMeeting] {
        let root = projectFolder.appending(path: ".meetings", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let meta = try? MeetingMeta.load(from: folder), let status = meta.status,
                  stuckStatuses.contains(status) else { return nil }
            return StuckMeeting(folder: folder, status: status)
        }
        .sorted { $0.folder.lastPathComponent < $1.folder.lastPathComponent }
    }

    /// Converts a crashed recording's CAF files to m4a and marks it "recorded".
    @discardableResult
    static func recoverRecording(_ folder: URL) async -> Bool {
        guard var meta = try? MeetingMeta.load(from: folder) else { return false }
        let saved = await RecordingFiles.finalize(folder: folder)
        let seconds = saved.mic ?? saved.system
        let hasAudio = [Recorder.micFileName, Recorder.systemFileName]
            .contains { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
        meta.durationSeconds = ((seconds ?? meta.durationSeconds) * 10).rounded() / 10
        meta.status = hasAudio ? .recorded : .failed
        meta.error = hasAudio
            ? "Recovered after lắng quit unexpectedly while recording."
            : "lắng quit while recording and no audio could be recovered."
        try? meta.save(to: folder)
        Log.info("Recovered \(folder.lastPathComponent): \(seconds ?? 0) s, problems: \(saved.problems)")
        return hasAudio
    }

    /// "Để sau": leave the meeting in a normal state the Meetings window can retry.
    static func markForLater(_ meeting: StuckMeeting) {
        guard var meta = try? MeetingMeta.load(from: meeting.folder) else { return }
        switch meeting.status {
        case .transcribing:
            meta.status = .failed
            meta.error = "Interrupted: lắng quit during transcription. Use Re-transcribe."
        case .summarizing:
            meta.status = .summaryFailed
            meta.summaryError = "Interrupted: lắng quit while summarizing. Use Summarize again."
        default:
            break // recordings were already recovered to "recorded"
        }
        try? meta.save(to: meeting.folder)
    }
}

// MARK: - Power: pause background indexing on low battery / Low Power Mode

enum PowerState {
    /// Why background work should wait right now, or nil.
    static func pauseReason() -> String? {
        let battery = batteryStatus()
        return pauseReason(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                           onBattery: battery?.onBattery ?? false, percent: battery?.percent ?? 100)
    }

    static func pauseReason(lowPowerMode: Bool, onBattery: Bool, percent: Int) -> String? {
        if lowPowerMode { return "Low Power Mode" }
        if onBattery, percent < 20 { return "pin dưới 20%" }
        return nil
    }

    /// The internal battery's state (nil on a Mac without one).
    static func batteryStatus() -> (onBattery: Bool, percent: Int)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return (onBattery, current * 100 / max)
        }
        return nil
    }
}

// MARK: - Storage

/// Sizes on disk, and cleaning up old audio.
enum StorageReport {
    struct AudioFile: Equatable {
        let url: URL
        let meetingDate: Date
        let size: Int64
        /// Audio is only deleted for meetings that already have a transcript.
        let hasTranscript: Bool
    }

    static var ollamaModelsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ollama/models", directoryHint: .isDirectory)
    }

    static func folderSize(_ url: URL, where include: (URL) -> Bool = { _ in true }) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker where include(file) {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    static let audioExtensions: Set<String> = ["m4a", "caf"]

    /// Every audio file in <project>/.meetings/<timestamp>/.
    static func audioFiles(projectFolder: URL) -> [AudioFile] {
        let root = projectFolder.appending(path: ".meetings", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.flatMap { folder -> [AudioFile] in
            guard let date = ProjectScanner.meetingDate(folder.lastPathComponent) else { return [] }
            let transcript = FileManager.default.fileExists(atPath: folder.appending(path: TranscriptWriter.markdownFileName).path)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
            return files.filter { audioExtensions.contains($0.pathExtension.lowercased()) }.map { url in
                let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
                return AudioFile(url: url, meetingDate: date, size: Int64(size), hasTranscript: transcript)
            }
        }
    }

    /// Audio older than `days` from meetings that were transcribed (never the only copy of a meeting's words).
    static func oldAudio(_ files: [AudioFile], olderThanDays days: Int, now: Date = Date()) -> [AudioFile] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return files.filter { $0.hasTranscript && $0.meetingDate < cutoff }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Settings → Storage & logs.
struct StorageSettings: View {
    let projectFolder: URL?
    @State private var audio: Int64?
    @State private var models: Int64?
    @State private var ollama: Int64?
    @State private var indexes: Int64?
    @State private var candidates: [StorageReport.AudioFile] = []
    @State private var confirmDelete = false
    @State private var message: String?

    var body: some View {
        LabeledContent("Audio of this project", value: audio.map(StorageReport.format) ?? "…")
        LabeledContent("Whisper models", value: models.map(StorageReport.format) ?? "…")
        LabeledContent("Ollama models", value: ollama.map(StorageReport.format) ?? "…")
        LabeledContent("Project indexes", value: indexes.map(StorageReport.format) ?? "…")
        Button("Delete audio older than 30 days…") { confirmDelete = true }
            .disabled(candidates.isEmpty)
            .help(candidates.isEmpty ? "No transcribed meeting older than 30 days has audio." : "")
            .confirmationDialog("Move \(candidates.count) audio files (\(StorageReport.format(candidates.reduce(0) { $0 + $1.size }))) to the Trash?",
                                isPresented: $confirmDelete) {
                Button("Move to Trash", role: .destructive) { deleteOld() }
            } message: {
                Text("Only audio of meetings older than 30 days that already have a transcript. Transcripts and summaries stay.")
            }
        HStack {
            Button("Copy log") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Log.recentText(), forType: .string)
                message = "Log copied."
            }
            Button("Show Logs Folder") {
                try? FileManager.default.createDirectory(at: Log.folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(Log.folder)
            }
        }
        if let message {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        Color.clear.frame(height: 0).task(id: projectFolder) { await refresh() }
    }

    private func refresh() async {
        let project = projectFolder
        let result = await Task.detached(priority: .utility) {
            let files = project.map(StorageReport.audioFiles) ?? []
            return (files.reduce(Int64(0)) { $0 + $1.size },
                    StorageReport.folderSize(WhisperKitEngine.modelsFolder),
                    StorageReport.folderSize(StorageReport.ollamaModelsFolder),
                    StorageReport.folderSize(IndexStore.folder),
                    StorageReport.oldAudio(files, olderThanDays: 30))
        }.value
        (audio, models, ollama, indexes, candidates) = result
    }

    private func deleteOld() {
        var moved = 0
        for file in candidates where (try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)) != nil {
            moved += 1
        }
        Log.info("Moved \(moved) old audio files to the Trash")
        message = "Moved \(moved) audio files to the Trash."
        Task { await refresh() }
    }
}
