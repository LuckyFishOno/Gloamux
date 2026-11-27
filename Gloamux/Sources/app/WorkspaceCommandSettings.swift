import Foundation
import Terminal

/// Settings, output triggers, layout, and the password vault, for `gloamux settings|triggers|layout|vault|signins|workspace`.
extension WorkspaceCommand {
    /// The app's preferences. The running app answers commands with its own defaults; a command run without the app
    /// writes the same domain, so the next launch sees it. The `gloamux` inside a renamed copy of the app writes that
    /// copy's domain, not the installed app's. Tests replace it.
    @MainActor public static var preferences: UserDefaults = {
        let id = enclosingAppIdentifier ?? "local.gloamux.desktop"
        return Bundle.main.bundleIdentifier == id ? .standard : UserDefaults(suiteName: id) ?? .standard
    }()

    /// The bundle identifier of the app this executable belongs to, through the `Resources/bin/gloamux` link too.
    nonisolated static var enclosingAppIdentifier: String? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(),
              executable.deletingLastPathComponent().lastPathComponent == "MacOS" else { return nil }
        let info = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let id = NSDictionary(contentsOf: info)?["CFBundleIdentifier"] as? String, id.hasPrefix("local.gloamux.") else { return nil }
        return id
    }

    struct Setting {
        enum Kind {
            case bool(Bool)
            case int(ClosedRange<Int>, Int)
            case number(ClosedRange<Double>, Double)
            case choice([String], String)
            case text(String)
            case list([String], allowed: [String]?)
        }
        let name: String
        let key: String
        let kind: Kind
    }

    @MainActor static let settingsTable: [Setting] = [
        Setting(name: "app.font-size", key: AppTextSize.key, kind: .number(AppTextSize.sizes, AppTextSize.defaultSize)),
        Setting(name: "terminal.font", key: TerminalPreferences.fontKey, kind: .text("")),
        Setting(name: "terminal.font-size", key: TerminalPreferences.fontSizeKey, kind: .number(TerminalPreferences.fontSizes, TerminalPreferences.defaultFontSize)),
        Setting(name: "terminal.cursor", key: TerminalPreferences.cursorKey, kind: .choice(CursorShape.allCases.map(\.rawValue), CursorShape.block.rawValue)),
        Setting(name: "terminal.cursor-blinks", key: TerminalPreferences.blinkKey, kind: .bool(false)),
        Setting(name: "terminal.new-tab", key: TerminalPreferences.newTabKey, kind: .text(NewTabChoice.local.raw)),
        Setting(name: "terminal.opacity", key: TerminalPreferences.opacityKey, kind: .number(0.3...1, 1)),
        Setting(name: "terminal.line-spacing", key: TerminalPreferences.lineSpacingKey, kind: .number(TerminalPreferences.spacings, 1)),
        Setting(name: "terminal.character-spacing", key: TerminalPreferences.characterSpacingKey, kind: .number(TerminalPreferences.spacings, 1)),
        Setting(name: "terminal.ligatures", key: TerminalPreferences.ligaturesKey, kind: .bool(false)),
        Setting(name: "terminal.minimum-contrast", key: TerminalPreferences.minimumContrastKey, kind: .number(TerminalPreferences.contrasts, 1)),
        Setting(name: "terminal.scrollback", key: TerminalPreferences.scrollbackKey,
                kind: .choice(TerminalPreferences.scrollbackChoices.map(String.init), String(TerminalPreferences.defaultScrollback))),
        Setting(name: "terminal.bell", key: TerminalPreferences.bellKey, kind: .choice(BellStyle.allCases.map(\.rawValue), BellStyle.flash.rawValue)),
        Setting(name: "terminal.confirm-multiline-paste", key: TerminalPreferences.pasteKey, kind: .bool(true)),
        Setting(name: "terminal.paste-trims", key: TerminalPreferences.pasteTrimKey, kind: .bool(false)),
        Setting(name: "terminal.paste-joins-lines", key: TerminalPreferences.pasteJoinKey, kind: .bool(false)),
        Setting(name: "terminal.allow-clipboard-writes", key: TerminalPreferences.clipboardKey, kind: .bool(false)),
        Setting(name: "terminal.mouse-reporting", key: TerminalPreferences.mouseKey, kind: .bool(true)),
        Setting(name: "terminal.log-every-session", key: TerminalPreferences.logKey, kind: .bool(false)),
        Setting(name: "terminal.log-format", key: TerminalPreferences.logFormatKey, kind: .choice(TerminalLogFormat.allCases.map(\.rawValue), TerminalLogFormat.text.rawValue)),
        Setting(name: "history.enabled", key: ConnectionHistory.enabledKey, kind: .bool(true)),
        Setting(name: "history.commands", key: ConnectionHistory.commandsKey, kind: .bool(true)),
        Setting(name: "terminal.confirm-close", key: TerminalPreferences.confirmCloseKey, kind: .bool(true)),
        Setting(name: "terminal.right-click-paste", key: TerminalPreferences.rightClickPasteKey, kind: .bool(false)),
        Setting(name: "terminal.option-as-meta", key: TerminalPreferences.optionMetaKey, kind: .bool(false)),
        Setting(name: "terminal.copy-on-select", key: TerminalPreferences.copyOnSelectKey, kind: .bool(false)),
        Setting(name: "terminal.middle-click-paste", key: TerminalPreferences.middleClickPasteKey, kind: .bool(true)),
        Setting(name: "terminal.bell-bounces-dock", key: TerminalPreferences.bellDockKey, kind: .bool(true)),
        Setting(name: "terminal.inline-images", key: TerminalPreferences.inlineImagesKey, kind: .bool(true)),
        Setting(name: "terminal.zmodem", key: TerminalPreferences.zmodemKey, kind: .bool(true)),
        Setting(name: "terminal.zmodem-folder", key: TerminalPreferences.zmodemFolderKey, kind: .text("")),
        Setting(name: "terminal.ambiguous-wide", key: TerminalPreferences.ambiguousWideKey, kind: .bool(false)),
        Setting(name: "terminal.word-characters", key: TerminalPreferences.wordCharactersKey, kind: .text(TerminalPreferences.defaultWordCharacters)),
        Setting(name: "terminal.type", key: TerminalPreferences.terminalTypeKey, kind: .choice(TerminalPreferences.terminalTypes, "xterm-256color")),
        Setting(name: "ssh.keepalive-seconds", key: TerminalPreferences.keepAliveKey, kind: .int(0...3600, 30)),
        Setting(name: "ssh.reconnect", key: TerminalPreferences.reconnectKey, kind: .bool(true)),
        Setting(name: "shell-integration.local", key: ShellIntegration.localKey, kind: .bool(true)),
        Setting(name: "shell-integration.ssh", key: ShellIntegration.remoteKey, kind: .bool(false)),
        Setting(name: "notify-after-seconds", key: ShellIntegration.notifyKey, kind: .number(0...86_400, 10)),
        Setting(name: "workspace.reopen-tabs", key: WorkspaceModel.restoreTabsKey, kind: .bool(false)),
        Setting(name: "workspace.lock-after-minutes", key: WorkspaceModel.lockIdleKey, kind: .int(0...1440, 0)),
        Setting(name: "menu-bar-extra", key: MenuBarSettings.key, kind: .bool(true)),
        Setting(name: "dropdown-hotkey", key: DropdownWindow.hotkeyKey, kind: .choice(DropdownHotkey.allCases.map(\.rawValue), DropdownHotkey.off.rawValue)),
        Setting(name: "spotlight", key: SpotlightIndex.key, kind: .bool(true)),
        Setting(name: "reachability", key: Reachability.key, kind: .bool(true)),
        Setting(name: "desktop.share-clipboard", key: RemoteDesktopSession.clipboardKey, kind: .bool(true)),
        Setting(name: "video.format", key: VideoSettings.formatKey, kind: .choice(VideoFormat.allCases.map(\.rawValue), VideoFormat.mp4.rawValue)),
        Setting(name: "video.quality", key: VideoSettings.qualityKey, kind: .choice(VideoQuality.allCases.map(\.rawValue), VideoQuality.high.rawValue)),
        Setting(name: "video.frame-rate", key: VideoSettings.frameRateKey, kind: .choice(VideoSettings.frameRates, "30")),
        Setting(name: "video.show-pointer", key: VideoSettings.pointerKey, kind: .bool(true)),
        Setting(name: "video.folder", key: VideoSettings.folderKey, kind: .text("")),
        Setting(name: "safety.confirm-environments", key: SessionEnvironment.confirmingKey,
                kind: .list([SessionEnvironment.production.rawValue, SessionEnvironment.staging.rawValue], allowed: SessionEnvironment.allCases.map(\.rawValue))),
        Setting(name: "safety.risky-patterns", key: RiskyCommands.key, kind: .list(RiskyCommands.defaults, allowed: nil)),
    ]

    @MainActor static func value(_ setting: Setting) -> Any {
        let stored = preferences.object(forKey: setting.key)
        switch setting.kind {
        case .bool(let fallback): return stored as? Bool ?? fallback
        case .int(_, let fallback): return stored as? Int ?? fallback
        case .number(_, let fallback): return stored as? Double ?? fallback
        case .choice(_, let fallback):
            if let number = stored as? Int { return String(number) }
            return stored as? String ?? fallback
        case .text(let fallback): return stored as? String ?? fallback
        case .list(let fallback, _): return stored as? [String] ?? fallback
        }
    }

    /// `local`, `form`, or a saved session by ID or by a name only one session has.
    @MainActor static func newTabChoice(_ raw: String, _ tree: SessionTreeStore) throws -> NewTabChoice {
        if raw == "local" { return .local }
        if raw == "form" { return .form }
        let sessions = tree.nodes.filter { !$0.isFolder }
        if let found = sessions.first(where: { $0.id.uuidString.caseInsensitiveCompare(raw) == .orderedSame }) { return .saved(found.id) }
        let named = sessions.filter { $0.name == raw }
        guard named.count == 1 else {
            throw named.isEmpty ? Usage("Use local, form, or a saved session's ID or name. Run gloamux sessions list.")
                : WorkspaceError.invalid("More than one saved session is named \(raw). Use its ID.")
        }
        return .saved(named[0].id)
    }

    @MainActor static func settings(_ action: String, _ args: [String], _ model: WorkspaceModel, live: Bool) throws -> Any {
        func setting(_ name: String) throws -> Setting {
            guard let setting = settingsTable.first(where: { $0.name == name }) else { throw Usage("Unknown setting \(name). Run gloamux settings list.") }
            return setting
        }
        switch action {
        case "list":
            try count(args, 0...0)
            var all = Dictionary(uniqueKeysWithValues: settingsTable.map { ($0.name, value($0)) })
            all["language"] = model.language.rawValue
            return all
        case "get":
            try count(args, 1...1)
            if args[0] == "language" { return ["language": model.language.rawValue] }
            let found = try setting(args[0])
            return [found.name: value(found)]
        case "reset":
            try count(args, 1...1)
            if args[0] == "language" { return try settings("set", ["language", AppLanguage.system.rawValue], model, live: live) }
            let found = try setting(args[0])
            preferences.removeObject(forKey: found.key)
            return [found.name: value(found)]
        case "set":
            try count(args, 2...2)
            let raw = args[1]
            if args[0] == "language" {
                guard let language = AppLanguage(rawValue: raw) else {
                    let choices = AppLanguage.allCases.map(\.rawValue).joined(separator: ", ")
                    throw Usage("Choose a language: \(choices).")
                }
                guard live else { throw WorkspaceError.invalid("Open Gloamux to change its language.") }
                model.language = language
                return ["language": language.rawValue]
            }
            let found = try setting(args[0])
            let stored: Any
            switch found.kind {
            case .bool:
                guard ["true", "false", "on", "off"].contains(raw) else { throw Usage("Use on or off.") }
                stored = raw == "true" || raw == "on"
            case .int(let range, _):
                guard let number = Int(raw), range.contains(number) else { throw Usage("Enter a whole number from \(range.lowerBound) to \(range.upperBound).") }
                stored = number
            case .number(let range, _):
                guard let number = Double(raw), range.contains(number) else { throw Usage("Enter a number from \(range.lowerBound) to \(range.upperBound).") }
                stored = number
            case .choice(let choices, _):
                guard choices.contains(raw) else { throw Usage("Choose \(choices.joined(separator: ", ")).") }
                stored = found.key == TerminalPreferences.scrollbackKey ? Int(raw) ?? TerminalPreferences.defaultScrollback : raw
            case .text where found.key == TerminalPreferences.newTabKey:
                stored = try newTabChoice(raw, model.sessionTree).raw
            case .text:
                guard raw.count <= 128 else { throw Usage("Enter up to 128 characters.") }
                if found.key == TerminalPreferences.fontKey, !raw.isEmpty, !TerminalPreferences.monospacedFamilies().contains(raw) {
                    throw WorkspaceError.invalid("No fixed-pitch font family named \(raw) is installed.")
                }
                stored = raw
            case .list(_, let allowed):
                let items: [String]
                if allowed != nil {
                    items = raw == "-" ? [] : raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard let allowed, items.allSatisfy(allowed.contains) else { throw Usage("Use a comma-separated list of \(allowed?.joined(separator: ", ") ?? ""), or -.") }
                } else {
                    guard let data = raw.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) as? [String],
                          parsed.count <= 64 else { throw Usage("Pass the patterns as a JSON array of strings.") }
                    for pattern in parsed {
                        guard !pattern.isEmpty, pattern.count <= 512, (try? NSRegularExpression(pattern: pattern)) != nil else {
                            throw WorkspaceError.invalid("Not a valid regular expression: \(pattern)")
                        }
                    }
                    items = parsed
                }
                stored = items
            }
            preferences.set(stored, forKey: found.key)
            return [found.name: value(found)]
        default: throw Usage("Unknown settings operation.")
        }
    }

    @MainActor static func triggers(_ action: String, _ args: [String], _ model: WorkspaceModel) throws -> Any {
        let store = model.triggers
        // A file that could not be used is read again, so a repaired one works without reopening Gloamux.
        if store.loadError != nil { store.reload() }
        if let problem = store.loadError { throw WorkspaceError.invalid(problem) }
        func find(_ raw: String) throws -> OutputTrigger {
            guard let id = UUID(uuidString: raw), let found = store.triggers.first(where: { $0.id == id }) else {
                throw WorkspaceError.invalid("No trigger with that ID. Run gloamux triggers list.")
            }
            return found
        }
        func describe(_ trigger: OutputTrigger) -> [String: Any] {
            ["id": trigger.id.uuidString, "name": trigger.name, "pattern": trigger.pattern, "regex": trigger.regex,
             "caseSensitive": trigger.caseSensitive, "action": trigger.action.rawValue, "enabled": trigger.enabled]
        }
        /// NAME PATTERN [notify|sound|mark] [text|regex] [ignore-case|match-case]
        func configure(_ trigger: inout OutputTrigger, _ rest: [String]) throws {
            trigger.name = rest[0]; trigger.pattern = rest[1]
            if let raw = rest.dropFirst(2).first {
                guard let action = OutputTrigger.Action(rawValue: raw) else { throw Usage("Choose notify, sound, or mark.") }
                trigger.action = action
            }
            if let raw = rest.dropFirst(3).first {
                guard ["text", "regex"].contains(raw) else { throw Usage("Choose text or regex.") }
                trigger.regex = raw == "regex"
            }
            if let raw = rest.dropFirst(4).first {
                guard ["ignore-case", "match-case"].contains(raw) else { throw Usage("Choose ignore-case or match-case.") }
                trigger.caseSensitive = raw == "match-case"
            }
            guard !trigger.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw Usage("Enter a trigger name.") }
        }
        switch action {
        case "list":
            try count(args, 0...0)
            return store.triggers.map(describe)
        case "add":
            try count(args, 2...5)
            var trigger = OutputTrigger(name: "", pattern: "")
            try configure(&trigger, args)
            try store.save(trigger)
            return describe(trigger)
        case "edit":
            try count(args, 3...6)
            var trigger = try find(args[0])
            try configure(&trigger, Array(args.dropFirst()))
            try store.save(trigger)
            return describe(trigger)
        case "enable", "disable":
            try count(args, 1...1)
            var trigger = try find(args[0])
            trigger.enabled = action == "enable"
            try store.save(trigger)
            return describe(trigger)
        case "remove":
            try count(args, 1...1)
            let trigger = try find(args[0])
            try store.remove(trigger.id)
            return ["id": trigger.id.uuidString]
        default: throw Usage("Unknown triggers operation.")
        }
    }

    @MainActor static func layout(_ action: String, _ args: [String], _ model: WorkspaceModel, live: Bool) throws -> Any {
        switch action {
        case "get":
            try count(args, 0...0)
        case "set":
            try count(args, 1...1)
            guard let layout = WorkspaceLayout(argument: args[0]) else { throw Usage("Choose default, classic, or workbench.") }
            try model.selectLayout(layout)
        case "dropdown":
            try count(args, 0...0)
            guard live else { throw WorkspaceError.invalid("Open Gloamux to show the dropdown window.") }
            guard DropdownWindow.hotkey != .off else { throw Usage("Choose a dropdown-hotkey setting first.") }
            return ["dropdown": DropdownWindow.shared.toggle()]
        default: throw Usage("Unknown layout operation.")
        }
        return ["layout": model.layout.argument]
    }

    /// `vault status|lock`, `signins list|remove`, and `workspace lock`. Unlocking and reading secrets stay in the app.
    @MainActor static func security(_ command: String, _ action: String, _ args: [String], _ model: WorkspaceModel) async throws -> Any {
        try count(args, command == "signins" && action == "remove" ? 1...1 : 0...0)
        switch (command, action) {
        case ("vault", "status"):
            return ["vault": await model.vault.state]
        case ("vault", "lock"):
            await model.lockVault()
            return ["vault": await model.vault.state]
        case ("workspace", "lock"):
            model.lockWorkspace()
            return ["locked": model.workspaceLocked]
        case ("signins", "list"), ("signins", "remove"):
            // The same Touch ID or Mac password check as the Saved passwords window, shown by Gloamux.
            guard await model.authorizeSavedSignIns() else { throw WorkspaceError.invalid("Touch ID or the Mac password is required.") }
            let saved = await model.savedSignIns()
            if action == "list" {
                return saved.map { ["id": $0.id, "account": $0.account, "kind": $0.isPassphrase ? "passphrase" : "password",
                                    "place": $0.place == .vault ? "vault" : "mac", "sessions": $0.sessions] as [String: Any] }
            }
            guard let item = saved.first(where: { $0.id == args[0] }) else { throw WorkspaceError.invalid("No saved password with that ID.") }
            try await model.removeSignIn(item)
            return ["id": item.id]
        default: throw Usage("Unknown \(command) operation.")
        }
    }
}
