import Foundation
import Terminal

/// Operations on the running app's tabs and terminals, for `gloamux tabs` and `gloamux commands send|run`.
extension WorkspaceCommand {
    @MainActor static func requireLive(_ live: Bool, _ model: WorkspaceModel) throws {
        guard live else { throw WorkspaceError.invalid("Open Gloamux before controlling tabs.") }
        guard !model.workspaceLocked else { throw WorkspaceError.invalid("Unlock this workspace in Gloamux first.") }
    }

    /// Finds a tab by ID in any open workspace window, including a session moved to a window of its own. A tab in a
    /// locked window is refused here, so no command reads, types into, or changes it until that window is unlocked.
    @MainActor static func tab(_ id: String, _ windows: [WorkspaceModel]) throws -> (model: WorkspaceModel, tab: SessionTab) {
        if let value = UUID(uuidString: id) {
            for model in windows {
                if let tab = model.tabs.first(where: { $0.id == value }) ?? model.sessionWindows[value]?.tab {
                    guard !model.workspaceLocked else { throw WorkspaceError.invalid(lockedTab) }
                    return (model, tab)
                }
            }
        }
        throw WorkspaceError.invalid("No open tab with that ID. Run gloamux tabs list.")
    }

    static let lockedTab = "That tab is in a locked Gloamux window. Unlock the window first."

    @MainActor static func kind(_ tab: SessionTab) -> String {
        if let container = tab.container { return container.tool.rawValue }
        if tab.isLocal { return "local" }
        if let security = tab.ftpSecurity { return security == .none ? "ftp" : "ftps" }
        return "ssh"
    }

    @MainActor static func describe(_ tab: SessionTab, in model: WorkspaceModel, window: Int) -> [String: Any] {
        // A locked window shows only its tab bar, so a list gives no more than that for its tabs.
        if model.workspaceLocked {
            return ["id": tab.id.uuidString, "title": tab.title, "kind": kind(tab), "window": window, "locked": true]
        }
        var info: [String: Any] = [
            "locked": false,
            "id": tab.id.uuidString, "title": tab.title, "kind": kind(tab), "window": window,
            "selected": tab.id == model.selection, "ownWindow": model.sessionWindows[tab.id] != nil,
            "connected": tab.isLocal || tab.connected, "terminalReady": tab.terminalReady, "readOnly": tab.readOnly,
            "logging": model.logs.isLogging(tab), "encoding": tab.encoding.rawValue, "multiExec": model.multiExec
        ]
        if let saved = tab.savedSessionID { info["session"] = saved.uuidString }
        if !tab.isLocal, !tab.host.isEmpty { info["host"] = tab.host; info["username"] = tab.username }
        if let environment = tab.environment { info["environment"] = environment.rawValue }
        if let group = model.group(containing: tab.id) { info["split"] = group.tabIDs.map(\.uuidString) }
        if let error = tab.error { info["error"] = error }
        return info
    }

