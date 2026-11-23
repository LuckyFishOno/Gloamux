import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Terminal

/// Saved terminal recordings, with a player and export to asciinema's `.cast` format.
struct RecordingsView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var store: TerminalRecordings
    @State private var selection: URL?
    @State private var error: String?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(T("Recordings")).appFont(.headline)
                    InfoButton(T("Start recording from the Terminal menu or the command palette. Only what the terminal shows is recorded, never your keystrokes, and access tokens, private keys, and password values are replaced with [REDACTED]. Files use the asciinema format."))
                    Spacer()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([store.folder]) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help(T("Show in Finder"))
                        .disabled(!FileManager.default.fileExists(atPath: store.folder.path))
                }
                .padding(12)
                Divider()
                if store.saved.isEmpty {
                    ContentUnavailableView(T("No recordings"), systemImage: "record.circle", description: Text(T("Recordings you save appear here.")))
                } else {
                    List(store.saved, selection: $selection) { recording in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(recording.title).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(recording.date, format: .dateTime.month().day().hour().minute())
                                Text(formatDuration(recording.duration))
                                Text(ByteCountFormatter.string(fromByteCount: Int64(recording.size), countStyle: .file))
                            }
                            .appFont(.caption).foregroundStyle(.secondary)
                        }
                        .tag(recording.url)
                        .contextMenu {
                            Button(T("Export…")) { export(recording) }
                            Button(T("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([recording.url]) }
                            Divider()
                            Button(T("Move to Trash"), role: .destructive) { remove(recording) }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            Group {
                if let url = selection, let recording = store.saved.first(where: { $0.url == url }) {
                    RecordingPlayerView(model: model, recording: recording) { export(recording) }.id(url)
                } else {
                    ContentUnavailableView(T("Choose a recording"), systemImage: "play.rectangle")
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { store.reload(); if selection == nil { selection = store.saved.first?.url } }
        .alert(T("The recording could not be changed."), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(T("OK")) { error = nil }
        } message: { Text(error.map(T) ?? "") }
    }

    private func export(_ recording: TerminalRecordings.Recording) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = recording.url.lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: "cast") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: recording.url, to: url)
        } catch { self.error = error.localizedDescription }
    }

    private func remove(_ recording: TerminalRecordings.Recording) {
        do { try store.delete(recording); if selection == recording.url { selection = store.saved.first?.url } }
        catch { self.error = error.localizedDescription }
    }
}

/// Plays a recording in a terminal of the size it was recorded at.
@MainActor final class RecordingPlayer: ObservableObject {
    let tab = SessionTab()
    private(set) var header = Asciicast.Header()
    private var events: [Asciicast.Event] = []
    private var next = 0
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var playing = false
    @Published var speed = 1.0
    @Published private(set) var error: String?
    private var timer: Timer?
    var duration: TimeInterval { max(header.duration ?? 0, events.last?.time ?? 0) }

    init(url: URL) {
        do { (header, events) = try Asciicast.read(url) } catch { self.error = error.localizedDescription }
        reset()
    }

    private func reset() {
        var options = TerminalOptions(); options.rows = header.height; options.cols = header.width; options.scrollbackSize = 5000
        tab.screen = TerminalScreen(options: options)
        tab.screenRevision += 1
        next = 0; position = 0
    }

    /// Feeds events up to `time`, rebuilding the screen first when going back.
    func seek(_ time: TimeInterval) {
        let target = min(max(0, time), duration)
        if target < position { reset() }
        while next < events.count, events[next].time <= target {
            let event = events[next]
            if event.kind == "o" { tab.screen.feed(event.data) }
            else if event.kind == "r" {
                let size = event.data.split(separator: "x").compactMap { Int($0) }
                if size.count == 2 { tab.screen.resize(rows: min(200, max(5, size[1])), cols: min(400, max(20, size[0]))) }
            }
            next += 1
        }
        _ = tab.screen.takeEvents()
        position = target
        tab.screenRevision += 1
        if position >= duration { pause() }
    }

    func toggle() { playing ? pause() : play() }

    func play() {
        if position >= duration { reset() }
        playing = true
        var last = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playing else { return }
                let now = Date()
                // Long pauses in the recording are shortened to two seconds, as asciinema's player does.
                var step = now.timeIntervalSince(last) * self.speed
                last = now
                if self.next < self.events.count, self.events[self.next].time - self.position > 2 {
                    step = max(step, self.events[self.next].time - self.position - 2)
                }
                self.seek(self.position + step)
            }
        }
    }

    func pause() { playing = false; timer?.invalidate(); timer = nil }
}

private struct RecordingPlayerView: View {
    @ObservedObject var model: WorkspaceModel
    let recording: TerminalRecordings.Recording
    let export: () -> Void
    @StateObject private var player: RecordingPlayer

    init(model: WorkspaceModel, recording: TerminalRecordings.Recording, export: @escaping () -> Void) {
        self.model = model; self.recording = recording; self.export = export
        _player = StateObject(wrappedValue: RecordingPlayer(url: recording.url))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = player.error {
                ContentUnavailableView(T("The recording could not be read."), systemImage: "exclamationmark.triangle", description: Text(T(error)))
            } else {
                TerminalDisplay(tab: player.tab, model: model, resizes: false)
                    .background(model.theme.terminalBackground.color)
                Divider()
                HStack(spacing: 10) {
                    Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 18) }
                        .buttonStyle(.borderless).keyboardShortcut(.space, modifiers: [])
                        .help(T(player.playing ? "Pause" : "Play"))
                    Text(formatClock(player.position)).appFont(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(player.duration, 0.01))
                    Text(formatClock(player.duration)).appFont(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    AppPicker(T("Speed"), selection: $player.speed, current: "\(player.speed.formatted())×") {
                        ForEach([0.5, 1, 2, 4], id: \.self) { Text("\($0.formatted())×").tag($0) }
                    }
                    .labelsHidden()
                    Button(T("Export…"), action: export)
                }
                .padding(10)
            }
        }
        .onDisappear { player.pause() }
    }

    private func formatClock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
