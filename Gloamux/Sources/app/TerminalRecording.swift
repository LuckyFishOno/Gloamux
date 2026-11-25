import Foundation
import SwiftUI
import Terminal

/// Records what a terminal shows, in the asciinema v2 format (asciicast). Only output is recorded, never keystrokes,
/// and likely secrets (private keys, access tokens, `password=` values) are masked before anything is written.
@MainActor final class TerminalRecordings: ObservableObject {
    struct Recording: Identifiable, Equatable {
        let url: URL
        var id: URL { url }
        let title: String
        let date: Date
        let duration: TimeInterval
        let size: Int
    }

    /// What stopping a recording did.
    enum StopResult: Equatable {
        case saved(URL)
        /// Nothing was being recorded, or the terminal showed nothing.
        case nothingRecorded
        /// The file could not be written; the recording waits in `unsaved` for another try.
        case failed(String)
    }

    let folder: URL
    @Published private(set) var active: [UUID: TerminalRecorder] = [:]
    @Published private(set) var saved: [Recording] = []
    /// Stopped recordings whose file could not be written, oldest first, kept to try again.
    @Published private(set) var unsaved: [RecordingSnapshot] = []
    /// Stopped recordings still being masked and written.
    @Published private(set) var saving = 0
    /// A recording stops by itself at this many bytes of output.
    static let limit = 32 * 1024 * 1024
    /// At most this many unsaved recordings are kept; a further failure drops the oldest.
    static let unsavedLimit = 4
    static let saveFailed = "Couldn’t save the recording. Gloamux keeps it until you try again or discard it."
    /// The last save in line. Saves run one at a time, in the order the recordings stopped.
    private var lastSave: Task<StopResult, Never>?

    init(folder: URL) {
        self.folder = folder
        reload()
    }

    func isRecording(_ tab: SessionTab) -> Bool { active[tab.id] != nil }

    func start(_ tab: SessionTab) {
        guard active[tab.id] == nil else { return }
        active[tab.id] = TerminalRecorder(title: UIStrings.text(tab.title, language: UIStrings.language),
                                          columns: tab.screen.cols, rows: tab.screen.rows)
        tab.objectWillChange.send()
    }

    func output(_ tab: SessionTab, bytes: [UInt8]) {
        guard let recorder = active[tab.id] else { return }
        recorder.output(bytes)
        if recorder.size > Self.limit { stop(tab) }
    }

    func resize(_ tab: SessionTab, rows: Int, columns: Int) {
        active[tab.id]?.resize(rows: rows, columns: columns)
    }

    /// Stops the tab's recording at once and saves it in the background: masking secrets and writing a recording
    /// near the size limit takes about a second, which would otherwise hold up every window. Await the task for
    /// the result.
    @discardableResult func stop(_ tab: SessionTab) -> Task<StopResult, Never> {
        guard let recorder = active.removeValue(forKey: tab.id) else { return Task { .nothingRecorded } }
        tab.objectWillChange.send()
        guard recorder.hasOutput else { return Task { .nothingRecorded } }
        return enqueue(recorder.snapshot)
    }

    /// Stops every recording, as quitting does, and saves each in the background.
    func stopAll() {
        for id in Array(active.keys) {
            if let recorder = active.removeValue(forKey: id), recorder.hasOutput { enqueue(recorder.snapshot) }
        }
    }

    /// Saves the recordings that could not be saved before. Returns the files written; any that fail again stay.
    @discardableResult func retryUnsaved() async -> [URL] {
        let waiting = unsaved
        unsaved = []
        var written: [URL] = []
        for snapshot in waiting {
            if case .saved(let url) = await enqueue(snapshot).value { written.append(url) }
        }
        return written
    }

    /// Drops the recordings that could not be saved.
    func discardUnsaved() { unsaved = [] }

    /// Waits for the saves under way, at most `seconds`. Returns false if one is still running then.
    func finishSaving(within seconds: Double = 20) async -> Bool {
        guard let last = lastSave, saving > 0 else { return true }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await last.value }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await group.next()
            group.cancelAll()
        }
        return saving == 0
    }

    @discardableResult private func enqueue(_ snapshot: RecordingSnapshot) -> Task<StopResult, Never> {
        let previous = lastSave, folder = folder
        saving += 1
        let task = Task { @MainActor [weak self] () -> StopResult in
            _ = await previous?.value
            let written = await Task.detached(priority: .utility) { Result { try snapshot.write(into: folder) } }.value
            guard let self else { return .failed(Self.saveFailed) }
            self.saving -= 1
            switch written {
            case .success(let url):
                self.reload()
                return .saved(url)
            case .failure:
                self.unsaved.append(snapshot)
                if self.unsaved.count > Self.unsavedLimit { self.unsaved.removeFirst(self.unsaved.count - Self.unsavedLimit) }
                return .failed(Self.saveFailed)
            }
        }
        lastSave = task
        return task
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        saved = urls.filter { $0.pathExtension == "cast" }.compactMap { url in
            guard let header = Asciicast.header(of: url) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Recording(url: url, title: header.title ?? url.deletingPathExtension().lastPathComponent,
                             date: Date(timeIntervalSince1970: header.timestamp ?? 0), duration: header.duration ?? 0, size: size)
        }.sorted { $0.date > $1.date }
    }

    func delete(_ recording: Recording) throws {
        try FileManager.default.trashItem(at: recording.url, resultingItemURL: nil)
        reload()
    }
}

