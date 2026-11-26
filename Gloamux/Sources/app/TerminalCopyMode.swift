import AppKit

/// Terminal › Copy mode, as in iTerm2: the keyboard moves a cursor through the terminal's text and selects without the
/// mouse. Keys follow vim: h j k l and the arrows move, w and b go by word, 0 and $ to the line's ends, g and G to the
/// top and bottom, Control-U and Control-D half a screen. v starts a selection, V a selection of whole lines. y or
/// Return copies and leaves, Escape or q leaves.
struct TerminalCopyMode: Equatable {
    var cursor: Int
    var anchor: Int?
    var lineWise = false

    enum Result: Equatable { case moved, copy, exit, ignored }

    init(cursor: Int) { self.cursor = cursor }

    /// The selection to show: the cursor's character, or everything from the anchor to the cursor.
    func selection(in text: NSString) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let cursor = min(self.cursor, text.length - 1)
        guard let anchor = anchor.map({ min($0, text.length - 1) }) else { return NSRange(location: cursor, length: 1) }
        var start = min(anchor, cursor), end = max(anchor, cursor) + 1
        if lineWise {
            start = text.lineRange(for: NSRange(location: start, length: 0)).location
            end = Self.contentEnd(of: text.lineRange(for: NSRange(location: end - 1, length: 0)), in: text)
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Handles one key. `words` are the characters that count as part of a word besides letters and digits.
    mutating func handle(characters: String, keyCode: UInt16, control: Bool, in text: NSString, words: String, pageLines: Int) -> Result {
        guard text.length > 0 else { return keyCode == 53 || characters == "q" ? .exit : .ignored }
        let line = text.lineRange(for: NSRange(location: cursor, length: 0))
        let column = cursor - line.location
        func moveLine(by count: Int) {
            var range = text.lineRange(for: NSRange(location: cursor, length: 0))
            for _ in 0..<abs(count) {
                if count < 0 {
                    guard range.location > 0 else { break }
                    range = text.lineRange(for: NSRange(location: range.location - 1, length: 0))
                } else {
                    let next = NSMaxRange(range)
                    guard next < text.length else { break }
                    range = text.lineRange(for: NSRange(location: next, length: 0))
                }
            }
            cursor = min(range.location + column, max(range.location, Self.contentEnd(of: range, in: text) - 1))
        }
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < text.length, let scalar = UnicodeScalar(text.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || words.unicodeScalars.contains(scalar)
        }
        switch (keyCode, control ? "^" + characters.lowercased() : characters) {
        case (53, _), (_, "q"): return .exit
        case (36, _), (76, _), (_, "y"): return .copy
        case (123, _), (_, "h"): cursor = max(line.location, cursor - 1)
        case (124, _), (_, "l"): cursor = min(max(line.location, Self.contentEnd(of: line, in: text) - 1), cursor + 1)
        case (125, _), (_, "j"): moveLine(by: 1)
        case (126, _), (_, "k"): moveLine(by: -1)
        case (_, "^d"): moveLine(by: max(1, pageLines / 2))
        case (_, "^u"): moveLine(by: -max(1, pageLines / 2))
        case (_, "0"), (115, _): cursor = line.location
        case (_, "$"), (119, _): cursor = max(line.location, Self.contentEnd(of: line, in: text) - 1)
        case (_, "g"): cursor = 0
        case (_, "G"): cursor = text.lineRange(for: NSRange(location: text.length - 1, length: 0)).location
        case (_, "w"):
            var index = cursor
            while index < text.length, isWord(index) { index += 1 }
            while index < text.length, !isWord(index) { index += 1 }
            if index < text.length { cursor = index }
        case (_, "b"):
            var index = cursor - 1
            while index > 0, !isWord(index) { index -= 1 }
            while index > 0, isWord(index - 1) { index -= 1 }
            cursor = max(0, index)
        case (_, "v"):
            if anchor != nil && !lineWise { anchor = nil } else { anchor = cursor; lineWise = false }
        case (_, "V"):
            if anchor != nil && lineWise { anchor = nil; lineWise = false } else { anchor = cursor; lineWise = true }
        default: return .ignored
        }
        return .moved
    }

    /// The end of a line's text, before its line break and the blank cells after the last character.
    static func contentEnd(of line: NSRange, in text: NSString) -> Int {
        var end = NSMaxRange(line)
        if end > line.location, text.character(at: end - 1) == 0x0A { end -= 1 }
        while end > line.location, text.character(at: end - 1) == 0x20 { end -= 1 }
        return end
    }
}

extension TerminalTextView {
    func startCopyMode() {
        guard copyMode == nil, (string as NSString).length > 0 else { copyModeEnded?(); return }
        window?.makeFirstResponder(self)
        let start = selectedRange().length > 0 ? selectedRange().location : terminalInsertionRange.location
        copyMode = TerminalCopyMode(cursor: min(start, (string as NSString).length - 1))
        showCopyMode()
    }

    func endCopyMode(copying: Bool) {
        guard let mode = copyMode else { return }
        if copying {
            setSelectedRange(mode.selection(in: string as NSString))
            copy(nil)
        }
        copyMode = nil
        setSelectedRange(terminalInsertionRange)
        copyModeEnded?()
    }

    /// A key while copy mode is on; nothing reaches the session.
    func copyModeKey(_ event: NSEvent) {
        guard var mode = copyMode else { return }
        let pageLines = Int((enclosingScrollView?.contentView.bounds.height ?? 0) / max(1, fonts.lineHeight))
        let result = mode.handle(characters: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode,
                                 control: event.modifierFlags.contains(.control), in: string as NSString,
                                 words: TerminalPreferences.wordCharacters, pageLines: pageLines)
        switch result {
        case .moved: copyMode = mode; showCopyMode()
        case .copy: copyMode = mode; endCopyMode(copying: true)
        case .exit: endCopyMode(copying: false)
        case .ignored: NSSound.beep()
        }
    }

    private func showCopyMode() {
        guard let mode = copyMode else { return }
        setSelectedRange(mode.selection(in: string as NSString))
        scrollRangeToVisible(NSRange(location: mode.cursor, length: 0))
    }
}
