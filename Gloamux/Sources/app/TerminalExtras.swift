import AppKit
import Foundation
import Formats
import Highlight
import SwiftUI
import UniformTypeIdentifiers

/// Tab navigation and renaming, imported colors, read-only terminals, closing with confirmation, and saving what a
/// terminal shows.
extension WorkspaceModel {
    // MARK: Tabs

    /// One tab per tab-bar entry, in order; a split group is represented by its first pane.
    var stripTabIDs: [UUID] {
        var seen = Set<Int>()
        return tabs.compactMap { tab in
            guard let index = groups.firstIndex(where: { $0.contains(tab.id) }) else { return tab.id }
            return seen.insert(index).inserted ? (groups[index].tabIDs.first ?? tab.id) : nil
        }
    }

    /// ⌘1 to ⌘8 select that tab; ⌘9 selects the last, as in Safari and Terminal.
    func selectTab(number: Int) {
        let ids = stripTabIDs
        guard !ids.isEmpty else { return }
        let index = number >= 9 ? ids.count - 1 : number - 1
        guard ids.indices.contains(index) else { return }
        selectTab(ids[index])
    }

    /// ⇧⌘] and ⇧⌘[ move to the next or previous tab, wrapping around.
    func selectAdjacentTab(_ offset: Int) {
        let ids = stripTabIDs
        guard ids.count > 1, let selection else { return }
        let current = ids.firstIndex { id in id == selection || group(containing: id)?.contains(selection) == true } ?? 0
        selectTab(ids[(current + offset + ids.count) % ids.count])
    }

