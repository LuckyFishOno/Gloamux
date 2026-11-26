import AppKit
import SwiftUI
import Terminal

/// A ZMODEM transfer in a terminal tab: `sz` on the server sends files to the download folder, and `rz` waits for
/// files chosen here or with `gloamux tabs zmodem`. Its bar shows over the terminal until it is dismissed.
@MainActor final class ZmodemTransfer: ObservableObject {
    let session: ZmodemSession
    var direction: Zmodem.Start { session.start }
    let folder: URL
    @Published private(set) var progress: ZmodemSession.Progress?
    @Published private(set) var outcome: Zmodem.Outcome?
    @Published private(set) var files: [URL] = []
    /// Leading "O" characters to drop from the next output: the end of a finished download can come after it.
    var drain = 0
    /// After Gloamux stops a download, the data `sz` had already sent keeps arriving. It is dropped until the line
    /// has been quiet for a moment, or for a few seconds at most; the text that came after the last of it is shown.
    private(set) var discarding = false
    private var discardEnds = Date.distantPast
    private var shownAfter: [UInt8] = []
    private var quiet: DispatchWorkItem?
    static let quietTime = 0.3, longestDiscard = 5.0
    /// The file panel open for an upload, closed when the transfer ends another way.
    var panel: NSOpenPanel?
    /// Replaces the terminal connection in tests: what the session writes, and whether it was accepted.
    static var writeForTesting: ((SessionTab, [UInt8]) -> Bool)?
    /// Tests choose upload files with `sendZmodemFiles` instead of the panel.
    static var choosesFiles = true
    private var shown = Date.distantPast

    init(_ session: ZmodemSession, folder: URL) {
        self.session = session
        self.folder = folder
    }

    var isActive: Bool { outcome == nil }

    /// Progress changes every few kilobytes; the bar redraws a few times a second.
    func update(_ value: ZmodemSession.Progress) {
        let now = Date()
        guard value.name != progress?.name || value.done == value.total || now.timeIntervalSince(shown) > 0.2 else { return }
        shown = now
        progress = value
    }

    func added(_ url: URL) { files.append(url) }

    /// Drops output after an abort. Returns false once the time is up, so the output is the terminal's again.
    func discard(_ bytes: [UInt8], deliver: @escaping ([UInt8]) -> Void) -> Bool {
        if !discarding { discarding = true; discardEnds = Date().addingTimeInterval(Self.longestDiscard) }
        guard Date() < discardEnds else { stopDiscarding(); return false }
        if !bytes.isEmpty { shownAfter = ZmodemSession.textAfterAbort(bytes, before: shownAfter) }
        quiet?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.discarding else { return }
            let text = self.shownAfter
            self.stopDiscarding()
            if !text.isEmpty { deliver(text) }
        }
        quiet = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietTime, execute: item)
        return true
    }

    private func stopDiscarding() {
        discarding = false
        shownAfter = []
        quiet?.cancel(); quiet = nil
    }

    func finish(_ result: Zmodem.Outcome) {
        outcome = result
        if let panel { self.panel = nil; panel.cancel(nil) }
    }

    /// What `gloamux tabs zmodem` reports.
    var state: [String: Any] {
        var result: [String: Any] = ["direction": direction == .download ? "download" : "upload",
                                     "files": files.map(\.path), "folder": folder.path]
        switch outcome {
        case nil: result["state"] = session.awaitingFiles ? "waiting" : "transferring"
        case .finished?: result["state"] = "finished"
        case .cancelled?: result["state"] = "cancelled"
        case .failed(let reason)?: result["state"] = "failed"; result["error"] = reason
        }
        if let progress {
            result["file"] = progress.name
            result["bytes"] = progress.done
            if let total = progress.total { result["size"] = total }
        }
        return result
    }
}

/// A file from `sz`, written straight into the download folder; a file cut short is removed.
final class ZmodemDownload: ZmodemSink {
    let url: URL
    private let handle: FileHandle
    private let finished: (URL) -> Void

