import XCTest
import AppKit
@testable import App
import Terminal

@MainActor final class TerminalInputTests: XCTestCase {
    func testSpecialKeysAreRemoteBytes() {
        XCTAssertEqual(TerminalKeyboard.bytes(keyCode: 36, characters: "", control: false), [13])
        XCTAssertEqual(TerminalKeyboard.bytes(keyCode: 48, characters: "", control: false), [9])
        XCTAssertEqual(TerminalKeyboard.bytes(keyCode: 8, characters: "c", control: true), [3])
        XCTAssertEqual(TerminalKeyboard.bytes(keyCode: 126, characters: "", control: false), Array("\u{1b}[A".utf8))
        XCTAssertEqual(TerminalKeyboard.bytes(keyCode: 126, characters: "", control: false, applicationCursorKeys: true), Array("\u{1b}OA".utf8))
        XCTAssertEqual(TerminalKeyboard.bytes(keyCode: 51, characters: "", control: false), [127])
    }
    func testKeysSendWhatXtermAndITerm2Send() {
        func keys(_ code: UInt16, _ characters: String = "", control: Bool = false, shift: Bool = false, option: Bool = false,
                  application: Bool = false) -> String? {
            TerminalKeyboard.bytes(keyCode: code, characters: characters, control: control, applicationCursorKeys: application,
                                   shift: shift, option: option).map { String(decoding: $0, as: UTF8.self) }
        }
        XCTAssertEqual(keys(48, shift: true), "\u{1b}[Z", "Shift-Tab")
        XCTAssertEqual(keys(123, control: true), "\u{1b}[1;5D", "Control-Left")
        XCTAssertEqual(keys(124, option: true), "\u{1b}[1;3C", "Option-Right")
        XCTAssertEqual(keys(126, shift: true, application: true), "\u{1b}[1;2A", "Modifiers win over application mode")
        XCTAssertEqual(keys(115), "\u{1b}[H"); XCTAssertEqual(keys(119, application: true), "\u{1b}OF")
        XCTAssertEqual(keys(117), "\u{1b}[3~"); XCTAssertEqual(keys(117, control: true), "\u{1b}[3;5~")
        XCTAssertEqual(keys(116), "\u{1b}[5~"); XCTAssertEqual(keys(121, shift: true), "\u{1b}[6;2~")
        XCTAssertEqual(keys(122), "\u{1b}OP"); XCTAssertEqual(keys(118), "\u{1b}OS")
        XCTAssertEqual(keys(120, shift: true), "\u{1b}[1;2Q")
        XCTAssertEqual(keys(96), "\u{1b}[15~"); XCTAssertEqual(keys(109), "\u{1b}[21~"); XCTAssertEqual(keys(111, control: true), "\u{1b}[24;5~")
        XCTAssertEqual(keys(19, "2", control: true), "\u{0}"); XCTAssertEqual(keys(22, "6", control: true), "\u{1e}")
        XCTAssertEqual(keys(27, "-", control: true), "\u{1f}"); XCTAssertEqual(keys(44, "/", control: true), "\u{1f}")
        XCTAssertNil(keys(19, "2"), "A plain digit is typed text")
    }
    func testBoldBasicColorsShowBright() {
        let ansi = (0..<16).map { NSColor(calibratedWhite: CGFloat($0) / 16, alpha: 1) }
        var renderer = TerminalLineRenderer(background: .black, foreground: .white, ansi: ansi) { color, fallback, ansi in
            if case .indexed(let index) = color { return ansi[Int(index)] }
            return fallback
        }
        var style = CellStyle(); style.foreground = .indexed(1); style.bold = true
        XCTAssertEqual(renderer.attributes(style)[.foregroundColor] as? NSColor, ansi[9])
        style.bold = false
        XCTAssertEqual(renderer.attributes(style)[.foregroundColor] as? NSColor, ansi[1])
        style.foreground = .indexed(9); style.bold = true
        XCTAssertEqual(renderer.attributes(style)[.foregroundColor] as? NSColor, ansi[9])
    }
    func testItalicAndFaintTextShow() {
        var renderer = TerminalLineRenderer(background: .black, foreground: .white, ansi: Array(repeating: .gray, count: 16)) { _, fallback, _ in fallback }
        var style = CellStyle(); style.italic = true
        let font = renderer.attributes(style)[.font] as? NSFont
        let fonts = TerminalFonts.standard
        XCTAssertEqual(font, fonts.italic)
        XCTAssertTrue(fonts.slantsItalic ? renderer.attributes(style)[.obliqueness] != nil
                                         : NSFontManager.shared.traits(of: fonts.italic).contains(.italicFontMask))
        XCTAssertEqual(fonts.italic.advancement(forGlyph: fonts.italic.glyph(withName: "M")).width, fonts.cellWidth, accuracy: 0.01,
                       "Italic keeps the cell width")
        style.bold = true
        XCTAssertEqual(renderer.attributes(style)[.font] as? NSFont, fonts.boldItalic)
        style = CellStyle(); style.faint = true
        let faint = (renderer.attributes(style)[.foregroundColor] as? NSColor)?.usingColorSpace(.deviceRGB)
        XCTAssertTrue((0.4...0.65).contains(faint?.redComponent ?? 0), "Faint is about halfway to the background")
    }
    func testSpacingLigaturesAndMinimumContrast() {
        let plain = TerminalFonts.make(name: "", size: 13, lineSpacing: 1, characterSpacing: 1, ligatures: false)
        let spaced = TerminalFonts.make(name: "", size: 13, lineSpacing: 1.5, characterSpacing: 1.2, ligatures: true)
        XCTAssertEqual(spaced.lineHeight, (plain.lineHeight * 1.5).rounded())
        XCTAssertEqual(spaced.cellWidth, plain.cellWidth * 1.2, accuracy: 0.001)
        XCTAssertEqual(spaced.extraWidth, plain.cellWidth * 0.2, accuracy: 0.001)
        XCTAssertGreaterThan(spaced.baselineOffset, 0)
        XCTAssertEqual(plain.extraWidth, 0); XCTAssertEqual(plain.baselineOffset, 0)
        var renderer = TerminalLineRenderer(background: .black, foreground: .white, ansi: Array(repeating: .gray, count: 16),
                                            color: { _, fallback, _ in fallback }, fonts: spaced)
        let cells = [cell("a"), { var wide = cell("中"); wide.width = 2; return wide }(), { var rest = cell(" "); rest.width = 0; return rest }()]
        let line = renderer.line(cells, cursorColumn: nil, cursorColor: nil)
        XCTAssertEqual(line.string, "a中")
        XCTAssertEqual(line.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat ?? 0, spaced.extraWidth, accuracy: 0.001)
        XCTAssertEqual(line.attribute(.kern, at: 1, effectiveRange: nil) as? CGFloat ?? 0, spaced.extraWidth * 2, accuracy: 0.001)
        XCTAssertEqual(line.attribute(.ligature, at: 0, effectiveRange: nil) as? Int, 1)
        var off = TerminalLineRenderer(background: .black, foreground: .white, ansi: Array(repeating: .gray, count: 16),
                                       color: { _, fallback, _ in fallback }, fonts: plain)
        XCTAssertEqual(off.attributes(CellStyle())[.ligature] as? Int, 0)
        XCTAssertNil(off.attributes(CellStyle())[.kern])

        let background = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        let dim = NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        XCTAssertLessThan(TerminalLineRenderer.contrast(dim, background), 2)
        var contrasted = TerminalLineRenderer(background: background, foreground: dim, ansi: Array(repeating: .gray, count: 16),
                                              color: { _, fallback, _ in fallback }, fonts: plain, minimumContrast: 4.5)
        let shown = contrasted.attributes(CellStyle())[.foregroundColor] as! NSColor
        XCTAssertGreaterThanOrEqual(TerminalLineRenderer.contrast(shown, background), 4.5)
        XCTAssertLessThan(TerminalLineRenderer.contrast(shown, background), 5, "Moved only as far as needed")
        XCTAssertEqual(TerminalLineRenderer.contrasting(.white, on: background, ratio: 4.5), .white, "Enough contrast is left alone")
    }
    func testCopyJoinsWrappedRowsAndDropsTrailingBlanks() {
        let screen = TerminalScreen()
        screen.resize(rows: 4, cols: 10)
        screen.feed(Array("abcdefghijKLM\r\nend   \r\n".utf8))
        let view = TerminalTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.screen = screen
        // Rows as the renderer draws them, with every cell.
        view.string = (0..<screen.rows).map { row in String(screen.row(absolute: screen.trimmedLines + row)!.filter { $0.width != 0 }.map(\.character)) }
            .joined(separator: "\n")
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        XCTAssertEqual(view.copiedSelection(), "abcdefghijKLM\nend\n")
        XCTAssertNil({ view.setSelectedRange(NSRange(location: 0, length: 0)); return view.copiedSelection() }())
    }
    func testSelectingCopiesAndTheMiddleButtonPastesWhenTurnedOn() throws {
        let defaults = UserDefaults.standard
        let keys = [TerminalPreferences.copyOnSelectKey, TerminalPreferences.middleClickPasteKey, TerminalPreferences.pasteKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        let board = NSPasteboard(name: NSPasteboard.Name("gloamux-test-\(UUID())"))
        defer { board.releaseGlobally() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = TerminalTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView?.addSubview(view)
        view.pasteboard = board; view.inputEnabled = true
        var received: [UInt8] = []; view.input = { received += $0 }
        view.string = "copied text"
        func click(_ type: NSEvent.EventType, button: CGMouseButton) throws -> NSEvent {
            let cgType: CGEventType = type == .otherMouseDown ? .otherMouseDown : .leftMouseDown
            let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: cgType, mouseCursorPosition: .zero, mouseButton: button))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            return try XCTUnwrap(NSEvent(cgEvent: event))
        }

        defaults.set(false, forKey: TerminalPreferences.copyOnSelectKey)
        view.setSelectedRange(NSRange(location: 0, length: 6))
        view.selectionFinished()
        XCTAssertNil(board.string(forType: .string), "Off by default")
        defaults.set(true, forKey: TerminalPreferences.copyOnSelectKey)
        view.selectionFinished()
        XCTAssertEqual(board.string(forType: .string), "copied")

        defaults.set(false, forKey: TerminalPreferences.pasteKey)
        defaults.set(true, forKey: TerminalPreferences.middleClickPasteKey)
        view.otherMouseDown(with: try click(.otherMouseDown, button: .center))
        XCTAssertEqual(String(decoding: received, as: UTF8.self), "copied")
        received = []
        defaults.set(false, forKey: TerminalPreferences.middleClickPasteKey)
        view.otherMouseDown(with: try click(.otherMouseDown, button: .center))
        XCTAssertEqual(received, [])
    }
    func testWordCharactersAndAmbiguousWidthFollowSettings() throws {
        let defaults = UserDefaults.standard
        let keys = [TerminalPreferences.wordCharactersKey, TerminalPreferences.ambiguousWideKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        let view = TerminalTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = "a.b:c"
        defaults.set(":", forKey: TerminalPreferences.wordCharactersKey)
        let range = view.selectionRange(forProposedRange: NSRange(location: 4, length: 0), granularity: .selectByWord)
        XCTAssertEqual((view.string as NSString).substring(with: range), "b:c", "A dot no longer joins words; a colon does")

        defaults.set(true, forKey: TerminalPreferences.ambiguousWideKey)
        let screen = TerminalPreferences.newScreen()
        screen.resize(rows: 2, cols: 10)
        screen.feed(Array("①x".utf8))
        let row = try XCTUnwrap(screen.row(absolute: screen.trimmedLines))
        XCTAssertEqual(row.prefix(3).map(\.width), [2, 0, 1])
        var renderer = TerminalLineRenderer(background: .black, foreground: .white, ansi: Array(repeating: .gray, count: 16)) { _, fallback, _ in fallback }
        let line = renderer.line(Array(row.prefix(3)), cursorColumn: nil, cursorColor: nil)
        XCTAssertEqual(line.string, "①x")
        let kern = try XCTUnwrap(line.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat)
        XCTAssertGreaterThan(kern, 0, "A wide ambiguous character is spaced to fill two cells")
        defaults.set(false, forKey: TerminalPreferences.ambiguousWideKey)
        let narrow = TerminalPreferences.newScreen()
        narrow.resize(rows: 2, cols: 10)
        narrow.feed(Array("①x".utf8))
        XCTAssertEqual(narrow.row(absolute: narrow.trimmedLines)?.prefix(2).map(\.width), [1, 1])
    }
    func testPasteCanBeTrimmedAndJoined() {
        let text = "  ls -la\r\ncd /tmp\n\n"
        XCTAssertEqual(TerminalKeyboard.prepared(paste: text, trims: false, joinsLines: false), text)
        XCTAssertEqual(TerminalKeyboard.prepared(paste: text, trims: true, joinsLines: false), "ls -la\r\ncd /tmp")
        XCTAssertEqual(TerminalKeyboard.prepared(paste: text, trims: true, joinsLines: true), "ls -la cd /tmp")
        XCTAssertFalse(TerminalKeyboard.isMultiline(TerminalKeyboard.prepared(paste: text, trims: false, joinsLines: true)))
    }
    func testCopyModeMovesSelectsAndCopiesWithTheKeyboard() {
        let text = "ls -la  \nmy-app/main.c ok\nlast" as NSString
        var mode = TerminalCopyMode(cursor: 0)
        func key(_ characters: String, _ code: UInt16 = 0, control: Bool = false) -> TerminalCopyMode.Result {
            mode.handle(characters: characters, keyCode: code, control: control, in: text, words: "/-_.", pageLines: 4)
        }
        XCTAssertEqual(mode.selection(in: text), NSRange(location: 0, length: 1), "The cursor shows as one character")
        XCTAssertEqual(key("$"), .moved); XCTAssertEqual(mode.cursor, 5, "$ stops at the last character, not the blanks")
        XCTAssertEqual(key("j"), .moved); XCTAssertEqual(mode.cursor, 14, "j keeps the column")
        XCTAssertEqual(key("0"), .moved); XCTAssertEqual(mode.cursor, 9)
        XCTAssertEqual(key("v"), .moved)
        XCTAssertEqual(key("w"), .moved); XCTAssertEqual(mode.cursor, 23, "my-app/main.c is one word")
        XCTAssertEqual(text.substring(with: mode.selection(in: text)), "my-app/main.c o")
        XCTAssertEqual(key("b"), .moved); XCTAssertEqual(mode.cursor, 9)
        XCTAssertEqual(key("V"), .moved)
        XCTAssertEqual(key("k"), .moved)
        XCTAssertEqual(text.substring(with: mode.selection(in: text)), "ls -la  \nmy-app/main.c ok", "V selects whole lines")
        XCTAssertEqual(key("G"), .moved); XCTAssertEqual(mode.cursor, 26)
        XCTAssertEqual(key("u", control: true), .moved); XCTAssertEqual(mode.cursor, 0, "Half of four lines up")
        XCTAssertEqual(key("d", control: true), .moved); XCTAssertEqual(mode.cursor, 26)
        XCTAssertEqual(key("g"), .moved); XCTAssertEqual(mode.cursor, 0)
        XCTAssertEqual(key("x"), .ignored)
        XCTAssertEqual(key("y"), .copy); XCTAssertEqual(key("", 53), .exit); XCTAssertEqual(key("q"), .exit)

        let board = NSPasteboard(name: NSPasteboard.Name("gloamux-test-\(UUID())"))
        defer { board.releaseGlobally() }
        let view = TerminalTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.pasteboard = board; view.inputEnabled = true
        var sent: [UInt8] = []; view.input = { sent += $0 }
        var ended = 0; view.copyModeEnded = { ended += 1 }
        view.string = "hello world"
        view.startCopyMode()
        func press(_ characters: String, _ code: UInt16) {
            view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
        }
        press("v", 9); press("e", 14); press("w", 13); press("y", 16)
        XCTAssertEqual(board.string(forType: .string), "hello w")
        XCTAssertNil(view.copyMode); XCTAssertEqual(ended, 1)
        XCTAssertEqual(sent, [], "Nothing reaches the session")
    }
    func testDoubleClickSelectsPathsAndHostsWhole() {
        let view = TerminalTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = "ls ~/src/my-app_v1.2/main.c+x, host.example.test:22"
        let text = view.string as NSString
        let path = text.range(of: "~/src/my-app_v1.2/main.c+x")
        func word(at offset: Int) -> String {
            text.substring(with: view.selectionRange(forProposedRange: NSRange(location: offset, length: 0), granularity: .selectByWord))
        }
        XCTAssertEqual(word(at: path.location + 8), "~/src/my-app_v1.2/main.c+x")
        XCTAssertEqual(word(at: text.range(of: "example").location), "host.example.test")
        XCTAssertEqual(word(at: 0), "ls")
    }
    func testTextViewRoutesCommittedUnicodeAndReturnWithoutLocalEcho() {
        let view = TerminalTextView(); view.inputEnabled = true
        var received: [UInt8] = []; view.input = { received += $0 }
        view.insertText("\u{4f60}\u{597d}", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(received, Array("\u{4f60}\u{597d}".utf8)); XCTAssertEqual(view.string, "")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        view.keyDown(with: event); XCTAssertEqual(received.last, 13)
        view.inputEnabled = false; view.insertText("blocked", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertFalse(String(decoding: received, as: UTF8.self).contains("blocked"))
    }
    func testTerminalOnlyHandlesEditShortcutsWhileFocused() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let terminal = TerminalTextView(frame: NSRect(x: 0, y: 28, width: 250, height: 72))
        let search = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        window.contentView?.addSubview(terminal)
        window.contentView?.addSubview(search)
        terminal.string = "Terminal output"
        let selectAll = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                      characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))

        XCTAssertTrue(window.makeFirstResponder(search))
        XCTAssertFalse(terminal.performKeyEquivalent(with: selectAll))
        XCTAssertTrue(window.makeFirstResponder(terminal))
        XCTAssertTrue(terminal.performKeyEquivalent(with: selectAll))
        XCTAssertEqual(terminal.selectedRange().length, terminal.string.utf16.count)
    }
    private func cell(_ character: Character, _ style: CellStyle = CellStyle()) -> Cell {
        var cell = Cell.blank; cell.character = character; cell.style = style; return cell
    }
    func testTerminalBlockCursorDoesNotFollowTheTextSelection() {
        let view = TerminalTextView()
        func render(cursorColor: NSColor?) {
            var renderer = TerminalLineRenderer(background: .black, foreground: .white, ansi: Array(repeating: .gray, count: 16)) { _, fallback, _ in fallback }
            let cells = "prompt>   ".map { cell($0) }
            let line = renderer.line(cells, cursorColumn: 7, cursorColor: cursorColor)
            view.showTerminalLines([line], dropped: 0, firstChanged: 0, cursorLine: 0, cursorColumnOffset: renderer.lastCursorOffset)
        }

        render(cursorColor: .green)
        XCTAssertFalse(view.shouldDrawInsertionPoint)
        XCTAssertEqual(view.terminalInsertionRange, NSRange(location: 7, length: 0))
        XCTAssertEqual(view.textStorage?.attribute(.backgroundColor, at: 7, effectiveRange: nil) as? NSColor, .green)
        let selectedText = NSRange(location: 0, length: 6)
        view.setSelectedRange(selectedText)
        render(cursorColor: .green)
        XCTAssertEqual(view.selectedRange(), selectedText)
        XCTAssertEqual(view.textStorage?.attribute(.backgroundColor, at: 7, effectiveRange: nil) as? NSColor, .green)
        render(cursorColor: nil)
        // The default background is the view's own, so cells on it carry no color of their own.
        XCTAssertNil(view.textStorage?.attribute(.backgroundColor, at: 7, effectiveRange: nil))
    }
    func testIncrementalTerminalUpdatesMatchAFullRedraw() {
        let view = TerminalTextView()
        func lines(_ texts: [String]) -> [NSAttributedString] { texts.map { NSAttributedString(string: $0) } }
        view.showTerminalLines(lines(["a", "bb", "ccc"]), dropped: 0, firstChanged: 0, cursorLine: 2, cursorColumnOffset: 3)
        XCTAssertEqual(view.string, "a\nbb\nccc")
        // A new line at the bottom; the top line falls out of a full scrollback.
        view.showTerminalLines(lines(["bb", "ccc", "dddd"]), dropped: 1, firstChanged: 2, cursorLine: 2, cursorColumnOffset: 4)
        XCTAssertEqual(view.string, "bb\nccc\ndddd")
        XCTAssertEqual(view.terminalInsertionRange.location, "bb\nccc\ndddd".utf16.count)
        // A change in the middle rewrites from there down; the screen also grows.
        view.showTerminalLines(lines(["bb", "CC", "dddd", "e"]), dropped: 0, firstChanged: 1, cursorLine: 3, cursorColumnOffset: 0)
        XCTAssertEqual(view.string, "bb\nCC\ndddd\ne")
        // Everything replaced.
        view.showTerminalLines(lines(["x"]), dropped: 4, firstChanged: 0, cursorLine: 0, cursorColumnOffset: 1)
        XCTAssertEqual(view.string, "x")
        XCTAssertEqual(view.terminalInsertionRange.location, 1)
    }
    func testRendererMergesCellsThatShareAStyleIntoOneRun() {
        var renderer = TerminalLineRenderer(background: .black, foreground: .white, ansi: Array(repeating: .gray, count: 16)) { _, fallback, _ in fallback }
        var bold = CellStyle(); bold.bold = true
        let cells = "abc".map { cell($0) } + "de".map { cell($0, bold) }
        let line = renderer.line(cells, cursorColumn: nil, cursorColor: nil)
        XCTAssertEqual(line.string, "abcde")
        var runs = 0
        line.enumerateAttributes(in: NSRange(location: 0, length: line.length)) { _, _, _ in runs += 1 }
        XCTAssertEqual(runs, 2)
    }
    func testLocalizationsAreCompleteAndTheSystemLanguageResolves() throws {
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["zh-TW"]), "zh-Hant")
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["zh-HK"]), "zh-Hant")
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["zh-CN"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["ja-JP", "zh-Hant-TW", "en"]), "ja", "The first shipped language wins")
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["fr-FR", "es-MX", "en"]), "es")
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["en-US"]), "en")
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["fr-FR"]), "en")
        XCTAssertEqual(AppLanguage.from(appleLanguages: ["zh-Hant-TW"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.from(appleLanguages: ["zh-Hans", "en"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.from(appleLanguages: ["ja_JP"]), .japanese)
        XCTAssertEqual(AppLanguage.from(appleLanguages: ["es-419"]), .spanish)
        XCTAssertEqual(AppLanguage.from(appleLanguages: nil), .system)

        // All shipped catalogs carry the same keys, and every translation is filled in.
        func catalog(_ code: String) throws -> [String: String] {
            let bundle = try XCTUnwrap(UIStrings.bundles[code])
            let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"), code)
            return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], code)
        }
        let english = try catalog("en")
        XCTAssertGreaterThan(english.count, 100)
        for code in AppLanguage.supported where code != "en" {
            let localized = try catalog(code)
            XCTAssertEqual(Set(english.keys), Set(localized.keys), code)
            for (key, value) in localized { XCTAssertFalse(value.isEmpty, "\(code): \(key)") }
        }
        XCTAssertEqual(UIStrings.text("Connect", language: .traditionalChinese), "連線")
        XCTAssertEqual(UIStrings.text("Connect", language: .simplifiedChinese), "连接")
        XCTAssertEqual(UIStrings.text("Connect", language: .japanese), "接続")
        XCTAssertEqual(UIStrings.text("Connect", language: .spanish), "Conectar")
        XCTAssertEqual(UIStrings.text("Connect", language: .english), "Connect")
        XCTAssertEqual(UIStrings.text("Not a key", language: .traditionalChinese), "Not a key")
    }
}