    /// Moves a tab one place left or right in the tab bar, past a whole split group when one is next to it.
    /// A pane inside a split moves with its group, so it is left where it is.
    func moveTab(_ id: UUID? = nil, by offset: Int) {
        guard let id = id ?? selection, group(containing: id) == nil else { return }
        let ids = stripTabIDs
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset),
              let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let neighbor = ids[index + offset]
        let members = group(containing: neighbor)?.tabIDs ?? [neighbor]
        var reordered = tabs
        let tab = reordered.remove(at: from)
        let positions = reordered.indices.filter { members.contains(reordered[$0].id) }
        guard let first = positions.first, let last = positions.last else { return }
        reordered.insert(tab, at: offset < 0 ? first : last + 1)
        tabs = reordered
    }

    /// Whether the tab can be opened again: a saved session, or a plain local terminal.
    func canDuplicate(_ tab: SessionTab) -> Bool {
        if let id = tab.savedSessionID { return sessionTree.node(id) != nil }
        return tab.isLocal && tab.container == nil
    }

    /// Opens the same session again in a new tab next to it. A saved session connects again; a local shell starts in
    /// the folder the original is in, and a local command runs again.
    @discardableResult func duplicateTab(_ tab: SessionTab? = nil) -> SessionTab? {
        guard let tab = tab ?? selected, canDuplicate(tab) else { return nil }
        let copy: SessionTab?
        if let id = tab.savedSessionID, let node = sessionTree.node(id) {
            copy = openSaved(node)
        } else {
            let runsCommand = tab.localLaunch?.arguments.contains("-c") == true
            let launch = runsCommand ? tab.localLaunch
                : .loginShell(directory: tab.screen.workingDirectory, integration: ShellIntegration.local)
            copy = addLocalTab(launch: launch, title: tab.title)
        }
        if let copy, tabs.contains(where: { $0.id == tab.id }) { placeTab(copy.id, after: tab.id) }
        return copy
    }

    /// Moves a tab to just after another, or after the whole split group the other is in.
    private func placeTab(_ id: UUID, after anchor: UUID) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        var reordered = tabs
        let moved = reordered.remove(at: from)
        let members = group(containing: anchor)?.tabIDs ?? [anchor]
        guard let last = reordered.indices.last(where: { members.contains(reordered[$0].id) }) else { return }
        reordered.insert(moved, at: last + 1)
        tabs = reordered
    }

    /// Moves a tab out of the tab bar into a window of its own. The session stays connected.
    func moveTabToWindow(_ tab: SessionTab? = nil) {
        guard let tab = tab ?? selected, tabs.contains(where: { $0.id == tab.id }), sessionWindows[tab.id] == nil else { return }
        removeFromTabBar(tab)
        let controller = SavedSessionWindow(model: self, tab: tab)
        sessionWindows[tab.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Puts a session from its own window back at the end of the tab bar. The session stays connected.
    func moveWindowToTabs(_ tab: SessionTab) {
        guard let controller = sessionWindows.removeValue(forKey: tab.id) else { return }
        controller.keepsSession = true
        controller.close()
        tabs.append(tab)
        selectTab(tab.id)
    }

    /// The session whose own window is in front, for the menu command that moves it back to the tab bar.
    var keySessionWindowTab: SessionTab? {
        sessionWindows.values.first { $0.window?.isKeyWindow == true }?.tab
    }

    func renameTab(_ tab: SessionTab? = nil) {
        guard let tab = tab ?? selected else { return }
        let alert = NSAlert()
        alert.messageText = T("Rename tab")
        alert.addButton(withTitle: T("Rename"))
        alert.addButton(withTitle: T("Cancel"))
        let field = NSTextField(string: UIStrings.text(tab.title, language: language))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            tab.title = String(name.prefix(80))
            tab.renamed = true
        }
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: apply) } else { apply(alert.runModal()) }
    }

    // MARK: Colors

    /// Applies an Xshell color scheme (.xcs) to one terminal.
    func chooseColorScheme(_ tab: SessionTab? = nil) {
        guard let tab = tab ?? selected, let url = Self.chooseFile(T("Import color scheme")) else { return }
        do { try importColors(url, tab: tab) } catch { tab.error = T("This file is not an Xshell color scheme.") }
    }

    /// Applies an Xshell highlight set to one terminal: matching keywords are colored as output arrives.
    func chooseHighlightSet(_ tab: SessionTab? = nil) {
        guard let tab = tab ?? selected, let url = Self.chooseFile(T("Import highlight set")) else { return }
        do { try importHighlights(url, tab: tab) } catch { tab.error = T("This file is not an Xshell highlight set.") }
    }

    func resetTerminalColors(_ tab: SessionTab? = nil) {
        guard let tab = tab ?? selected else { return }
        tab.colorScheme = nil
        tab.highlights = nil
        tab.screenRevision += 1
    }

    private static func chooseFile(_ title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Read-only and closing

    /// A read-only terminal shows output but ignores typing and pasting, so nothing is sent by accident.
    func toggleReadOnly(_ tab: SessionTab? = nil) {
        guard let tab = tab ?? selected else { return }
        tab.readOnly.toggle()
    }

    /// Whether closing the tab would end something: a connected SSH session, or a command running in a local shell.
    func closingInterrupts(_ tab: SessionTab) -> Bool {
        if tab.isLocal {
            guard tab.terminalReady else { return false }
            if tab.container != nil { return true }
            guard let last = tab.screen.commandMarks.last else { return false }
            return last.outputLine != nil && last.finishedAt == nil
        }
        return tab.connected
    }

    /// Closes a tab after asking, when that is turned on and closing would end a session or a running command.
    func requestClose(_ tab: SessionTab) {
        guard TerminalPreferences.confirmsClose, closingInterrupts(tab) else { Task { await disconnectAndClose(tab) }; return }
        let alert = NSAlert()
        alert.messageText = String(format: T("Close “%@”?"), UIStrings.text(tab.title, language: language))
        alert.informativeText = tab.isLocal ? T("A command is still running in this terminal.") : T("This disconnects the session.")
        alert.addButton(withTitle: T("Close"))
        alert.addButton(withTitle: T("Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = T("Don't ask again")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(false, forKey: TerminalPreferences.confirmCloseKey) }
            guard response == .alertFirstButtonReturn else { return }
            Task { await self?.disconnectAndClose(tab) }
        }
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    // MARK: Saving output

    /// Plain text of the scrollback and the screen, without trailing blank lines.
    func outputText(_ tab: SessionTab) -> String {
        var lines = tab.lines.map { line in
            var line = line
            while line.last == " " { line.removeLast() }
            return line
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Saves the terminal's text to a file the user chooses.
    func saveOutput(_ tab: SessionTab? = nil) {
        guard let tab = tab ?? selected else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let title = UIStrings.text(tab.title, language: language).map { "/:\\".contains($0) ? "_" : $0 }
        panel.nameFieldStringValue = "\(String(title.prefix(60))) \(formatter.string(from: Date())).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try writePrivate(Data(outputText(tab).utf8), to: url) } catch { tab.error = error.localizedDescription }
    }

    /// Opens the terminal's text in the default text editor, from a private temporary file.
    func openOutputInEditor(_ tab: SessionTab? = nil) {
        guard let tab = tab ?? selected else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Gloamux-Output", isDirectory: true)
        let title = UIStrings.text(tab.title, language: language).map { "/:\\".contains($0) ? "_" : $0 }
        let url = folder.appendingPathComponent("\(String(title.prefix(60))) \(UUID().uuidString.prefix(8)).txt")
        do {
            try writePrivate(Data(outputText(tab).utf8), to: url)
            NSWorkspace.shared.open(url)
        } catch { tab.error = error.localizedDescription }
    }
}

/// The Tab menu items: selecting by number, moving through tabs, renaming, and moving a tab.
struct TabCommands: View {
    let model: WorkspaceModel
    /// What the items show, worked out by the Terminal commands that hold this menu.
    let menu: WorkspaceCommandState.Snapshot

    var body: some View {
        Button(T("Show next tab")) { model.selectAdjacentTab(1) }
            .keyboardShortcut("]", modifiers: [.command, .shift])
        Button(T("Show previous tab")) { model.selectAdjacentTab(-1) }
            .keyboardShortcut("[", modifiers: [.command, .shift])
        Button(T("Move tab left")) { model.moveTab(by: -1) }
        Button(T("Move tab right")) { model.moveTab(by: 1) }
        Button(T("Rename tab…")) { model.renameTab() }
            .disabled(!menu.hasSelection)
        Button(T("Duplicate tab")) { model.duplicateTab() }
            .disabled(!menu.canDuplicate)
        Button(T("Move tab to new window")) { model.moveTabToWindow() }
            .disabled(!menu.hasSelection)
        Button(T("Move window to tab bar")) { if let tab = model.keySessionWindowTab { model.moveWindowToTabs(tab) } }
            .disabled(!menu.hasKeySessionWindow)
        Divider()
        ForEach(1...9, id: \.self) { number in
            Button(number == 9 ? T("Last tab") : String(format: T("Tab %d"), number)) { model.selectTab(number: number) }
                .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
        }
    }
}
