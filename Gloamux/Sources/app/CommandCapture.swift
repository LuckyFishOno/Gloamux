import Foundation
import Terminal

/// Reads the commands run in a terminal, for the session log. A command is taken from the line the terminal showed when
/// Return was sent, never from the keys alone, so what the server does not echo, such as a password, is not part of it.
/// History recall and completion are read as the shell shows them.
@MainActor public final class CommandCapture {
    /// A line that was sent and whose echo has not been read yet.
    private struct Line {
        let typed: String
        /// `typed` is the whole line: no arrows, completion, or other editing keys were used.
        let plain: Bool
        /// What was on the line before typing started; nil when it was typed before that could be seen.
        let prompt: String?
        /// What was already to the right of the cursor, such as a prompt on the right.
        let right: String
        let sent = Date()
        var lines = 0
    }

    /// An `ssh` that was run and has not been seen to connect or fail.
    private struct Attempt {
        let ssh: TypedSSH
        let command: String
        /// Where its command is; nil inside a full-screen program, whose lines move.
        let line: Int?
        var interrupted = false
    }

    private let record: (String) -> Void
    private let ended: (TypedSSH, TypedSSH.Outcome) -> Void
    private var attempt: Attempt?
    private var settling: Task<Void, Never>?
    private var typed = ""
    private var plain = true
    private var started: (prompt: String?, right: String)?
    private var pasting = false
    private var pending: [Line] = []

    /// `ssh` is told how each `ssh` run in the terminal went.
    init(_ record: @escaping (String) -> Void, ssh: @escaping (TypedSSH, TypedSSH.Outcome) -> Void) {
        self.record = record
        ended = ssh
    }

    // MARK: Input

    /// Notes input before it is sent. `screen` is what the terminal shows now.
    public func sent(_ bytes: [UInt8], on screen: TerminalScreen) {
        settle(screen)
        var scalars = Substring(String(decoding: bytes, as: UTF8.self)).unicodeScalars
        while let scalar = scalars.popFirst() {
            switch scalar.value {
            case 0x1B:
                let sequence = Self.escape(&scalars)
                switch sequence {
                case "[200~": begin(screen); pasting = true
                case "[201~": pasting = false
                // Focus and mouse reports are not keys.
                case "[I", "[O": break
                case let report where report.hasPrefix("[<") || report.hasPrefix("[M"): break
                default: begin(screen); plain = false
                }
            case 0x0D, 0x0A:
                if pasting { typed.append("\n") } else { finish(screen) }
            case 0x03, 0x1A: reset(); pending = []; attempt?.interrupted = true
            case 0x08, 0x7F:
                begin(screen)
                if !typed.isEmpty { typed.removeLast() }
            case 0x15: begin(screen); typed = ""
            case ..<0x20: begin(screen); plain = false
            default:
                begin(screen)
                if typed.utf8.count < 65536 { typed.unicodeScalars.append(scalar) }
            }
        }
    }

    /// Removes one escape sequence, without its ESC, from the start of `scalars`.
    private static func escape(_ scalars: inout Substring.UnicodeScalarView) -> String {
        guard let first = scalars.popFirst() else { return "" }
        var sequence = String(first)
        switch first {
        case "[":
            while let scalar = scalars.popFirst() {
                sequence.unicodeScalars.append(scalar)
                if (0x40...0x7E).contains(scalar.value) { break }
            }
            // An old mouse report is followed by three bytes.
            if sequence == "[M" { scalars = scalars.dropFirst(3) }
        case "O": if let scalar = scalars.popFirst() { sequence.unicodeScalars.append(scalar) }
        default: break
        }
        return sequence
    }

    private func begin(_ screen: TerminalScreen) {
        guard started == nil else { return }
        let shown = Self.line(screen)
        // Before the shell has drawn anything, or while earlier lines are still on their way, the prompt is not known.
        let known = pending.isEmpty && !(shown.before.isEmpty && screen.cursorRow == 0 && screen.scrollback.isEmpty)
        started = (known ? shown.before : nil, known ? shown.after.trimmingCharacters(in: .whitespaces) : "")
    }

    private func reset() { typed = ""; plain = true; started = nil; pasting = false }

    private func finish(_ screen: TerminalScreen) {
        defer { reset() }
        guard let started else { return }
        let line = Line(typed: typed, plain: plain, prompt: started.prompt, right: started.right)
        if screen.usingAlternate { finishFullScreen(line, screen); return }
        if pending.count < 256 { pending.append(line) }
    }

