import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Terminal

final class InlineImageTests: XCTestCase {
    /// A solid PNG of the given pixel size.
    private func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0.5, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func screen(rows: Int = 10, cols: Int = 20) -> TerminalScreen {
        var options = TerminalOptions()
        options.rows = rows; options.cols = cols; options.scrollbackSize = 50
        let screen = TerminalScreen(options: options)
        screen.cellSize = (10, 16)
        return screen
    }

    func testITermFileCoversCellsAndLeavesTheCursorAfterIt() throws {
        let s = screen()
        let data = try png(width: 20, height: 32)
        s.feed("ab\u{1B}]1337;File=name=eC5wbmc=;size=\(data.count);inline=1:\(data.base64EncodedString())\u{07}")
        let image = try XCTUnwrap(s.images.first)
        XCTAssertEqual(image.column, 2)
        XCTAssertEqual(image.columns, 2)
        XCTAssertEqual(image.rows, 2)
        XCTAssertEqual(image.line, 0)
        XCTAssertEqual(s.cursorRow, 1, "The cursor ends on the picture's last row")
        XCTAssertEqual(s.cursorCol, 4, "just after it")
        if case .encoded(let stored) = image.content { XCTAssertEqual(stored, data) } else { XCTFail("Kept as the file") }

        // A requested width in cells keeps the proportions; a file not marked inline is never shown.
        s.feed("\r\n\u{1B}]1337;File=width=4;inline=1:\(data.base64EncodedString())\u{1B}\\")
        XCTAssertEqual(s.images.last.map { [$0.columns, $0.rows] }, [4, 4])
        s.feed("\u{1B}]1337;File=inline=0:\(data.base64EncodedString())\u{07}")
        s.feed("\u{1B}]1337;File=inline=1:bm90IGFuIGltYWdl\u{07}")
        XCTAssertEqual(s.images.count, 2, "Downloads and files that are not pictures are ignored")
        s.feed("\u{1B}]1337;File=width=100%;height=2;preserveAspectRatio=0;inline=1:\(data.base64EncodedString())\u{07}")
        XCTAssertEqual(s.images.last.map { [$0.columns, $0.rows] }, [20 - s.images.last!.column, 2])
        XCTAssertEqual(s.images.last?.stretches, true)
    }

    func testMultipartFileJoinsItsParts() throws {
        let s = screen()
        let text = try png(width: 10, height: 16).base64EncodedString()
        let middle = text.index(text.startIndex, offsetBy: text.count / 2 / 4 * 4)
        s.feed("\u{1B}]1337;MultipartFile=inline=1\u{07}\u{1B}]1337;FilePart=\(text[..<middle])\u{07}")
        s.feed("\u{1B}]1337;FilePart=\(text[middle...])\u{07}\u{1B}]1337;FileEnd\u{07}")
        XCTAssertEqual(s.images.map { [$0.columns, $0.rows] }, [[1, 1]])
    }

    func testSixelDecodesColorsAndLeavesTheCursorBelow() throws {
        let s = screen()
        // Raster 8×12, register 1 set to red in RGB percent, two bands of eight full sixels.
        s.feed("x\u{1B}P0;1;0q\"1;1;8;12#1;2;100;0;0#1!8~-!8~\u{1B}\\")
        let image = try XCTUnwrap(s.images.first)
        guard case .rgba(let pixels, let width, let height) = image.content else { return XCTFail("Decoded to pixels") }
        XCTAssertEqual([width, height], [8, 12])
        XCTAssertEqual(Array(pixels.prefix(4)), [255, 0, 0, 255])
        XCTAssertEqual(Array(pixels.suffix(4)), [255, 0, 0, 255])
        XCTAssertEqual([image.column, image.columns, image.rows], [1, 1, 1])
        XCTAssertEqual([s.cursorRow, s.cursorCol], [1, 1], "The cursor goes to the line below, at the picture's column")

        // HLS: DEC hue 120 is red. A repeat past the size limit is refused rather than allocated.
        s.feed("\u{1B}Pq#2;1;120;50;100#2~\u{1B}\\")
        if case .rgba(let pixels, _, _)? = s.images.last?.content { XCTAssertEqual(Array(pixels.prefix(4)), [255, 0, 0, 255]) }
        s.feed("\u{1B}Pq!99999~\u{1B}\\")
        XCTAssertEqual(s.images.count, 2)
        // Other DCS strings are skipped, and text after them prints as usual.
        s.feed("\u{1B}P+q544e\u{1B}\\ok")
        XCTAssertEqual(s.images.count, 2)
        XCTAssertTrue(s.text(lines: s.absoluteLine(ofRow: 0)..<s.absoluteLine(ofRow: s.rows)).contains("ok"))
    }

    func testPicturesScrollAreErasedAndFollowReflow() throws {
        let s = screen(rows: 4, cols: 20)
        let data = try png(width: 10, height: 32)
        s.feed("one\r\n\u{1B}]1337;File=inline=1:\(data.base64EncodedString())\u{07}\r\n")
        XCTAssertEqual(s.images.first?.line, 1)
        s.feed("a\r\nb\r\nc\r\n")
        XCTAssertEqual(s.images.first?.line, 1, "It keeps its absolute line as text scrolls")
        s.resize(rows: 4, cols: 10)
        XCTAssertEqual(s.images.first?.line, 1, "Rewrapping keeps it beside its line")
        s.feed("\u{1B}[2J")
        XCTAssertEqual(s.images.count, 1, "Erasing the screen keeps pictures in the scrollback")
        s.feed("\u{1B}[3J")
        XCTAssertTrue(s.images.isEmpty, "Erasing the scrollback removes them")

        s.feed("\u{1B}[?1049h\u{1B}]1337;File=inline=1:\(data.base64EncodedString())\u{07}")
        XCTAssertEqual(s.images.first?.alternate, true)
        s.feed("\u{1B}[?1049l")
        XCTAssertTrue(s.images.isEmpty, "Leaving the alternate screen discards its pictures")

        for _ in 0..<80 { s.feed("\u{1B}]1337;File=inline=1:\(data.base64EncodedString())\u{07}\r\n") }
        XCTAssertTrue(s.images.allSatisfy { $0.line + $0.rows > s.trimmedLines }, "Pictures that left the scrollback are dropped")
        XCTAssertLessThanOrEqual(s.images.count, InlineImages.maximumImages)
    }

    func testDeviceAttributesReportSixelAndImagesCanBeTurnedOff() throws {
        let s = screen()
        s.feed("\u{1B}[c")
        XCTAssertEqual(s.takeEvents(), [.reply(Array("\u{1B}[?62;4;22c".utf8))])
        var options = TerminalOptions()
        options.inlineImages = false
        let plain = TerminalScreen(options: options)
        plain.feed("\u{1B}[c\u{1B}Pq#1~\u{1B}\\\u{1B}]1337;File=inline=1:\(try png(width: 4, height: 4).base64EncodedString())\u{07}")
        XCTAssertEqual(plain.takeEvents(), [.reply(Array("\u{1B}[?62;22c".utf8))])
        XCTAssertTrue(plain.images.isEmpty)
    }
}
