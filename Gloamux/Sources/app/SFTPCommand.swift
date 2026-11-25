import Foundation

/// An `sftp` command line as people copy it from a portal, with the sftp lines that follow it: where to connect, how to
/// sign in, and what to copy. Reading it connects to nothing and runs nothing.
public struct SFTPCommand: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case localFolder(String)
        case remoteFolder(String)
        case get(remote: String, local: String?, recursive: Bool)
        case put(local: String, remote: String?, recursive: Bool)
    }

    public var connection: SavedConnection
    /// The path after `host:`, or of an `sftp://` address.
    public var remotePath: String?
    public var steps: [Step] = []
    /// Lines that were not understood, shown so nothing is skipped silently.
    public var ignored: [String] = []

    /// The local folder the command changes to last.
    public var localFolder: String? {
        steps.reversed().lazy.compactMap { if case .localFolder(let path) = $0 { return path } else { return nil } }.first
    }

    /// Where the saved session should open: `cd`, the path after the host, or the folder of the first download.
    public var startFolder: String? {
        for case .remoteFolder(let path) in steps { return path }
        if let remotePath { return remotePath }
        for case .get(let remote, _, _) in steps where remote.hasPrefix("/") {
            return (remote as NSString).deletingLastPathComponent
        }
        return nil
    }

    public var transfers: [Step] {
        steps.filter { if case .get = $0 { return true } else if case .put = $0 { return true } else { return false } }
    }

    /// Options that change where the connection goes or what runs on this Mac. Leaving one out would connect somewhere
    /// else than the command does, so they are refused rather than ignored.
    private static let refusedOptions: Set<String> = ["proxycommand", "proxyjump", "proxyusefdpass", "hostname", "remotecommand",
                                                      "localcommand", "permitlocalcommand", "knownhostscommand", "pkcs11provider",
                                                      "securitykeyprovider", "certificatefile", "bindaddress", "bindinterface",
                                                      "controlpath", "include", "match"]
    private static let lineCommands: Set<String> = ["lcd", "cd", "get", "reget", "put", "reput", "bye", "exit", "quit"]

    /// Whether `text` starts as an sftp command, so a field can offer to read it.
    public static func looksLike(_ text: String) -> Bool {
        let start = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8).lowercased()
        return start.hasPrefix("sftp ") || start.hasPrefix("sftp\n") || start.hasPrefix("sftp\\") || start.hasPrefix("sftp://")
            || start.hasPrefix("$ sftp ")
    }

    /// Reads a pasted command. Throws a message for the user when it is not one Gloamux can follow.
    public static func parse(_ text: String) throws -> SFTPCommand {
        guard text.utf8.count <= 64 * 1024 else { throw WorkspaceError.invalid("The sftp command is too long.") }
        var source = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{a0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("$ ") { source = String(source.dropFirst(2)) }
        // A backslash at the end of a line continues it. A one-line field may have turned the line end into a space.
        source = source.replacingOccurrences(of: #"\\[ \t]*\n"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\s)\\\s+"#, with: " ", options: .regularExpression)
        var lines = source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, looksLike(lines[0] + " ") else {
            throw WorkspaceError.invalid("Paste a command that starts with sftp.")
        }
        var words = try tokens(lines.removeFirst())
        if words.first?.lowercased() == "sftp" { words.removeFirst() }
        let (command, rest) = try destination(words)
        var result = command
        // Lines that a one-line field joined to the first one.
        var current: [String] = []
        for word in rest {
            if lineCommands.contains(word), !current.isEmpty { result.add(current); current = [] }
            current.append(word)
        }
        if !current.isEmpty { result.add(current) }
        for line in lines {
            let line = line.hasPrefix("sftp>") ? String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) : line
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let words = try? tokens(line) { result.add(words, line: line) } else { result.ignored.append(line) }
        }
        return result
    }

    /// Reads the arguments of `sftp`, as the command line passes them.
    public static func parse(arguments: [String]) throws -> SFTPCommand {
        let (command, rest) = try destination(arguments)
        guard rest.isEmpty else { throw WorkspaceError.invalid("Unexpected argument \(rest[0]).") }
        return command
    }

    private static func destination(_ words: [String]) throws -> (SFTPCommand, [String]) {
        var port: Int?, user: String?, identity: String?
        var questions = false
        var index = 0
        func value(_ option: String, _ attached: Substring) throws -> String {
            if !attached.isEmpty { return String(attached) }
            index += 1
            guard index < words.count else { throw WorkspaceError.invalid("Missing value for \(option).") }
            return words[index]
        }
        func number(_ text: String) throws -> Int {
            guard let port = Int(text), (1...65535).contains(port) else { throw WorkspaceError.invalid("Enter a valid port.") }
            return port
        }
        while index < words.count, words[index].hasPrefix("-"), words[index].count > 1 {
            let word = words[index]
            let letter = word[word.index(after: word.startIndex)], attached = word.dropFirst(2)
            switch letter {
            case "P": port = try number(value("-P", attached))
            case "i": identity = try value("-i", attached)
            case "o":
                let option = try value("-o", attached)
                let parts = option.split(maxSplits: 1, omittingEmptySubsequences: true) { $0 == "=" || $0 == " " }
                let key = parts.first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                let setting = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " =\"")) : ""
                guard !refusedOptions.contains(key) else {
                    throw WorkspaceError.invalid("Gloamux cannot follow the option \(parts[0]). Create the session by hand.")
                }
                switch key {
                case "port": port = try number(setting)
                case "user": user = setting
                case "identityfile": identity = setting
                case "preferredauthentications":
                    questions = setting.lowercased().split(separator: ",").first == "keyboard-interactive"
                default: break
                }
            case "J", "F", "S", "D", "b", "X", "s":
                throw WorkspaceError.invalid("Gloamux cannot follow the option -\(letter). Create the session by hand.")
            case "B", "c", "l", "R": _ = try value("-\(letter)", attached)
            default: break
            }
            index += 1
        }
        guard index < words.count else { throw WorkspaceError.invalid("The sftp command has no host.") }
        var target = words[index]
        index += 1
        var path: String?
        if target.lowercased().hasPrefix("sftp://") {
            target = String(target.dropFirst(7))
            if let slash = target.firstIndex(of: "/") {
                path = String(target[slash...]).removingPercentEncoding
                target = String(target[..<slash])
            }
            if let at = target.lastIndex(of: "@") {
                user = String(target[..<at]).removingPercentEncoding ?? String(target[..<at])
                target = String(target[target.index(after: at)...])
            }
            if let colon = target.lastIndex(of: ":"), !target.hasSuffix("]") {
                port = try number(String(target[target.index(after: colon)...]))
                target = String(target[..<colon])
            }
        } else {
            // The account may contain @ itself, as with some gateways: user@target@gateway.
            if let at = target.lastIndex(of: "@") {
                user = String(target[..<at])
                target = String(target[target.index(after: at)...])
            }
            if target.hasPrefix("["), let close = target.firstIndex(of: "]") {
                let after = target[target.index(after: close)...]
                if after.hasPrefix(":") { path = String(after.dropFirst()) }
            } else if let colon = target.firstIndex(of: ":") {
                path = String(target[target.index(after: colon)...])
                target = String(target[..<colon])
            }
        }
        if target.hasPrefix("["), let close = target.firstIndex(of: "]") {
            target = String(target[target.index(after: target.startIndex)..<close])
        }
        let invalid = CharacterSet(charactersIn: "/\\[]?#").union(.whitespacesAndNewlines).union(.controlCharacters)
        guard !target.isEmpty, !target.hasPrefix("-"), !target.unicodeScalars.contains(where: invalid.contains) else {
            throw WorkspaceError.invalid("The sftp command has no host.")
        }
        let account = user ?? ""
        guard !account.hasPrefix("-"), account.utf8.count <= 1024,
              !account.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw WorkspaceError.invalid("The sftp command has an invalid user name.")
        }
        let expanded = identity.map { ($0 as NSString).expandingTildeInPath }
        var connection = SavedConnection(host: target, port: port ?? 22, username: account, identityPath: expanded, opensFiles: true)
        connection.fileProtocol = .sftp
        if expanded == nil, questions || SessionKey.looksLikeKey(account) { connection.signIn = .questions }
        return (SFTPCommand(connection: connection, remotePath: path.flatMap { $0.isEmpty ? nil : $0 }), Array(words[index...]))
    }

    private mutating func add(_ words: [String], line: String? = nil) {
        guard let name = words.first?.lowercased() else { return }
        var recursive = false
        var paths: [String] = []
        for word in words.dropFirst() {
            if word.hasPrefix("-"), word.count > 1, paths.isEmpty {
                if word.lowercased().contains("r") { recursive = true }
            } else { paths.append(word) }
        }
        switch (name, paths.count) {
        case ("lcd", 1): steps.append(.localFolder(paths[0]))
        case ("cd", 1): steps.append(.remoteFolder(paths[0]))
        case ("get", 1...2) where !Self.hasWildcard(paths[0]), ("reget", 1...2) where !Self.hasWildcard(paths[0]):
            steps.append(.get(remote: paths[0], local: paths.count > 1 ? paths[1] : nil, recursive: recursive))
        case ("put", 1...2) where !Self.hasWildcard(paths[0]), ("reput", 1...2) where !Self.hasWildcard(paths[0]):
            steps.append(.put(local: paths[0], remote: paths.count > 1 ? paths[1] : nil, recursive: recursive))
        case ("bye", 0), ("exit", 0), ("quit", 0): break
        default: ignored.append(line ?? words.joined(separator: " "))
        }
    }

    private static func hasWildcard(_ path: String) -> Bool { path.contains("*") || path.contains("?") }

    /// Splits one line as sftp does: spaces separate words, quotes keep them together, and a backslash keeps the next
    /// character. Curly quotes, which chat apps and documents put in place of straight ones, count as quotes.
    public static func tokens(_ line: String) throws -> [String] {
        var words: [String] = [], word = "", started = false
        var quote: Character?
        var characters = line.makeIterator()
        while let next = characters.next() {
            if let open = quote {
                if next == open { quote = nil }
                else if next == "\\", open == "\"" {
                    guard let escaped = characters.next() else { throw WorkspaceError.invalid("A quote is not closed.") }
                    if escaped != "\"" && escaped != "\\" { word.append("\\") }
                    word.append(escaped)
                } else { word.append(next) }
                continue
            }
            switch next {
            case "\"", "'": quote = next; started = true
            case "\u{201c}": quote = "\u{201d}"; started = true
            case "\u{2018}": quote = "\u{2019}"; started = true
            case "\\":
                if let escaped = characters.next() { word.append(escaped); started = true }
            case " ", "\t", "\n":
                if started { words.append(word); word = ""; started = false }
            default: word.append(next); started = true
            }
        }
        guard quote == nil else { throw WorkspaceError.invalid("A quote is not closed.") }
        if started { words.append(word) }
        return words
    }
}