    @MainActor static func tabs(_ action: String, _ args: [String], _ model: WorkspaceModel, _ windows: [WorkspaceModel]) async throws -> Any {
        func on(_ edge: String) throws -> PaneDropEdge {
            switch edge {
            case "left": return .left
            case "right": return .right
            case "top", "up": return .top
            case "bottom", "down": return .bottom
            default: throw Usage("Choose left, right, top, or bottom.")
            }
        }
        func toggle(_ value: String) throws -> Bool {
            switch value {
            case "on": return true
            case "off": return false
            default: throw Usage("Use on or off.")
            }
        }
        switch action {
        case "list":
            try count(args, 0...0)
            return windows.enumerated().flatMap { index, window in
                (window.tabs + window.sessionWindows.values.map(\.tab)).map { describe($0, in: window, window: index + 1) }
            }
        case "open", "open-window":
            try count(args, 1...1)
            let item = try item(args[0], in: model.sessionTree)
            guard let tab = model.openSaved(item, inNewWindow: action == "open-window") else { throw Usage("Select a saved connection.") }
            model.reveal(tab: tab.id)
            return ["id": tab.id.uuidString]
        case "connect":
            try count(args, 1...1)
            guard let direct = SavedConnection.quickTarget(args[0]) else { throw Usage("Use user@host or user@host:port.") }
            guard let tab = model.openSaved(SessionTreeNode(name: "\(direct.username)@\(direct.host)", connection: direct)) else {
                throw Usage("Use user@host or user@host:port.")
            }
            model.reveal(tab: tab.id)
            return ["id": tab.id.uuidString]
        case "colors", "highlights":
            try count(args, 2...2)
            let (owner, tab) = try tab(args[0], windows)
            guard tab.desktop == nil else { throw Usage("Remote desktop tabs have no terminal colors.") }
            guard args[1].hasPrefix("/") else { throw Usage("Use an absolute path.") }
            let url = URL(fileURLWithPath: args[1])
            do {
                if action == "colors" { try owner.importColors(url, tab: tab) } else { try owner.importHighlights(url, tab: tab) }
            } catch let error as WorkspaceError { throw error }
            catch { throw WorkspaceError.invalid(action == "colors" ? "This file is not an Xshell color scheme." : "This file is not an Xshell highlight set.") }
            return ["id": tab.id.uuidString]
        case "local":
            try count(args, 0...0)
            let tab = model.addLocalTab()
            model.reveal(tab: tab.id)
            return ["id": tab.id.uuidString]
        case "show":
            try count(args, 1...1)
            let (owner, tab) = try tab(args[0], windows)
            return describe(tab, in: owner, window: (windows.firstIndex { $0 === owner } ?? 0) + 1)
        case "select", "close", "disconnect", "reconnect", "duplicate", "window", "attach", "unsplit":
            try count(args, 1...1)
            let (owner, tab) = try tab(args[0], windows)
            switch action {
            case "select": owner.reveal(tab: tab.id)
            case "close": await owner.disconnectAndClose(tab)
            case "disconnect":
                guard !tab.isLocal else { throw Usage("A local terminal has no connection. Use close.") }
                await owner.disconnect(tab)
            case "reconnect":
                guard !tab.isLocal, tab.container == nil else { throw Usage("Only SSH and file connections reconnect from here.") }
                guard !tab.connected else { throw WorkspaceError.invalid("The tab is already connected.") }
                // A sign-in form or host-key question shows in the tab, so the command does not wait for it.
                Task { await owner.connect(tab) }
                owner.reveal(tab: tab.id)
                return ["id": tab.id.uuidString, "status": "connecting"]
            case "duplicate":
                guard let copy = owner.duplicateTab(tab) else { throw Usage("Only saved sessions and local terminals can be duplicated.") }
                return ["id": copy.id.uuidString]
            case "window":
                guard owner.sessionWindows[tab.id] == nil else { throw WorkspaceError.invalid("The tab already has its own window.") }
                owner.moveTabToWindow(tab)
            case "attach":
                guard owner.sessionWindows[tab.id] != nil else { throw WorkspaceError.invalid("The tab is already in the tab bar.") }
                owner.moveWindowToTabs(tab)
            default:
                guard owner.group(containing: tab.id) != nil else { throw WorkspaceError.invalid("The tab is not in a split.") }
                owner.detachPane(tab.id)
            }
            return ["id": tab.id.uuidString]
        case "rename":
            try count(args, 2...2)
            let tab = try tab(args[0], windows).tab
            let name = args[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw Usage("Enter a tab name.") }
            tab.title = String(name.prefix(80))
            tab.renamed = true
            return ["id": tab.id.uuidString, "title": tab.title]
        case "split":
            try count(args, 3...3)
            let (owner, target) = try tab(args[0], windows)
            let edge = try on(args[1])
            let (other, added) = try tab(args[2], windows)
            guard other === owner, owner.sessionWindows[target.id] == nil, owner.sessionWindows[added.id] == nil else {
                throw WorkspaceError.invalid("Both tabs must be in the tab bar of the same window.")
            }
            guard target.id != added.id, owner.canSplit(target.id), owner.canSplit(added.id) else {
                throw WorkspaceError.invalid("Only connected sessions and local terminals can share a split.")
            }
            owner.placeTab(added.id, at: edge, of: target.id)
            return ["id": added.id.uuidString, "split": owner.group(containing: added.id)?.tabIDs.map(\.uuidString) ?? []]
        case "broadcast":
            try count(args, 2...2)
            let (owner, tab) = try tab(args[0], windows)
            let wanted = try toggle(args[1])
            guard let group = owner.group(containing: tab.id) else { throw WorkspaceError.invalid("The tab is not in a split.") }
            if owner.selection.map(group.contains) != true { owner.reveal(tab: tab.id) }
            if owner.broadcastInput != wanted { owner.toggleBroadcastInput() }
            return ["id": tab.id.uuidString, "broadcast": owner.broadcastInput]
        case "multiexec":
            try count(args, 2...2)
            // MultiExec belongs to the window that holds the tab, like the button in its toolbar.
            let (owner, tab) = try tab(args[0], windows)
            if try toggle(args[1]) != owner.multiExec { owner.toggleMultiExec() }
            return ["id": tab.id.uuidString, "multiExec": owner.multiExec]
        case "record":
            try count(args, 2...2)
            let (owner, tab) = try tab(args[0], windows)
            guard tab.desktop == nil else { throw Usage("Remote desktop tabs have no terminal to record.") }
            let wanted = try toggle(args[1])
            if wanted, !tab.terminalReady { throw WorkspaceError.invalid("Wait for the terminal to open before recording.") }
            var info: [String: Any] = ["id": tab.id.uuidString]
            if wanted, !owner.recordings.isRecording(tab) {
                owner.recordings.start(tab)
            } else if !wanted {
                switch await owner.recordings.stop(tab).value {
                case .saved(let saved):
                    // The same notice as Stop recording in the menu.
                    owner.recordingSaved = saved
                    info["file"] = saved.lastPathComponent
                case .failed(let problem): throw WorkspaceError.invalid(problem)
                case .nothingRecorded: break
                }
            }
            info["recording"] = owner.recordings.isRecording(tab)
            return info
        case "integration":
            try count(args, 1...1)
            let (owner, tab) = try tab(args[0], windows)
            guard tab.terminalReady, tab.desktop == nil else { throw WorkspaceError.invalid("Wait for the terminal to open first.") }
            owner.installShellIntegration(tab)
            return ["id": tab.id.uuidString, "integration": true]
        case "view":
            try count(args, 2...2)
            let (owner, tab) = try tab(args[0], windows)
            switch args[1] {
            case "files":
                guard !tab.isLocal, tab.desktop == nil, tab.container == nil else { throw Usage("Choose an SSH or FTP tab for file transfer.") }
                owner.openFileTransfer(for: tab)
            case "terminal":
                if owner.tabs.contains(where: { $0.id == tab.id }) { owner.selectTab(tab.id) }
                owner.showTerminal()
            default: throw Usage("Choose terminal or files.")
            }
            return ["id": tab.id.uuidString, "view": args[1]]
        case "readonly":
            try count(args, 2...2)
            let tab = try tab(args[0], windows).tab
            tab.readOnly = try toggle(args[1])
            return ["id": tab.id.uuidString, "readOnly": tab.readOnly]
        case "log":
            try count(args, 2...2)
            let (owner, tab) = try tab(args[0], windows)
            guard tab.desktop == nil else { throw Usage("Remote desktop tabs have no terminal log.") }
            if try toggle(args[1]) != owner.logs.isLogging(tab) { owner.toggleLogging(tab) }
            return ["id": tab.id.uuidString, "logging": owner.logs.isLogging(tab)]
        case "encoding":
            try count(args, 2...2)
            let (owner, tab) = try tab(args[0], windows)
            guard let encoding = TerminalEncoding(rawValue: args[1]) else {
                throw Usage("Choose \(TerminalEncoding.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            owner.setEncoding(encoding, for: tab)
            return ["id": tab.id.uuidString, "encoding": encoding.rawValue]
        case "read":
            try count(args, 1...2)
            let tab = try tab(args[0], windows).tab
            guard tab.desktop == nil else { throw Usage("Remote desktop tabs have no terminal text.") }
            var wanted: Int?
            if let raw = args.dropFirst().first {
                guard let count = Int(raw), (1...100_000).contains(count) else { throw Usage("Enter a line count from 1 to 100000.") }
                wanted = count
            }
            var lines = wanted == nil ? tab.screen.lines : tab.lines
            // Drop the empty rows below the cursor first, so LINES counts the last lines of output.
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            if let wanted { lines = Array(lines.suffix(wanted)) }
            return ["id": tab.id.uuidString, "text": lines.map { String($0.reversed().drop(while: { $0 == " " }).reversed()) }.joined(separator: "\n")]
        case "send", "run":
            try count(args, 2...2)
            let (owner, tab) = try tab(args[0], windows)
            return try type(args[1], into: tab, of: owner, pressReturn: action == "run")
        default: throw Usage("Unknown tabs operation.")
        }
    }

    /// `commands send|run COMMAND_ID TAB_ID`: types a saved quick command into a tab.
    @MainActor static func commandToTab(_ action: String, _ args: [String], _ model: WorkspaceModel, _ windows: [WorkspaceModel]) throws -> Any {
        try count(args, 2...2)
        let store = model.quickCommands
        let id = try quickID(args[0], store)
        guard let command = store.entries.first(where: { $0.id == id }) else { throw WorkspaceError.invalid("No saved quick command with that ID.") }
        if let problem = command.validationError { throw WorkspaceError.invalid(problem) }
        let (owner, tab) = try tab(args[1], windows)
        return try type(command.text, into: tab, of: owner, pressReturn: action == "run")
    }

    /// Types text into one terminal as a paste. In an environment that confirms risky commands, a matching command
    /// waits in Gloamux for the user's answer, the same as typing it there.
    @MainActor static func type(_ text: String, into tab: SessionTab, of model: WorkspaceModel, pressReturn: Bool) throws -> Any {
        guard tab.desktop == nil else { throw Usage("Remote desktop tabs take no typed text.") }
        guard !tab.readOnly else { throw WorkspaceError.invalid("This terminal is read-only.") }
        guard tab.terminalReady else { throw WorkspaceError.invalid("The terminal in this tab is not ready.") }
        guard !text.isEmpty, text.utf8.count <= 65536, var bytes = TerminalKeyboard.pasteBytes(text, bracketed: tab.screen.bracketedPaste),
              var plain = TerminalKeyboard.pasteBytes(text, bracketed: false) else { throw Usage("Enter text of up to 64 KB.") }
        if pressReturn { bytes.append(0x0D); plain.append(0x0D) }
        if let command = model.riskyCommand(in: tab, typing: plain) {
            tab.riskyCommand = RiskyCommandPrompt(command: command, bytes: bytes, environment: tab.environment ?? .production,
                                                  terminalID: tab.terminalID)
            model.reveal(tab: tab.id)
            return ["id": tab.id.uuidString, "status": "waiting for confirmation in Gloamux"]
        }
        guard model.enqueueTerminalInput(tab, bytes: bytes) else { throw WorkspaceError.invalid("The terminal input is full. Try again.") }
        model.trackTyping(tab, bytes)
        return ["id": tab.id.uuidString, "status": "sent"]
    }
}