    init(name: String, folder: URL, finished: @escaping (URL) -> Void) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = Self.free(Self.safeName(name), in: folder)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw WorkspaceError.invalid("Could not create \(url.lastPathComponent) in \(folder.path).")
        }
        handle = try FileHandle(forWritingTo: url)
        self.finished = finished
    }

    func write(_ data: Data) throws { try handle.write(contentsOf: data) }

    func close(complete: Bool) {
        try? handle.close()
        if complete { finished(url) } else { try? FileManager.default.removeItem(at: url) }
    }

    /// The last part of the name the server sent, without characters that would leave the folder.
    static func safeName(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = last.replacingOccurrences(of: ":", with: "-").filter { !$0.isNewline && $0 != "\u{0}" }
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return trimmed.isEmpty ? "download" : String(trimmed.prefix(200))
    }

    /// `name`, or `name 2.ext` and so on when the folder already has it.
    static func free(_ name: String, in folder: URL) -> URL {
        var url = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return url
    }
}

/// A file on this Mac sent to `rz`.
final class ZmodemUpload: ZmodemSource {
    let name: String
    let size: Int
    let modified: Date
    private let handle: FileHandle

    /// ZMODEM counts positions in 32 bits.
    static let maximumSize = Int(UInt32.max)

    init(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true else { throw WorkspaceError.invalid("\(url.path) is not a file.") }
        guard let size = values.fileSize, size <= Self.maximumSize else { throw WorkspaceError.invalid("\(url.lastPathComponent) is larger than 4 GB.") }
        name = url.lastPathComponent
        self.size = size
        modified = values.contentModificationDate ?? Date()
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit { try? handle.close() }

    func read(at offset: Int, count: Int) throws -> Data {
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
    }
}

extension WorkspaceModel {
    /// Output for a tab while ZMODEM may be involved. Returns the bytes that are still terminal output.
    func zmodemOutput(_ tab: SessionTab, _ bytes: [UInt8]) -> [UInt8] {
        var bytes = bytes
        if let transfer = tab.zmodem, transfer.drain > 0 {
            var removed = 0
            while removed < transfer.drain, bytes.first == 0x4F { bytes.removeFirst(); removed += 1 }
            transfer.drain = 0
        }
        if let transfer = tab.zmodem, transfer.discarding,
           transfer.discard(bytes, deliver: { [weak self, weak tab] text in if let self, let tab { self.terminalReceived(tab, bytes: text) } }) {
            return []
        }
        if let transfer = tab.zmodem, transfer.isActive {
            tab.bytesReceived += bytes.count
            transfer.session.receive(bytes)
            return []
        }
        guard TerminalPreferences.zmodem, !tab.readOnly, tab.desktop == nil, let found = Zmodem.detect(bytes) else { return bytes }
        if found.index > 0 { terminalReceived(tab, bytes: Array(bytes[..<found.index])) }
        startZmodem(tab, found.start, Array(bytes[found.index...]))
        return []
    }

    private func startZmodem(_ tab: SessionTab, _ start: Zmodem.Start, _ bytes: [UInt8]) {
        let session = ZmodemSession(start: start)
        let transfer = ZmodemTransfer(session, folder: TerminalPreferences.zmodemFolder)
        tab.zmodem = transfer
        session.output = { [weak self, weak tab, weak session] output in
            guard let self, let tab else { return }
            let sent = ZmodemTransfer.writeForTesting?(tab, output) ?? self.enqueueTerminalInput(tab, bytes: output, records: false, encodes: false)
            if !sent, session?.isOver == false {
                session?.cancel()
            }
        }
        session.accept = { [weak transfer] name, _ in
            guard let transfer else { return nil }
            return try? ZmodemDownload(name: name, folder: transfer.folder) { [weak transfer] url in transfer?.added(url) }
        }
        session.progressed = { [weak transfer] progress in transfer?.update(progress) }
        session.ended = { [weak self, weak tab, weak transfer] outcome, rest in
            guard let self, let tab, let transfer else { return }
            transfer.finish(outcome)
            if transfer.direction == .download, transfer.session.abortedHere {
                _ = transfer.discard(rest) { [weak self, weak tab] text in if let self, let tab { self.terminalReceived(tab, bytes: text) } }
                return
            }
            if transfer.direction == .download, outcome == .finished, rest.isEmpty { transfer.drain = 2 }
            if !rest.isEmpty { self.terminalReceived(tab, bytes: rest) }
        }
        session.receive(bytes)
        if start == .upload, session.awaitingFiles, ZmodemTransfer.choosesFiles { chooseZmodemFiles(tab, transfer) }
    }

