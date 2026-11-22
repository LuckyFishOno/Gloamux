import XCTest
@testable import Terminal

final class ShellIntegrationTests: XCTestCase {
    private func screen(rows: Int = 6, cols: Int = 40, scrollback: Int = 100) -> TerminalScreen {
        var options = TerminalOptions(); options.rows = rows; options.cols = cols; options.scrollbackSize = scrollback
        return TerminalScreen(options: options)
    }

    func testPromptMarksRecordTheCommandItsOutputAndExitCode() throws {
        let s = screen()
        s.feed("\u{1b}]133;A\u{07}me@host % \u{1b}]133;B\u{07}ls -l\r\n\u{1b}]133;C\u{07}one\r\ntwo\r\n\u{1b}]133;D;2\u{07}")
        s.feed("\u{1b}]133;A\u{07}me@host % \u{1b}]133;B\u{07}")
        XCTAssertEqual(s.commandMarks.count, 2)
        let first = s.commandMarks[0]
        XCTAssertEqual(first.promptLine, 0)
        XCTAssertEqual(first.command, "ls -l")
        XCTAssertEqual(first.outputLine, 1)
        XCTAssertEqual(first.endLine, 3)
        XCTAssertEqual(first.exitCode, 2)
        XCTAssertEqual(s.text(lines: first.outputLine!..<first.endLine!), "one\ntwo")
        XCTAssertEqual(s.commandMarks[1].promptLine, 3)
        let events = s.takeEvents()
        guard case .commandFinished(let mark)? = events.first(where: { if case .commandFinished = $0 { return true }; return false }) else {
            return XCTFail("expected a finished command event")
        }
        XCTAssertEqual(mark.exitCode, 2)
        XCTAssertNotNil(mark.duration)
    }

    func testAFinishWithoutARunCommandRaisesNoEvent() {
        let s = screen()
        s.feed("\u{1b}]133;A\u{07}% \u{1b}]133;B\u{07}\r\n\u{1b}]133;D;0\u{07}\u{1b}]133;A\u{07}% ")
        XCTAssertFalse(s.takeEvents().contains { if case .commandFinished = $0 { return true }; return false })
    }

    func testAbsoluteLinesKeepCountingAfterScrollbackIsTrimmed() {
        let s = screen(rows: 3, cols: 20, scrollback: 2)
        s.feed("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}seq\r\n\u{1b}]133;C\u{07}")
        for n in 1...10 { s.feed("\(n)\r\n") }
        s.feed("\u{1b}]133;D;0\u{07}")
        XCTAssertGreaterThan(s.trimmedLines, 0)
        let mark = s.commandMarks[0]
        XCTAssertNil(s.row(absolute: mark.promptLine), "the prompt line has been trimmed")
        XCTAssertEqual(mark.endLine, 11)
        XCTAssertEqual(s.text(lines: 9..<11), "9\n10")
    }

    func testOSC8LinksSurviveAStyleResetAndEnd() {
        let s = screen()
        s.feed("a \u{1b}]8;;https://example.com/x\u{07}li\u{1b}[0mnk\u{1b}]8;;\u{07} b")
        let link = s.cell(row: 0, col: 2).style.link
        XCTAssertNotEqual(link, 0)
        XCTAssertEqual(s.link(link), "https://example.com/x")
        XCTAssertEqual(s.cell(row: 0, col: 4).style.link, link)
        XCTAssertEqual(s.cell(row: 0, col: 7).style.link, 0)
        XCTAssertEqual(s.cell(row: 0, col: 0).style.link, 0)
        XCTAssertNil(s.unsupported["OSC 8"])
    }

    func testOSC8RejectsControlCharactersAndReusesTargets() {
        let s = screen()
        s.feed("\u{1b}]8;id=1;https://a.example\u{07}x\u{1b}]8;;\u{07}\u{1b}]8;;https://a.example\u{07}y\u{1b}]8;;\u{07}")
        XCTAssertEqual(s.cell(row: 0, col: 0).style.link, s.cell(row: 0, col: 1).style.link)
        XCTAssertEqual(s.links.count, 2)
    }
}
