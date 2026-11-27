import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Terminal

/// A Markdown runbook: prose with fenced shell blocks that run in a chosen session after confirmation.
struct Runbook: Equatable {
    enum Block: Equatable {
        case heading(Int, String)
        case text(String)
        /// A shell block, numbered among the runnable blocks.
        case code(index: Int, language: String, code: String)
        /// A fenced block in another language, shown but not run.
        case listing(String)
    }

    let title: String
    let blocks: [Block]
    static let runnableLanguages: Set<String> = ["", "sh", "bash", "zsh", "shell", "console", "shell-session"]

    init(markdown: String, fallbackTitle: String) {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var fence: (marker: String, language: String, lines: [String])?
        var index = 0
        func flush() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.text(text)) }
            paragraph = []
        }
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var open = fence {
                if trimmed.hasPrefix(open.marker) && trimmed.trimmingCharacters(in: CharacterSet(charactersIn: open.marker.prefix(1) + " ")).isEmpty {
                    let language = open.language.lowercased()
                    var code = open.lines
                    // A console block shows prompts; only the commands after `$ ` run.
                    if language == "console" || language == "shell-session" {
                        code = code.filter { $0.hasPrefix("$ ") || $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
                    }
                    let text = code.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    if Runbook.runnableLanguages.contains(language), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        blocks.append(.code(index: index, language: language, code: text)); index += 1
                    } else {
                        blocks.append(.listing(open.lines.joined(separator: "\n")))
                    }
                    fence = nil
                } else {
                    open.lines.append(line); fence = open
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let marker = String(trimmed.prefix(while: { $0 == "`" || $0 == "~" }))
                let language = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "{}.")) } ?? ""
                fence = (marker, language, [])
                continue
            }
            if trimmed.hasPrefix("#"), let level = Optional(trimmed.prefix(while: { $0 == "#" }).count), level <= 6,
               trimmed.dropFirst(level).first == " " {
                flush()
                blocks.append(.heading(level, String(trimmed.dropFirst(level + 1))))
                continue
            }
            if trimmed.isEmpty { flush() } else { paragraph.append(line) }
        }
        if let open = fence { blocks.append(.listing(open.lines.joined(separator: "\n"))) }
        flush()
        self.blocks = blocks
        if case .heading(_, let heading)? = blocks.first(where: { if case .heading = $0 { return true }; return false }) {
            title = heading
        } else { title = fallbackTitle }
    }

    var commands: [(index: Int, code: String)] {
        blocks.compactMap { if case .code(let index, _, let code) = $0 { return (index, code) }; return nil }
    }
}

/// Resumes a runbook block once the shell reports the command finished, or when it times out.
@MainActor final class CommandWaiter {
    var continuation: CheckedContinuation<CommandMark?, Never>?
    func finish(_ mark: CommandMark?) {
        continuation?.resume(returning: mark)
        continuation = nil
    }
}

/// The result of running one block: its exit status, time, and output when the shell reports them.
struct RunbookResult: Codable, Equatable {
    var date: Date
    var destination: String
    var command: String
    var exitCode: Int?
    var duration: TimeInterval?
    var output: String?
    /// The shell has no integration, so Gloamux could only send the command.
    var sentOnly = false
}

/// Runbook files in the workspace's `runbooks` folder, and the results of their runs.
@MainActor final class RunbookLibrary: ObservableObject {
    let folder: URL
    @Published private(set) var files: [URL] = []
    /// The latest result of each block, by file name and block number.
    @Published private(set) var results: [String: [Int: RunbookResult]] = [:]
    @Published var running: Set<String> = []
    /// The runbook shown in the Runbooks window, also set from the command palette.
    @Published var selected: URL?

    init(folder: URL) {
        self.folder = folder
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        files = urls.map { $0.resolvingSymlinksInPath().standardizedFileURL }.filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for file in files where results[file.lastPathComponent] == nil { results[file.lastPathComponent] = loadResults(file) }
    }

    func runbook(_ url: URL) -> Runbook {
        let text = (try? FileHandle(forReadingFrom: url)).flatMap { handle -> String? in
            defer { try? handle.close() }
            return (try? handle.read(upToCount: 2 * 1024 * 1024)).map { String(decoding: $0, as: UTF8.self) }
        } ?? ""
        return Runbook(markdown: text, fallbackTitle: url.deletingPathExtension().lastPathComponent)
    }

