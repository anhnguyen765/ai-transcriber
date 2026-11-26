import AppKit
import CoreAudio
import UserNotifications

// MARK: - Which apps are using the microphone (Core Audio, macOS 14.2+)

struct AudioInputProcess: Equatable {
    let pid: pid_t
    let bundleID: String
}

enum CoreAudioProcesses {
    /// Processes (other than lắng) whose audio input is running right now.
    static func usingMicrophone() -> [AudioInputProcess] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        let me = ProcessInfo.processInfo.processIdentifier
        return ids.compactMap { id in
            guard uint32(id, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            let pid = pid_t(bitPattern: uint32(id, kAudioProcessPropertyPID) ?? 0)
            guard pid != me else { return nil }
            let bundle = string(id, kAudioProcessPropertyBundleID)
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                ?? ""
            return AudioInputProcess(pid: pid, bundleID: bundle)
        }
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?, !string.isEmpty else { return nil }
        return string
    }
}

// MARK: - Which of those look like a call

struct DetectedCall: Equatable {
    let bundleID: String
    /// "Zoom", "Google Chrome (có thể là Google Meet)"…
    let name: String
    let isBrowser: Bool

    /// The app's own bundle id (helper processes like "com.google.Chrome.helper" → "com.google.Chrome").
    let appBundleID: String
}

enum CallApps {
    static let meetingApps: [(prefix: String, name: String)] = [
        ("us.zoom.", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.webex.", "Webex"),
        ("com.cisco.webex", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.hnc.Discord", "Discord"),
        ("com.vng.zalo", "Zalo"),
        ("com.microsoft.SkypeForBusiness", "Skype"),
    ]
    static let browsers: [(prefix: String, name: String)] = [
        ("com.google.Chrome", "Google Chrome"),
        ("com.apple.Safari", "Safari"),
        ("com.apple.WebKit.GPU", "Safari"), // Safari captures the mic in its GPU process
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("company.thebrowser.Browser", "Arc"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.brave.Browser", "Brave"),
        ("com.operasoftware.Opera", "Opera"),
        ("com.vivaldi.Vivaldi", "Vivaldi"),
    ]

    static func classify(_ process: AudioInputProcess) -> DetectedCall? {
        if let app = meetingApps.first(where: { process.bundleID.hasPrefix($0.prefix) }) {
            return DetectedCall(bundleID: process.bundleID, name: app.name, isBrowser: false,
                                appBundleID: appID(process.bundleID, prefix: app.prefix))
        }
        if let browser = browsers.first(where: { process.bundleID.hasPrefix($0.prefix) }) {
            let appID = browser.prefix == "com.apple.WebKit.GPU" ? "com.apple.Safari" : browser.prefix
            return DetectedCall(bundleID: process.bundleID, name: "\(browser.name) (có thể là Google Meet)",
                                isBrowser: true, appBundleID: appID)
        }
        return nil
    }

    private static func appID(_ bundleID: String, prefix: String) -> String {
        prefix.hasSuffix(".") ? bundleID.components(separatedBy: ".").prefix(3).joined(separator: ".") : prefix
    }
}

// MARK: - Decisions (pure logic, unit-tested)

/// Decides when to suggest recording and when to suggest stopping. Never starts recording itself.
struct MeetingDetectionLogic {
    enum Event: Equatable {
        case suggestRecording(DetectedCall)
        case suggestStopping(appName: String)
    }

    static let cooldown: TimeInterval = 10 * 60
    /// The call app must stop using the mic this long before we ask "Dừng ghi?".
    static let silenceBeforeStopPrompt: TimeInterval = 45

    private(set) var lastSuggestion: Date?
    private var callDuringRecording: DetectedCall?
    private var silentSince: Date?
    private var askedToStop = false

    mutating func update(calls: [DetectedCall], recording: Bool, now: Date) -> [Event] {
        if recording {
            if let call = calls.first {
                callDuringRecording = call
                silentSince = nil
            } else if let call = callDuringRecording, !askedToStop {
                let since = silentSince ?? now
                silentSince = since
                if now.timeIntervalSince(since) >= Self.silenceBeforeStopPrompt {
                    askedToStop = true
                    return [.suggestStopping(appName: call.name)]
                }
            }
            return []
        }

        // Not recording: forget the last recording's call, maybe suggest recording.
        callDuringRecording = nil
        silentSince = nil
        askedToStop = false
        guard let call = calls.first else { return [] }
        if let last = lastSuggestion, now.timeIntervalSince(last) < Self.cooldown { return [] }
        lastSuggestion = now
        return [.suggestRecording(call)]
    }

    /// The call app quit while recording → ask right away (once).
    mutating func appTerminated(bundleID: String, recording: Bool) -> [Event] {
        guard recording, let call = callDuringRecording, !askedToStop,
              bundleID == call.appBundleID || bundleID.hasPrefix(call.appBundleID) else { return [] }
        askedToStop = true
        return [.suggestStopping(appName: call.name)]
    }
}

// MARK: - Detector (polls Core Audio every 2 s while enabled)

@MainActor
final class MeetingDetector {
    static let recordCategory = "MEETING_DETECTED"
    static let stopCategory = "STOP_RECORDING"
    static let recordAction = "RECORD"
    static let stopAction = "STOP"

    var isRecording: () -> Bool = { false }

    private var logic = MeetingDetectionLogic()
    private var timer: Timer?
    private var terminationObserver: NSObjectProtocol?

    /// Registers the notification buttons ("Ghi âm", "Dừng ghi").
    static func registerNotificationCategories() {
        let record = UNNotificationAction(identifier: recordAction, title: "Ghi âm", options: [])
        let stop = UNNotificationAction(identifier: stopAction, title: "Dừng ghi", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: recordCategory, actions: [record], intentIdentifiers: []),
            UNNotificationCategory(identifier: stopCategory, actions: [stop], intentIdentifiers: []),
        ])
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let bundleID = app?.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handle(self.logic.appTerminated(bundleID: bundleID, recording: self.isRecording()))
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        terminationObserver = nil
    }

    private func tick() {
        guard AppSettings.meetingDetection else { return }
        let calls = CoreAudioProcesses.usingMicrophone().compactMap(CallApps.classify)
        handle(logic.update(calls: calls, recording: isRecording(), now: Date()))
    }

    private func handle(_ events: [MeetingDetectionLogic.Event]) {
        for event in events {
            switch event {
            case .suggestRecording(let call):
                Log.info("Meeting detected: \(call.bundleID)")
                Notifier.post(title: "Có vẻ bạn đang họp. Ghi lại không?",
                              body: "\(call.name) đang dùng micro.",
                              category: Self.recordCategory, id: "meeting-detected")
            case .suggestStopping(let name):
                Log.info("Call ended in \(name) while recording")
                Notifier.post(title: "Dừng ghi?", body: "Cuộc gọi trên \(name) có vẻ đã kết thúc.",
                              category: Self.stopCategory, id: "stop-recording")
            }
        }
    }
}
