import XCTest
@testable import Terminal

final class ZmodemTests: XCTestCase {
    final class Sink: ZmodemSink {
        var data = Data()
        var closed: Bool?
        func write(_ chunk: Data) throws { data.append(chunk) }
        func close(complete: Bool) { closed = complete }
    }

    final class Source: ZmodemSource {
        let name: String, contents: Data, modified = Date(timeIntervalSince1970: 1_700_000_000)
        var size: Int { contents.count }
        init(_ name: String, _ contents: Data) { self.name = name; self.contents = contents }
        func read(at offset: Int, count: Int) throws -> Data { contents.subdata(in: offset..<(offset + count)) }
    }

    func testChecksumsAndHeadersMatchTheProtocol() {
        XCTAssertEqual(Zmodem.crc16(Array("123456789".utf8)), 0x31C3)
        XCTAssertEqual(Zmodem.crc32(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(Zmodem.hexHeader(.rqinit), Array("**\u{18}B00000000000000\r".utf8) + [0x8A, 0x11])
        XCTAssertEqual(Zmodem.hexHeader(.fin).suffix(2), [0x0D, 0x8A], "ZFIN has no XON after it")
        XCTAssertEqual(Zmodem.detect(Array("rz\r**\u{18}B00000000000000\r".utf8))?.index, 3)
        XCTAssertEqual(Zmodem.detect(Array("**\u{18}B0100000023be50".utf8))?.start, .upload)
        XCTAssertNil(Zmodem.detect(Array("** not zmodem **".utf8)))
    }

    func testSubpacketsSurviveEscapingEveryByte() {
        let data = (0..<1024).map { UInt8($0 % 256) }
        for (wide, controls) in [(false, false), (true, false), (true, true)] {
            var reader = ZmodemReader()
            reader.expectsData = true
            let encoded = Zmodem.subpacket(data, end: .e, crc32: wide, escapesControls: controls)
            XCTAssertFalse(encoded.contains(0x11), "XON never appears unescaped")
            if controls { XCTAssertFalse(encoded.dropLast(6).contains { $0 < 0x20 && $0 != Zmodem.dle }) }
            // The 32-bit check needs the reader to know the header was wide.
            var header = Zmodem.binaryHeader(.data, Zmodem.position(0), crc32: wide, escapesControls: controls)
            reader.expectsData = false
            var items: [ZmodemReader.Item] = []
            for byte in header { if let item = reader.read(byte) { items.append(item); reader.expectsData = true } }
            for byte in encoded { if let item = reader.read(byte) { items.append(item) } }
            XCTAssertEqual(items, [.header(.data, [0, 0, 0, 0], crc32: wide), .subpacket(data, .e)], "wide \(wide), controls \(controls)")
            header = []
        }
    }

    /// Runs `sz` (an upload session) against `rz` (a download session) in memory. `damage` may change bytes the
    /// sender writes, as a noisy line would.
    private func transfer(_ files: [Source], damage: ((inout [UInt8], Int) -> Void)? = nil)
        -> (sinks: [String: Sink], up: Zmodem.Outcome?, down: Zmodem.Outcome?, rest: [UInt8]) {
        let up = ZmodemSession(start: .upload), down = ZmodemSession(start: .download)
        var toUp: [[UInt8]] = [], toDown: [[UInt8]] = []
        var sinks: [String: Sink] = [:]
        var upOutcome: Zmodem.Outcome?, downOutcome: Zmodem.Outcome?, rest: [UInt8] = []
        var writes = 0
        up.output = { bytes in
            var bytes = bytes
            writes += 1
            damage?(&bytes, writes)
            toDown.append(bytes)
        }
        down.output = { toUp.append($0) }
        down.accept = { name, size in
            let sink = Sink()
            sinks[name] = sink
            XCTAssertEqual(size, files.first { $0.name == name }?.size)
            return sink
        }
        up.ended = { outcome, _ in upOutcome = outcome }
        down.ended = { outcome, leftover in downOutcome = outcome; rest = leftover }
        up.send(files)
        XCTAssertTrue(toDown.isEmpty, "Nothing is sent before rz says it is ready")
        // sz starts by asking for ZRINIT; here rz starts with it instead.
        down.receive(Zmodem.hexHeader(.rqinit))
        var rounds = 0
        while (!toUp.isEmpty || !toDown.isEmpty) && rounds < 10_000 {
            rounds += 1
            if !toUp.isEmpty { up.receive(toUp.removeFirst()) }
            if !toDown.isEmpty {
                var bytes = toDown.removeFirst()
                if down.isOver { continue }
                if up.isOver { bytes += Array("$ prompt".utf8) }
                down.receive(bytes)
            }
        }
        return (sinks, upOutcome, downOutcome, rest)
    }

    func testFilesCrossIntactAndTheRestGoesBackToTheTerminal() {
        var random = SystemRandomNumberGenerator()
        let big = Data((0..<300_000).map { _ in UInt8.random(in: 0...255, using: &random) })
        let files = [Source("big.bin", big), Source("empty.txt", Data()), Source("notes.txt", Data("hello\r\nworld".utf8))]
        let result = transfer(files)
        XCTAssertEqual(result.up, .finished)
        XCTAssertEqual(result.down, .finished)
        XCTAssertEqual(result.rest, [], "The line end after ZFIN is not shown")
        XCTAssertEqual(ZmodemSession.afterFinish(ArraySlice(Array("\r\nOO$ ls".utf8))), Array("$ ls".utf8))
        XCTAssertEqual(ZmodemSession.afterFinish(ArraySlice(Array("OOO".utf8))), Array("O".utf8))
        for file in files {
            XCTAssertEqual(result.sinks[file.name]?.data, file.contents, file.name)
            XCTAssertEqual(result.sinks[file.name]?.closed, true)
        }
    }

    func testADamagedPacketIsSentAgain() {
        let contents = Data((0..<50_000).map { UInt8($0 % 251) })
        var damaged = false
        let result = transfer([Source("file", contents)]) { bytes, _ in
            // Corrupt one byte in the middle of the first data batch.
            guard !damaged, bytes.count > 20_000 else { return }
            damaged = true
            bytes[10_000] ^= 0x01
        }
        XCTAssertTrue(damaged)
        XCTAssertEqual(result.down, .finished)
        XCTAssertEqual(result.sinks["file"]?.data, contents)
    }

    func testOnlyTextAfterTheLastTransferByteIsShownAfterAnAbort() {
        let data = Zmodem.subpacket(Array(0..<255), end: .g, crc32: true, escapesControls: false)
        XCTAssertEqual(ZmodemSession.textAfterAbort(data), [], "Still transfer data")
        XCTAssertEqual(ZmodemSession.textAfterAbort(data + Array(repeating: 0x18, count: 10) + Array(repeating: 0x08, count: 10) + Array("\r\nuser@host:~$ ".utf8)),
                       Array("user@host:~$ ".utf8))
        XCTAssertEqual(ZmodemSession.textAfterAbort(Array("\u{1B}[1mready\u{1B}[0m 中文".utf8)), Array("\u{1B}[1mready\u{1B}[0m 中文".utf8))
        XCTAssertEqual(ZmodemSession.textAfterAbort([0x41, 0x00, 0xFF, 0x42]), [], "Binary is not text")
        XCTAssertEqual(ZmodemSession.textAfterAbort(Array("\r\n$ ".utf8), before: Array("done".utf8)), Array("done\r\n$ ".utf8), "Text continues text")
        XCTAssertEqual(ZmodemSession.textAfterAbort(data, before: Array("done".utf8)), [], "More data starts over")
    }

    func testCancelsAndCommandsEndTheTransfer() {
        let down = ZmodemSession(start: .download)
        var sent: [UInt8] = [], outcome: Zmodem.Outcome?
        let sink = Sink()
        down.output = { sent += $0 }
        down.accept = { _, _ in sink }
        down.ended = { result, _ in outcome = result }
        down.receive(Zmodem.hexHeader(.rqinit))
        down.receive(Zmodem.binaryHeader(.file, [0, 0, 0, 0], crc32: true, escapesControls: false)
                     + Zmodem.subpacket(Array("a.txt\u{0}5 0 0".utf8), end: .w, crc32: true, escapesControls: false))
        XCTAssertTrue(sent.suffix(21).starts(with: Array("**\u{18}B09".utf8)), "It asks for the file from the start")
        down.receive(Array(repeating: 0x18, count: 5))
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(sink.closed, false, "A file cut short is reported incomplete")

        let other = ZmodemSession(start: .download)
        var refused: Zmodem.Outcome?
        other.ended = { result, _ in refused = result }
        other.receive(Zmodem.hexHeader(.rqinit) + Zmodem.binaryHeader(.command, [0, 0, 0, 0], crc32: false, escapesControls: false)
                      + Zmodem.subpacket(Array("rm -rf ~\u{0}".utf8), end: .w, crc32: false, escapesControls: false))
        guard case .failed? = refused else { return XCTFail("A command from the server is refused") }

        let waiting = ZmodemSession(start: .upload)
        var abort: [UInt8] = []
        waiting.output = { abort += $0 }
        waiting.receive(Zmodem.hexHeader(.rinit, [0, 0, 0, 0x23]))
        XCTAssertTrue(waiting.awaitingFiles)
        XCTAssertFalse(waiting.abortedHere)
        waiting.cancel()
        XCTAssertTrue(waiting.abortedHere)
        XCTAssertEqual(abort, Zmodem.abortSequence)
        XCTAssertFalse(waiting.awaitingFiles)
    }
}
