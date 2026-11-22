import XCTest
import Terminal

/// Mouse reporting, cursor shapes, focus reports, OSC 52, scrollback size, and legacy encodings.
final class TerminalModesTests: XCTestCase {
    private func screen(rows: Int = 24, cols: Int = 80) -> TerminalScreen {
        var options = TerminalOptions(); options.rows = rows; options.cols = cols
        return TerminalScreen(options: options)
    }

    func testMouseReportsFollowTheModeTheProgramChose() {
        let s = screen()
        XCTAssertNil(s.mouseReport(.left, .press, row: 0, column: 0), "nothing is reported until a program asks")
        s.feed("\u{1b}[?1000h")
        XCTAssertEqual(s.mouseTracking, .clicks)
        XCTAssertEqual(s.mouseReport(.left, .press, row: 2, column: 4), [0x1B, 0x5B, 0x4D, 32, 32 + 5, 32 + 3])
        XCTAssertEqual(s.mouseReport(.left, .release, row: 2, column: 4), [0x1B, 0x5B, 0x4D, 32 + 3, 32 + 5, 32 + 3])
        XCTAssertNil(s.mouseReport(.left, .drag, row: 2, column: 5), "click tracking ignores drags")
        s.feed("\u{1b}[?1002h\u{1b}[?1006h")
        XCTAssertEqual(s.mouseReport(.left, .drag, row: 2, column: 5).map { String(decoding: $0, as: UTF8.self) }, "\u{1b}[<32;6;3M")
        XCTAssertEqual(s.mouseReport(.right, .release, row: 0, column: 0).map { String(decoding: $0, as: UTF8.self) }, "\u{1b}[<2;1;1m")
        XCTAssertEqual(s.mouseReport(.wheelUp, .press, row: 0, column: 0, control: true).map { String(decoding: $0, as: UTF8.self) }, "\u{1b}[<80;1;1M")
        XCTAssertNil(s.mouseReport(.none, .move, row: 1, column: 1), "motion needs 1003")
        s.feed("\u{1b}[?1003h")
        XCTAssertNotNil(s.mouseReport(.none, .move, row: 1, column: 1))
        s.feed("\u{1b}[?1003l")
        XCTAssertEqual(s.mouseTracking, .off)
    }

    func testLegacyMouseEncodingStopsBeyondColumn223() {
        let s = screen(rows: 24, cols: 300)
        s.feed("\u{1b}[?1000h")
        XCTAssertNil(s.mouseReport(.left, .press, row: 0, column: 250))
        s.feed("\u{1b}[?1006h")
        XCTAssertEqual(s.mouseReport(.left, .press, row: 0, column: 250).map { String(decoding: $0, as: UTF8.self) }, "\u{1b}[<0;251;1M")
    }

    func testCursorShapeAndFocusReports() {
        let s = screen()
        XCTAssertNil(s.cursorShape)
        s.feed("\u{1b}[5 q")
        XCTAssertEqual(s.cursorShape, .bar); XCTAssertEqual(s.cursorBlinks, true)
        s.feed("\u{1b}[4 q")
        XCTAssertEqual(s.cursorShape, .underline); XCTAssertEqual(s.cursorBlinks, false)
        s.feed("\u{1b}[0 q")
        XCTAssertNil(s.cursorShape); XCTAssertNil(s.cursorBlinks)
        s.feed("\u{1b}[?1004h")
        XCTAssertTrue(s.reportsFocus)
        s.feed("\u{1b}c")
        XCTAssertFalse(s.reportsFocus)
    }

    func testOSC52WritesButNeverReadsTheClipboard() {
        let s = screen()
        s.feed("\u{1b}]52;c;" + Data("copied 文字".utf8).base64EncodedString() + "\u{07}")
        XCTAssertEqual(s.takeEvents(), [.clipboard("copied 文字")])
        s.feed("\u{1b}]52;c;?\u{1b}\\")
        XCTAssertEqual(s.takeEvents(), [], "a request to read the clipboard is not answered")
        s.feed("\u{1b}]52;c;!!!not base64\u{07}")
        XCTAssertEqual(s.takeEvents(), [])
    }

