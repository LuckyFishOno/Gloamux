import XCTest
import AVFoundation
import AVKit
import CoreVideo
import SwiftUI
@testable import App

/// Window video: where frames land when the recording pauses, the limits, file names, settings, the writer, and
/// `gloamux videos`. Capturing a real window needs Screen Recording permission, so that is checked in the packaged app.
@MainActor final class VideoRecordingTests: XCTestCase {
    private var saved: UserDefaults!

    override func setUp() async throws {
        saved = WorkspaceCommand.preferences
        let name = "gloamux-video-test-\(UUID().uuidString)"
        WorkspaceCommand.preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    }

    override func tearDown() async throws { WorkspaceCommand.preferences = saved }

    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-video-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Timeline

    func testFramesStartAtZeroAndKeepTheirSpacing() {
        var timeline = VideoTimeline()
        XCTAssertEqual(timeline.place(100), 0)
        XCTAssertEqual(timeline.place(100.5), 0.5)
        XCTAssertEqual(timeline.place(102), 2)
        XCTAssertNil(timeline.place(102), "A frame at the same time as the last is dropped")
        XCTAssertNil(timeline.place(101), "A frame that arrives out of order is dropped")
        XCTAssertEqual(timeline.recorded(until: 103), 3)
    }

    func testAPauseIsCutOutOfTheVideo() {
        var timeline = VideoTimeline()
        XCTAssertEqual(timeline.place(10), 0)
        timeline.pause(at: 11)
        XCTAssertTrue(timeline.isPaused)
        XCTAssertNil(timeline.place(12), "A frame captured while a sheet was open is not in the video")
        XCTAssertEqual(timeline.recorded(until: 14), 1, "The paused time does not count while it lasts")
        timeline.resume(at: 15)
        XCTAssertFalse(timeline.isPaused)
        XCTAssertEqual(timeline.place(15.5), 1.5, "Frames after the pause follow on from the last frame before it")
        // A second pause, and one that started before the first frame.
        timeline.pause(at: 16); timeline.resume(at: 20)
        XCTAssertEqual(timeline.place(21), 3, "11 s since the first frame, less two pauses of 4 s")
        XCTAssertEqual(timeline.recorded(until: 22), 4)

        var early = VideoTimeline()
        early.pause(at: 1); early.resume(at: 3)
        XCTAssertNil(early.place(2))
        XCTAssertEqual(early.place(3), 0, "A pause before the first frame takes nothing off the video")
        XCTAssertEqual(early.recorded(until: 5), 2)
    }

    func testPausingTwiceOrResumingWithoutAPauseChangesNothing() {
        var timeline = VideoTimeline()
        _ = timeline.place(0)
        timeline.resume(at: 1)
        timeline.pause(at: 2); timeline.pause(at: 3)
        XCTAssertEqual(timeline.pauses.count, 1)
        timeline.resume(at: 4); timeline.resume(at: 5)
        XCTAssertEqual(timeline.pauses, [VideoTimeline.Pause(start: 2, end: 4)])
        XCTAssertEqual(timeline.recorded(until: 6), 4)
    }

    // MARK: Rules

    func testRecordingStopsAtTheSizeLimitOrWhenTheDiskIsNearlyFull() {
        XCTAssertNil(VideoRules.stopReason(fileSize: 10, freeSpace: 50 * 1024 * 1024 * 1024))
        XCTAssertNil(VideoRules.stopReason(fileSize: 10, freeSpace: nil))
        XCTAssertEqual(VideoRules.stopReason(fileSize: VideoRules.sizeLimit, freeSpace: nil), .sizeLimit)
        XCTAssertEqual(VideoRules.stopReason(fileSize: 10, freeSpace: VideoRules.minimumFreeSpace - 1), .lowDisk)
        XCTAssertNotNil(VideoStopReason.lowDisk.notice)
        XCTAssertNil(VideoStopReason.stopped.notice)
        XCTAssertNil(VideoStopReason.windowClosed.notice)
        XCTAssertEqual(VideoRules.concurrentLimit, 4)
    }

