import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import Terminal

/// Saved terminal text recordings, with a player and export to asciinema's `.cast` format, and window videos.
struct RecordingsView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var store: TerminalRecordings
    @ObservedObject var videos: VideoRecordings
    @State private var selection: URL?
    @State private var error: String?
    @State private var confirmClear = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(T("Recordings")).appFont(.headline)
                    InfoButton(T("Terminal text recordings start from the Terminal menu or the command palette. Only what the terminal shows is recorded, never your keystrokes, and access tokens, private keys, and password values are replaced with [REDACTED]. Files use the asciinema format.\n\nWindow videos record the whole workspace window as a video file, without sound. Nothing in them is masked."))
                    Spacer()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([shownFolder]) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help(T("Show in Finder"))
                        .disabled(!FileManager.default.fileExists(atPath: shownFolder.path))
                }
                .padding(12)
                Divider()
                List(selection: $selection) {
                    // Headings are plain rows: a sidebar section heading always offers to collapse its section.
                    if !store.saved.isEmpty {
                        Section {
                            heading(T("Terminal text"))
                            ForEach(store.saved, content: row)
                        }
                    }
                    if !videos.saved.isEmpty {
                        Section {
                            heading(T("Window video")) {
                                Button(T("Clear History")) { confirmClear = true }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .help(T("Takes every video off this list. The video files stay where they are."))
                            }
                            ForEach(videos.saved, content: row)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
            }
            // The column fills the window's height even with nothing listed; otherwise the split view shrinks to the
            // header and the empty message and sits at the bottom of the window.
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380, maxHeight: .infinity, alignment: .top)
            Group {
                if let url = selection, let recording = store.saved.first(where: { $0.url == url }) {
                    RecordingPlayerView(model: model, recording: recording) { export(recording) }.id(url)
                } else if let url = selection, let video = videos.saved.first(where: { $0.url == url }) {
                    if video.exists {
                        VideoPlayerPane(video: video) { export(video) }.id(url)
                    } else {
                        ContentUnavailableView {
                            Label(T("File not found"), systemImage: "questionmark.folder")
                        } description: {
                            Text(video.url.path).textSelection(.enabled)
                        } actions: {
                            Button(T("Remove from List")) { forget(video) }
                        }
                    }
                } else if store.saved.isEmpty && videos.saved.isEmpty {
                    ContentUnavailableView(T("No recordings"), systemImage: "record.circle", description: Text(T("Recordings you save appear here.")))
                } else {
                    ContentUnavailableView(T("Choose a recording"), systemImage: "play.rectangle")
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            reload()
            // The newest recording of either kind, so a video just saved is the one shown.
            if selection == nil {
                let text = store.saved.first, video = videos.saved.first
                if let text, let video { selection = video.date > text.date ? video.url : text.url }
                else { selection = text?.url ?? video?.url }
            }
        }
        // A video may have been moved or deleted in the Finder while Gloamux was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
        .task(id: videos.saved.map(\.url)) { await videos.loadDurations() }
        .alert(T("Clear the video history?"), isPresented: $confirmClear) {
            Button(T("Clear History"), role: .destructive) {
                videos.clearList()
                if let url = selection, VideoRules.isVideo(url) { selection = store.saved.first?.url }
            }
            Button(T("Cancel"), role: .cancel) {}
        } message: { Text(T("The video files stay where they are.")) }
        .alert(T("The recording could not be changed."), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(T("OK")) { error = nil }
        } message: { Text(error.map(T) ?? "") }
    }

    private func heading(_ title: String, @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .center) {
            Text(title).appFont(.subheadline).fontWeight(.semibold).foregroundStyle(.secondary)
            Spacer()
            trailing().appFont(.subheadline)
        }
        .frame(minHeight: 22, alignment: .center)
        // The list already leaves room above its first row, so less above and more below centers the heading.
        .padding(.bottom, 6)
        .padding(.trailing, 6)
        .selectionDisabled()
        .accessibilityAddTraits(.isHeader)
    }

    private func reload() {
        store.reload(); videos.reload()
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

    private func row(_ recording: TerminalRecordings.Recording) -> some View {
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

    private func row(_ video: VideoRecordings.Video) -> some View {
        HStack(spacing: 8) {
            VideoThumbnail(video: video)
            VStack(alignment: .leading, spacing: 3) {
                Text(VideoRules.shownName(video.title)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(video.exists ? .primary : .secondary)
                HStack(spacing: 6) {
                    Text(VideoRules.startDate(fromName: video.title) ?? video.date, format: .dateTime.month().day().hour().minute())
                    if video.exists {
                        if let duration = video.duration { Text(VideoRecordButton.clock(duration)).monospacedDigit() }
                        Text(ByteCountFormatter.string(fromByteCount: Int64(video.size), countStyle: .file))
                    } else {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(T("File not found"))
                        }
                    }
                }
                .appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help(video.url.lastPathComponent)
        .tag(video.url)
        .contextMenu {
            if video.exists {
                Button(T("Export…")) { export(video) }
                Button(T("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([video.url]) }
                Divider()
                Button(T("Move to Trash"), role: .destructive) { remove(video) }
            }
            Button(T("Remove from List")) { forget(video) }
        }
    }

    /// The folder of the selected kind of recording.
    /// The selected video's folder, or where new videos go, when a video or only videos are shown.
    private var shownFolder: URL {
        if let url = selection, VideoRules.isVideo(url) { return url.deletingLastPathComponent() }
        return store.saved.isEmpty && !videos.saved.isEmpty ? VideoSettings.current.folder : store.folder
    }

    private func export(_ video: VideoRecordings.Video) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = video.url.lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: video.url.pathExtension) ?? .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: video.url, to: url)
        } catch { self.error = error.localizedDescription }
    }

    private func remove(_ video: VideoRecordings.Video) {
        do { try videos.delete(video); if selection == video.url { selection = videos.saved.first?.url ?? store.saved.first?.url } }
        catch { self.error = error.localizedDescription }
    }

    private func forget(_ video: VideoRecordings.Video) {
        videos.forget(video)
        if selection == video.url { selection = videos.saved.first?.url ?? store.saved.first?.url }
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

/// Plays a window video with the system's controls.
private struct VideoPlayerPane: View {
    let video: VideoRecordings.Video
    let export: () -> Void
    @State private var player: AVPlayer

    init(video: VideoRecordings.Video, export: @escaping () -> Void) {
        self.video = video; self.export = export
        _player = State(initialValue: AVPlayer(url: video.url))
    }

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(player: player).background(Color.black)
            Divider()
            HStack(spacing: 10) {
                Label((video.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    .help(video.url.path)
                Spacer()
                Button(T("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([video.url]) }
                Button(T("Export…"), action: export)
            }
            .appFont(.callout)
            .padding(10)
        }
        .onDisappear { player.pause() }
    }
}

/// The first frame of a video, or a placeholder while it loads or when the file is gone.
private struct VideoThumbnail: View {
    let video: VideoRecordings.Video
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: video.exists ? "film" : "questionmark")
                    .appFont(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.08)))
        .opacity(video.exists ? 1 : 0.6)
        .accessibilityHidden(true)
        .task(id: video.exists) {
            guard video.exists else { image = nil; return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 208, height: 128)
            if let frame = try? await generator.image(at: .zero).image {
                image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
            }
        }
    }
}

/// AppKit's player view. SwiftUI's `VideoPlayer` stops the app when its view is first built in a Swift package build:
/// its AVKit overlay cannot load the metadata of the class it is built on.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
