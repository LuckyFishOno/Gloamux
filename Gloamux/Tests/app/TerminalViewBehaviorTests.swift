import XCTest
import AppKit
@testable import App
import Terminal

/// The terminal view's input method composition, find, mouse reports, and cursor, in a real window.
@MainActor final class TerminalViewBehaviorTests: XCTestCase {
    private func makeTerminal(lines: [String], rows: Int) -> (NSWindow, TerminalTextView, TerminalScreen) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        let scroll = TerminalScrollView(frame: window.contentView!.bounds)
        let view = TerminalTextView(frame: scroll.bounds)
        view.textContainerInset = NSSize(width: 18, height: 16)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: 100000, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        window.contentView?.addSubview(scroll)
        var options = TerminalOptions(); options.rows = rows; options.cols = 40
        let screen = TerminalScreen(options: options)
        view.screen = screen
        view.inputEnabled = true
        var renderer = TerminalLineRenderer(background: .black, foreground: .white, ansi: Array(repeating: .gray, count: 16)) { _, fallback, _ in fallback }
        let rendered = lines.map { text -> NSAttributedString in
            var cells = Array(repeating: Cell.blank, count: 40)
            for (index, character) in text.enumerated() { cells[index].character = character }
            return renderer.line(cells, cursorColumn: nil, cursorColor: nil)
        }
        view.showTerminalLines(rendered, dropped: 0, firstChanged: 0, cursorLine: lines.count - 1, cursorColumnOffset: 2)
        window.makeFirstResponder(view)
        return (window, view, screen)
    }

    func testCompositionStaysOutOfTheTranscriptAndKeepsReturn() throws {
        let (_, view, _) = makeTerminal(lines: ["$ "], rows: 1)
        var sent: [UInt8] = []
        view.input = { sent += $0 }
        let before = view.string
        view.setMarkedText("ㄓㄨㄥ", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange().length, 3)
        XCTAssertEqual(view.string, before, "composition is drawn over the terminal, not typed into it")
        XCTAssertFalse(view.firstRect(forCharacterRange: view.markedRange(), actualRange: nil).isEmpty)
        // Return belongs to the input method while it composes.
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                   characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        view.keyDown(with: enter)
        XCTAssertFalse(sent.contains(13))
        view.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(String(decoding: sent, as: UTF8.self), "中")
        view.keyDown(with: enter)
        XCTAssertEqual(sent.last, 13)
    }

    func testFindHighlightsMatchesAndSteps() {
        let (_, view, _) = makeTerminal(lines: ["error one", "ok", "Error two", "error three"], rows: 4)
        var status = view.find(TerminalSearch(query: "error"), mode: .latest)
        XCTAssertEqual(status, TerminalSearchStatus(current: 3, total: 3))
        XCTAssertTrue(view.hasFindResult)
        XCTAssertNotNil(view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil))
        status = view.find(TerminalSearch(query: "error"), mode: .previous)
        XCTAssertEqual(status.current, 2)
        status = view.find(TerminalSearch(query: "error"), mode: .next)
        XCTAssertEqual(status.current, 3)
        status = view.find(TerminalSearch(query: "error"), mode: .next)
        XCTAssertEqual(status.current, 1, "Find Next wraps to the top")
        XCTAssertEqual(view.find(TerminalSearch(query: "error", caseSensitive: true), mode: .latest).total, 2)
        XCTAssertEqual(view.find(TerminalSearch(query: "e(rr|x)or (one|two)", regex: true), mode: .latest).total, 2)
        XCTAssertEqual(view.find(TerminalSearch(query: "(", regex: true), mode: .latest), TerminalSearchStatus(invalid: true))
        XCTAssertEqual(view.find(TerminalSearch(query: "(", regex: false), mode: .latest).total, 0, "literal text is not a pattern")
        view.find(TerminalSearch(query: "one"), mode: .latest)
        view.clearFind()
        XCTAssertFalse(view.hasFindResult)
        XCTAssertNil(view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil))
    }

    func testMouseGoesToTheProgramOnlyWhenItAsks() throws {
        let (window, view, screen) = makeTerminal(lines: ["abcdef", "ghijkl"], rows: 2)
        var replies: [String] = []
        view.reply = { replies.append(String(decoding: $0, as: UTF8.self)) }
        window.layoutIfNeeded()
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        // The middle of "j": row 1, column 3. Each row holds all 40 cells and a line break.
        let manager = try XCTUnwrap(view.layoutManager)
        let glyph = manager.glyphRange(forCharacterRange: NSRange(location: 41 + 3, length: 1), actualCharacterRange: nil)
        var rect = manager.boundingRect(forGlyphRange: glyph, in: view.textContainer!)
        rect = rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let point = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Clicks that select text run AppKit's own tracking loop, so only the decision is checked for them.
        XCTAssertFalse(view.sendsMouse(event(.leftMouseDown)), "without a request, clicks select text")

        screen.feed("\u{1b}[?1000h\u{1b}[?1006h")
        view.mouseDown(with: event(.leftMouseDown))
        view.mouseUp(with: event(.leftMouseUp))
        XCTAssertEqual(replies, ["\u{1b}[<0;4;2M", "\u{1b}[<0;4;2m"])
        XCTAssertFalse(view.sendsMouse(event(.leftMouseDown, .option)), "Option selects text even while a program takes the mouse")
        view.reportsMouse = false
        XCTAssertFalse(view.sendsMouse(event(.leftMouseDown)), "the setting turns reporting off")
    }

    func testCursorSitsOnItsCellAndFollowsFocus() {
        let (window, view, _) = makeTerminal(lines: ["$ ls"], rows: 1)
        view.updateCursor(shape: .bar, blinks: false, color: .green, visible: true, background: .black)
        let cursor = view.subviews.compactMap { $0 as? TerminalCursorView }.first
        XCTAssertNotNil(cursor)
        XCTAssertEqual(cursor?.shape, .bar)
        XCTAssertFalse(cursor?.isHidden ?? true)
        XCTAssertGreaterThan(cursor?.frame.minX ?? 0, view.textContainerOrigin.x, "column 2 is right of the first cell")
        XCTAssertEqual(cursor?.focused, window.isKeyWindow)
        view.updateCursor(shape: .block, blinks: true, color: .green, visible: false, background: .black)
        XCTAssertTrue(cursor?.isHidden ?? false)
    }

    func testFocusReportsWhenAsked() {
        let (window, view, screen) = makeTerminal(lines: ["$ "], rows: 1)
        var replies: [String] = []
        view.reply = { replies.append(String(decoding: $0, as: UTF8.self)) }
        window.makeFirstResponder(nil)
        window.makeFirstResponder(view)
        XCTAssertEqual(replies, [])
        screen.feed("\u{1b}[?1004h")
        window.makeFirstResponder(nil)
        window.makeFirstResponder(view)
        XCTAssertEqual(replies, ["\u{1b}[O", "\u{1b}[I"])
    }
}
