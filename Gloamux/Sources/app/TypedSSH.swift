import Foundation

/// An `ssh` command run inside a terminal, and how it went as the terminal shows it.
struct TypedSSH: Equatable {
    enum Outcome: Equatable { case connected, failed(String?) }

    /// Where it connects to, as it was typed: `user@host` and a port other than the default.
    let destination: String
    /// Its errors are not shown, so nothing shown does not mean it connected.
    let quiet: Bool

    /// Reads the last command of a line, or nil when that is not an `ssh` that signs in to a server.
    init?(_ line: String) {
        let command = line.replacingOccurrences(of: "&&", with: ";").components(separatedBy: ";").last ?? ""
        // Its errors may go elsewhere, or it may not be what the prompt waits for.
        guard !command.contains(where: { "|<>&`".contains($0) }) else { return nil }
        var words = command.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }[...]
        // What may stand before it: variables, sudo, and sshpass with its own options.
        while let word = words.first, (word as NSString).lastPathComponent != "ssh" {
            switch (word as NSString).lastPathComponent {
            case "sudo", "command", "exec", "time", "env", "proxychains", "proxychains4": words.removeFirst()
            case "sshpass":
                guard let next = words.firstIndex(where: { ($0 as NSString).lastPathComponent == "ssh" }) else { return nil }
                words = words[next...]
            case let name where name.contains("="): words.removeFirst()
            default: return nil
            }
        }
        guard words.popFirst() != nil else { return nil }
        var user: String?, port: String?, host: String?, quiet = false
        while let word = words.popFirst() {
            guard word.hasPrefix("-"), word.count > 1 else { host = word; break }
            if word == "--" { host = words.popFirst(); break }
            var flags = word.dropFirst()
            while let flag = flags.popFirst() {
                // Commands that print something or hold a tunnel open, with no session.
                if "GVQOWN".contains(flag) { return nil }
                if flag == "q" { quiet = true }
                guard "BbcDEeFIiJLlmopRSwP".contains(flag) else { continue }
                let value = flags.isEmpty ? words.popFirst() ?? "" : String(flags)
                flags = ""
                switch flag {
                case "l": user = value
                case "p": port = value
                case "E": quiet = true
                case "o":
                    let option = value.lowercased()
                    if option.hasPrefix("loglevel"), option.hasSuffix("quiet") || option.hasSuffix("fatal") { quiet = true }
                    if option.hasPrefix("port=") { port = String(value.dropFirst(5)) }
                    if option.hasPrefix("user=") { user = String(value.dropFirst(5)) }
                default: break
                }
            }
        }
        guard var host, !host.isEmpty else { return nil }
        if host.hasPrefix("ssh://") { host = String(host.dropFirst(6)) }
        if let at = host.lastIndex(of: "@") {
            user = user ?? String(host[..<at])
            host = String(host[host.index(after: at)...])
        }
        destination = (user.map { SessionKey.masked($0) + "@" } ?? "") + host + (port.map { $0 == "22" ? "" : ":" + $0 } ?? "")
        self.quiet = quiet
    }

    /// How it went, from the lines it showed before the next prompt; nil when that cannot be told.
    /// `ssh` always says why it could not sign in, unless it was interrupted or told to be quiet.
    func outcome(_ lines: [String], interrupted: Bool) -> Outcome? {
        let lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0.hasPrefix("Last login:") }) { return .connected }
        if let reason = lines.lazy.compactMap(Self.reason).first { return .failed(reason) }
        if interrupted { return .failed(nil) }
        return quiet ? nil : .connected
    }

    /// Why `ssh` gave up, when `line` says so. A refused password that is asked for again is not the end.
    static func reason(_ line: String) -> String? {
        if let found = line.wholeMatch(of: #/ssh: connect to .* port \d+: (.+)/#) { return String(found.1) }
        if let found = line.wholeMatch(of: #/ssh: (.+)/#) { return String(found.1) }
        if let found = line.wholeMatch(of: #/(?:\S+: )?(Permission denied \(.+)/#) { return String(found.1) }
        let others = #/(?:Host key verification failed|(?:kex|ssh)_exchange_identification: |ssh_dispatch_run_fatal: |Connection (?:closed|reset) by |Connection timed out|Connection to .+ port \d+ timed out|Unable to negotiate with |Received disconnect from |Disconnected from |Too many authentication failures|Bad port |Bad owner or permissions|channel \d+: open failed|stdio forwarding failed|unknown option -- |usage: ssh|command-line: line|no matching )|.*ssh: (?:command )?not found|.*command not found: ssh/#
        return line.prefixMatch(of: others) == nil ? nil : line
    }

    /// Whether the text before the cursor is a prompt that waits for a command.
    static func isPrompt(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let last = text.last, text.count <= 300 else { return false }
        // Themes end a prompt with a symbol of their own font.
        return "$#%>❯»➜λ›▶".contains(last) || last.unicodeScalars.allSatisfy { (0xE000...0xF8FF).contains($0.value) }
    }

    /// Whether a line that was answered asked for something, such as a password or whether to trust a host key.
    static func isQuestion(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).last.map { ":?：？".contains($0) } ?? false
    }
}
