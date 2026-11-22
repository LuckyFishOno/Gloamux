import Foundation
import AppKit
import UserNotifications
import Terminal

/// Shell integration: the shell reports where each prompt, command, and its output start (OSC 133), its exit status,
/// and its folder (OSC 7). Local zsh loads it automatically; other shells and SSH sessions get a one-line hook typed
/// into them on request (or automatically for SSH when the user turns that on).
enum ShellIntegration {
    /// Preference keys, shared by the settings window and the workspace.
    static let localKey = "Gloamux.shellIntegration.local"
    static let remoteKey = "Gloamux.shellIntegration.ssh"
    static let notifyKey = "Gloamux.notifyAfterSeconds"

    static var local: Bool { UserDefaults.standard.object(forKey: localKey) as? Bool ?? true }
    static var remote: Bool { UserDefaults.standard.bool(forKey: remoteKey) }
    /// Commands that run at least this long notify when they finish out of sight; 0 turns notifications off.
    static var notifyAfter: TimeInterval { UserDefaults.standard.object(forKey: notifyKey) as? Double ?? 10 }

    /// One line for bash or zsh. The leading space keeps it out of most shell histories. In zsh the exit status is
    /// read first and the marks are written last, after prompt themes have built `PS1`.
    static let hook = #" if [ -n "$ZSH_VERSION" ]; then _gloamux_s(){ _gloamux_rc=$?; }; _gloamux_p(){ printf '\033]133;D;%s\007\033]7;file://%s%s\007\033]133;A\007' "$_gloamux_rc" "$HOST" "$PWD"; [[ $PS1 == *133\;B* ]] || PS1="$PS1%{$(printf '\033]133;B\007')%}"; }; _gloamux_x(){ printf '\033]133;C\007'; }; precmd_functions=(_gloamux_s $precmd_functions _gloamux_p); preexec_functions+=(_gloamux_x); else _gloamux_p(){ _gloamux_rc=$?; printf '\033]133;D;%s\007\033]7;file://%s%s\007\033]133;A\007' "$_gloamux_rc" "$HOSTNAME" "$PWD"; return $_gloamux_rc; }; PROMPT_COMMAND="_gloamux_p${PROMPT_COMMAND:+;$PROMPT_COMMAND}"; case "$PS1" in *133\;B*) ;; *) PS1="$PS1\[$(printf '\033]133;B\007')\]";; esac; PS0="${PS0}$(printf '\033]133;C\007')"; fi"#