    func testTitleAndBellEvents() {
        let s = screen()
        s.feed("\u{1b}]2;vim notes.txt\u{07}\u{07}")
        XCTAssertEqual(s.takeEvents(), [.title("vim notes.txt"), .bell])
    }

    func testScrollbackSizeCanShrinkAndGrow() {
        var options = TerminalOptions(); options.rows = 2; options.cols = 10; options.scrollbackSize = 100
        let s = TerminalScreen(options: options)
        for n in 0..<50 { s.feed("line \(n)\r\n") }
        XCTAssertEqual(s.scrollback.count, 49)
        s.setScrollbackSize(10)
        XCTAssertEqual(s.scrollback.count, 10)
        XCTAssertEqual(s.trimmedLines, 39)
        s.setScrollbackSize(1000)
        for n in 0..<20 { s.feed("more \(n)\r\n") }
        XCTAssertEqual(s.scrollback.count, 30)
    }

    func testColumnOfUTF16OffsetCountsWideCharacters() {
        let s = screen(rows: 2, cols: 10)
        s.feed("a中b😀c")
        // Text as drawn: "a", "中", "b", "😀" (two UTF-16 units), "c".
        XCTAssertEqual(s.column(ofUTF16Offset: 0, inRow: 0), 0)
        XCTAssertEqual(s.column(ofUTF16Offset: 1, inRow: 0), 1)
        XCTAssertEqual(s.column(ofUTF16Offset: 2, inRow: 0), 3)
        XCTAssertEqual(s.column(ofUTF16Offset: 4, inRow: 0), 4)
        XCTAssertEqual(s.column(ofUTF16Offset: 5, inRow: 0), 6)
    }

    func testLegacyEncodingsDecodeAcrossChunksAndEncodeInput() {
        let big5: [UInt8] = [0xA4, 0xA4, 0xA4, 0xE5] // 中文
        var decoder = TerminalDecoder(encoding: .big5)
        let first = decoder.decode([0x1B, 0x5B, 0x31, 0x6D] + Array(big5.prefix(3)))
        let second = decoder.decode(Array(big5.suffix(1)) + [0x0D, 0x0A])
        XCTAssertEqual(String(decoding: first + second, as: UTF8.self), "\u{1b}[1m中文\r\n")
        XCTAssertEqual(TerminalEncoding.big5.encode(Array("中文 ok".utf8)), big5 + Array(" ok".utf8))

        var gb = TerminalDecoder(encoding: .gb18030)
        let gbBytes = Array("終端€".data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))!)
        var out: [UInt8] = []
        for byte in gbBytes { out += gb.decode([byte]) }
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "終端€")

        var sjis = TerminalDecoder(encoding: .shiftJIS)
        XCTAssertEqual(String(decoding: sjis.decode([0x83, 0x65, 0x83, 0x58, 0x83, 0x67, 0xB1]), as: UTF8.self), "テストｱ")

        var latin = TerminalDecoder(encoding: .latin1)
        XCTAssertEqual(String(decoding: latin.decode([0x63, 0x61, 0x66, 0xE9]), as: UTF8.self), "café")
        var utf8 = TerminalDecoder(encoding: .utf8)
        XCTAssertEqual(utf8.decode([0xE4, 0xB8]), [0xE4, 0xB8], "UTF-8 passes through for the parser to join")
    }

    func testInvalidLegacyBytesBecomeReplacementCharacters() {
        var decoder = TerminalDecoder(encoding: .eucKR)
        let text = String(decoding: decoder.decode([0x41, 0xA1, 0x20, 0x42]), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("A"))
        XCTAssertTrue(text.hasSuffix("B"))
    }
}