/// A stopped recording: what was recorded, fixed, so it can be masked and written away from the main actor.
struct RecordingSnapshot: Sendable {
    struct Event: Sendable { let time: TimeInterval; let kind: String; let data: String }
    let title: String
    let started: Date
    let columns: Int, rows: Int
    let events: [Event]

    func asciicast() throws -> Data {
        let redacted = SecretRedaction.redact(events.filter { $0.kind == "o" }.map { ($0.time, $0.data) })
        var outputs = redacted.makeIterator()
        var lines: [String] = []
        let duration = events.last?.time ?? 0
        let header: [String: Any] = ["version": 2, "width": columns, "height": rows, "timestamp": Int(started.timeIntervalSince1970),
                                     "duration": (duration * 1000).rounded() / 1000, "title": title,
                                     "env": ["TERM": "xterm-256color"]]
        lines.append(String(decoding: try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]), as: UTF8.self))
        for event in events {
            let data = event.kind == "o" ? (outputs.next()?.1 ?? "") : event.data
            if event.kind == "o" && data.isEmpty { continue }
            let line = try JSONSerialization.data(withJSONObject: [(event.time * 1_000_000).rounded() / 1_000_000, event.kind, data],
                                                  options: [.fragmentsAllowed])
            lines.append(String(decoding: line, as: UTF8.self))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Writes the recording as a private `.cast` file named for its start time and title. Saves run one at a time,
    /// so the name chosen here is still free when the file is written.
    func write(into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let safe = title.map { "/:\\".contains($0) ? "_" : $0 }
        let base = "\(formatter.string(from: started)) \(String(safe.prefix(60)))"
        // Two recordings with the same title can stop within one second; neither replaces the other.
        var url = folder.appendingPathComponent(base + ".cast"), number = 1
        while FileManager.default.fileExists(atPath: url.path) {
            number += 1
            url = folder.appendingPathComponent("\(base) \(number).cast")
        }
        try writePrivate(asciicast(), to: url)
        return url
    }
}

/// One recording in progress.
final class TerminalRecorder {
    let title: String
    let started = Date()
    private let columns: Int, rows: Int
    private var events: [RecordingSnapshot.Event] = []
    private var pending: [UInt8] = []
    private(set) var size = 0

    init(title: String, columns: Int, rows: Int) { self.title = title; self.columns = columns; self.rows = rows }

    var hasOutput: Bool { events.contains { $0.kind == "o" } }

    func output(_ bytes: [UInt8]) {
        size += bytes.count
        pending += bytes
        // Keep an incomplete UTF-8 sequence for the next chunk.
        var end = pending.count
        var back = 0
        while back < 3, end - back - 1 >= 0, pending[end - back - 1] & 0xC0 == 0x80 { back += 1 }
        if end - back - 1 >= 0 {
            let lead = pending[end - back - 1]
            let needed = lead >= 0xF0 ? 3 : lead >= 0xE0 ? 2 : lead >= 0xC0 ? 1 : 0
            if needed > back { end = end - back - 1 }
        }
        guard end > 0 else { return }
        let text = String(decoding: pending[..<end], as: UTF8.self)
        pending.removeFirst(end)
        events.append(.init(time: Date().timeIntervalSince(started), kind: "o", data: text))
    }

    func resize(rows: Int, columns: Int) {
        events.append(.init(time: Date().timeIntervalSince(started), kind: "r", data: "\(columns)x\(rows)"))
    }

    var snapshot: RecordingSnapshot { RecordingSnapshot(title: title, started: started, columns: columns, rows: rows, events: events) }

    func asciicast() throws -> Data { try snapshot.asciicast() }
}

