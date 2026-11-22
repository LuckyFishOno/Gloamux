import XCTest
@testable import Terminal

final class ReflowTests: XCTestCase {
    private func screen(rows: Int = 5, cols: Int = 10) -> TerminalScreen {
        var options = TerminalOptions(); options.rows = rows; options.cols = cols
        return TerminalScreen(options: options)
    }

    func testNarrowingWrapsAndWideningJoinsAgain() {
        let s = screen()
        s.feed("abcdefghij12345\r\nend")
        XCTAssertEqual(s.lines.prefix(3), ["abcdefghij", "12345", "end"])
        s.resize(rows: 5, cols: 6)
        XCTAssertEqual(s.lines.prefix(4), ["abcdef", "ghij12", "345", "end"])
        XCTAssertEqual(s.cursorRow, 3); XCTAssertEqual(s.cursorCol, 3)
        s.resize(rows: 5, cols: 20)
        XCTAssertEqual(s.lines.prefix(2), ["abcdefghij12345", "end"])
        XCTAssertEqual(s.cursorRow, 1); XCTAssertEqual(s.cursorCol, 3)
    }

    func testHardLineBreaksStaySeparate() {
        let s = screen()
        s.feed("one\r\ntwo")
        s.resize(rows: 5, cols: 20)
        XCTAssertEqual(s.lines.prefix(2), ["one", "two"])
    }

    func testWideCharacterMovesToTheNextRowInsteadOfSplitting() {
        let s = screen(cols: 6)
        s.feed("abcde中文")
        s.resize(rows: 5, cols: 5)
        XCTAssertEqual(s.lines.prefix(3), ["abcde", "中文", ""])
        s.resize(rows: 5, cols: 4)
        XCTAssertEqual(s.lines.prefix(3), ["abcd", "e中", "文"])
    }

    func testOverflowGoesToScrollbackAndComesBack() {
        let s = screen(rows: 3, cols: 10)
        s.feed("0123456789abcdefghij\r\nx")
        s.resize(rows: 3, cols: 5)
        XCTAssertEqual(s.lines, ["abcde", "fghij", "x"])
        XCTAssertEqual(s.scrollback.count, 2)
        s.resize(rows: 3, cols: 20)
        XCTAssertEqual(s.scrollback.count, 0)
        XCTAssertEqual(s.lines.prefix(2), ["0123456789abcdefghij", "x"])
    }

    func testCursorStaysWithTypedText() {
        let s = screen(rows: 4, cols: 10)
        s.feed("$ echo hello world")
        XCTAssertEqual(s.cursorRow, 1); XCTAssertEqual(s.cursorCol, 8)
        s.resize(rows: 4, cols: 30)
        XCTAssertEqual(s.lines[0], "$ echo hello world")
        XCTAssertEqual(s.cursorRow, 0); XCTAssertEqual(s.cursorCol, 18)
    }

    func testCommandMarksFollowTheirLines() {
        let s = screen(rows: 6, cols: 10)
        s.feed("aaaaaaaaaaaaaaa\r\n")
        s.feed("\u{1B}]133;A\u{07}$ ls\r\n")
        let before = s.commandMarks.last?.promptLine
        XCTAssertEqual(before, 2)
        s.resize(rows: 6, cols: 20)
        XCTAssertEqual(s.commandMarks.last?.promptLine, 1)
        XCTAssertEqual(s.text(lines: 1..<2), "$ ls")
    }

    func testAlternateScreenIsOnlyCut() {
        let s = screen()
        s.feed("abcdefghij12345")
        s.feed("\u{1B}[?1049h\u{1B}[H")
        s.feed("vim screen")
        s.resize(rows: 5, cols: 6)
        XCTAssertEqual(s.lines[0], "vim sc")
        s.feed("\u{1B}[?1049l")
        XCTAssertEqual(s.lines.prefix(3), ["abcdef", "ghij12", "345"])
    }
}

final class BulkTextTests: XCTestCase {
    /// Output split at any byte draws the same screen as the same output in one piece.
    func testSplittingOutputAnywhereDrawsTheSameScreen() {
        var options = TerminalOptions(); options.rows = 6; options.cols = 12
        let text = "plain \u{1B}[31mred\u{1B}[0m 中文 wide\r\noverwrite\u{1B}[3D***\ttab\u{1B}[2;11Habcdef 終端機 end\u{1B}[?7lno wrap here at all"
        let whole = TerminalScreen(options: options)
        whole.feed(text)
        for split in stride(from: 1, to: text.utf8.count, by: 3) {
            let bytes = Array(text.utf8)
            let parts = TerminalScreen(options: options)
            parts.feed(Array(bytes[..<split])); parts.feed(Array(bytes[split...]))
            XCTAssertEqual(parts.lines, whole.lines, "split at \(split)")
            XCTAssertEqual(parts.cursorCol, whole.cursorCol); XCTAssertEqual(parts.cursorRow, whole.cursorRow)
        }
        let byByte = TerminalScreen(options: options)
        for b in text.utf8 { byByte.feed([b]) }
        XCTAssertEqual(byByte.lines, whole.lines)
    }

    func testWritingOverHalfAWideCharacterBlanksTheOtherHalf() {
        var options = TerminalOptions(); options.rows = 2; options.cols = 8
        let s = TerminalScreen(options: options)
        s.feed("中文字\r\u{1B}[1Cab")
        XCTAssertEqual(s.lines[0], " ab 字")
    }

    func testMalformedUTF8BecomesReplacementCharacter() {
        let s = TerminalScreen()
        s.feed([0xC0, 0x80, 0x41, 0xED, 0xA0, 0x80, 0x42])
        XCTAssertEqual(s.lines[0], "\u{FFFD}A\u{FFFD}B")
    }
}

final class ParameterTests: XCTestCase {
    /// The byte-by-byte parser gives what splitting the string did.
    func testParametersMatchStringSplitting() {
        func split(_ params: String) -> [Int?] {
            let body = params.hasPrefix("?") || params.hasPrefix(">") || params.hasPrefix("=") ? String(params.dropFirst()) : params
            return body.split(separator: ";", omittingEmptySubsequences: false).map { Int($0.split(separator: ":").first ?? "") }
        }
        for params in ["", "0", "1;31", "38;5;208", "38;2;10;20;30", "?1049", ">0;1", "=5", ";;3", "4:3", "38:2:1:2:3;1",
                       "1<2", "12?", "007", ";", "1;", "999999999999999999999"] {
            XCTAssertEqual(TerminalScreen.parameters(params), split(params), params)
        }
    }
}