    func testVideoSizeIsEvenAndCapped() {
        let retina = VideoRules.pixels(points: CGSize(width: 1201, height: 801), scale: 2)
        XCTAssertEqual(retina.width, 2402)
        XCTAssertEqual(retina.height, 1602)
        let standard = VideoRules.pixels(points: CGSize(width: 1201, height: 801), scale: 2, quality: .standard)
        XCTAssertEqual(standard.width, 1200, "Standard records points, not pixels, with even sides")
        XCTAssertEqual(standard.height, 800)
        let wide = VideoRules.pixels(points: CGSize(width: 3000, height: 1000), scale: 2)
        XCTAssertEqual(wide.width, VideoRules.longestSide)
        XCTAssertEqual(wide.height, 1280, "The window keeps its shape when it is scaled down")
        let tiny = VideoRules.pixels(points: CGSize(width: 0, height: 0), scale: 0)
        XCTAssertEqual([tiny.width, tiny.height], [2, 2])
    }

    func testBitRateFollowsQualityAndFrameRate() {
        let high = VideoRules.bitRate(width: 2400, height: 1600)
        XCTAssertEqual(high, 2400 * 1600 * 3)
        XCTAssertGreaterThan(VideoRules.bitRate(width: 2400, height: 1600, quality: .best), high)
        XCTAssertLessThan(VideoRules.bitRate(width: 1200, height: 800, quality: .standard), high)
        XCTAssertEqual(VideoRules.bitRate(width: 2400, height: 1600, framesPerSecond: 60), high * 2)
        XCTAssertEqual(VideoRules.bitRate(width: 3800, height: 2400, framesPerSecond: 60), VideoQuality.high.bitRates.upperBound)
        XCTAssertEqual(VideoRules.bitRate(width: 10, height: 10, quality: .best), VideoQuality.best.bitRates.lowerBound)
    }

    func testFileNames() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-27T01:02:03Z"))
        let base = VideoRules.baseName(title: "../a/b:c\nd", started: date)
        XCTAssertFalse(base.contains("/"))
        XCTAssertFalse(base.contains(":"))
        XCTAssertFalse(base.contains("\n"))
        XCTAssertTrue(base.hasSuffix(" _a_b_c_d"), base)
        XCTAssertTrue(VideoRules.baseName(title: "  ", started: date).hasSuffix(" Gloamux"))

        for format in VideoFormat.allCases {
            let partial = VideoRules.partialName("one two", format: format)
            XCTAssertTrue(partial.hasPrefix("."), "Hidden while it records")
            let finished = try XCTUnwrap(VideoRules.finishedBase(forPartial: partial))
            XCTAssertEqual(finished.base, "one two")
            XCTAssertEqual(finished.format, format)
        }
        XCTAssertNil(VideoRules.finishedBase(forPartial: "one.mp4"))
        XCTAssertNil(VideoRules.finishedBase(forPartial: ".recording.mp4"))

