import SwiftUI
import AppKit
import Terminal

/// The Settings window's scene identifier. Gloamux opens its own window instead of SwiftUI's `Settings` scene, so
/// the app menu has a single, translated **Settings…** item.
public enum SettingsWindow {
    public static let id = "settings"
    static let showPane = Notification.Name("GloamuxSettingsShowPane")
    /// The pane a toolbar button asked for, taken when the window appears or is already open.
    @MainActor static var requestedPane: String?

    /// Asks the Settings window to show one pane; call before `openWindow(id: SettingsWindow.id)`.
    @MainActor static func request(_ pane: String) {
        requestedPane = pane
        NotificationCenter.default.post(name: showPane, object: nil)
    }
}

/// The app menu's **Settings…** item, in the workspace's language. It is there before the workspace finishes
/// loading, using the saved language until then.
public struct PreferencesMenuLink: View {
    private let model: WorkspaceModel?
    @Environment(\.openWindow) private var openWindow
    public init(model: WorkspaceModel?) { self.model = model }
    public var body: some View {
        Button { openWindow(id: SettingsWindow.id) } label: {
            if let model { MenuTitle(model: model) } else { Text(T("Settings…")) }
        }
        .keyboardShortcut(",", modifiers: .command)
    }

    private struct MenuTitle: View {
        @ObservedObject var model: WorkspaceModel
        var body: some View { Text(UIStrings.text("Settings…", language: model.language)) }
    }
}

/// The Settings window: General (language) and Appearance (workspace theme).
public struct PreferencesView: View {
    enum Pane: String, Hashable { case general, terminal, text, triggers, safety, agents, appearance }
    @ObservedObject private var model: WorkspaceModel
    @Environment(\.appTextScale) private var textScale
    /// `--preferences-pane terminal` opens on another pane, for screenshots.
    @State private var pane: Pane = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--preferences-pane"), index + 1 < arguments.count else { return .general }
        return Pane(rawValue: arguments[index + 1]) ?? .general
    }()
    public init(model: WorkspaceModel) { self.model = model }

    private func takeRequestedPane() {
        guard let requested = SettingsWindow.requestedPane.flatMap(Pane.init(rawValue:)) else { return }
        SettingsWindow.requestedPane = nil
        pane = requested
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Pane buttons along the top, icon over name, as in the system's own settings windows.
            // Seven panes fit the 540-point window with a margin at both ends.
            HStack(spacing: 2) {
                paneButton(.general, T("General"), "gearshape")
                paneButton(.terminal, T("Terminal"), "terminal")
                paneButton(.text, T("Text"), "textformat")
                paneButton(.triggers, T("Triggers"), "bolt.badge.clock")
                paneButton(.safety, T("Safety"), "exclamationmark.shield")
                paneButton(.agents, T("Agents"), "sparkles")
                paneButton(.appearance, T("Appearance"), "paintpalette")
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(model.theme.header.color)
            Rectangle().fill(model.theme.foreground.color.opacity(0.1)).frame(height: 1)
            Group {
                switch pane {
                case .general: GeneralSettings(model: model)
                case .terminal: TerminalSettings(model: model)
                case .text: TextSettings()
                case .triggers: OutputTriggerSettings(store: model.triggers)
                case .safety: SafetySettings(model: model)
                case .agents: AgentSettings(model: model)
                case .appearance: AppearanceSettings(model: model)
                }
            }
            .padding(20)
        }
        // Wider with larger app text, so the pane buttons and labels keep their room.
        .frame(width: (540 * max(1, textScale)).rounded())
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(T("Settings"))
        .onAppear(perform: takeRequestedPane)
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindow.showPane)) { _ in takeRequestedPane() }
        .background(model.theme.background.color)
        .foregroundStyle(model.theme.foreground.color)
        .background(ThemeTitlebar(theme: model.theme))
        .background(WindowControlsVisible())
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .tint(model.theme.accent.color)
    }

    private func paneButton(_ value: Pane, _ title: String, _ symbol: String) -> some View {
        let selected = pane == value
        return Button { pane = value } label: {
            VStack(spacing: 3) {
                // Some symbols, such as textformat, change with the Mac's language (格式 in Chinese); keep the Latin "Aa".
                Image(systemName: symbol).appFont(.system(size: 18)).environment(\.locale, Locale(identifier: "en"))
                Text(title).appFont(.system(size: 11))
            }
            .foregroundStyle(selected ? model.theme.accent.color : model.theme.foreground.color.opacity(0.7))
            .frame(minWidth: 60).padding(.vertical, 5).padding(.horizontal, 5)
            .background(selected ? model.theme.foreground.color.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Keeps the window's own close, minimize, and zoom buttons visible. SwiftUI lays this window's content under the
/// titlebar and in front of it, which hides them; content that starts below the titlebar leaves them showing, and the
/// titlebar keeps the theme's color.
private struct WindowControlsVisible: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlsView { ControlsView() }
    func updateNSView(_ view: ControlsView, context: Context) { view.show() }

    final class ControlsView: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); show() }
        func show() {
            guard let window, window.styleMask.contains(.fullSizeContentView) else { return }
            window.styleMask.remove(.fullSizeContentView)
        }
    }
}

