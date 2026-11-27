import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Where each captured frame goes in the video. Times are seconds on the host clock, the clock ScreenCaptureKit
/// stamps frames with. A pause cuts its span out of the video: frames captured while paused are dropped, and later
/// frames move up by the paused time, so the video plays on as if the pause never happened.
struct VideoTimeline: Equatable {
    struct Pause: Equatable { let start: Double; var end: Double? }
    /// When the first frame was captured; the video starts there.
    private(set) var start: Double?
    private(set) var pauses: [Pause] = []
    /// The last frame's time in the video. Frames arrive in order, but one at the same time or earlier is dropped.
    private(set) var lastFrame: Double?

    var isPaused: Bool { pauses.last.map { $0.end == nil } ?? false }

    mutating func pause(at time: Double) {
        guard !isPaused else { return }
        pauses.append(Pause(start: time, end: nil))
    }

    mutating func resume(at time: Double) {
        guard isPaused else { return }
        pauses[pauses.count - 1].end = max(time, pauses[pauses.count - 1].start)
    }

    /// The time in the video for a frame captured at `time`, or nil when the frame is dropped.
    mutating func place(_ time: Double) -> Double? {
        if pauses.contains(where: { $0.start <= time && ($0.end.map { time < $0 } ?? true) }) { return nil }
        if start == nil { start = time }
        let placed = recorded(until: time)
        if let lastFrame, placed <= lastFrame { return nil }
        lastFrame = placed
        return placed
    }

    /// Seconds of video up to `time`: the time since the first frame, less the paused time.
    func recorded(until time: Double) -> Double {
        guard let start, time > start else { return 0 }
        let paused = pauses.reduce(0.0) { sum, pause in
            let from = max(pause.start, start), to = min(pause.end ?? time, time)
            return sum + max(0, to - from)
        }
        return max(0, time - start - paused)
    }
}

/// The file a video is saved as. Both hold H.264 video with no sound; MOV suits QuickTime and Final Cut, MP4 the web.
enum VideoFormat: String, CaseIterable, Identifiable {
    case mp4, mov
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
    var fileExtension: String { rawValue }
}

/// How sharp the video is, against how large its file grows.
enum VideoQuality: String, CaseIterable, Identifiable {
    /// The window's size in points, at a lower bit rate: about a quarter of the pixels on a Retina display.
    case standard
    /// Every pixel of a Retina display.
    case high
    /// Every pixel, at twice the bit rate of High, for text that stays sharp while it scrolls.
    case best
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        case .best: return "Best"
        }
    }
    /// Bits per pixel each second at 30 frames per second, and the most and least bits per second.
    var bitsPerPixel: Double { self == .standard ? 2 : self == .high ? 3 : 6 }
    var bitRates: ClosedRange<Int> {
        switch self {
        case .standard: return 2_000_000...8_000_000
        case .high: return 4_000_000...24_000_000
        case .best: return 8_000_000...50_000_000
        }
    }
}

/// The choices in Settings › General › Window video, read when a recording starts.
struct VideoSettings: Equatable {
    static let formatKey = "Gloamux.video.format"
    static let qualityKey = "Gloamux.video.quality"
    static let frameRateKey = "Gloamux.video.frameRate"
    static let pointerKey = "Gloamux.video.showsPointer"
    /// The folder new videos are saved in; empty means Downloads.
    static let folderKey = "Gloamux.video.folder"
    static let frameRates = ["30", "60"]

    var format = VideoFormat.mp4
    var quality = VideoQuality.high
    var framesPerSecond: Int32 = 30
    var showsPointer = true
    var folder = VideoSettings.downloads

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    @MainActor static var current: VideoSettings {
        let defaults = WorkspaceCommand.preferences
        var settings = VideoSettings()
        settings.format = defaults.string(forKey: formatKey).flatMap(VideoFormat.init(rawValue:)) ?? .mp4
        settings.quality = defaults.string(forKey: qualityKey).flatMap(VideoQuality.init(rawValue:)) ?? .high
        settings.framesPerSecond = defaults.string(forKey: frameRateKey) == "60" ? 60 : 30
        settings.showsPointer = defaults.object(forKey: pointerKey) as? Bool ?? true
        if let path = defaults.string(forKey: folderKey)?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            settings.folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return settings
    }
}

/// Why a video recording ended.
enum VideoStopReason: String, Equatable {
    case stopped, windowClosed, quit, sizeLimit, lowDisk, failed, writeFailed

