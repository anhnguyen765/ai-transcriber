import SwiftUI

/// RippleView + RecordButton wired to the real recorder and its live audio levels.
/// Small on purpose: it redraws ~30×/s while recording, nothing else around it does.
struct RecorderRipple: View {
    @ObservedObject var recorder: Recorder
    /// Why recording can't start right now (e.g. no project folder), or nil.
    var disabledReason: String?
    var size: CGFloat = 196
    let toggle: () -> Void

    var body: some View {
        let levels = recorder.levels
        RippleView(phase: recorder.isRecording ? .recording : .idle,
                   micLevel: levels.mic, systemLevel: levels.system, size: size) {
            RecordButton(isRecording: recorder.isRecording || recorder.state == .stopping,
                         isBusy: recorder.state == .starting || recorder.state == .stopping,
                         disabledReason: recorder.isRecording ? nil : disabledReason,
                         diameter: size * 0.36,
                         action: toggle)
        }
    }
}
