import CoreGraphics
import Foundation

/// `gloamux videos`: the toolbar's window video and the videos in the Recordings window.
extension WorkspaceCommand {
    static let videoAgreement = "A video shows everything the workspace window shows, with nothing masked: terminal output, file lists and paths, and commands in the Session Log. Run the command again with --yes to agree. Gloamux asks only once."

    /// `videos start [--window N] [--yes] | stop [--window N] | status | list | export FILE PATH | remove FILE`.
    /// Window numbers are those of `gloamux tabs list`; without `--window`, the front workspace window.
    @MainActor static func videos(_ action: String, _ args: [String], _ model: WorkspaceModel, live: Bool,
                                  _ windows: [WorkspaceModel]) async throws -> Any {
        switch action {
        case "start":
            try requireLive(live, model)
            let (number, owner, yes) = try videoWindow(args, model, windows, allowsYes: true)
            guard owner.videos.active == nil else { throw WorkspaceError.invalid("Window \(number) is already being recorded.") }
            if !VideoRecordings.acknowledged {
                guard yes else { throw Usage(videoAgreement) }
                VideoRecordings.acknowledged = true
            }
            guard !owner.workspaceLocked else { throw WorkspaceError.invalid("Unlock window \(number) first.") }
            guard let window = owner.workspaceWindow else { throw WorkspaceError.invalid("Window \(number) is not open.") }
            guard VideoRecordings.hasPermission else {
                // Asks macOS once, which also lists Gloamux in System Settings, where the permission is turned on.
                _ = CGRequestScreenCaptureAccess()
                throw VideoRecordings.StartError.noPermission
            }
            owner.objectWillChange.send()
            defer { owner.objectWillChange.send() }
            try await owner.videos.start(window: window)
            let settings = VideoSettings.current
            return ["window": number, "status": "recording", "format": settings.format.rawValue, "folder": settings.folder.path,
                    "quality": settings.quality.rawValue, "framesPerSecond": Int(settings.framesPerSecond)] as [String: Any]
        case "stop":
            try requireLive(live, model)
            let (number, owner, _) = try videoWindow(args, model, windows, allowsYes: false)
            guard owner.videos.active != nil else { throw WorkspaceError.invalid("Window \(number) is not being recorded.") }
            switch await owner.videos.stop().value {
            case .saved(let url): return ["window": number, "file": url.lastPathComponent, "path": url.path] as [String: Any]
            case .nothingRecorded: return ["window": number, "status": "nothing recorded"] as [String: Any]
            case .failed(let message): throw WorkspaceError.invalid(message)
            }
        case "status":
            try requireLive(live, model)
            try count(args, 0...0)
            return windows.enumerated().map { index, owner -> [String: Any] in
                guard let recorder = owner.videos.active else { return ["window": index + 1, "recording": false] }
                return ["window": index + 1, "recording": true, "paused": recorder.paused,
                        "seconds": (recorder.elapsed * 10).rounded() / 10]
            }
        case "list":
            try count(args, 0...0)
            let store = model.videos
            store.reload()
            await store.loadDurations()
            let dates = ISO8601DateFormatter()
            return store.saved.map { video -> [String: Any] in
                var info: [String: Any] = ["file": video.url.lastPathComponent, "path": video.url.path, "title": video.title,
                                           "date": dates.string(from: video.date),
                                           "format": video.url.pathExtension.lowercased(), "bytes": video.size]
                if let duration = video.duration { info["seconds"] = (duration * 10).rounded() / 10 }
                return info
            }
        case "export":
            try count(args, 2...2)
            let source = try savedVideo(args[0], model)
            guard args[1].hasPrefix("/") else { throw Usage("Use an absolute path for the video file.") }
            let url = URL(fileURLWithPath: args[1])
            guard !FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceError.invalid("\(url.path) already exists.") }
            try FileManager.default.copyItem(at: source.url, to: url)
            return ["path": url.path]
        case "remove":
            try count(args, 1...1)
            let found = try savedVideo(args[0], model)
            try model.videos.delete(found)
            return ["removed": found.url.lastPathComponent]
        default: throw Usage("Unknown videos operation.")
        }
    }

    /// The window `--window N` names, or the front one, and whether `--yes` was given.
    @MainActor private static func videoWindow(_ args: [String], _ model: WorkspaceModel, _ windows: [WorkspaceModel],
                                               allowsYes: Bool) throws -> (Int, WorkspaceModel, Bool) {
        var number = 1, yes = false, rest = args[...]
        while let flag = rest.popFirst() {
            switch flag {
            case "--yes" where allowsYes: yes = true
            case "--window":
                guard let value = rest.popFirst(), let parsed = Int(value), parsed >= 1 else { throw Usage("Give a window number after --window.") }
                number = parsed
            default: throw Usage("Unknown option \(flag).")
            }
        }
        let open = windows.isEmpty ? [model] : windows
        guard number <= open.count else {
            throw WorkspaceError.invalid("No workspace window \(number). Gloamux has \(open.count) open; run gloamux tabs list.")
        }
        return (number, open[number - 1], yes)
    }

    @MainActor private static func savedVideo(_ name: String, _ model: WorkspaceModel) throws -> VideoRecordings.Video {
        model.videos.reload()
        guard let found = model.videos.saved.first(where: { $0.url.lastPathComponent == name || $0.url.path == name }) else {
            throw WorkspaceError.invalid("No video named \(name). Run gloamux videos list.")
        }
        return found
    }
}