    @discardableResult func create(named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var url = folder.appendingPathComponent(name).appendingPathExtension("md"), index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(index)").appendingPathExtension("md"); index += 1
        }
        let template = """
        # \(name)

        \(T("Describe what this runbook does. Each shell block below runs in the session you choose, after you confirm it."))

        ```sh
        uname -a
        ```

        ```sh
        df -h
        ```
        """
        try writePrivate(Data(template.utf8), to: url)
        reload()
        // Directory enumeration resolves aliases such as /var -> /private/var; selection must use the same identity.
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    func importFile(_ source: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var url = folder.appendingPathComponent(source.lastPathComponent), index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent) \(index).\(source.pathExtension)"); index += 1
        }
        try FileManager.default.copyItem(at: source, to: url)
        reload()
        // Directory enumeration resolves aliases such as /var -> /private/var; selection must use the same identity.
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    func delete(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        try? FileManager.default.removeItem(at: resultsURL(url))
        results[url.lastPathComponent] = nil
        reload()
    }

    private func resultsURL(_ file: URL) -> URL {
        folder.appendingPathComponent(".results", isDirectory: true).appendingPathComponent(file.lastPathComponent + ".json")
    }

    private func loadResults(_ file: URL) -> [Int: RunbookResult] {
        guard let data = try? Data(contentsOf: resultsURL(file)) else { return [:] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Int: RunbookResult].self, from: data)) ?? [:]
    }

    func record(_ result: RunbookResult, block: Int, in file: URL) {
        var all = results[file.lastPathComponent] ?? [:]
        all[block] = result
        results[file.lastPathComponent] = all
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(all) { try? writePrivate(data, to: resultsURL(file)) }
    }
}

extension WorkspaceModel {
    /// Sends a runbook block to a terminal and waits for the shell to report it finished. Without shell integration it
    /// returns as soon as the command is sent.
    /// `terminal` is the connection the run started on; a later block is not sent to a reconnected session.
    func runBlock(_ code: String, in tab: SessionTab, terminal: UUID? = nil, timeout: TimeInterval = 1800) async -> RunbookResult {
        let destination = UIStrings.text(tab.title, language: language)
        var result = RunbookResult(date: Date(), destination: destination, command: code)
        guard !workspaceLocked else {
            result.output = T("Not run: the workspace is locked."); result.exitCode = -1
            return result
        }
        if let terminal, tab.terminalID != terminal {
            result.output = T("Not run: the session reconnected."); result.exitCode = -1
            return result
        }
        guard tab.terminalReady, let bytes = TerminalKeyboard.pasteBytes(code, bracketed: tab.screen.bracketedPaste) else {
            result.output = T("The session is disconnected."); result.exitCode = -1
            return result
        }
        let integrated = hasShellIntegration(tab)
        guard integrated else {
            enqueueTerminalInput(tab, bytes: bytes + [0x0D])
            result.sentOnly = true
            return result
        }
        let waiter = CommandWaiter()
        commandObservers[tab.id] = { [weak waiter] mark in waiter?.finish(mark) }
        let timer = Task { @MainActor [weak waiter] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            waiter?.finish(nil)
        }
        let mark: CommandMark? = await withCheckedContinuation { continuation in
            // The body runs at once on the main actor, before anything can finish.
            MainActor.assumeIsolated {
                waiter.continuation = continuation
                if !enqueueTerminalInput(tab, bytes: bytes + [0x0D]) { waiter.finish(nil) }
            }
        }
        timer.cancel()
        commandObservers[tab.id] = nil
        guard let mark else { result.output = T("No result: the command did not finish in time."); return result }
        result.exitCode = mark.exitCode
        result.duration = mark.duration
        if let output = mark.outputLine, let end = mark.endLine {
            result.output = String(SecretRedaction.redact(tab.screen.text(lines: output..<end)).prefix(65_536))
        }
        return result
    }
}