    /// Shown when the recording ended by itself. Nil when someone stopped it.
    var notice: String? {
        switch self {
        case .stopped, .windowClosed, .quit: return nil
        case .writeFailed: return "The video could not be written, so the recording stopped. The part recorded so far was kept."
        case .sizeLimit: return "The video recording stopped at 4 GB. Start another to keep recording."
        case .lowDisk: return "The video recording stopped because less than 1 GB of disk space was left."
        case .failed: return "The video recording stopped because the window could no longer be captured."
        }
    }
}

/// What stopping a video recording did.
enum VideoStopResult: Equatable {
    case saved(URL)
    /// Nothing was captured before it stopped.
    case nothingRecorded
    case failed(String)
}

/// The rules for a video recording that do not depend on capturing anything, kept apart so they can be tested.
enum VideoRules {
    static let sizeLimit: Int64 = 4 * 1024 * 1024 * 1024
    static let minimumFreeSpace: Int64 = 1024 * 1024 * 1024
    /// Windows recorded at the same time, across every workspace window.
    static let concurrentLimit = 4
    /// The longer side of the video, in pixels. Hardware H.264 encoders stop at 4096.
    static let longestSide = 3840

    /// Stops a recording that has reached the size limit or is filling the disk.
    static func stopReason(fileSize: Int64, freeSpace: Int64?) -> VideoStopReason? {
        if fileSize >= sizeLimit { return .sizeLimit }
        if let freeSpace, freeSpace < minimumFreeSpace { return .lowDisk }
        return nil
    }

    /// The video's size in pixels for a window of `points` at `scale`: even sides, as H.264 needs, and no larger
    /// than `longestSide`, keeping the window's shape.
    static func pixels(points: CGSize, scale: CGFloat, quality: VideoQuality = .high) -> (width: Int, height: Int) {
        let scale = quality == .standard ? 1 : max(1, scale)
        var width = Double(max(1, points.width * scale)), height = Double(max(1, points.height * scale))
        let longest = max(width, height)
        if longest > Double(longestSide) {
            width *= Double(longestSide) / longest
            height *= Double(longestSide) / longest
        }
        func even(_ value: Double) -> Int { max(2, Int(value.rounded()) / 2 * 2) }
        return (even(width), even(height))
    }

    /// Bits per second: enough for sharp text, scaled with the picture and the frame rate.
    static func bitRate(width: Int, height: Int, quality: VideoQuality = .high, framesPerSecond: Int32 = 30) -> Int {
        let bits = Int(Double(width * height) * quality.bitsPerPixel * Double(framesPerSecond) / 30)
        return min(max(bits, quality.bitRates.lowerBound), quality.bitRates.upperBound)
    }

    /// The file name, without extension, for a recording of the window titled `title` that started at `date`.
    static func baseName(title: String, started date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var safe = String(title.map { "/:\\\n\r\t".contains($0) ? "_" : $0 }.prefix(60)).trimmingCharacters(in: .whitespaces)
        while safe.hasPrefix(".") { safe.removeFirst() }
        return "\(formatter.string(from: date)) \(safe.isEmpty ? "Gloamux" : safe)"
    }

    /// While a recording runs, its file has this hidden name, and gets its own name when it is finished.
    static func partialName(_ base: String, format: VideoFormat = .mp4) -> String { ".\(base).recording.\(format.fileExtension)" }

    /// The finished name and format for a partial file's name, or nil when `name` is not one.
    static func finishedBase(forPartial name: String) -> (base: String, format: VideoFormat)? {
        guard name.hasPrefix(".") else { return nil }
        for format in VideoFormat.allCases where name.hasSuffix(".recording.\(format.fileExtension)") {
            let base = String(name.dropFirst().dropLast(".recording.\(format.fileExtension)".count))
            return base.isEmpty ? nil : (base, format)
        }
        return nil
    }

    /// A name in `folder` that no file has yet: `base.mp4`, then `base 2.mp4`, and so on.
    static func freeURL(_ base: String, format: VideoFormat = .mp4, in folder: URL) -> URL {
        let ext = format.fileExtension
        var url = folder.appendingPathComponent("\(base).\(ext)"), number = 1
        while FileManager.default.fileExists(atPath: url.path) {
            number += 1
            url = folder.appendingPathComponent("\(base) \(number).\(ext)")
        }
        return url
    }

    static func isVideo(_ url: URL) -> Bool { VideoFormat(rawValue: url.pathExtension.lowercased()) != nil }
}