/// A key that stands in for a user name, as access gateways hand out for one connection or one day.
public enum SessionKey {
    /// Long, with letters and digits and nothing a person would type as a name.
    public static func looksLikeKey(_ user: String) -> Bool {
        guard user.utf8.count >= 20, user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_=+.".contains($0)) }) else { return false }
        return user.contains(where: \.isNumber) && user.contains(where: \.isLetter)
    }

    /// How a user name is written down or shown: a key keeps only its first four characters.
    public static func masked(_ user: String) -> String {
        looksLikeKey(user) ? user.prefix(4) + "••••" : user
    }

    /// The key in what the user pasted: the key alone, `key@host`, or the whole sftp command, which must be for `host`.
    static func read(_ text: String, host: String, port: Int) throws -> (key: String, command: SFTPCommand?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A one-line field can drop line ends, which joins the host to the line after it.
        var pasted = trimmed.replacingOccurrences(of: "(@" + NSRegularExpression.escapedPattern(for: host) + ")(?=(lcd|cd|get|put)\\s)",
                                                  with: "$1 ", options: .regularExpression)
        if !SFTPCommand.looksLike(trimmed), trimmed.contains("@"), !trimmed.contains(where: \.isWhitespace) {
            pasted = "sftp -P \(port) " + trimmed
        }
        if SFTPCommand.looksLike(pasted) {
            let command = try SFTPCommand.parse(pasted)
            guard command.connection.host.caseInsensitiveCompare(host) == .orderedSame, command.connection.port == port else {
                throw WorkspaceError.invalid("This command is for another server: \(command.connection.host):\(command.connection.port)")
            }
            guard !command.connection.username.isEmpty else { throw WorkspaceError.invalid("Enter the session key.") }
            return (command.connection.username, command)
        }
        guard !trimmed.isEmpty, trimmed.utf8.count <= 1024,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { throw WorkspaceError.invalid("Enter the session key.") }
        return (trimmed, nil)
    }
}