/// Language, and later other app-wide choices.
private struct GeneralSettings: View {
    @ObservedObject var model: WorkspaceModel
    @AppStorage(WorkspaceModel.restoreTabsKey) private var reopenTabs = false
    @AppStorage(WorkspaceModel.lockIdleKey) private var lockAfter = 0
    @ObservedObject private var updates = AppUpdates.shared


    var body: some View {
        Form {
            AppPicker(title: T("Language"), selection: $model.language,
                      current: model.language == .system ? String(format: T("System default (%@)"), AppLanguage.title(for: model.language.resolved())) : model.language.title) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language == .system ? String(format: T("System default (%@)"), AppLanguage.title(for: language.resolved())) : language.title)
                        .tag(language)
                }
            }
            label: {
                HStack(spacing: 6) {
                    Text(T("Language"))
                    InfoButton(T("Language changes apply immediately. System default follows the language set in System Settings."))
                }
            }
            .accessibilityIdentifier("languagePicker")
            Toggle(isOn: $reopenTabs) {
                HStack(spacing: 6) {
                    Text(T("Reopen tabs at launch"))
                    InfoButton(T("Opens the saved sessions and local terminals that were open when Gloamux quit. Each session connects on its own, so one that fails leaves the others open."))
                }
            }
            AppPicker(title: T("Lock the workspace"), selection: $lockAfter,
                      current: lockAfter == 0 ? T("Never") : String(format: T("After %d minutes"), lockAfter)) {
                Text(T("Never")).tag(0)
                Text(String(format: T("After %d minutes"), 5)).tag(5)
                Text(String(format: T("After %d minutes"), 15)).tag(15)
                Text(String(format: T("After %d minutes"), 30)).tag(30)
                Text(String(format: T("After %d minutes"), 60)).tag(60)
            } label: {
                HStack(spacing: 6) {
                    Text(T("Lock the workspace"))
                    InfoButton(T("Covers every terminal after this long without using Gloamux. Sessions stay connected. Unlock with Touch ID or the Mac password. Lock at any time with ⌃⌘L."))
                }
            }
            if updates.isAvailable {
                Toggle(isOn: Binding(get: { updates.checksAutomatically }, set: { updates.checksAutomatically = $0 })) {
                    HStack(spacing: 6) {
                        Text(T("Check for updates automatically"))
                        InfoButton(T("Once a day, Gloamux asks GitHub whether a newer version is out, sending only the app's name and version. Check at any time from Gloamux › Check for Updates."))
                    }
                }
                .accessibilityIdentifier("automaticUpdatesToggle")
            }
            LabeledContent {
                HStack(spacing: 8) {
                    Button(T("Export…")) { model.exportConfiguration() }
                    Button(T("Import…")) { model.importConfiguration() }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(T("All settings"))
                    InfoButton(T("Export saves sessions with their accounts, quick commands, triggers, runbooks, host keys, the theme, the layout, settings, and the password vault in one file, with a .sha256 file next to it. The vault stays sealed under its master password, which is not saved in the file. Passwords remembered on this Mac are not included. Import replaces all of these and restarts Gloamux. The current ones are kept in the Backups folder of Gloamux's data folder first."))
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .padding(-8)
    }
}