/// Saved window videos and the recording running in one workspace window.
@MainActor final class VideoRecordings: ObservableObject {
    struct Video: Identifiable, Equatable {
        let url: URL
        var id: URL { url }
        let title: String
        let date: Date
        var duration: TimeInterval?
        let size: Int
    }

    enum StartError: LocalizedError, Equatable {
        case alreadyRecording, tooMany, noPermission, noWindow, capture(String)
        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "This window is already being recorded."
            case .tooMany: return "Gloamux records at most 4 windows at a time. Stop one first."
            case .noPermission:
                return "Gloamux needs Screen Recording permission. Turn on Gloamux in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
            case .noWindow: return "The window could not be found for recording. Show it and try again."
            case .capture(let detail): return detail
            }
        }
    }

    /// Set once someone has agreed to what a video records, in the app or with `gloamux videos start --yes`.
    static let acknowledgedKey = "Gloamux.video.acknowledged"
    /// Recordings running in every workspace window.
    private(set) static var running = 0
    /// Folders and lists whose leftover partial files were already given their names, once per launch.
    private static var recovered: Set<String> = []

    /// The videos Gloamux saved, wherever they are, and the hidden files of recordings still running. Videos go to
    /// Downloads or a chosen folder, so the list is how Gloamux tells its videos from the other files there.
    struct Index: Codable, Equatable {
        var videos: [String] = []
        var recording: [String] = []
    }

    /// The workspace's `videos` folder, where videos were saved before they went to Downloads. They are still listed.
    let folder: URL
    /// `videos.json` in the workspace folder.
    let indexURL: URL
    @Published private(set) var active: WindowVideoRecorder?
    @Published private(set) var saved: [Video] = []
    /// Tells the workspace a recording ended, with why, so it can show the file or explain a stop.
    var finished: ((VideoStopResult, VideoStopReason) -> Void)?
    private var stopping: Task<VideoStopResult, Never>?

    init(folder: URL, index: URL) {
        self.folder = folder
        indexURL = index
        Self.recoverPartialFiles(in: folder)
        Self.recoverListedFiles(index)
        reload()
    }

    /// Read again each time: the windows of one workspace share the list.
    static func readIndex(_ url: URL) -> Index {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Index.self, from: $0) } ?? Index()
    }

    static func changeIndex(_ url: URL, _ change: (inout Index) -> Void) {
        var index = readIndex(url)
        change(&index)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(index) { try? writePrivate(data, to: url) }
    }

    /// Recordings cut off by a crash or a forced quit, wherever they were saved, get their own names and join the list.
    static func recoverListedFiles(_ url: URL) {
        guard !recovered.contains(url.path) else { return }
        recovered.insert(url.path)
        let leftovers = readIndex(url).recording
        guard !leftovers.isEmpty else { return }
        var finished: [String] = []
        for path in leftovers {
            let source = URL(fileURLWithPath: path)
            guard let (base, format) = VideoRules.finishedBase(forPartial: source.lastPathComponent),
                  let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) else { continue }
            if size == 0 { try? FileManager.default.removeItem(at: source); continue }
            let target = VideoRules.freeURL(base, format: format, in: source.deletingLastPathComponent())
            if (try? FileManager.default.moveItem(at: source, to: target)) != nil { finished.append(target.path) }
        }
        changeIndex(url) { index in
            index.recording.removeAll { leftovers.contains($0) }
            index.videos += finished
        }
    }

    static var acknowledged: Bool {
        get { WorkspaceCommand.preferences.bool(forKey: acknowledgedKey) }
        set { WorkspaceCommand.preferences.set(newValue, forKey: acknowledgedKey) }
    }
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// A recording cut off by a crash or a forced quit is a playable file under its hidden name. At launch it gets
    /// its own name, so it shows in the list. Only once per folder, so a second window does not take the file of a
    /// recording running in the first.
    static func recoverPartialFiles(in folder: URL) {
        guard !recovered.contains(folder.path) else { return }
        recovered.insert(folder.path)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names {
            guard let (base, format) = VideoRules.finishedBase(forPartial: name) else { continue }
            let source = folder.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
            if size == 0 { try? FileManager.default.removeItem(at: source); continue }
            try? FileManager.default.moveItem(at: source, to: VideoRules.freeURL(base, format: format, in: folder))
        }
    }

    /// Starts recording `window`. The caller has already asked for agreement and checked the permission.
    func start(window: NSWindow) async throws {
        guard active == nil, stopping == nil else { throw StartError.alreadyRecording }
        guard Self.running < VideoRules.concurrentLimit else { throw StartError.tooMany }
        guard Self.hasPermission else { throw StartError.noPermission }
        let settings = VideoSettings.current
        do {
            try FileManager.default.createDirectory(at: settings.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw StartError.capture("Gloamux can’t save videos in the chosen folder. Choose another folder in Settings › General.")
        }
        let title = window.title.isEmpty ? "Gloamux" : window.title
        let recorder = WindowVideoRecorder(window: window, folder: settings.folder,
                                           base: VideoRules.baseName(title: title, started: Date()), settings: settings)
        Self.running += 1
        active = recorder
        recorder.ended = { [weak self] reason in self?.stop(reason: reason) }
        // Listed before the file exists, so a crash leaves a file Gloamux knows to finish at the next launch.
        Self.changeIndex(indexURL) { $0.recording.append(recorder.partial.path) }
        do {
            try await recorder.start()
        } catch {
            // A stop that came in while capture was starting has already given back its place.
            if active === recorder, stopping == nil {
                active = nil
                Self.running -= 1
                Self.changeIndex(indexURL) { $0.recording.removeAll { $0 == recorder.partial.path } }
            }
            throw error
        }
    }

    /// Stops the recording and finishes its file. Stopping again while it finishes waits for the same result.
    @discardableResult func stop(reason: VideoStopReason = .stopped) -> Task<VideoStopResult, Never> {
        if let stopping { return stopping }
        guard let recorder = active else { return Task { .nothingRecorded } }
        let task = Task { @MainActor [weak self] () -> VideoStopResult in
            let result = await recorder.finish()
            guard let self else { return result }
            Self.changeIndex(self.indexURL) { index in
                // A partial file that could not be renamed stays listed, to be finished at the next launch.
                if recorder.savedURL != nil || !FileManager.default.fileExists(atPath: recorder.partial.path) {
                    index.recording.removeAll { $0 == recorder.partial.path }
                }
                if let url = recorder.savedURL { index.videos.append(url.path) }
            }
            Self.running -= 1
            self.active = nil
            self.stopping = nil
            self.reload()
            self.finished?(result, reason)
            return result
        }
        stopping = task
        return task
    }

    /// The listed videos that still exist, and any in the workspace's own `videos` folder.
    func reload() {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        let old = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let listed = Self.readIndex(indexURL).videos.map { URL(fileURLWithPath: $0) }
        var seen = Set<String>()
        let urls = (listed + old).filter { url in
            VideoRules.isVideo(url) && FileManager.default.fileExists(atPath: url.path) && seen.insert(url.standardizedFileURL.path).inserted
        }
        let durations = Dictionary(saved.map { ($0.url, $0.duration) }, uniquingKeysWith: { first, _ in first })
        saved = urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Video(url: url, title: url.deletingPathExtension().lastPathComponent, date: values?.creationDate ?? .distantPast,
                         duration: durations[url] ?? nil, size: values?.fileSize ?? 0)
        }.sorted { $0.date > $1.date }
    }

    /// Reads each listed video's length from its file.
    func loadDurations() async {
        for video in saved where video.duration == nil {
            let seconds = try? await AVURLAsset(url: video.url).load(.duration).seconds
            if let index = saved.firstIndex(where: { $0.url == video.url }), let seconds, seconds.isFinite {
                saved[index].duration = seconds
            }
        }
    }

    /// Moves the video to the Trash and takes it off the list.
    func delete(_ video: Video) throws {
        try FileManager.default.trashItem(at: video.url, resultingItemURL: nil)
        Self.changeIndex(indexURL) { $0.videos.removeAll { URL(fileURLWithPath: $0).standardizedFileURL == video.url.standardizedFileURL } }
        reload()
    }
}

