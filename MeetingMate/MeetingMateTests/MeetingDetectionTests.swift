import Foundation
import Testing
@testable import MeetingMate

struct MeetingDetectionTests {
    private let zoom = CallApps.classify(AudioInputProcess(pid: 1, bundleID: "us.zoom.xos"))!
    private let chromeHelper = CallApps.classify(AudioInputProcess(pid: 2, bundleID: "com.google.Chrome.helper"))!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func classifiesCallAppsAndBrowsers() {
        #expect(zoom.name == "Zoom" && !zoom.isBrowser && zoom.appBundleID == "us.zoom.xos")
        #expect(chromeHelper.isBrowser && chromeHelper.appBundleID == "com.google.Chrome")
        #expect(chromeHelper.name.contains("Google Meet"))
        #expect(CallApps.classify(AudioInputProcess(pid: 3, bundleID: "com.microsoft.teams2"))?.name == "Microsoft Teams")
        #expect(CallApps.classify(AudioInputProcess(pid: 4, bundleID: "com.apple.WebKit.GPU"))?.appBundleID == "com.apple.Safari")
        #expect(CallApps.classify(AudioInputProcess(pid: 5, bundleID: "com.apple.VoiceMemos")) == nil)
    }

    @Test func suggestsRecordingOnceThenWaitsTenMinutes() {
        var logic = MeetingDetectionLogic()
        #expect(logic.update(calls: [zoom], recording: false, now: t0) == [.suggestRecording(zoom)])
        #expect(logic.update(calls: [zoom], recording: false, now: t0.addingTimeInterval(2)).isEmpty)
        #expect(logic.update(calls: [zoom], recording: false, now: t0.addingTimeInterval(9 * 60)).isEmpty)
        #expect(logic.update(calls: [zoom], recording: false, now: t0.addingTimeInterval(10 * 60 + 1))
                == [.suggestRecording(zoom)])
    }

    @Test func noSuggestionWhileRecordingOrWithoutACall() {
        var logic = MeetingDetectionLogic()
        #expect(logic.update(calls: [], recording: false, now: t0).isEmpty)
        #expect(logic.update(calls: [zoom], recording: true, now: t0).isEmpty)
    }

    @Test func asksToStopAfterTheCallReleasesTheMic() {
        var logic = MeetingDetectionLogic()
        _ = logic.update(calls: [chromeHelper], recording: true, now: t0)
        #expect(logic.update(calls: [], recording: true, now: t0.addingTimeInterval(10)).isEmpty) // short gap
        #expect(logic.update(calls: [], recording: true, now: t0.addingTimeInterval(40)).isEmpty)
        #expect(logic.update(calls: [], recording: true, now: t0.addingTimeInterval(56))
                == [.suggestStopping(appName: chromeHelper.name)])
        #expect(logic.update(calls: [], recording: true, now: t0.addingTimeInterval(200)).isEmpty) // only once
    }

    @Test func asksToStopRightAwayWhenTheCallAppQuits() {
        var logic = MeetingDetectionLogic()
        _ = logic.update(calls: [zoom], recording: true, now: t0)
        #expect(logic.appTerminated(bundleID: "com.apple.Notes", recording: true).isEmpty)
        #expect(logic.appTerminated(bundleID: "us.zoom.xos", recording: true) == [.suggestStopping(appName: "Zoom")])
        #expect(logic.appTerminated(bundleID: "us.zoom.xos", recording: true).isEmpty)
    }

    @Test func recordingWithoutAnyCallNeverAsksToStop() {
        var logic = MeetingDetectionLogic()
        #expect(logic.update(calls: [], recording: true, now: t0).isEmpty)
        #expect(logic.update(calls: [], recording: true, now: t0.addingTimeInterval(600)).isEmpty)
    }
}