        let folder = folder()
        XCTAssertEqual(VideoRules.freeURL("clip", in: folder).lastPathComponent, "clip.mp4")
        try Data().write(to: folder.appendingPathComponent("clip.mp4"))
        XCTAssertEqual(VideoRules.freeURL("clip", in: folder).lastPathComponent, "clip 2.mp4")
        XCTAssertEqual(VideoRules.freeURL("clip", format: .mov, in: folder).lastPathComponent, "clip.mov")
        XCTAssertTrue(VideoRules.isVideo(URL(fileURLWithPath: "/x/a.MOV")))
        XCTAssertFalse(VideoRules.isVideo(URL(fileURLWithPath: "/x/a.cast")))
    }

    /// The list shows a video's name and, on its own line, when it started.
    func testTheListShowsTheNameWithoutTheStartTime() {
        XCTAssertEqual(VideoRules.shownName("2026-11-27 10.00.00 web"), "web")
        XCTAssertEqual(VideoRules.shownName("2026-11-27 10.00.00 web 2"), "web 2")
        XCTAssertEqual(VideoRules.shownName("holiday"), "holiday", "A name without a start time is kept")
        XCTAssertEqual(VideoRules.shownName("2026-11-27 10.00.00"), "2026-11-27 10.00.00")
    }

    func testACutOffRecordingGetsItsNameAtLaunch() throws {
        let folder = folder()
        try Data("video".utf8).write(to: folder.appendingPathComponent(VideoRules.partialName("2026-11-27 10.00.00 web", format: .mov)))
        try Data().write(to: folder.appendingPathComponent(VideoRules.partialName("2026-11-27 10.00.01 empty")))
        let index = self.folder().appendingPathComponent("videos.json")
        let store = VideoRecordings(folder: folder, index: index)
        XCTAssertEqual(store.saved.map(\.url.lastPathComponent), ["2026-11-27 10.00.00 web.mov"])
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(left, ["2026-11-27 10.00.00 web.mov"], "An empty partial file is removed")

        // Once per folder: a second window's store does not touch a file another window is recording.
        let running = folder.appendingPathComponent(VideoRules.partialName("running"))
        try Data("x".utf8).write(to: running)
        _ = VideoRecordings(folder: folder, index: index)
        XCTAssertTrue(FileManager.default.fileExists(atPath: running.path))
    }

    /// Videos go to Downloads or a chosen folder, among other files. The list in the workspace says which are Gloamux's,
    /// and names a recording cut off by a crash so it is finished at the next launch, wherever it was saved.
    func testVideosSavedElsewhereAreListedRecoveredAndRemoved() throws {
        let workspace = folder(), elsewhere = folder()
        let old = workspace.appendingPathComponent("videos", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let index = workspace.appendingPathComponent("videos.json")
        let earlier = old.appendingPathComponent("2026-11-26 09.00.00 old.mp4")
        try Data("old".utf8).write(to: earlier)
        let listed = elsewhere.appendingPathComponent("2026-11-27 09.00.00 saved.mp4")
        try Data("saved".utf8).write(to: listed)
        try Data("not ours".utf8).write(to: elsewhere.appendingPathComponent("holiday.mov"))
        let cutOff = elsewhere.appendingPathComponent(VideoRules.partialName("2026-11-27 10.00.00 web", format: .mov))
        try Data("video".utf8).write(to: cutOff)
        let gone = elsewhere.appendingPathComponent("2026-11-27 08.00.00 moved away.mp4")
        VideoRecordings.changeIndex(index) {
            $0.videos = [listed.path, gone.path]
            $0.recording = [cutOff.path]
        }

        let store = VideoRecordings(folder: old, index: index)
        let recovered = elsewhere.appendingPathComponent("2026-11-27 10.00.00 web.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.path), "The cut-off recording got its name where it was")
        XCTAssertEqual(Set(store.saved.map(\.url.lastPathComponent)),
                       ["2026-11-26 09.00.00 old.mp4", "2026-11-27 09.00.00 saved.mp4", "2026-11-27 10.00.00 web.mov",
                        "2026-11-27 08.00.00 moved away.mp4"],
                       "Listed videos, including one whose file is gone, and the old videos folder; not other files in the folder")
        XCTAssertEqual(store.saved.filter { !$0.exists }.map(\.url), [gone])
        let after = VideoRecordings.readIndex(index)
        XCTAssertTrue(after.recording.isEmpty)
        XCTAssertTrue(after.videos.contains(recovered.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: index.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        let saved = try XCTUnwrap(store.saved.first { $0.url.lastPathComponent == listed.lastPathComponent })
        try store.delete(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: listed.path), "Removed to the Trash")
        XCTAssertFalse(VideoRecordings.readIndex(index).videos.contains(listed.path))
        XCTAssertFalse(store.saved.contains { $0.url.lastPathComponent == listed.lastPathComponent })
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("holiday.mov").path))
    }

    /// The list is a history: a video moved or deleted in the Finder stays on it, marked, until it is taken off. Taking it
    /// off or clearing the list leaves the files, and the old videos folder is not listed again after a clear.
    func testTheListKeepsVideosWhoseFileIsGone() throws {
        let workspace = folder(), elsewhere = folder()
        let old = workspace.appendingPathComponent("videos", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let index = workspace.appendingPathComponent("videos.json")
        let earlier = old.appendingPathComponent("2026-11-26 09.00.00 old.mp4")
        try Data("old".utf8).write(to: earlier)
        let first = elsewhere.appendingPathComponent("2026-11-27 09.00.00 first.mov")
        let second = elsewhere.appendingPathComponent("2026-11-27 10.00.00 second.mp4")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        VideoRecordings.changeIndex(index) { $0.videos = [first.path, second.path] }

        let store = VideoRecordings(folder: old, index: index)
        XCTAssertEqual(store.saved.count, 3)
        XCTAssertTrue(store.saved.allSatisfy(\.exists))
        try FileManager.default.removeItem(at: second)
        store.reload()
        let missing = try XCTUnwrap(store.saved.first { $0.url == second })
        XCTAssertFalse(missing.exists)
        XCTAssertEqual(missing.size, 0)
        XCTAssertEqual(missing.date, VideoRules.startDate(fromName: "2026-11-27 10.00.00 second"))

        try store.delete(missing)
        XCTAssertFalse(store.saved.contains { $0.url == second }, "Move to Trash takes a gone file off the list without an error")
        let kept = try XCTUnwrap(store.saved.first { $0.url == first })
        store.forget(kept)
        XCTAssertFalse(store.saved.contains { $0.url == first })
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path), "Taking a video off the list leaves the file")

        store.clearList()
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: earlier.path))
        XCTAssertTrue(VideoRecordings(folder: old, index: index).saved.isEmpty, "The old videos folder is listed only once")
    }

    func testVideosGoToDownloadsUnlessAFolderIsChosen() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(VideoSettings.current.folder.standardizedFileURL, downloads.standardizedFileURL)
        WorkspaceCommand.preferences.set("~/Movies/Gloamux", forKey: VideoSettings.folderKey)
        XCTAssertEqual(VideoSettings.current.folder.path, NSHomeDirectory() + "/Movies/Gloamux")
        WorkspaceCommand.preferences.set("  ", forKey: VideoSettings.folderKey)
        XCTAssertEqual(VideoSettings.current.folder.standardizedFileURL, downloads.standardizedFileURL)
    }

    func testSettingsComeFromPreferences() {
        XCTAssertEqual(VideoSettings.current, VideoSettings())
        let defaults = WorkspaceCommand.preferences
        defaults.set("mov", forKey: VideoSettings.formatKey)
        defaults.set("best", forKey: VideoSettings.qualityKey)
        defaults.set("60", forKey: VideoSettings.frameRateKey)
        defaults.set(false, forKey: VideoSettings.pointerKey)
        XCTAssertEqual(VideoSettings.current, VideoSettings(format: .mov, quality: .best, framesPerSecond: 60, showsPointer: false))
        defaults.set("avi", forKey: VideoSettings.formatKey)
        defaults.set("24", forKey: VideoSettings.frameRateKey)
        XCTAssertEqual(VideoSettings.current.format, .mp4)
        XCTAssertEqual(VideoSettings.current.framesPerSecond, 30)
    }

    func testToolbarClock() {
        XCTAssertEqual(VideoRecordButton.clock(0), "0:00")
        XCTAssertEqual(VideoRecordButton.clock(42.9), "0:42")
        XCTAssertEqual(VideoRecordButton.clock(3723), "1:02:03")
    }

    // MARK: Writer

    private func frame(_ shade: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(pixels) {
            memset(CVPixelBufferGetBaseAddressOfPlane(pixels, plane), plane == 0 ? Int32(shade) : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) * CVPixelBufferGetHeightOfPlane(pixels, plane))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    /// Writes frames each `step` seconds over `times`, waiting for the encoder as a real capture would.
    private func write(_ writer: CaptureWriter, _ times: [Double]) async throws {
        for (index, time) in times.enumerated() {
            let pixels = try frame(UInt8(40 + index * 10 % 200))
            writer.queue.sync { writer.append(pixels, capturedAt: time) }
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    func testTheWriterCutsPausesAndEndsAtTheStopTime() async throws {
        for format in VideoFormat.allCases {
            let url = folder().appendingPathComponent(VideoRules.partialName("clip", format: format))
            let writer = CaptureWriter()
            var settings = VideoSettings()
            settings.format = format
            try writer.open(url: url, width: 64, height: 48, settings: settings)
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            XCTAssertEqual(permissions, 0o600, "Only this account can read a video")
            try await write(writer, stride(from: 100.0, to: 101.0, by: 0.1).map { $0 })
            writer.setPaused(true, at: 101)
            try await write(writer, [101.5, 102, 102.5])
            writer.setPaused(false, at: 103)
            try await write(writer, stride(from: 103.0, to: 104.0, by: 0.1).map { $0 })
            XCTAssertEqual(writer.recorded(until: 104), 2, accuracy: 0.001)
            let outcome = await writer.close(at: 104.5)
            XCTAssertEqual(outcome, .written)

            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            XCTAssertEqual(duration, 2.5, accuracy: 0.05, "1 s, the 2 s pause cut out, then 1.5 s to the stop")
            let track = try await XCTUnwrapAsync(await asset.loadTracks(withMediaType: .video).first)
            let size = try await track.load(.naturalSize)
            XCTAssertEqual(size, CGSize(width: 64, height: 48))
            let audio = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertTrue(audio.isEmpty, "Videos have no sound")
        }
    }

    func testAWriterThatGotNoFramesLeavesNoFile() async throws {
        let url = folder().appendingPathComponent("empty.mp4")
        let writer = CaptureWriter()
        try writer.open(url: url, width: 64, height: 48, settings: VideoSettings())
        writer.setPaused(true, at: 1)
        try await write(writer, [2, 3])
        let outcome = await writer.close(at: 4)
        XCTAssertEqual(outcome, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Recordings window

    /// The Recordings window opens on the newest recording; with a video, AppKit's player is built at once. SwiftUI's
    /// `VideoPlayer` stopped the packaged (release) app here; a debug test build does not show that, so the packaged
    /// app is checked too.
    func testTheRecordingsWindowShowsAVideo() async throws {
        let model = try workspace()
        let folder = model.videos.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(VideoRules.partialName("2026-11-27 10.00.00 web", format: .mp4))
        let writer = CaptureWriter()
        try writer.open(url: partial, width: 64, height: 48, settings: VideoSettings())
        try await write(writer, stride(from: 10.0, to: 10.5, by: 0.1).map { $0 })
        let outcome = await writer.close(at: 10.5)
        XCTAssertEqual(outcome, .written)
        let saved = folder.appendingPathComponent("2026-11-27 10.00.00 web.mp4")
        try FileManager.default.moveItem(at: partial, to: saved)
        VideoRecordings.changeIndex(model.videos.indexURL) { $0.videos.append(saved.path) }
        model.videos.reload()

        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: RecordingsView(model: model, store: model.recordings, videos: model.videos))
        window.orderBack(nil)
        addTeardownBlock { window.orderOut(nil) }
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.videos.saved.count, 1)
        XCTAssertNotNil(Self.find(AVPlayerView.self, in: window.contentView), "The selected video has a player")
    }

    private static func find<V: NSView>(_ type: V.Type, in view: NSView?) -> V? {
        guard let view else { return nil }
        if let match = view as? V { return match }
        for child in view.subviews { if let match = find(type, in: child) { return match } }
        return nil
    }

    // MARK: Command line

    private func workspace() throws -> WorkspaceModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-test-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try WorkspaceModel(storage: root)
    }

    @discardableResult
    private func run(_ argv: [String], _ model: WorkspaceModel, live: Bool = true) async throws -> Any {
        let data = try await WorkspaceCommand.run(argv, model: model, live: live, windows: [model])
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    func testVideosOnTheCommandLine() async throws {
        let model = try workspace()
        let folder = model.videos.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = folder.appendingPathComponent("2026-11-27 10.00.00 web.mov")
        try Data("not really a video".utf8).write(to: video)
        VideoRecordings.changeIndex(model.videos.indexURL) { $0.videos.append(video.path) }

        let listed = try await run(["videos", "list"], model, live: false) as? [[String: Any]]
        XCTAssertEqual(listed?.first?["file"] as? String, video.lastPathComponent)
        XCTAssertEqual(listed?.first?["format"] as? String, "mov")
        XCTAssertEqual(listed?.first?["exists"] as? Bool, true)
        XCTAssertEqual((listed?.first?["path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }, video.lastPathComponent,
                       "Videos may be anywhere, so the list gives each one's path")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-video-\(UUID()).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        try await run(["videos", "export", video.lastPathComponent, copy.path], model)
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: video))
        do { try await run(["videos", "export", video.lastPathComponent, copy.path], model); XCTFail("An existing file was overwritten") } catch {}
        do { try await run(["videos", "export", video.lastPathComponent, "relative.mov"], model); XCTFail("A relative path was taken") } catch {}
        try await run(["videos", "remove", video.lastPathComponent], model)
        XCTAssertTrue(model.videos.saved.isEmpty)
        do { try await run(["videos", "remove", "missing.mp4"], model); XCTFail("A missing video was removed") } catch {}

        // A video deleted in the Finder stays on the list until it is forgotten or the list is cleared.
        let kept = folder.appendingPathComponent("2026-11-27 11.00.00 kept.mp4"), gone = folder.appendingPathComponent("2020-01-01 12.00.00 gone.mp4")
        try Data("kept".utf8).write(to: kept)
        VideoRecordings.changeIndex(model.videos.indexURL) { $0.videos += [kept.path, gone.path] }
        let history = try await run(["videos", "list"], model, live: false) as? [[String: Any]]
        XCTAssertEqual(history?.map { $0["exists"] as? Bool }, [true, false], "Newest first, by the time in the name when the file is gone")
        do { try await run(["videos", "export", gone.lastPathComponent, copy.path + ".2"], model); XCTFail("Exported a file that is gone") } catch WorkspaceError.invalid {}
        let forgotten = try await run(["videos", "forget", gone.lastPathComponent], model) as? [String: Any]
        XCTAssertEqual(forgotten?["forgotten"] as? String, gone.lastPathComponent)
        let cleared = try await run(["videos", "clear"], model) as? [String: Any]
        XCTAssertEqual(cleared?["cleared"] as? Int, 1)
        XCTAssertTrue(model.videos.saved.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "Clearing the list leaves the files")

        // Starting needs the app, an answer to what a video shows, and an open window.
        do { try await run(["videos", "start"], model, live: false); XCTFail("Started without the app") } catch WorkspaceError.invalid {}
        do { try await run(["videos", "start"], model); XCTFail("Started without --yes") }
        catch let usage as WorkspaceCommand.Usage { XCTAssertEqual(usage.detail, WorkspaceCommand.videoAgreement) }
        XCTAssertFalse(VideoRecordings.acknowledged)
        do { try await run(["videos", "start", "--window", "2", "--yes"], model); XCTFail("Started a window that is not open") } catch WorkspaceError.invalid {}
        do { try await run(["videos", "start", "--window"], model); XCTFail("Took --window without a number") } catch is WorkspaceCommand.Usage {}
        do { try await run(["videos", "stop", "--yes"], model); XCTFail("stop took --yes") } catch is WorkspaceCommand.Usage {}
        do { try await run(["videos", "stop"], model); XCTFail("Stopped a window that is not recording") } catch WorkspaceError.invalid {}
        let status = try await run(["videos", "status"], model) as? [[String: Any]]
        XCTAssertEqual(status?.first?["recording"] as? Bool, false)
        XCTAssertEqual(status?.first?["window"] as? Int, 1)

        // The settings behind Settings › General › Window video.
        try await run(["settings", "set", "video.format", "mov"], model)
        try await run(["settings", "set", "video.quality", "best"], model)
        try await run(["settings", "set", "video.frame-rate", "60"], model)
        try await run(["settings", "set", "video.show-pointer", "off"], model)
        let chosen = self.folder()
        try await run(["settings", "set", "video.folder", chosen.path], model)
        XCTAssertEqual(VideoSettings.current, VideoSettings(format: .mov, quality: .best, framesPerSecond: 60, showsPointer: false,
                                                            folder: URL(fileURLWithPath: chosen.path, isDirectory: true)))
        do { try await run(["settings", "set", "video.frame-rate", "24"], model); XCTFail("Took 24 frames per second") } catch {}
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