/// Masks likely secrets in recorded output. Matches are found across chunk boundaries: the mask goes in the chunk
/// where the secret starts, and the rest of the secret is removed from the following chunks.
enum SecretRedaction {
    static let mask = "[REDACTED]"
    private static let patterns: [(NSRegularExpression, String)] = [
        (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#, mask),
        (#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, mask),
        (#"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#, mask),
        (#"\bgithub_pat_[A-Za-z0-9_]{22,}"#, mask),
        (#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, mask),
        (#"\bsk-[A-Za-z0-9_-]{20,}"#, mask),
        (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, mask),
        (#"(?i)\b(bearer)\s+[A-Za-z0-9._~+/-]{8,}=*"#, "$1 " + mask),
        (#"(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key)(\s*[:=]\s*)[^\s'"]{3,}"#, "$1$2" + mask),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func redact(_ text: String) -> String {
        redact([(0, text)]).first?.1 ?? text
    }

    /// Redacts `text` as part of what surrounds it, so a part of a secret is removed too.
    static func redact(_ text: String, before: String, after: String) -> String {
        redact([(0, before), (0, text), (0, after)], marksContinued: true)[1].1
    }

    /// `marksContinued` also writes the mask in a chunk that holds only a later part of a secret.
    static func redact(_ chunks: [(TimeInterval, String)], marksContinued: Bool = false) -> [(TimeInterval, String)] {
        let joined = chunks.map(\.1).joined() as NSString
        // Replacements as (range in the joined text, replacement), without overlaps.
        var replacements: [(NSRange, String)] = []
        for (pattern, template) in patterns {
            for match in pattern.matches(in: joined as String, range: NSRange(location: 0, length: joined.length)) {
                guard !replacements.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) else { continue }
                replacements.append((match.range, pattern.replacementString(for: match, in: joined as String, offset: 0, template: template)))
            }
        }
        guard !replacements.isEmpty else { return chunks }
        replacements.sort { $0.0.location < $1.0.location }
        var result: [(TimeInterval, String)] = []
        var offset = 0
        for (time, text) in chunks {
            let chunk = text as NSString
            let range = NSRange(location: offset, length: chunk.length)
            var output = ""
            var position = range.location
            for (secret, replacement) in replacements where NSMaxRange(secret) > range.location && secret.location < NSMaxRange(range) {
                if secret.location > position { output += joined.substring(with: NSRange(location: position, length: secret.location - position)) }
                if secret.location >= range.location { output += replacement } else if marksContinued { output += mask }
                position = max(position, min(NSMaxRange(secret), NSMaxRange(range)))
            }
            if position < NSMaxRange(range) { output += joined.substring(with: NSRange(location: position, length: NSMaxRange(range) - position)) }
            result.append((time, output))
            offset += chunk.length
        }
        return result
    }
}

/// Reads asciicast v2 files for the recordings list and the player.
enum Asciicast {
    struct Header { var width = 80, height = 24; var title: String?; var timestamp: Double?; var duration: Double? }
    struct Event { let time: TimeInterval; let kind: String; let data: String }

    static func header(of url: URL) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16_384)) ?? Data()
        guard let line = head.split(separator: UInt8(ascii: "\n")).first else { return nil }
        return parseHeader(Data(line))
    }

    private static func parseHeader(_ data: Data) -> Header? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["version"] as? Int == 2 else { return nil }
        var header = Header()
        header.width = min(400, max(20, object["width"] as? Int ?? 80))
        header.height = min(200, max(5, object["height"] as? Int ?? 24))
        header.title = object["title"] as? String
        header.timestamp = object["timestamp"] as? Double
        header.duration = object["duration"] as? Double
        return header
    }

    /// The header and output events of a file up to 64 MiB.
    static func read(_ url: URL) throws -> (Header, [Event]) {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 64 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 64 * 1024 * 1024 else { throw WorkspaceError.invalid("The recording is larger than 64 MiB.") }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        guard let first = lines.first, var header = parseHeader(Data(first)) else { throw WorkspaceError.invalid("This is not an asciicast v2 recording.") }
        var events: [Event] = []
        for line in lines.dropFirst() {
            guard let array = try? JSONSerialization.jsonObject(with: Data(line)) as? [Any], array.count == 3,
                  let time = (array[0] as? NSNumber)?.doubleValue, let kind = array[1] as? String, let text = array[2] as? String else { continue }
            events.append(Event(time: max(0, time), kind: kind, data: text))
        }
        if header.duration == nil { header.duration = events.last?.time }
        return (header, events)
    }
}

/// Shown while a stopped recording could not be written, until it is saved or discarded.
struct UnsavedRecordingBanner: View {
    @ObservedObject var recordings: TerminalRecordings
    let saved: (URL) -> Void
    @State private var confirmingDiscard = false

    var body: some View {
        if !recordings.unsaved.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(T("Recording not saved")).fontWeight(.medium)
                InfoButton(T(TerminalRecordings.saveFailed))
                Button(T("Try again")) { Task { if let url = await recordings.retryUnsaved().last { saved(url) } } }
                    .disabled(recordings.saving > 0)
                Button(T("Discard")) { confirmingDiscard = true }
            }
            .appFont(.callout)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .confirmationDialog(T("Discard the unsaved recording?"), isPresented: $confirmingDiscard) {
                Button(T("Discard"), role: .destructive) { recordings.discardUnsaved() }
                Button(T("Cancel"), role: .cancel) {}
            } message: {
                Text(T("The recorded output is lost."))
            }
        }
    }
}

extension WorkspaceModel {
    /// Before the app quits: stops the recordings still running and waits for every save, at most `seconds`.
    /// Returns false when a recording would be lost, because it could not be written or is still being written.
    public func finishRecordingsBeforeQuit(within seconds: Double = 20) async -> Bool {
        recordings.stopAll()
        let finished = await recordings.finishSaving(within: seconds)
        return finished && recordings.unsaved.isEmpty
    }
}