    private func chooseZmodemFiles(_ tab: SessionTab, _ transfer: ZmodemTransfer) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = T("Choose files to send to the server")
        panel.prompt = T("Send")
        transfer.panel = panel
        let done: (NSApplication.ModalResponse) -> Void = { [weak self, weak tab, weak transfer] response in
            guard let self, let tab, let transfer, transfer.panel === panel, transfer.session.awaitingFiles else { return }
            transfer.panel = nil
            if response == .OK {
                do { try self.sendZmodemFiles(tab, panel.urls) } catch { tab.error = error.localizedDescription; transfer.session.cancel() }
            } else {
                transfer.session.cancel()
            }
        }
        if let window = workspaceWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    /// Answers a waiting `rz` with these files.
    func sendZmodemFiles(_ tab: SessionTab, _ urls: [URL]) throws {
        guard let transfer = tab.zmodem, transfer.session.awaitingFiles else {
            throw WorkspaceError.invalid("No rz is waiting in this tab. Run rz on the server first.")
        }
        guard !urls.isEmpty else { throw WorkspaceError.invalid("Choose at least one file.") }
        let files = try urls.map(ZmodemUpload.init)
        if let panel = transfer.panel { transfer.panel = nil; panel.cancel(nil) }
        for url in urls { transfer.added(url) }
        transfer.session.send(files)
    }

    func cancelZmodem(_ tab: SessionTab) {
        tab.zmodem?.session.cancel()
    }
}

/// The transfer's progress over the bottom of the terminal, then its result until closed.
struct ZmodemBar: View {
    @ObservedObject var transfer: ZmodemTransfer
    let cancel: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .download ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let outcome = transfer.outcome {
                Text(summary(outcome)).lineLimit(1).truncationMode(.middle)
                if transfer.direction == .download, outcome == .finished, !transfer.files.isEmpty {
                    Button(T("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(transfer.files) }
                }
                Button { close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help(T("Close"))
                    .accessibilityLabel(T("Close"))
            } else {
                if let progress = transfer.progress {
                    Text(String(format: T(transfer.direction == .download ? "Receiving %@" : "Sending %@"), progress.name))
                        .lineLimit(1).truncationMode(.middle)
                    if let total = progress.total, total > 0 {
                        ProgressView(value: Double(min(progress.done, total)), total: Double(total)).frame(width: 140)
                    }
                    Text(ByteCountFormatter.string(fromByteCount: Int64(progress.done), countStyle: .file))
                        .monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text(T(transfer.direction == .download ? "Starting ZMODEM transfer" : "Waiting for files to send"))
                }
                Button(T("Cancel"), action: cancel)
            }
        }
        .appFont(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("zmodemBar")
    }

    private func summary(_ outcome: Zmodem.Outcome) -> String {
        switch outcome {
        case .finished:
            String(format: T(transfer.direction == .download ? "Files received: %d" : "Files sent: %d"), transfer.files.count)
        case .cancelled: T("Transfer cancelled")
        case .failed(let reason): String(format: T("Transfer failed: %@"), T(reason))
        }
    }
}