    /// Inside tmux, screen, or Mosh the whole screen is redrawn, so only a line with a shell prompt that names a user and
    /// host is read: text typed into an editor is not a command.
    private func finishFullScreen(_ line: Line, _ screen: TerminalScreen) {
        let shown = Self.line(screen).whole
        guard let found = shown.wholeMatch(of: #/\s*[\[(]?[\w.-]+@[\w.-]+[^$#%❯]*[$#%❯]\s+(.+)/#) else { return }
        let body = String(found.1).trimmingCharacters(in: .whitespaces)
        let typed = line.typed.trimmingCharacters(in: .whitespaces)
        if line.plain, typed.contains("\n") { return }
        if !body.isEmpty { note(line.plain && typed.hasPrefix(body) ? typed : body, screen) }
    }

    // MARK: Output

    /// Feeds output to `screen`, reading the sent line at the line end the server echoes for it.
    public func feed(_ bytes: [UInt8], to screen: TerminalScreen) {
        let fullScreen = screen.usingAlternate
        // What was typed into a full-screen program is not the start of the next command.
        defer {
            if screen.usingAlternate != fullScreen { reset() }
            if attempt != nil { settleSoon(screen) }
        }
        guard !pending.isEmpty, bytes.contains(0x0A) else { screen.feed(bytes); return }
        var start = 0
        while !pending.isEmpty, let end = bytes[start...].firstIndex(of: 0x0A) {
            screen.feed(Array(bytes[start..<end]))
            if screen.usingAlternate { pending = [] } else { lineEnded(screen) }
            screen.feed([0x0A])
            start = end + 1
        }
        if start < bytes.count { screen.feed(Array(bytes[start...])) }
    }

    private func lineEnded(_ screen: TerminalScreen) {
        while let line = pending.first, line.lines >= 400 || Date().timeIntervalSince(line.sent) > 15 { pending.removeFirst() }
        guard !pending.isEmpty else { return }
        pending[0].lines += 1
        // A line that got no line end of its own, such as an answer to `read -s`, must not hold up the lines after it.
        let count = (pending.indices.first { matches(pending[$0], screen) } ?? 0) + 1
        guard let commands = read(pending[count - 1], screen) else { return }
        pending.removeFirst(count)
        if !commands.isEmpty, attempt != nil {
            let whole = Self.line(screen).whole.trimmingCharacters(in: .whitespaces)
            let before = whole.hasSuffix(commands[0]) ? String(whole.dropLast(commands[0].count)) : ""
            // An answer to what ssh asks, such as whether to trust a host key, is not a command.
            if TypedSSH.isQuestion(before) { return }
            // A command after a prompt of a form that is not known.
            if !before.allSatisfy(\.isWhitespace) { conclude(screen) }
        }
        for command in commands { note(command, screen) }
    }

    private func note(_ command: String, _ screen: TerminalScreen) {
        record(command)
        guard let ssh = TypedSSH(command) else { return }
        attempt = Attempt(ssh: ssh, command: command, line: screen.usingAlternate ? nil : screen.absoluteLine(ofRow: screen.cursorRow))
    }

    // MARK: ssh

    /// Output comes in pieces, and a part of a line can look like a prompt, so it is read once there is no more for a moment.
    private func settleSoon(_ screen: TerminalScreen) {
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { self?.settle(screen) }
        }
    }

    /// Ends the `ssh` that was run when a prompt waits below it.
    func settle(_ screen: TerminalScreen) {
        guard attempt != nil, TypedSSH.isPrompt(Self.line(screen).before) else { return }
        conclude(screen)
    }

    private func conclude(_ screen: TerminalScreen) {
        guard let attempt else { return }
        let shown = Self.line(screen), end = shown.lines.lowerBound
        // Not moved on yet.
        if Self.ends(shown.whole.trimmingCharacters(in: .whitespaces), with: attempt.command) { return }
        let top = screen.absoluteLine(ofRow: 0)
        var lines: [String]
        if let line = attempt.line {
            // A screen that was cleared starts again from its top.
            lines = Self.texts(screen, end > line ? max(line, end - 1000)..<end : top..<max(top, end))
            if end > line, !lines.isEmpty { lines.removeFirst() }
        } else {
            lines = Self.texts(screen, top..<max(top, end))
            if let start = lines.lastIndex(where: { Self.ends($0.trimmingCharacters(in: .whitespaces), with: attempt.command) }) {
                lines.removeSubrange(...start)
            }
        }
        self.attempt = nil
        settling?.cancel()
        if let outcome = attempt.ssh.outcome(lines, interrupted: attempt.interrupted) { ended(attempt.ssh, outcome) }
    }