/// Captures one window with ScreenCaptureKit and writes it as H.264 in an `.mp4` or `.mov`, never with sound. The file
/// is written in fragments every two seconds, so a recording cut off by a crash still plays up to its last fragment.
@MainActor final class WindowVideoRecorder: NSObject, ObservableObject {
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var paused = false
    let started = Date()
    /// Called when the recording has to end by itself: the window closed, the file grew too large, or capture failed.
    var ended: ((VideoStopReason) -> Void)?

    private weak var window: NSWindow?
    private let folder: URL
    private let base: String
    /// The hidden file written while recording.
    let partial: URL
    /// The finished file, once `finish` has given it its name.
    private(set) var savedURL: URL?
    private let settings: VideoSettings
    private var stream: SCStream?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var sheetOpen = false
    /// From just before the window starts moving to the Dock until it is there.
    private var minimizing = false
    private var finishing = false
    private let capture: CaptureWriter

    init(window: NSWindow, folder: URL, base: String, settings: VideoSettings) {
        self.window = window
        self.folder = folder
        self.base = base
        self.settings = settings
        partial = folder.appendingPathComponent(VideoRules.partialName(base, format: settings.format))
        capture = CaptureWriter()
    }

    func start() async throws {
        guard let window else { throw VideoRecordings.StartError.noWindow }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw VideoRecordings.hasPermission ? VideoRecordings.StartError.capture(error.localizedDescription) : .noPermission
        }
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw VideoRecordings.StartError.noWindow
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let size = VideoRules.pixels(points: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale), quality: settings.quality)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: settings.framesPerSecond)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = settings.showsPointer
        configuration.queueDepth = 6
        // The video keeps the size the window had when recording started. A window made larger or smaller later is
        // scaled to fit, with bars on the sides that do not match its new shape.
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.backgroundColor = .black
        configuration.capturesAudio = false

        try capture.open(url: partial, width: size.width, height: size.height, settings: settings)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
            try await stream.startCapture()
        } catch {
            capture.cancel()
            throw VideoRecordings.hasPermission ? VideoRecordings.StartError.capture(error.localizedDescription) : .noPermission
        }
        // Stopped while capture was starting: nothing is kept running.
        if finishing {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
        watch(window)
        if window.attachedSheet != nil { sheetOpen = true }
        updatePause()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes keep the clock and the size and disk limits running while an alert or a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A sheet on the window (a password, a confirmation) or the window in the Dock pauses the recording. Sheets are
    /// watched from just before they open, so none of a sheet is in the video.
    private func watch(_ window: NSWindow) {
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ action: @escaping (WindowVideoRecorder) -> Void) {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            })
        }
        on(NSWindow.willBeginSheetNotification) { $0.sheetOpen = true; $0.updatePause() }
        on(NSWindow.didEndSheetNotification) { $0.sheetOpen = $0.window?.attachedSheet != nil; $0.updatePause() }
        on(NSWindow.willMiniaturizeNotification) { $0.minimizing = true; $0.updatePause() }
        on(NSWindow.didMiniaturizeNotification) { $0.minimizing = false; $0.updatePause() }
        on(NSWindow.didDeminiaturizeNotification) { $0.minimizing = false; $0.updatePause() }
        on(NSWindow.willCloseNotification) { $0.ended?(.windowClosed) }
    }

    private func updatePause() {
        guard !finishing else { return }
        // A sheet that opened without the notification, such as one already open when a nested one closes.
        if window?.attachedSheet != nil { sheetOpen = true }
        let pause = sheetOpen || minimizing || window?.isMiniaturized == true
        guard pause != paused else { return }
        paused = pause
        capture.setPaused(pause, at: Self.now)
    }

    private func tick() {
        guard !finishing else { return }
        updatePause()
        elapsed = capture.recorded(until: Self.now)
        let size = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        if let reason = VideoRules.stopReason(fileSize: size, freeSpace: free) { ended?(reason) }
        else if capture.hasFailed { ended?(.writeFailed) }
    }

    /// Stops capturing and finishes the file under its own name.
    func finish() async -> VideoStopResult {
        guard !finishing else { return .nothingRecorded }
        finishing = true
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let stream { try? await stream.stopCapture() }
        stream = nil
        let outcome = await capture.close(at: Self.now)
        switch outcome {
        case .empty:
            return .nothingRecorded
        case .written, .failed:
            let url = VideoRules.freeURL(base, format: settings.format, in: folder)
            do {
                try FileManager.default.moveItem(at: partial, to: url)
            } catch {
                return .failed("Couldn’t finish the video. The part recorded so far gets its name the next time Gloamux opens.")
            }
            savedURL = url
            if case .failed = outcome { return .failed("Couldn’t finish the video. The part recorded so far was saved as \(url.lastPathComponent).") }
            return .saved(url)
        }
    }

    static var now: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}

