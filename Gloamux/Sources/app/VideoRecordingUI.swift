import AppKit
import SwiftUI

extension WorkspaceModel {
    /// Starts or stops the video of this workspace window, from the toolbar, the Terminal menu, or the palette.
    func toggleWindowVideo() {
        if videos.active != nil {
            videos.stop()
            return
        }
        guard let window = workspaceWindow else { return }
        guard VideoRecordings.acknowledged else { confirmWindowVideo(window); return }
        guard VideoRecordings.hasPermission else { askForScreenRecording(window); return }
        Task { await startWindowVideo(window) }
    }

    func startWindowVideo(_ window: NSWindow) async {
        objectWillChange.send()
        do { try await videos.start(window: window) } catch { self.error = error.localizedDescription }
        objectWillChange.send()
    }

    /// Asked once: a video shows everything in the window, with nothing masked.
    private func confirmWindowVideo(_ window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = T("Record a video of this window?")
        alert.informativeText = T(Self.videoWarning)
        alert.addButton(withTitle: T("Record"))
        alert.addButton(withTitle: T("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            VideoRecordings.acknowledged = true
            // On the next turn, once the alert has left the window, so it is not in the video.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.toggleWindowVideo() } }
        }
    }

    static let videoWarning = "The video shows everything this window shows while it records: terminal output, file lists and paths, and commands in the Session Log. Nothing is masked. It pauses while a sheet such as a password prompt is open and while the window is in the Dock. Videos are saved in Downloads, or the folder chosen in Settings › General, readable only by your account."

    private func askForScreenRecording(_ window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = T("Allow screen recording")
        alert.informativeText = T("macOS asks before an app records a window. Turn on Gloamux in System Settings › Privacy & Security › Screen & System Audio Recording, then record again. macOS may ask you to reopen Gloamux.")
        alert.addButton(withTitle: T("Open System Settings"))
        alert.addButton(withTitle: T("Cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            // Puts Gloamux in the list in System Settings, where it can be turned on.
            _ = CGRequestScreenCaptureAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Stops this window's video, if one is running, and waits until its file is finished.
    func finishVideo(reason: VideoStopReason) async {
        guard videos.active != nil else { return }
        _ = await videos.stop(reason: reason).value
    }

    func videoFinished(_ result: VideoStopResult, reason: VideoStopReason) {
        objectWillChange.send()
        switch result {
        case .saved(let url):
            if reason != .quit, reason != .windowClosed { recordingSaved = url }
            if let notice = reason.notice { error = notice }
        case .failed(let message):
            error = message
        case .nothingRecorded:
            if let notice = reason.notice { error = notice }
        }
    }
}

/// The toolbar's video button: a record symbol, or while recording a red dot and the time, which stops it.
struct VideoRecordButton: View {
    @ObservedObject var videos: VideoRecordings
    let toggle: () -> Void

    var body: some View {
        if let recorder = videos.active {
            RecordingVideoButton(recorder: recorder, stop: toggle)
        } else {
            Button(action: toggle) { Label(T("Record window video"), systemImage: "record.circle") }
                .help(T("Record window video"))
                .accessibilityIdentifier("videoRecordButton")
        }
    }
}

private struct RecordingVideoButton: View {
    @ObservedObject var recorder: WindowVideoRecorder
    let stop: () -> Void

    var body: some View {
        Button(action: stop) {
            HStack(spacing: 5) {
                Image(systemName: recorder.paused ? "pause.circle.fill" : "record.circle.fill")
                    .foregroundStyle(recorder.paused ? Color.orange : Color.red)
                Text(VideoRecordButton.clock(recorder.elapsed)).monospacedDigit()
            }
        }
        .help(T(recorder.paused ? "Video paused while a sheet is open or the window is in the Dock. Click to stop." : "Recording this window. Click to stop."))
        .accessibilityLabel(T("Stop window video"))
        .accessibilityValue(VideoRecordButton.clock(recorder.elapsed))
        .accessibilityIdentifier("videoRecordButton")
    }
}

extension VideoRecordButton {
    /// "0:42", or "1:02:03" past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}
