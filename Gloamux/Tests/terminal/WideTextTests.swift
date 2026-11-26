import XCTest
@testable import Terminal

/// Text outside ASCII is written a row at a time when a whole run arrives in one read. These tests check that the
/// result is the same as writing one character at a time, which is what happens when a read ends mid-character.
final class WideTextTests: XCTestCase {
    private func screen(_ rows: Int, _ cols: Int, ambiguousWide: Bool = false) -> TerminalScreen {
        var options = TerminalOptions()
        options.rows = rows; options.cols = cols; options.scrollbackSize = 100; options.cjkAmbiguousAsWide = ambiguousWide
        return TerminalScreen(options: options)
    }

    /// Every cell, the scrollback, and the cursor, so two screens can be compared.
    private func snapshot(_ s: TerminalScreen) -> String {
        func describe(_ row: [Cell]) -> String {
            row.map { "\($0.character)|\($0.width)|\($0.wraps ? "w" : "")|\($0.style.foreground)" }.joined(separator: " ")
        }
        var lines = s.scrollback.map(describe)
        for row in 0..<s.rows { lines.append(describe((0..<s.cols).map { s.cell(row: row, col: $0) })) }
        lines.append("cursor \(s.cursorRow),\(s.cursorCol)")
        return lines.joined(separator: "\n")
    }

    private func assertSameAsOneByteAtATime(_ text: [UInt8], rows: Int = 4, cols: Int = 7, ambiguousWide: Bool = false,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let whole = screen(rows, cols, ambiguousWide: ambiguousWide), bytes = screen(rows, cols, ambiguousWide: ambiguousWide)
        whole.feed(text)
        for b in text { bytes.feed([b]) }
        XCTAssertEqual(snapshot(whole), snapshot(bytes), "for \(String(decoding: text, as: UTF8.self).debugDescription)", file: file, line: line)
    }

    func testRunsMatchCharacterByCharacterWriting() {
        let samples = [
            "中文字幕測試，第二行",
            "abc中def文ghi字",
            "日本語のテキストと 한국어 문자。",
            "e\u{301}中\u{302}x", // combining marks join the previous cell
            "\u{1F600}\u{1F680}ok", // emoji outside the BMP
            "αβγ─│┌①○", // ambiguous width
            "中中中中\r\n文文\u{1B}[31m紅字\u{1B}[0m",
            "\u{FF21}\u{FF22}\u{FF23}\t中\u{08}文",
            "ab\u{C3}(中\u{E4}\u{B8}文", // invalid and cut-off sequences become U+FFFD
            "\u{ED}\u{A0}\u{80}中\u{F4}\u{90}\u{80}\u{80}", // a surrogate and a value past U+10FFFF
            "\u{C0}\u{AF}中", // overlong
        ]
        for sample in samples {
            let bytes = Array(sample.utf8)
            assertSameAsOneByteAtATime(bytes)
            assertSameAsOneByteAtATime(bytes, rows: 2, cols: 3)
            assertSameAsOneByteAtATime(bytes, ambiguousWide: true)
        }
        // Raw bytes that are not valid UTF-8 at all.
        assertSameAsOneByteAtATime([0x61, 0xE4, 0xB8, 0x41, 0xF0, 0x9F, 0x98, 0x80, 0xFF, 0xE4, 0xB8, 0xAD])
    }

    func testRandomTextMatchesCharacterByCharacterWriting() {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["中", "文", "a", "b", " ", "한", "の", "\u{301}", "é", "α", "①", "\u{1F600}", "\r\n", "\u{1B}[1m", "\u{1B}[0m", "\t", "─"]
        for _ in 0..<200 {
            let text = (0..<Int.random(in: 1...40, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined()
            assertSameAsOneByteAtATime(Array(text.utf8), rows: 3, cols: Int.random(in: 1...9, using: &generator),
                                       ambiguousWide: Bool.random(using: &generator))
        }
    }

    func testOneColumnTerminalTakesWideCharactersInOneCell() {
        let s = screen(3, 1)
        s.feed("中a文")
        XCTAssertEqual((0..<3).map { s.lineText($0) }, ["中", "a", "文"])
        XCTAssertEqual(s.cell(row: 0, col: 0).width, 1)
    }

    func testWideCharacterAtTheLastColumnWrapsAndMarksTheRow() {
        let s = screen(3, 5)
        s.feed("abcd中文")
        XCTAssertEqual(s.lineText(0), "abcd")
        XCTAssertEqual(s.lineText(1), "中文")
        XCTAssertTrue(s.cell(row: 0, col: 4).wraps)
        XCTAssertEqual(s.cursorRow, 1)
        XCTAssertEqual(s.cursorCol, 4)
    }

    func testOverwritingHalfOfAWideCharacterBlanksTheOtherHalf() {
        let s = screen(1, 6)
        s.feed("中文字\r\u{1B}[1Cé")
        XCTAssertEqual(s.lineText(0), " é文字")
    }

    func testWidthTable() {
        XCTAssertEqual(TerminalScreen.width(of: "a", ambiguousWide: false), 1)
        XCTAssertEqual(TerminalScreen.width(of: "中", ambiguousWide: false), 2)
        XCTAssertEqual(TerminalScreen.width(of: "한", ambiguousWide: false), 2)
        XCTAssertEqual(TerminalScreen.width(of: "\u{1F600}", ambiguousWide: false), 2)
        XCTAssertEqual(TerminalScreen.width(of: "\u{20000}", ambiguousWide: false), 2, "Past the table, the ranges still apply")
        XCTAssertEqual(TerminalScreen.width(scalar: 0x301, ambiguousWide: false), 0)
        XCTAssertEqual(TerminalScreen.width(scalar: 0x200B, ambiguousWide: false), 0)
        XCTAssertEqual(TerminalScreen.width(of: "─", ambiguousWide: false), 1)
        XCTAssertEqual(TerminalScreen.width(of: "─", ambiguousWide: true), 2)
        XCTAssertEqual(TerminalScreen.width(of: "°", ambiguousWide: true), 2)
        XCTAssertEqual(TerminalScreen.width(of: "é", ambiguousWide: true), 1)
    }
}
