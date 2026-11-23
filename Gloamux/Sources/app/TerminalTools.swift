import SwiftUI
import AppKit
import Terminal

/// The Terminal menu: prompt navigation, shell integration, and recording for the focused session.
public struct TerminalCommands: Commands {
    private let model: WorkspaceModel
    /// Observed in place of the whole workspace, so these menus rebuild only when what they show changes.
    @ObservedObject private var state: WorkspaceCommandState
    public init(model: WorkspaceModel) { self.model = model; state = model.commandState }

    public var body: some Commands {
        let menu = state.snapshot
        // The toolbar's New menu also lives in the File menu, so its shortcuts work from anywhere in the window.
        CommandGroup(after: .newItem) {
            Button(T("New connection")) { model.newConnectionTab() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button(T("New local terminal")) { model.addLocalTab() }
                .keyboardShortcut("t", modifiers: .command)
        }
        // Find in the Edit menu, where macOS apps keep it, for the focused terminal.
        CommandGroup(replacing: .textEditing) {
            Button(T("Find…")) { model.showFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!menu.hasSelection)
            Button(T("Find next")) { model.findAgain(backwards: false) }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!menu.hasSelection)
            Button(T("Find previous")) { model.findAgain(backwards: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!menu.hasSelection)
        }
        CommandGroup(after: .toolbar) {
            // In a session these change its font, as in other terminals; anywhere else, the app's text.
            Button(T("Bigger text")) { AppTextSize.zoomFocused(1) }
                .keyboardShortcut("+", modifiers: .command)
            Button(T("Smaller text")) { AppTextSize.zoomFocused(-1) }
                .keyboardShortcut("-", modifiers: .command)
            Button(T("Actual size")) { AppTextSize.zoomFocused(0) }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            // The app's text from anywhere, a session included.
            Button(T("Bigger app text")) { AppTextSize.zoom(1) }
                .keyboardShortcut("+", modifiers: [.command, .option])
            Button(T("Smaller app text")) { AppTextSize.zoom(-1) }
                .keyboardShortcut("-", modifiers: [.command, .option])
            Button(T("App text actual size")) { AppTextSize.zoom(0) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Divider()
        }
        CommandGroup(before: .windowList) {
            TabCommands(model: model, menu: menu)
            Divider()
            Button(T("Lock workspace")) { model.lockWorkspace() }
                .keyboardShortcut("l", modifiers: [.command, .control])
                .disabled(menu.workspaceLocked)
            Divider()
        }
        CommandMenu(T("Terminal")) {
            let live = menu.terminalReady
            Button(T("Command palette…")) { model.showCommandPalette() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button(T("Previous prompt")) { model.navigate(.previousPrompt) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!menu.hasShellIntegration)
            Button(T("Next prompt")) { model.navigate(.nextPrompt) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!menu.hasShellIntegration)
            Button(T("Select output of last command")) { model.navigate(.selectLastOutput) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!menu.hasLastCommand)
            Button(T("Share with Agents")) { if let tab = model.selected { model.shareWithAgents(tab, selection: WorkspaceModel.terminalSelection()) } }
                .disabled(!menu.hasSelection || menu.isDesktop || !menu.agentsEnabled)
            Divider()
            Button(T("Enable shell integration")) { if let tab = model.selected { model.installShellIntegration(tab) } }
                .disabled(!live || menu.hasShellIntegration)
            Button(T(menu.recording ? "Stop recording" : "Start recording")) { model.toggleRecording() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!live && !menu.recording)
            Button(T("Recordings…")) { model.showRecordings() }
            Button(T(menu.logging ? "Stop session log" : "Start session log")) { model.toggleLogging() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!live && !menu.logging)
            Button(T("Show session logs")) { model.logs.revealFolder() }
            Button(T("Save output…")) { model.saveOutput() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!menu.hasSelection)
            Button(T("Open output in text editor")) { model.openOutputInEditor() }
                .disabled(!menu.hasSelection)
            Divider()
            Toggle(T("Read-only"), isOn: Binding(get: { menu.readOnly }, set: { _ in model.toggleReadOnly() }))
                .disabled(!menu.hasSelection)
            Button(T("Import color scheme…")) { model.chooseColorScheme() }
                .disabled(!menu.hasSelection)
            Button(T("Import highlight set…")) { model.chooseHighlightSet() }
                .disabled(!menu.hasSelection)
            Button(T("Use default colors")) { model.resetTerminalColors() }
                .disabled(!menu.hasSelection || !menu.hasCustomColors)
            Divider()
            Picker(T("Text encoding"), selection: Binding(get: { menu.encoding }, set: { model.setEncoding($0) })) {
                ForEach(TerminalEncoding.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!menu.hasSelection)
            Button(T("Runbooks…")) { model.showRunbooks() }
        }
    }
}

extension WorkspaceModel {
    func toggleRecording(_ tab: SessionTab? = nil) {
        guard let tab = tab ?? selected else { return }
        if recordings.isRecording(tab) {
            let saving = recordings.stop(tab)
            Task { if case .saved(let url) = await saving.value { recordingSaved = url } }
        } else if tab.terminalReady {
            recordings.start(tab)
        }
    }
}

/// The pane header's last command: a check or the exit code, and how long it ran. It opens the command history.
struct CommandStatusButton: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    @State private var showing = false

    var body: some View {
        if let last = tab.lastCommand {
            let failed = (last.exitCode ?? 0) != 0
            Button { showing.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(failed ? Color.red : Color.green)
                    if failed, let code = last.exitCode { Text("\(code)").monospacedDigit() }
                    if let duration = last.duration { Text(formatDuration(duration)).foregroundStyle(.secondary) }
                }
                .appFont(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 6).frame(height: 20)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .help((last.command.map { $0 + "\n" } ?? "") + T("Command history"))
            .accessibilityLabel(T("Command history"))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                CommandHistoryList(model: model, tab: tab) { showing = false }
            }
        }
    }
}

/// Recent commands from shell integration, newest first. Choosing one scrolls to it; the menu copies its output.
struct CommandHistoryList: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    let dismiss: () -> Void

    var body: some View {
        let marks = Array(tab.screen.commandMarks.filter { $0.command != nil }.suffix(40).reversed())
        VStack(alignment: .leading, spacing: 0) {
            Text(T("Command history")).appFont(.headline).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            Divider()
            if marks.isEmpty {
                Text(T("No commands yet.")).foregroundStyle(.secondary).padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in row(mark) }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 380)
    }

    private func row(_ mark: CommandMark) -> some View {
        let available = tab.screen.row(absolute: mark.promptLine) != nil
        let failed = (mark.exitCode ?? 0) != 0
        return Button {
            model.navigate(.lines(mark.promptLine, through: nil), in: tab)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: mark.finishedAt == nil ? "clock" : failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(mark.finishedAt == nil ? Color.secondary : failed ? Color.red : Color.green)
                Text(mark.command ?? "").appFont(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if failed, let code = mark.exitCode { Text("\(code)").appFont(.caption.monospacedDigit()).foregroundStyle(.red) }
                if let duration = mark.duration { Text(formatDuration(duration)).appFont(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .contextMenu {
            Button(T("Copy command")) { copy(mark.command ?? "") }
            if let output = mark.outputLine, let end = mark.endLine {
                Button(T("Copy output")) { copy(tab.screen.text(lines: output..<end)) }
                Button(T("Select output")) { model.navigate(.lines(output, through: end), in: tab); dismiss() }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A red record mark in the pane header while the session is being recorded. Clicking it stops and saves.
/// "LOG" in the pane header while a session log is open. It stops the log; the menu shows the folder.
struct LogIndicator: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    @ObservedObject var logs: TerminalLogs

    var body: some View {
        if logs.isLogging(tab) {
            Menu {
                Button(T("Stop session log")) { model.toggleLogging(tab) }
                Button(T("Show session logs")) { logs.revealFolder() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "doc.text").appFont(.system(size: 9, weight: .semibold))
                    Text(T("LOG")).appFont(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).frame(height: 20)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(T("Session log"))
        }
    }
}

struct RecordingIndicator: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    @State private var pulse = false

    var body: some View {
        if model.recordings.isRecording(tab) {
            Button { model.toggleRecording(tab) } label: {
                HStack(spacing: 4) {
                    Circle().fill(Color.red).frame(width: 7, height: 7).opacity(pulse ? 0.35 : 1)
                    Text(T("REC")).appFont(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 6).frame(height: 20)
                .background(Color.red.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(T("Stop recording"))
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
        }
    }
}