/// Shell integration, notifications, the menu bar item, and how the terminal behaves: scrollback, the bell, pasting,
/// the mouse, the clipboard, and session logs.
private struct TerminalSettings: View {
    @ObservedObject var model: WorkspaceModel
    @AppStorage(ShellIntegration.localKey) private var local = true
    @AppStorage(ShellIntegration.remoteKey) private var remote = false
    @AppStorage(ShellIntegration.notifyKey) private var notifyAfter = 10.0
    @AppStorage(MenuBarSettings.key) private var menuBar = true
    @AppStorage(TerminalPreferences.scrollbackKey) private var scrollback = TerminalPreferences.defaultScrollback
    @AppStorage(TerminalPreferences.bellKey) private var bell = BellStyle.flash.rawValue
    @AppStorage(TerminalPreferences.pasteKey) private var confirmPaste = true
    @AppStorage(TerminalPreferences.mouseKey) private var mouse = true
    @AppStorage(TerminalPreferences.clipboardKey) private var clipboard = false
    @AppStorage(TerminalPreferences.logKey) private var logEverySession = false
    @AppStorage(TerminalPreferences.logFormatKey) private var logFormat = TerminalLogFormat.text.rawValue
    @AppStorage(TerminalPreferences.confirmCloseKey) private var confirmClose = true
    @AppStorage(TerminalPreferences.rightClickPasteKey) private var rightClickPaste = false
    @AppStorage(TerminalPreferences.optionMetaKey) private var optionMeta = false
    @AppStorage(TerminalPreferences.keepAliveKey) private var keepAlive = 30
    @AppStorage(TerminalPreferences.terminalTypeKey) private var terminalType = "xterm-256color"
    @AppStorage(TerminalPreferences.reconnectKey) private var reconnect = true
    @AppStorage(TerminalPreferences.newTabLocalKey) private var newTabLocal = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $newTabLocal) {
                    label(T("New tabs open a local terminal"), T("The + buttons open a terminal on this Mac at once, without the New connection form. New connection (⇧⌘N) still opens the form."))
                }
                Toggle(isOn: $local) {
                    label(T("Local shell integration"), T("zsh reports each prompt, command, exit status, and folder. Then ⌘↑ and ⌘↓ jump between prompts, the pane header shows the last result, and ⌘T opens in the same folder. Applies to new terminals."))
                }
                Toggle(isOn: $remote) {
                    label(T("SSH shell integration"), T("Types a one-line hook into bash or zsh after the terminal opens. It changes only that shell session. You can also turn it on for one terminal from the Terminal menu."))
                }
                AppPicker(title: T("Notify after long commands"), selection: $notifyAfter, current: Self.duration(Int(notifyAfter))) {
                    Text(T("Off")).tag(0.0)
                    Text("5 s").tag(5.0)
                    Text("10 s").tag(10.0)
                    Text("30 s").tag(30.0)
                    Text("1 min").tag(60.0)
                    Text("5 min").tag(300.0)
                } label: {
                    label(T("Notify after long commands"), T("Only for tabs you are not looking at. Needs shell integration."))
                }
                Toggle(isOn: $menuBar) {
                    label(T("Show in menu bar"), T("Quick connect, recent sessions, and saved tunnels from the menu bar."))
                }
            }
            Section {
                AppPicker(title: T("Check idle SSH connections"), selection: $keepAlive, current: Self.duration(keepAlive)) {
                    Text(T("Off")).tag(0)
                    Text("15 s").tag(15)
                    Text("30 s").tag(30)
                    Text("1 min").tag(60)
                    Text("2 min").tag(120)
                } label: {
                    label(T("Check idle SSH connections"), T("After this long without output, Gloamux asks the server for a reply. Routers then keep the connection open, and a dead connection is noticed instead of freezing. The check runs no command on the server."))
                }
                AppPicker(title: T("Terminal type"), selection: $terminalType, current: terminalType) {
                    ForEach(TerminalPreferences.terminalTypes, id: \.self) { Text($0).tag($0) }
                } label: {
                    label(T("Terminal type"), T("The TERM value SSH sessions report. Programs on the server use it to pick colors and keys. Change it only when a server lacks xterm-256color. Applies to new terminals."))
                }
                Toggle(isOn: $reconnect) {
                    label(T("Reconnect automatically"), T("When a saved session loses its connection, Gloamux connects again after 2, 5, 10, 30, and 60 seconds. Sessions set to ask before each connection wait for you. After the Mac wakes, every connection is checked at once."))
                }
            }
            Section {
                AppPicker(title: T("Scrollback"), selection: $scrollback, current: String(format: T("%@ lines"), scrollback.formatted())) {
                    ForEach(TerminalPreferences.scrollbackChoices, id: \.self) { lines in
                        Text(String(format: T("%@ lines"), lines.formatted())).tag(lines)
                    }
                } label: {
                    label(T("Scrollback"), T("Lines kept above the screen in each terminal. More lines use more memory."))
                }
                AppPicker(title: T("Bell"), selection: $bell,
                          current: T(bell == BellStyle.sound.rawValue ? "Sound" : bell == BellStyle.off.rawValue ? "Off" : "Flash")) {
                    Text(T("Flash")).tag(BellStyle.flash.rawValue)
                    Text(T("Sound")).tag(BellStyle.sound.rawValue)
                    Text(T("Off")).tag(BellStyle.off.rawValue)
                } label: {
                    label(T("Bell"), T("In a tab you are not looking at, the tab also shows a bell."))
                }
                Toggle(isOn: $confirmPaste) {
                    label(T("Confirm multiline paste"), T("Shows the text before it is pasted, so you can check or edit it. Each line break can run a command."))
                }
                Toggle(isOn: $mouse) {
                    label(T("Send mouse to programs"), T("vim, tmux, htop, and similar programs get clicks, drags, and the scroll wheel. Hold Option to select text instead."))
                }
                Toggle(isOn: $confirmClose) {
                    label(T("Confirm before closing"), T("Asks before closing a tab that is still connected, or a local terminal where a command is running."))
                }
                Toggle(isOn: $rightClickPaste) {
                    label(T("Right-click pastes"), T("As in PuTTY. Control-click still shows the menu."))
                }
                Toggle(isOn: $optionMeta) {
                    label(T("Use Option as Meta"), T("Option and a key send Escape and the key, for word movement in bash, zsh, and Emacs. Option no longer types special characters."))
                }
                Toggle(isOn: $clipboard) {
                    label(T("Let programs copy to the clipboard"), T("Programs can put text on this Mac's clipboard with OSC 52, such as yanking in vim or tmux over SSH. A server you connect to could also change your clipboard. Programs can never read it."))
                }
            }
            Section {
                Toggle(isOn: $logEverySession) {
                    label(T("Log every session"), T("Saves what each terminal shows to a file, from when it opens until it closes. Likely secrets are masked. You can also start a log for one terminal from the Terminal menu."))
                }
                AppPicker(title: T("Log format"), selection: $logFormat,
                          current: T(logFormat == TerminalLogFormat.raw.rawValue ? "With escape sequences" : "Plain text")) {
                    Text(T("Plain text")).tag(TerminalLogFormat.text.rawValue)
                    Text(T("With escape sequences")).tag(TerminalLogFormat.raw.rawValue)
                } label: {
                    label(T("Log format"), T("Plain text is easy to read and search. With escape sequences keeps colors for replaying with cat."))
                }
                LabeledContent(T("Session logs")) {
                    Button(T("Show in Finder")) { model.logs.revealFolder() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .padding(-8)
    }

    /// "Off", "5 s", or "1 min", as the pickers list them.
    static func duration(_ seconds: Int) -> String {
        seconds == 0 ? T("Off") : seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min"
    }

    private func label(_ title: String, _ info: String) -> some View {
        HStack(spacing: 6) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            InfoButton(info)
        }
    }
}