extension WindowVideoRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.finishing else { return }
            self.ended?(self.window == nil || self.window?.isVisible == false ? .windowClosed : .failed)
        }
    }
}

/// Receives frames on its own queue and writes them. Pauses come from the main thread; the timeline is shared under
/// a lock.
final class CaptureWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    enum Outcome { case written, empty, failed }

    let queue = DispatchQueue(label: "Gloamux.video.capture", qos: .userInitiated)
    private let lock = NSLock()
    private var timeline = VideoTimeline()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frames = 0
    private var closed = false
    /// The last frame written, and when it was captured. ScreenCaptureKit sends a frame only when the window changes,
    /// and a fragmented file fails when its frames are far apart, so a still window repeats its last frame.
    private var lastPixels: CVPixelBuffer?
    private var lastCaptured = 0.0
    private var repeater: DispatchSourceTimer?
    static let repeatAfter = 0.5

    private var frameLength = 1.0 / 30

    func open(url: URL, width: Int, height: Int, settings: VideoSettings) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: settings.format.fileType)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        let output: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: VideoRules.bitRate(width: width, height: height, quality: settings.quality,
                                                             framesPerSecond: settings.framesPerSecond),
                AVVideoExpectedSourceFrameRateKey: Int(settings.framesPerSecond),
                AVVideoMaxKeyFrameIntervalKey: Int(settings.framesPerSecond) * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                // Frames come at uneven times, when the window changes. Reordered frames then get decode times the
                // fragmented file cannot hold, and writing fails a few seconds in.
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: output)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw VideoRecordings.StartError.capture("The video could not be set up.") }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else {
            throw VideoRecordings.StartError.capture(writer.error?.localizedDescription ?? "The video file could not be created.")
        }
        writer.startSession(atSourceTime: .zero)
        // Only this account can read the video: it shows whatever the window showed.
        chmod(url.path, 0o600)
        let frameLength = 1.0 / Double(settings.framesPerSecond)
        queue.sync { self.writer = writer; self.input = input; self.adaptor = adaptor; self.frameLength = frameLength }
        let repeater = DispatchSource.makeTimerSource(queue: queue)
        repeater.schedule(deadline: .now() + Self.repeatAfter, repeating: Self.repeatAfter / 2)
        repeater.setEventHandler { [weak self] in self?.repeatStillFrame() }
        repeater.resume()
        self.repeater = repeater
    }

    func setPaused(_ paused: Bool, at time: Double) {
        lock.lock(); defer { lock.unlock() }
        if paused { timeline.pause(at: time) } else { timeline.resume(at: time) }
    }

    func recorded(until time: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        return timeline.recorded(until: time)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !closed, sampleBuffer.isValid, let pixels = sampleBuffer.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        append(pixels, capturedAt: sampleBuffer.presentationTimeStamp.seconds)
    }

    /// Writes one frame captured at `captured`, a time on the host clock, unless the timeline drops it. Called on `queue`.
    func append(_ pixels: CVPixelBuffer, capturedAt captured: Double) {
        guard !closed else { return }
        lock.lock()
        let placed = timeline.place(captured)
        lock.unlock()
        guard let placed, let input, let adaptor, input.isReadyForMoreMediaData else { return }
        if adaptor.append(pixels, withPresentationTime: CMTime(seconds: placed, preferredTimescale: 600)) {
            frames += 1
            lastPixels = pixels
            lastCaptured = captured
        }
    }

    /// Called on `queue`. Writes the last frame again when the window has not changed for a while.
    private func repeatStillFrame() {
        guard !closed, let lastPixels else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        guard now - lastCaptured >= Self.repeatAfter else { return }
        append(lastPixels, capturedAt: now)
        // A paused recording drops the frame; the next try waits as long again.
        lastCaptured = now
    }

    /// Ends the video at `time`, so the last frame stays on screen until then.
    func close(at time: Double) async -> Outcome {
        let (writer, input, frames, end): (AVAssetWriter?, AVAssetWriterInput?, Int, Double) = queue.sync {
            closed = true
            repeater?.cancel()
            lastPixels = nil
            lock.lock(); defer { lock.unlock() }
            let last = timeline.lastFrame ?? 0
            return (self.writer, self.input, self.frames, max(timeline.recorded(until: time), last + frameLength))
        }
        guard let writer, let input else { return .empty }
        guard frames > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: writer.outputURL)
            return .empty
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 600))
        await writer.finishWriting()
        return writer.status == .completed ? .written : .failed
    }

    /// Whether the file can no longer be written, as when the disk is full.
    var hasFailed: Bool { queue.sync { writer?.status == .failed } }

    func cancel() {
        queue.sync {
            closed = true
            repeater?.cancel()
            lastPixels = nil
            writer?.cancelWriting()
            if let url = writer?.outputURL { try? FileManager.default.removeItem(at: url) }
        }
    }
}