struct RunbooksView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var library: RunbookLibrary
    @State private var error: String?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(T("Runbooks")).appFont(.headline)
                    InfoButton(T("Runbooks are Markdown files in the workspace's runbooks folder. Each sh, bash, zsh, or console block can run in a session you choose, after you confirm it. With shell integration, Gloamux records each block's exit status and output."))
                    Spacer()
                    Menu {
                        Button(T("New runbook")) { newRunbook() }
                        Button(T("Import Markdown file…")) { importFile() }
                        Divider()
                        Button(T("Show in Finder")) {
                            try? FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([library.folder])
                        }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                .padding(12)
                Divider()
                List(library.files, id: \.self, selection: $library.selected) { url in
                    Label(url.deletingPathExtension().lastPathComponent, systemImage: "doc.text")
                        .contextMenu {
                            Button(T("Edit in default editor")) { NSWorkspace.shared.open(url) }
                            Button(T("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Divider()
                            Button(T("Move to Trash"), role: .destructive) {
                                do { try library.delete(url); if library.selected == url { library.selected = library.files.first } }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden)
                .overlay {
                    if library.files.isEmpty {
                        ContentUnavailableView {
                            Label(T("No runbooks"), systemImage: "list.bullet.rectangle")
                        } actions: {
                            Button(T("New runbook")) { newRunbook() }
                        }
                    }
                }
            }
            // Fills the window's height even with no runbooks, so the split view does not shrink to the header.
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 320, maxHeight: .infinity, alignment: .top)
            Group {
                if let selection = library.selected, library.files.contains(selection) {
                    RunbookDocumentView(model: model, library: library, url: selection).id(selection)
                } else {
                    ContentUnavailableView(T("Choose a runbook"), systemImage: "doc.text")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { library.reload(); if library.selected == nil { library.selected = library.files.first } }
        .alert(T("The runbook could not be changed."), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(T("OK")) { error = nil }
        } message: { Text(error.map(T) ?? "") }
    }

    private func newRunbook() {
        do { library.selected = try library.create(named: T("New runbook")) } catch { self.error = error.localizedDescription }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { library.selected = try library.importFile(url) } catch { self.error = error.localizedDescription }
    }
}

private struct RunbookDocumentView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var library: RunbookLibrary
    let url: URL
    @State private var runbook: Runbook
    @State private var destination: UUID?
    @State private var confirming: [(index: Int, code: String)]?
    @State private var modified = Date.distantPast

    init(model: WorkspaceModel, library: RunbookLibrary, url: URL) {
        self.model = model; self.library = library; self.url = url
        _runbook = State(initialValue: library.runbook(url))
    }

    private var sessions: [SessionTab] { (model.tabs + model.sessionWindows.values.map(\.tab)).filter(\.terminalReady) }
    private var target: SessionTab? { sessions.first { $0.id == destination } ?? sessions.first { $0.id == model.selection } ?? sessions.first }
    private var running: Bool { library.running.contains(url.lastPathComponent) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(runbook.title).appFont(.title3.bold()).lineLimit(1)
                Spacer()
                AppPicker(T("Run in"), selection: Binding(get: { target?.id }, set: { destination = $0 }),
                          current: target.map { UIStrings.text($0.title, language: model.language) + ($0.environment.map { " · " + T($0.title) } ?? "") } ?? T("No open terminal")) {
                    if sessions.isEmpty { Text(T("No open terminal")).tag(UUID?.none) }
                    ForEach(sessions) { tab in
                        Text(UIStrings.text(tab.title, language: model.language) + (tab.environment.map { " · " + T($0.title) } ?? "")).tag(Optional(tab.id))
                    }
                }
                .frame(maxWidth: 260)
                Button(T("Run all…")) { confirming = runbook.commands }
                    .disabled(target == nil || runbook.commands.isEmpty || running)
                if running { ProgressView().controlSize(.small) }
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(runbook.blocks.enumerated()), id: \.offset) { _, block in blockView(block) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            if let blocks = confirming, let tab = target { confirmation(blocks, tab: tab) }
        }
        // Edits made in another editor show up when the window comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in reloadIfChanged() }
        .onAppear { reloadIfChanged() }
    }

    private func reloadIfChanged() {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if date != modified { modified = date; runbook = library.runbook(url) }
    }

    @ViewBuilder private func blockView(_ block: Runbook.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text)).appFont(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline).padding(.top, level <= 2 ? 6 : 2)
        case .text(let text):
            Text(inline(text)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case .listing(let text):
            Text(text).appFont(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        case .code(let index, _, let code):
            codeBlock(index: index, code: code)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func codeBlock(index: Int, code: String) -> some View {
        let result = library.results[url.lastPathComponent]?[index]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(code).appFont(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { confirming = [(index, code)] } label: { Label(T("Run"), systemImage: "play.fill") }
                    .controlSize(.small).disabled(target == nil || running)
            }
            .padding(10)
            if let result {
                Divider()
                RunbookResultView(result: result)
            }
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func confirmation(_ blocks: [(index: Int, code: String)], tab: SessionTab) -> some View {
        let risky = tab.environment.map { SessionEnvironment.confirming.contains($0) } == true
            && blocks.contains { block in block.code.split(separator: "\n").contains { RiskyCommands.match(String($0)) != nil } }
        return VStack(alignment: .leading, spacing: 14) {
            Label(T(blocks.count == 1 ? "Run this block?" : "Run these blocks?"), systemImage: "play.rectangle").appFont(.title3.bold())
            HStack(spacing: 6) {
                Text(T("Destination:")).foregroundStyle(.secondary)
                Text(UIStrings.text(tab.title, language: model.language) + (tab.host.isEmpty ? "" : " (\(tab.host))")).fontWeight(.medium)
                if let environment = tab.environment { EnvironmentBadge(environment: environment) }
            }
            if risky {
                Label(T("This includes a command that can change or delete data in this environment."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            ScrollView {
                Text(blocks.map(\.code).joined(separator: "\n\n")).appFont(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(maxHeight: 260)
            .padding(8).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            if blocks.count > 1 && !model.hasShellIntegration(tab) {
                Label(T("Without shell integration, Gloamux sends every block at once and cannot stop after a failure."), systemImage: "info.circle")
                    .foregroundStyle(.secondary).appFont(.callout)
            }
            DialogActions(cancel: { confirming = nil }, title: T("Run"), warns: risky) { confirming = nil; run(blocks, in: tab) }
        }
        .padding(22).frame(width: 560)
    }

    /// Runs blocks one after another and stops at the first that fails.
    private func run(_ blocks: [(index: Int, code: String)], in tab: SessionTab) {
        let key = url.lastPathComponent
        library.running.insert(key)
        model.reveal(tab: tab.id)
        let terminal = tab.terminalID
        Task {
            for block in blocks {
                let result = await model.runBlock(block.code, in: tab, terminal: terminal)
                library.record(result, block: block.index, in: url)
                if (result.exitCode ?? 0) != 0 { break }
            }
            library.running.remove(key)
        }
    }
}

private struct RunbookResultView: View {
    let result: RunbookResult
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if result.sentOnly {
                    Image(systemName: "paperplane").foregroundStyle(.secondary)
                    Text(T("Sent")).foregroundStyle(.secondary)
                } else if let code = result.exitCode {
                    Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(code == 0 ? .green : .red)
                    Text(code == 0 ? T("Succeeded") : String(format: T("Exit code %d"), code))
                } else {
                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    Text(T("No result")).foregroundStyle(.secondary)
                }
                if let duration = result.duration { Text("· " + formatDuration(duration)).foregroundStyle(.secondary) }
                Text("· " + result.destination).foregroundStyle(.secondary).lineLimit(1)
                Text("· ").foregroundStyle(.secondary) + Text(result.date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary)
                Spacer()
                if let output = result.output, !output.isEmpty {
                    Button(T(expanded ? "Hide output" : "Show output")) { expanded.toggle() }.buttonStyle(.link).appFont(.caption)
                }
            }
            .appFont(.caption)
            if expanded, let output = result.output {
                ScrollView {
                    Text(output).appFont(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}

/// A small colored label for a session's environment.
struct EnvironmentBadge: View {
    let environment: SessionEnvironment
    var compact = false
    var body: some View {
        Text(compact ? environment.shortTitle : T(environment.title))
            .appFont(.system(size: compact ? 9 : 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 4 : 6).padding(.vertical, 1.5)
            .background(environment.color, in: Capsule())
            .accessibilityLabel(T(environment.title))
    }
}