/// The terminal font, its size, the cursor, and the background's opacity.
private struct TextSettings: View {
    @AppStorage(TerminalPreferences.fontKey) private var font = ""
    @AppStorage(TerminalPreferences.fontSizeKey) private var size = TerminalPreferences.defaultFontSize
    @AppStorage(TerminalPreferences.cursorKey) private var cursor = CursorShape.block.rawValue
    @AppStorage(TerminalPreferences.blinkKey) private var blinks = false
    @AppStorage(TerminalPreferences.opacityKey) private var opacity = 1.0
    @AppStorage(AppTextSize.key) private var appSize = AppTextSize.defaultSize
    @State private var families: [String] = []

    var body: some View {
        Form {
            Section(T("Application")) {
                LabeledContent {
                    Stepper(value: $appSize, in: AppTextSize.sizes, step: 1) {
                        Text("\(Int(AppTextSize.clamped(appSize))) pt").monospacedDigit()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(T("Application font size")).fixedSize(horizontal: false, vertical: true)
                        InfoButton(T("Lists, forms, toolbars, and this window. ⌘+ and ⌘− change it outside a session, ⌥⌘+ and ⌥⌘− from anywhere; ⌥⌘0 goes back to 13 pt."))
                    }
                }
            }
            Section(T("Session")) {
                AppPicker(T("Font"), selection: $font, current: font.isEmpty ? T("System monospaced") : font) {
                    Text(T("System monospaced")).tag("")
                    if !families.isEmpty { Divider() }
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent {
                    Stepper(value: $size, in: TerminalPreferences.fontSizes, step: 1) {
                        Text("\(Int(size)) pt").monospacedDigit()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(T("Session font size")).fixedSize(horizontal: false, vertical: true)
                        InfoButton(T("⌘+ and ⌘− change it in any session; ⌘0 goes back to 13 pt."))
                    }
                }
                Text(T("The quick brown fox · 終端機 · 0O1lI"))
                    .font(previewFont)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(T("Font preview"))
            }
            Section {
                Picker(T("Cursor"), selection: $cursor) {
                    Text(T("Block")).tag(CursorShape.block.rawValue)
                    Text(T("Underline")).tag(CursorShape.underline.rawValue)
                    Text(T("Bar")).tag(CursorShape.bar.rawValue)
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $blinks) {
                    HStack(spacing: 6) {
                        Text(T("Blinking cursor")).fixedSize(horizontal: false, vertical: true)
                        InfoButton(T("Programs such as vim can change the cursor's shape and blinking while they run."))
                    }
                }
                LabeledContent {
                    HStack {
                        Slider(value: $opacity, in: 0.3...1)
                        Text("\(Int((opacity * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(T("Background opacity")).fixedSize(horizontal: false, vertical: true)
                        InfoButton(T("Below 100%, what is behind the window shows through the terminal, blurred."))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .padding(-8)
        .task { if families.isEmpty { families = TerminalPreferences.monospacedFamilies() } }
    }

    private var previewFont: Font {
        Font(TerminalFonts.make(name: font, size: min(max(size, TerminalPreferences.fontSizes.lowerBound), TerminalPreferences.fontSizes.upperBound)).regular)
    }
}

/// Environments that confirm risky commands, the patterns they match, reachability checks, and host key history.
private struct SafetySettings: View {
    @ObservedObject var model: WorkspaceModel
    @State private var confirming = SessionEnvironment.confirming
    @State private var patterns = RiskyCommands.patterns.joined(separator: "\n")
    @AppStorage(Reachability.key) private var reachability = true

    var body: some View {
        Form {
            Section {
                HStack(spacing: 6) {
                    Text(T("Confirm risky commands in")).fixedSize(horizontal: false, vertical: true)
                    InfoButton(T("Tag a session or folder with an environment from its right-click menu. In the environments chosen here, a command that matches a pattern below waits for you to confirm it."))
                }
                HStack(spacing: 14) {
                    ForEach(SessionEnvironment.allCases) { environment in
                        Toggle(T(environment.title), isOn: Binding(get: { confirming.contains(environment) }, set: { on in
                            if on { confirming.insert(environment) } else { confirming.remove(environment) }
                            SessionEnvironment.confirming = confirming
                        }))
                        .toggleStyle(.checkbox)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(T("Patterns"))
                        InfoButton(T("One regular expression per line, matched without regard to case."))
                        Spacer()
                        Button(T("Restore defaults")) { patterns = RiskyCommands.defaults.joined(separator: "\n"); save() }
                            .controlSize(.small)
                    }
                    TextEditor(text: $patterns)
                        .appFont(.system(size: 11, design: .monospaced))
                        .frame(height: 120)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                        .onChange(of: patterns) { _, _ in save() }
                }
            }
            Section {
                Toggle(isOn: $reachability) {
                    HStack(spacing: 6) {
                        Text(T("Show host reachability")).fixedSize(horizontal: false, vertical: true)
                        InfoButton(T("Opens and closes a TCP connection to each visible saved host's SSH port every few minutes. No sign-in is attempted."))
                    }
                }
                HStack {
                    Text(T("Host key history"))
                    Spacer()
                    Button(T("Show…")) { model.openTool(.hostKeyHistory) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .padding(-8)
    }

    private func save() {
        RiskyCommands.patterns = patterns.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// The workspace theme, previewed live and kept only when applied.
private struct AppearanceSettings: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(T("Color theme")).appFont(.headline)
            // A click applies the theme, like every other choice in Settings.
            ThemeGallery(themes: model.themes, selectedID: model.themeID) { id in
                do { try model.selectTheme(id); model.error = nil }
                catch { model.error = error.localizedDescription }
            }.frame(height: 312)
            if let error = model.error { Text(T(error)).foregroundStyle(.red).appFont(.caption) }
        }
        .padding(.horizontal, 4)
    }
}