    /// The lines of a range of rows, with rows that ran past the edge joined.
    private static func texts(_ screen: TerminalScreen, _ range: Range<Int>) -> [String] {
        var lines: [String] = [], joins = false
        for number in range {
            guard let row = screen.row(absolute: number) else { continue }
            if joins { lines[lines.count - 1] += text(row) } else { lines.append(text(row)) }
            joins = row.last?.wraps == true
        }
        return lines
    }

    /// Whether the cursor's line ends with what was typed for `line`.
    private func matches(_ line: Line, _ screen: TerminalScreen) -> Bool {
        guard line.plain, let last = Self.typedLines(line).last else { return false }
        return Self.ends(Self.line(screen).whole.trimmingCharacters(in: .whitespaces), with: last)
    }

    private static func typedLines(_ line: Line) -> [String] {
        line.typed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The commands of a sent line as the screen shows them, none when the line was not echoed, or nil to wait for a
    /// later line of output.
    private func read(_ line: Line, _ screen: TerminalScreen) -> [String]? {
        let shown = Self.line(screen)
        let whole = shown.whole.trimmingCharacters(in: .whitespaces)
        var body = Self.markedInput(screen, shown) ?? line.prompt.flatMap { shown.whole.hasPrefix($0) ? String(shown.whole.dropFirst($0.count)) : nil }
        body = body?.trimmingCharacters(in: .whitespaces)
        if let text = body, !line.right.isEmpty, text.hasSuffix(line.right) {
            body = String(text.dropLast(line.right.count)).trimmingCharacters(in: .whitespaces)
        }
        let typed = Self.typedLines(line)
        if line.plain, let last = typed.last {
            if let body, body.hasPrefix(last) { return typed }
            if Self.ends(whole, with: last) { return typed }
            // Typed ahead, or the first lines of a paste: the shell shows the rest of it later.
            if typed.count > 1 || pending.count > 1 && body?.isEmpty == false || line.prompt == nil || line.prompt?.isEmpty == true && !whole.isEmpty { return nil }
        } else if line.plain { return [] }
        if let body { return Self.isMasked(body) ? [] : [body] }
        // The prompt was drawn again in another form, as some shells do when a line is accepted.
        if !line.plain, let found = whole.wholeMatch(of: #/[^$#%>❯»➜λ]{0,120}[$#%>❯»➜λ]\s+(.+)/#) { return [String(found.1)] }
        return []
    }

    /// Empty, or only the characters a program shows in place of a password.
    private static func isMasked(_ text: String) -> Bool { text.allSatisfy { "*•●".contains($0) } }

    /// Whether `text` is or ends with `end`, where `end` is not the rest of a longer word.
    private static func ends(_ text: String, with end: String) -> Bool {
        guard text.hasSuffix(end) else { return false }
        guard let before = text.dropLast(end.count).last else { return true }
        return !before.isLetter && !before.isNumber
    }

    /// What follows the prompt on the cursor's line when shell integration marks where typing starts.
    private static func markedInput(_ screen: TerminalScreen, _ shown: Shown) -> String? {
        guard let mark = screen.commandMarks.last, mark.outputLine == nil, let input = mark.inputLine, shown.lines.contains(input) else { return nil }
        let rows = (input..<shown.lines.upperBound).map { number -> String in
            let cells = screen.row(absolute: number) ?? []
            return text(number == input ? Array(cells.dropFirst(mark.inputColumn ?? 0)) : cells)
        }
        return rows.joined()
    }

    // MARK: Reading the screen

    private struct Shown {
        let lines: Range<Int>
        let before: String
        let after: String
        var whole: String { before + after }
    }

    /// The cursor's line, with rows that ran past the edge joined, as the text before and after the cursor.
    private static func line(_ screen: TerminalScreen) -> Shown {
        let cursor = screen.absoluteLine(ofRow: screen.cursorRow)
        var first = cursor, last = cursor
        while cursor - first < 50, screen.row(absolute: first - 1)?.last?.wraps == true { first -= 1 }
        while last - cursor < 50, screen.row(absolute: last)?.last?.wraps == true, screen.row(absolute: last + 1) != nil { last += 1 }
        let row = screen.row(absolute: cursor) ?? []
        let column = min(screen.cursorCol, row.count)
        let above = (first..<cursor).map { text(screen.row(absolute: $0) ?? []) }.joined()
        let below = last > cursor ? (cursor + 1...last).map { text(screen.row(absolute: $0) ?? []) }.joined() : ""
        return Shown(lines: first..<last + 1, before: above + text(Array(row[..<column])), after: text(Array(row[column...])) + below)
    }

    private static func text(_ cells: [Cell]) -> String {
        var text = ""
        for cell in cells where cell.width != 0 { text.append(cell.character) }
        return text
    }
}
