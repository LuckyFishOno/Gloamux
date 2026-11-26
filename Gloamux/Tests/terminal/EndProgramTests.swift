import XCTest
@testable import Terminal

/// What a tab does to its screen when a connection ends and when a new one starts.
final class EndProgramTests: XCTestCase {
    private func screen(_ rows: Int, _ cols: Int) -> TerminalScreen {
        var options = TerminalOptions()
        options.rows = rows; options.cols = cols; options.scrollbackSize = 100
        return TerminalScreen(options: options)
    }

    func testEndingAfterAShellKeepsTheCursorAtTheBottom() {
        // The reported case: a shell that never used the alternate screen, cursor after the last prompt. Leaving the
        // alternate screen with `ESC [?1049l` alone would put the cursor back at the top left.
        let s = screen(5, 20)
        s.feed("one\r\ntwo\r\n$ sudo reboot")
        s.endProgram()
        s.feed("Connection lost\r\n")
        XCTAssertEqual((0..<4).map { s.lineText($0) }, ["one", "two", "$ sudo reboot", "Connection lost"])
        XCTAssertEqual([s.cursorRow, s.cursorCol], [4, 0])
    }

    func testEndingInsideAFullScreenProgram() {
        let s = screen(4, 20)
        s.feed("$ vim\u{1B}[?1049h\u{1B}[2;3r\u{1B}[?1h\u{1B}[?2004h\u{1B}[?1002h\u{1B}[31m\u{1B}[Hediting")
        s.endProgram()
        XCTAssertFalse(s.usingAlternate)
        XCTAssertEqual(s.lineText(0), "$ vim")
        XCTAssertEqual([s.cursorRow, s.cursorCol], [1, 0], "A new line under the prompt")
        XCTAssertFalse(s.applicationCursorKeys)
        XCTAssertFalse(s.bracketedPaste)
        XCTAssertEqual(s.mouseTracking, .off)
        s.feed("a\r\nb\r\nc\r\nd")
        XCTAssertEqual(s.lines, ["a", "b", "c", "d"], "The scroll region is the whole screen again")
        XCTAssertEqual(s.scrollback.count, 1)
        XCTAssertEqual(s.cell(row: 3, col: 0).style.foreground, .default)
    }

    func testEndingDropsAHalfReadSequence() {
        let s = screen(3, 20)
        s.feed("$ cat\u{1B}]0;never finished")
        s.endProgram()
        s.feed("ok")
        XCTAssertEqual(s.lineText(1), "ok")
    }

    func testClearKeepingScrollbackMovesTheUsedLinesUp() {
        let s = screen(5, 20)
        s.feed("one\r\ntwo\r\n$ ")
        s.clearKeepingScrollback()
        XCTAssertEqual(s.lines, ["", "", "", "", ""])
        XCTAssertEqual(s.scrollback.count, 3)
        XCTAssertEqual([s.cursorRow, s.cursorCol], [0, 0])
        s.feed("Connected")
        XCTAssertEqual(s.lineText(0), "Connected")

        // A screen whose text is below the cursor (a program moved it) keeps that text too.
        let t = screen(4, 10)
        t.feed("\u{1B}[4;1Hlast\u{1B}[H")
        t.clearKeepingScrollback()
        XCTAssertEqual(t.scrollback.count, 4)
    }
}
