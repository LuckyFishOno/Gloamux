import Compression
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Terminal

final class KittyGraphicsTests: XCTestCase {
    private func screen(rows: Int = 10, cols: Int = 20, images: Bool = true) -> TerminalScreen {
        var options = TerminalOptions()
        options.rows = rows; options.cols = cols; options.scrollbackSize = 50; options.inlineImages = images
        let screen = TerminalScreen(options: options)
        screen.cellSize = (10, 16)
        return screen
    }

    /// RGBA pixels of a `width` × `height` image, each pixel numbered so crops can be checked.
    private func rgba(_ width: Int, _ height: Int) -> [UInt8] {
        (0..<(width * height)).flatMap { [UInt8($0 & 0xFF), 0, 0, 0xFF] }
    }

    private func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// `data` as a zlib stream (RFC 1950): a header, raw deflate, and the Adler-32 checksum.
    private func zlib(_ data: [UInt8]) -> [UInt8] {
        var deflated = [UInt8](repeating: 0, count: data.count + 1024)
        let count = compression_encode_buffer(&deflated, deflated.count, data, data.count, nil, COMPRESSION_ZLIB)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let adler = b << 16 | a
        return [0x78, 0x9C] + deflated.prefix(count) + [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
    }

    private func command(_ keys: String, _ payload: [UInt8] = []) -> String {
        "\u{1B}_G\(keys);\(Data(payload).base64EncodedString())\u{1B}\\"
    }

    private func replies(_ s: TerminalScreen) -> [String] {
        s.takeEvents().compactMap { if case .reply(let bytes) = $0 { return String(decoding: bytes, as: UTF8.self) } else { return nil } }
    }

    func testTransmitAndDisplayRawPixels() throws {
        let s = screen()
        s.feed("ab" + command("a=T,f=32,s=20,v=32,i=7", rgba(20, 32)))
        let image = try XCTUnwrap(s.images.first)
        XCTAssertEqual([image.column, image.columns, image.rows, image.line], [2, 2, 2, 0])
        XCTAssertEqual(image.kittyImage, 7)
        XCTAssertEqual([s.cursorRow, s.cursorCol], [1, 4], "The cursor ends after the picture on its last row")
        XCTAssertEqual(replies(s), ["\u{1B}_Gi=7;OK\u{1B}\\"])
        guard case .rgba(let pixels, 20, 32) = image.content else { return XCTFail("Kept as RGBA pixels") }
        XCTAssertEqual(pixels, rgba(20, 32))

        // RGB is widened to RGBA, and C=1 leaves the cursor where it was.
        s.feed(command("a=T,f=24,s=1,v=1,C=1", [1, 2, 3]))
        guard case .rgba(let rgb, 1, 1)? = s.images.last?.content else { return XCTFail("RGB kept as RGBA") }
        XCTAssertEqual(rgb, [1, 2, 3, 0xFF])
        XCTAssertEqual([s.cursorRow, s.cursorCol], [1, 4])
        XCTAssertEqual(replies(s), [], "No reply without an id")
    }

    func testPNGChunkedTransferAndZlib() throws {
        let s = screen()
        let file = try png(width: 30, height: 16)
        let text = Array(file.base64EncodedString().utf8)
        let middle = text.count / 2 / 4 * 4
        s.feed("\u{1B}_Ga=T,f=100,i=3,m=1;\(String(decoding: text[..<middle], as: UTF8.self))\u{1B}\\")
        XCTAssertTrue(s.images.isEmpty, "Nothing is shown until the last chunk")
        s.feed("\u{1B}_Gm=0;\(String(decoding: text[middle...], as: UTF8.self))\u{1B}\\")
        XCTAssertEqual(s.images.map { [$0.columns, $0.rows] }, [[3, 1]])
        XCTAssertEqual(replies(s), ["\u{1B}_Gi=3;OK\u{1B}\\"])

        s.feed(command("a=T,f=32,s=4,v=2,o=z,i=4", zlib(rgba(4, 2))))
        guard case .rgba(let pixels, 4, 2)? = s.images.last?.content else { return XCTFail("Inflated") }
        XCTAssertEqual(pixels, rgba(4, 2))
        XCTAssertEqual(replies(s), ["\u{1B}_Gi=4;OK\u{1B}\\"])
    }

    func testTransmitThenPlaceCropAndReplacePlacement() throws {
        let s = screen()
        s.feed(command("a=t,f=32,s=4,v=4,i=9", rgba(4, 4)))
        XCTAssertTrue(s.images.isEmpty)
        XCTAssertEqual(replies(s), ["\u{1B}_Gi=9;OK\u{1B}\\"])
        s.feed(command("a=p,i=9,p=1,c=5,r=2"))
        XCTAssertEqual(s.images.map { [$0.columns, $0.rows] }, [[5, 2]])
        XCTAssertEqual(s.images.first?.stretches, true, "Both c and r stretch the picture to fill them")
        XCTAssertEqual(replies(s), ["\u{1B}_Gi=9,p=1;OK\u{1B}\\"])
        s.feed("\r\n" + command("a=p,i=9,p=1,x=1,y=2,w=2,h=1,q=1"))
        XCTAssertEqual(s.images.count, 1, "The same placement id moves the placement")
        guard case .rgba(let part, 2, 1)? = s.images.first?.content else { return XCTFail("Cropped") }
        XCTAssertEqual(part, [9, 0, 0, 0xFF, 10, 0, 0, 0xFF])
        XCTAssertEqual(replies(s), [], "q=1 hides OK")

        s.feed(command("a=p,i=404"))
        XCTAssertEqual(replies(s), ["\u{1B}_Gi=404;ENOENT:no image with that id\u{1B}\\"])
        s.feed(command("a=p,i=404,q=2"))
        XCTAssertEqual(replies(s), [], "q=2 hides errors too")
    }

    func testImageNumbersGetAnIdInTheReply() {
        let s = screen()
        s.feed(command("a=t,f=24,s=1,v=1,I=5", [0, 0, 0]))
        let reply = replies(s).first ?? ""
        XCTAssertTrue(reply.hasPrefix("\u{1B}_Gi=") && reply.hasSuffix(",I=5;OK\u{1B}\\"), reply)
        s.feed(command("a=p,I=5"))
        XCTAssertEqual(s.images.count, 1)
    }

    func testDelete() {
        let s = screen()
        s.feed(command("a=T,f=24,s=1,v=1,i=1", [0, 0, 0]) + command("a=T,f=24,s=1,v=1,i=2", [0, 0, 0]))
        s.feed("\u{1B}Pq#1;2;100;0;0~\u{1B}\\") // a sixel picture, which kitty deletes leave alone
        XCTAssertEqual(s.images.map(\.kittyImage), [1, 2, nil])
        s.feed(command("a=d,d=i,i=1"))
        XCTAssertEqual(s.images.map(\.kittyImage), [2, nil])
        s.feed(command("a=p,i=1"))
        XCTAssertEqual(s.images.map(\.kittyImage), [2, nil, 1], "Lowercase keeps the data for another placement")
        s.feed(command("a=d,d=I,i=1") + command("a=p,i=1"))
        XCTAssertEqual(s.images.map(\.kittyImage), [2, nil])
        XCTAssertEqual(replies(s).last, "\u{1B}_Gi=1;ENOENT:no image with that id\u{1B}\\", "Uppercase drops the data")
        s.feed(command("a=d"))
        XCTAssertEqual(s.images.map(\.kittyImage), [nil])
    }

    func testRefusedCommands() {
        let s = screen()
        s.feed(command("a=T,t=f,i=1", Array("/etc/passwd".utf8)))
        XCTAssertEqual(replies(s), ["\u{1B}_Gi=1;EINVAL:only direct transmission (t=d) is supported\u{1B}\\"])
        s.feed(command("a=T,f=32,s=2,v=2,i=2", [1, 2, 3]))
        XCTAssertEqual(replies(s), ["\u{1B}_Gi=2;EINVAL:the image data or its size is not valid\u{1B}\\"])
        s.feed(command("a=T,f=32,s=5000,v=1,i=3", []))
        XCTAssertEqual(replies(s), ["\u{1B}_Gi=3;EFBIG:the image is larger than Gloamux shows\u{1B}\\"])
        s.feed(command("a=T,f=24,s=1,v=1,U=1,i=4", [0, 0, 0]))
        XCTAssertEqual(replies(s), ["\u{1B}_Gi=4;EINVAL:Unicode placeholders are not supported\u{1B}\\"])
        s.feed(command("a=f,i=5"))
        XCTAssertEqual(replies(s), ["\u{1B}_Gi=5;EINVAL:unsupported action\u{1B}\\"])
        XCTAssertTrue(s.images.isEmpty)
        // Other APC strings are still skipped, and the text after them is shown.
        s.feed("\u{1B}_something else\u{1B}\\ok")
        XCTAssertEqual(s.lineText(0), "ok")
    }

    func testQueryAnswersWithoutKeeping() {
        let s = screen()
        s.feed(command("i=31,s=1,v=1,a=q,t=d,f=24", [0, 0, 0]))
        XCTAssertEqual(replies(s), ["\u{1B}_Gi=31;OK\u{1B}\\"])
        s.feed(command("a=p,i=31"))
        XCTAssertEqual(replies(s), ["\u{1B}_Gi=31;ENOENT:no image with that id\u{1B}\\"])
        XCTAssertTrue(s.images.isEmpty)
    }

    func testTurnedOffGivesNoReply() {
        let s = screen(images: false)
        s.feed(command("i=31,s=1,v=1,a=q,t=d,f=24", [0, 0, 0]) + command("a=T,f=24,s=1,v=1,i=1", [0, 0, 0]) + "ok")
        XCTAssertEqual(replies(s), [])
        XCTAssertTrue(s.images.isEmpty)
        XCTAssertEqual(s.lineText(0), "ok")
    }

    func testResetDropsKeptImages() {
        let s = screen()
        s.feed(command("a=t,f=24,s=1,v=1,i=1", [0, 0, 0]) + "\u{1B}c" + command("a=p,i=1"))
        XCTAssertEqual(replies(s).last, "\u{1B}_Gi=1;ENOENT:no image with that id\u{1B}\\")
    }

    func testCellsFollowProportionsWhenOneSideIsGiven() {
        let cell = (width: 10.0, height: 20.0)
        XCTAssertEqual(KittyGraphics.cells(width: 100, height: 100, columns: 4, rows: nil, cell: cell).rows, 2)
        XCTAssertEqual(KittyGraphics.cells(width: 100, height: 100, columns: nil, rows: 3, cell: cell).columns, 6)
        let natural = KittyGraphics.cells(width: 25, height: 41, columns: nil, rows: nil, cell: cell)
        XCTAssertEqual([natural.columns, natural.rows], [3, 3])
        XCTAssertFalse(natural.stretches)
    }

    func testPixelSizeReports() {
        let s = screen(rows: 10, cols: 20)
        s.feed("\u{1B}[14t\u{1B}[16t\u{1B}[18t")
        XCTAssertEqual(replies(s), ["\u{1B}[4;160;200t", "\u{1B}[6;16;10t", "\u{1B}[8;10;20t"])
    }
}