    /// zsh startup files that hand over to the user's own and then add the marks, like the integrations in Visual
    /// Studio Code and Ghostty. `ZDOTDIR` points here only for the first file; the user's files load as usual.
    static let zshenv = #"""
    # Gloamux shell integration. Restores your ZDOTDIR, loads your .zshenv, then adds prompt marks (OSC 133) and the
    # current folder (OSC 7) once your .zshrc has run.
    if [[ -n "${GLOAMUX_USER_ZDOTDIR+x}" ]]; then ZDOTDIR="$GLOAMUX_USER_ZDOTDIR"; else unset ZDOTDIR; fi
    unset GLOAMUX_USER_ZDOTDIR
    [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]] && source "${ZDOTDIR:-$HOME}/.zshenv"
    if [[ -o interactive ]]; then
      _gloamux_install() {
        precmd_functions=(${precmd_functions:#_gloamux_install})
        _gloamux_s() { _gloamux_rc=$?; }
        _gloamux_p() {
          print -n "\e]133;D;${_gloamux_rc}\a\e]7;file://${HOST}${PWD// /%20}\a\e]133;A\a"
          [[ $PS1 == *133\;B* ]] || PS1="$PS1%{"$'\e]133;B\a'"%}"
        }
        _gloamux_x() { print -n "\e]133;C\a"; }
        precmd_functions=(_gloamux_s $precmd_functions _gloamux_p)
        preexec_functions+=(_gloamux_x)
        print -n "\e]7;file://${HOST}${PWD// /%20}\a\e]133;A\a"
        [[ $PS1 == *133\;B* ]] || PS1="$PS1%{"$'\e]133;B\a'"%}"
      }
      precmd_functions+=(_gloamux_install)
    fi
    """#

    /// Writes the zsh files to a private folder in this user's temporary directory and returns it.
    static func zshDirectory() -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-shell-integration/zsh", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let file = folder.appendingPathComponent(".zshenv")
            if (try? String(contentsOf: file, encoding: .utf8)) != zshenv {
                try Data(zshenv.utf8).write(to: file, options: .atomic)
            }
            return folder
        } catch { return nil }
    }

    /// Quotes a value for a POSIX shell command line.
    static func quote(_ value: String) -> String {
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_./:@=+,%".unicodeScalars.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Jumps and selections the terminal view performs for the menu, the command palette, and the pane header.
enum TerminalNavigation: Equatable {
    case previousPrompt, nextPrompt, selectLastOutput
    /// Scrolls to an absolute line and selects through the second one when given.
    case lines(Int, through: Int?)
}

struct TerminalNavigationRequest: Equatable {
    let action: TerminalNavigation
    var nonce = UUID()
}

/// Text of a command's duration, such as "850 ms", "12 s", or "3 min 4 s".
func formatDuration(_ seconds: TimeInterval) -> String {
    if seconds < 1 { return "\(Int(seconds * 1000)) ms" }
    if seconds < 60 { return String(format: seconds < 10 ? "%.1f s" : "%.0f s", seconds) }
    let total = Int(seconds.rounded())
    if total < 3600 { return "\(total / 60) min \(total % 60) s" }
    return "\(total / 3600) h \(total % 3600 / 60) min"
}

/// Opens links from terminal text. Web and mail links open in their apps; a file link is shown in Finder, and only
/// for this Mac's own files, so a link printed by a server cannot open or run anything here.
enum TerminalLinks {
    static let attribute = NSAttributedString.Key("GloamuxTerminalLink")
    private static let webSchemes: Set<String> = ["http", "https", "mailto", "ftp", "sftp", "ssh"]
    private static let pattern = try! NSRegularExpression(pattern: #"\b(?:https?|ftp)://[^\s<>"'`\x00-\x1f]+"#)

    static func target(_ text: String, local: Bool) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        if webSchemes.contains(scheme) { return url }
        if scheme == "file", local, url.host == nil || url.host == "" || url.host == "localhost" || url.host == ProcessInfo.processInfo.hostName {
            return url
        }
        return nil
    }

    @MainActor static func open(_ text: String, local: Bool) -> Bool {
        guard let url = target(text, local: local) else { return false }
        if url.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
        return true
    }

    /// Web addresses in plain text, without trailing punctuation that usually ends a sentence.
    static func detect(in text: String) -> [(NSRange, String)] {
        guard text.contains("://") else { return [] }
        let nsText = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            var range = match.range
            while range.length > 0, let last = nsText.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)).first,
                  ".,;:!?)]}'\"".contains(last) {
                if last == ")", nsText.substring(with: range).contains("(") { break }
                range.length -= 1
            }
            return range.length > 8 ? (range, nsText.substring(with: range)) : nil
        }
    }
}

/// Posts a notification when a long command finishes in a tab you are not looking at. Clicking it shows the tab.
@MainActor final class CommandNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CommandNotifier()
    weak var model: WorkspaceModel?
    private var authorized: Bool?

    /// Notifications need an app bundle; tests and the command-line tool have none.
    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    func notify(title: String, body: String, tab: UUID) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task { @MainActor in
            if authorized == nil {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorized == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body; content.sound = .default
            content.userInfo = ["tab": tab.uuidString]
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo["tab"] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if let id, let model = self.model { model.reveal(tab: id) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
