import Foundation

/// ZMODEM file transfer as lrzsz's `sz` and `rz` speak it, over a terminal's byte stream. The session only turns
/// bytes into frames and back; the app supplies files, writes received ones, and shows progress.
public enum Zmodem {
    public enum Start: Equatable, Sendable {
        /// `sz` on the server offers files to this Mac.
        case download
        /// `rz` on the server waits for files from this Mac.
        case upload
    }

    static let pad: UInt8 = 0x2A, dle: UInt8 = 0x18
    enum Frame: UInt8 {
        case rqinit = 0, rinit, sinit, ack, file, skip, nak, abort, fin, rpos, data, eof, ferr, crc, challenge, compl, can, freecnt, command, stderr
    }
    enum End: UInt8 { case e = 0x68, g = 0x69, q = 0x6A, w = 0x6B }
    /// ZRINIT capabilities: full duplex, overlapped I/O, 32-bit CRC.
    static let receiverFlags: UInt8 = 0x01 | 0x02 | 0x20
    static let canCRC32: UInt8 = 0x20, escapesControls: UInt8 = 0x40
    /// Eight cancels and eight backspaces abort the other side, as lrzsz sends them.
    public static let abortSequence: [UInt8] = Array(repeating: 0x18, count: 8) + Array(repeating: 0x08, count: 8)

    /// Where a transfer begins in output: `**` ZDLE `B00` when `sz` offers files, `B01` when `rz` is waiting.
    public static func detect(_ bytes: [UInt8]) -> (index: Int, start: Start)? {
        guard bytes.count >= 6 else { return nil }
        var index = 0
        while index + 5 < bytes.count {
            if bytes[index] == pad, bytes[index + 1] == pad, bytes[index + 2] == dle, bytes[index + 3] == 0x42, bytes[index + 4] == 0x30 {
                if bytes[index + 5] == 0x30 { return (index, .download) }
                if bytes[index + 5] == 0x31 { return (index, .upload) }
            }
            index += 1
        }
        return nil
    }

    // MARK: Checksums

    private static let crc16Table: [UInt16] = (0..<256).map { value in
        var crc = UInt16(value) << 8
        for _ in 0..<8 { crc = crc & 0x8000 != 0 ? crc << 1 ^ 0x1021 : crc << 1 }
        return crc
    }
    private static let crc32Table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 != 0 ? crc >> 1 ^ 0xEDB8_8320 : crc >> 1 }
        return crc
    }
    static func crc16<S: Sequence>(_ bytes: S, _ start: UInt16 = 0) -> UInt16 where S.Element == UInt8 {
        bytes.reduce(start) { crc, byte in crc << 8 ^ crc16Table[Int(UInt8(crc >> 8) ^ byte)] }
    }
    static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        ~bytes.reduce(UInt32.max) { crc, byte in crc >> 8 ^ crc32Table[Int(UInt8(crc & 0xFF) ^ byte)] }
    }

    // MARK: Encoding

    /// A header in hex, which every receiver reads: what `rz` sends, and how `sz` starts and ends.
    static func hexHeader(_ type: Frame, _ data: [UInt8] = [0, 0, 0, 0]) -> [UInt8] {
        let body = [type.rawValue] + data
        let crc = crc16(body)
        let hex = (body + [UInt8(crc >> 8), UInt8(crc & 0xFF)]).flatMap { Array(String(format: "%02x", $0).utf8) }
        var result: [UInt8] = [pad, pad, dle, 0x42] + hex + [0x0D, 0x8A]
        if type != .fin && type != .ack { result.append(0x11) }
        return result
    }

    /// A binary header, with a 32-bit CRC when the receiver accepts one.
    static func binaryHeader(_ type: Frame, _ data: [UInt8], crc32 wide: Bool, escapesControls: Bool) -> [UInt8] {
        let body = [type.rawValue] + data
        var result: [UInt8] = [pad, dle, wide ? 0x43 : 0x41]
        var check: [UInt8]
        if wide { let crc = crc32(body); check = [UInt8(crc & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 24)] }
        else { let crc = crc16(body); check = [UInt8(crc >> 8), UInt8(crc & 0xFF)] }
        escape(body + check, into: &result, controls: escapesControls)
        return result
    }

    static func subpacket<C: Collection>(_ data: C, end: End, crc32 wide: Bool, escapesControls: Bool) -> [UInt8] where C.Element == UInt8 {
        var result: [UInt8] = []
        result.reserveCapacity(data.count + data.count / 16 + 12)
        escape(data, into: &result, controls: escapesControls)
        result += [dle, end.rawValue]
        var check: [UInt8]
        if wide {
            var crc = UInt32.max
            for byte in data { crc = crc >> 8 ^ crc32Table[Int(UInt8(crc & 0xFF) ^ byte)] }
            crc = ~(crc >> 8 ^ crc32Table[Int(UInt8(crc & 0xFF) ^ end.rawValue)])
            check = [UInt8(crc & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 24)]
        } else {
            let crc = crc16([end.rawValue], crc16(data))
            check = [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        }
        escape(check, into: &result, controls: escapesControls)
        return result
    }

    private static func escape<S: Sequence>(_ bytes: S, into result: inout [UInt8], controls: Bool) where S.Element == UInt8 {
        var previous: UInt8 = 0
        for byte in bytes {
            let needs: Bool
            switch byte {
            case dle, 0x10, 0x11, 0x13, 0x90, 0x91, 0x93: needs = true
            case 0x0D, 0x8D: needs = controls || previous & 0x7F == 0x40
            default: needs = controls && byte & 0x60 == 0
            }
            if needs { result.append(dle); result.append(byte ^ 0x40) } else { result.append(byte) }
            previous = byte
        }
    }

    static func position(_ value: Int) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: value)
        return [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]
    }
    static func position(of data: [UInt8]) -> Int {
        Int(data[0]) | Int(data[1]) << 8 | Int(data[2]) << 16 | Int(data[3]) << 24
    }
}

/// Reads frames from the byte stream: headers in hex or binary, and the data subpackets that follow some of them.
struct ZmodemReader {
    enum Item: Equatable {
        case header(Zmodem.Frame, [UInt8], crc32: Bool)
        case subpacket([UInt8], Zmodem.End)
        /// A header or subpacket whose CRC did not match.
        case damaged
        /// Five cancels in a row: the other side gave up.
        case cancelled
    }
    private enum State { case scanning, padded, hex, binary, data, check }
    private var state = State.scanning
    private var escaped = false
    private var buffer: [UInt8] = []
    private var wide = false
    private var cancels = 0
    private var pendingEnd: Zmodem.End?
    private var payload: [UInt8] = []
    /// Set after a header that carries subpackets, until one ends the frame.
    var expectsData = false
    /// Data subpackets longer than this are damaged.
    static let maximumSubpacket = 64 * 1024

    /// One byte of output; a header, subpacket, or cancel when this byte completes one.
    mutating func read(_ byte: UInt8) -> Item? {
        if byte == Zmodem.dle {
            cancels += 1
            if cancels >= 5 { cancels = 0; state = .scanning; expectsData = false; return .cancelled }
        } else {
            cancels = 0
        }
        return take(byte)
    }

    private mutating func take(_ byte: UInt8) -> Item? {
        switch state {
        case .scanning:
            if expectsData { state = .data; buffer = []; escaped = false; return take(byte) }
            if byte == Zmodem.pad { state = .padded }
        case .padded:
            if byte == Zmodem.pad { return nil }
            if byte == Zmodem.dle { escaped = true; return nil }
            if escaped, byte == 0x42 { state = .hex; buffer = []; escaped = false; return nil }
            if escaped, byte == 0x41 || byte == 0x43 { state = .binary; wide = byte == 0x43; buffer = []; escaped = false; return nil }
            escaped = false; state = .scanning
        case .hex:
            guard let digit = Self.hexDigit(byte) else { state = .scanning; return .damaged }
            buffer.append(digit)
            guard buffer.count == 14 else { return nil }
            state = .scanning
            let bytes = stride(from: 0, to: 14, by: 2).map { buffer[$0] << 4 | buffer[$0 + 1] }
            let crc = UInt16(bytes[5]) << 8 | UInt16(bytes[6])
            guard Zmodem.crc16(bytes[0..<5]) == crc, let type = Zmodem.Frame(rawValue: bytes[0]) else { return .damaged }
            return header(type, Array(bytes[1..<5]), crc32: false)
        case .binary:
            guard let value = unescape(byte) else { return nil }
            guard case .byte(let b) = value else { state = .scanning; return .damaged }
            buffer.append(b)
            guard buffer.count == (wide ? 9 : 7) else { return nil }
            state = .scanning
            let body = Array(buffer[0..<5])
            let valid: Bool
            if wide {
                let crc = UInt32(buffer[5]) | UInt32(buffer[6]) << 8 | UInt32(buffer[7]) << 16 | UInt32(buffer[8]) << 24
                valid = Zmodem.crc32(body) == crc
            } else {
                valid = Zmodem.crc16(body) == UInt16(buffer[5]) << 8 | UInt16(buffer[6])
            }
            guard valid, let type = Zmodem.Frame(rawValue: body[0]) else { return .damaged }
            return header(type, Array(body[1..<5]), crc32: wide)
        case .data:
            guard let value = unescape(byte) else { return nil }
            switch value {
            case .byte(let b):
                guard buffer.count < Self.maximumSubpacket else { state = .scanning; expectsData = false; return .damaged }
                buffer.append(b)
            case .end(let end):
                pendingEnd = end; payload = buffer; buffer = []; state = .check
            }
        case .check:
            guard let value = unescape(byte) else { return nil }
            guard case .byte(let b) = value, let end = pendingEnd else { state = .scanning; expectsData = false; return .damaged }
            buffer.append(b)
            guard buffer.count == (wide ? 4 : 2) else { return nil }
            let valid: Bool
            if wide {
                let crc = UInt32(buffer[0]) | UInt32(buffer[1]) << 8 | UInt32(buffer[2]) << 16 | UInt32(buffer[3]) << 24
                valid = Zmodem.crc32(payload + [end.rawValue]) == crc
            } else {
                valid = Zmodem.crc16([end.rawValue], Zmodem.crc16(payload)) == UInt16(buffer[0]) << 8 | UInt16(buffer[1])
            }
            buffer = []
            state = end == .g || end == .q ? .data : .scanning
            if state == .scanning { expectsData = false }
            guard valid else { state = .scanning; expectsData = false; return .damaged }
            return .subpacket(payload, end)
        }
        return nil
    }

    private func header(_ type: Zmodem.Frame, _ data: [UInt8], crc32: Bool) -> Item {
        .header(type, data, crc32: crc32)
    }

    private enum Value { case byte(UInt8), end(Zmodem.End) }

    /// One byte after ZDLE decoding, nil while an escape is pending. Flow control characters are dropped.
    private mutating func unescape(_ byte: UInt8) -> Value? {
        if escaped {
            escaped = false
            if let end = Zmodem.End(rawValue: byte) { return .end(end) }
            if byte == 0x6C { return .byte(0x7F) }
            if byte == 0x6D { return .byte(0xFF) }
            if byte & 0x60 == 0x40 { return .byte(byte ^ 0x40) }
            return nil
        }
        if byte == Zmodem.dle { escaped = true; return nil }
        if byte & 0x7F == 0x11 || byte & 0x7F == 0x13 { return nil }
        return .byte(byte)
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x61...0x66: byte - 0x61 + 10
        case 0x41...0x46: byte - 0x41 + 10
        default: nil
        }
    }
}

/// A file offered by `sz`, and where its bytes go.
public protocol ZmodemSink: AnyObject {
    func write(_ data: Data) throws
    /// Called once: `complete` is false when the transfer stopped part way.
    func close(complete: Bool)
}

/// A file to send to `rz`.
public protocol ZmodemSource: AnyObject {
    var name: String { get }
    var size: Int { get }
    var modified: Date { get }
    func read(at offset: Int, count: Int) throws -> Data
}

/// One ZMODEM exchange, from its first header to ZFIN or a cancel.
public final class ZmodemSession {
    public enum Outcome: Equatable, Sendable { case finished, cancelled, failed(String) }
    public struct Progress: Equatable, Sendable {
        public var name: String
        public var done: Int
        public var total: Int?
        public var files: Int
    }

    public let start: Zmodem.Start
    /// Bytes for the other side.
    public var output: ([UInt8]) -> Void = { _ in }
    /// Asked for each offered file: where to write it, or nil to skip it.
    public var accept: (_ name: String, _ size: Int?) -> ZmodemSink? = { _, _ in nil }
    public var progressed: (Progress) -> Void = { _ in }
    /// Called once, with output that came after the transfer and belongs to the terminal.
    public var ended: (Outcome, [UInt8]) -> Void = { _, _ in }
    public private(set) var progress: Progress?
    public private(set) var isOver = false
    /// True once this side stopped the transfer, by `cancel` or after an error, rather than the server or the end.
    public private(set) var abortedHere = false
    /// An upload whose files are not chosen yet.
    public var awaitingFiles: Bool { start == .upload && sources == nil && !isOver }

    private var reader = ZmodemReader()
    // Receiving
    private var sink: ZmodemSink?
    private var offset = 0
    private var skippingData = false
    private var pendingFile = false
    private var pendingCommand = false
    private var pendingInit = false
    // Sending
    private var sources: [ZmodemSource]?
    private var current = -1
    private var wide = false, escapes = false
    private var sentFin = false
    private var receivedFiles = 0
    /// Subpackets sent before waiting for ZACK, and their size.
    static let chunk = 8192, batch = 16

    public init(start: Zmodem.Start) {
        self.start = start
    }

    /// Output from the server, starting with the bytes `Zmodem.detect` found.
    public func receive(_ bytes: [UInt8]) {
        guard !isOver else { return }
        for index in bytes.indices {
            guard let item = reader.read(bytes[index]) else { continue }
            handle(item)
            guard let outcome else { continue }
            ended(outcome, Self.afterFinish(bytes[(index + 1)...]))
            return
        }
    }

    /// Output after the last header, without the line end that closes a hex header and the "OO" that `sz` sends
    /// after ZFIN: those are not terminal output.
    public static func afterFinish(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var rest = bytes.drop { [0x0D, 0x0A, 0x8A, 0x8D, 0x11].contains($0) }
        var letters = 0
        while letters < 2, rest.first == 0x4F { rest = rest.dropFirst(); letters += 1 }
        return Array(rest)
    }

    /// The terminal text so far in output that arrived after this side stopped a download: what follows the last
    /// ZMODEM byte, without the line ends and backspaces `sz` sends as it quits. Empty while it is still transfer
    /// data, which `sz` had already sent when it was told to stop. Text alone continues the text `before` it.
    public static func textAfterAbort(_ bytes: [UInt8], before: [UInt8] = []) -> [UInt8] {
        let tail = abortTail(bytes)
        guard !bytes.contains(Zmodem.dle), !tail.isEmpty, !before.isEmpty else { return tail }
        return before + bytes
    }

    private static func abortTail(_ bytes: [UInt8]) -> [UInt8] {
        // A ZDLE always comes with the byte it escapes; data never holds one bare.
        let start = bytes.lastIndex(of: Zmodem.dle).map { $0 + 2 } ?? 0
        guard start < bytes.count else { return [] }
        let tail = Array(bytes[start...].drop { [0x0D, 0x0A, 0x8A, 0x8D, 0x11, 0x08].contains($0) })
        guard !tail.isEmpty, let text = String(bytes: tail, encoding: .utf8),
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value) || [0x07, 0x08, 0x09, 0x0A, 0x0D, 0x1B].contains($0.value) })
        else { return [] }
        return tail
    }

    /// Answers a waiting `rz` with these files; an empty list ends the transfer without sending any.
    public func send(_ files: [ZmodemSource]) {
        guard start == .upload, sources == nil, !isOver else { return }
        sources = files
        if let flags = lastReceiverFlags { nextFile(flags: flags) }
    }

    /// Stops the transfer and tells the other side.
    public func cancel() {
        guard !isOver else { return }
        output(Zmodem.abortSequence)
        abortedHere = true
        finish(.cancelled)
        ended(.cancelled, [])
    }

    private var lastReceiverFlags: UInt8?

    private func handle(_ item: ZmodemReader.Item) {
        switch item {
        case .cancelled:
            finish(.cancelled)
        case .damaged:
            if start == .download, sink != nil { skippingData = true; output(Zmodem.hexHeader(.rpos, Zmodem.position(offset))) }
        case .header(let type, let data, let crc32):
            if start == .download { receiverHeader(type, data, crc32: crc32) } else { senderHeader(type, data) }
        case .subpacket(let data, let end):
            receiverData(data, end)
        }
    }

    // MARK: Receiving (sz on the server)

    private func receiverHeader(_ type: Zmodem.Frame, _ data: [UInt8], crc32: Bool) {
        switch type {
        case .rqinit:
            output(Zmodem.hexHeader(.rinit, [0, 0, 0, Zmodem.receiverFlags]))
        case .sinit:
            pendingInit = true
            reader.expectsData = true
        case .file:
            pendingFile = true
            reader.expectsData = true
        case .data:
            let position = Zmodem.position(of: data)
            reader.expectsData = true
            skippingData = sink == nil || position != offset
            if sink != nil, position != offset { output(Zmodem.hexHeader(.rpos, Zmodem.position(offset))) }
        case .eof:
            guard let sink, Zmodem.position(of: data) == offset else { return }
            sink.close(complete: true)
            self.sink = nil
            receivedFiles += 1
            output(Zmodem.hexHeader(.rinit, [0, 0, 0, Zmodem.receiverFlags]))
        case .fin:
            output(Zmodem.hexHeader(.fin))
            finish(.finished)
        case .command:
            // A server must not run commands on this Mac.
            pendingCommand = true
            reader.expectsData = true
        case .abort, .ferr, .can:
            finish(.cancelled)
        default:
            break
        }
    }

    private func receiverData(_ data: [UInt8], _ end: Zmodem.End) {
        if pendingCommand {
            pendingCommand = false
            output(Zmodem.abortSequence)
            abortedHere = true
            finish(.failed("The server asked to run a command on this Mac, which Gloamux never allows."))
            return
        }
        if pendingFile {
            pendingFile = false
            let parts = data.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(decoding: parts.first ?? [], as: UTF8.self)
            let fields = parts.count > 1 ? String(decoding: parts[1], as: UTF8.self).split(separator: " ") : []
            let size = fields.first.flatMap { Int($0) }
            if let sink = accept(name, size) {
                self.sink = sink
                offset = 0
                progress = Progress(name: name, done: 0, total: size, files: receivedFiles)
                progress.map(progressed)
                output(Zmodem.hexHeader(.rpos, Zmodem.position(0)))
            } else {
                output(Zmodem.hexHeader(.skip))
            }
            return
        }
        if pendingInit {
            // ZSINIT's attention string needs only an acknowledgement.
            pendingInit = false
            output(Zmodem.hexHeader(.ack))
            return
        }
        guard !skippingData, let sink else { return }
        do { try sink.write(Data(data)) } catch {
            output(Zmodem.abortSequence)
            abortedHere = true
            finish(.failed(error.localizedDescription))
            return
        }
        offset += data.count
        if var current = progress { current.done = offset; progress = current; progressed(current) }
        if end == .q || end == .w { output(Zmodem.hexHeader(.ack, Zmodem.position(offset))) }
    }

    // MARK: Sending (rz on the server)

    private func senderHeader(_ type: Zmodem.Frame, _ data: [UInt8]) {
        switch type {
        case .rinit:
            lastReceiverFlags = data[3]
            guard sources != nil else { return }
            // rz repeats ZRINIT while it waits; only the one after a file, or the first, moves on.
            if current < 0 || sentFile { nextFile(flags: data[3]) }
        case .rpos:
            sentFile = false
            sendData(from: Zmodem.position(of: data))
        case .ack:
            if let position = ackPosition, Zmodem.position(of: data) == position { sendData(from: position) }
        case .skip:
            sentFile = true
            nextFile(flags: lastReceiverFlags ?? 0)
        case .fin:
            output(Array("OO".utf8))
            finish(.finished)
        case .abort, .ferr, .can:
            finish(.cancelled)
        default:
            break
        }
    }

    /// True once the current file has been sent to its end, or skipped.
    private var sentFile = false
    /// Where the next batch starts once the receiver acknowledges the last.
    private var ackPosition: Int?

    private func nextFile(flags: UInt8) {
        guard let sources else { return }
        wide = flags & Zmodem.canCRC32 != 0
        escapes = flags & Zmodem.escapesControls != 0
        current += 1
        sentFile = false
        ackPosition = nil
        guard current < sources.count else {
            if !sentFin { sentFin = true; output(Zmodem.hexHeader(.fin)) }
            return
        }
        let file = sources[current]
        let left = sources[current...].reduce(0) { $0 + $1.size }
        let info = "\(file.size) \(String(Int(file.modified.timeIntervalSince1970), radix: 8)) 100644 0 \(sources.count - current) \(left)"
        let name = Array((file.name as NSString).lastPathComponent.utf8)
        progress = Progress(name: file.name, done: 0, total: file.size, files: current)
        progress.map(progressed)
        output(Zmodem.binaryHeader(.file, [0, 0, 0, 1], crc32: wide, escapesControls: escapes)
               + Zmodem.subpacket(name + [0] + Array(info.utf8) + [0], end: .w, crc32: wide, escapesControls: escapes))
    }

    private func sendData(from start: Int) {
        guard let sources, current >= 0, current < sources.count else { return }
        let file = sources[current]
        var position = min(max(0, start), file.size)
        var packet = Zmodem.binaryHeader(.data, Zmodem.position(position), crc32: wide, escapesControls: escapes)
        for index in 0..<Self.batch {
            let data: Data
            do { data = try file.read(at: position, count: min(Self.chunk, file.size - position)) } catch {
                output(packet + Zmodem.abortSequence)
                abortedHere = true
                finish(.failed(error.localizedDescription))
                return
            }
            position += data.count
            let last = position >= file.size || data.isEmpty
            let end: Zmodem.End = last ? .e : index == Self.batch - 1 ? .w : .g
            packet += Zmodem.subpacket(data, end: end, crc32: wide, escapesControls: escapes)
            if last {
                packet += Zmodem.binaryHeader(.eof, Zmodem.position(file.size), crc32: wide, escapesControls: escapes)
                sentFile = true
                ackPosition = nil
                break
            }
            if end == .w { ackPosition = position }
        }
        if var current = progress { current.done = position; progress = current; progressed(current) }
        output(packet)
    }

    /// How it ended, once it has; `receive` then passes the rest of the output on.
    private var outcome: Outcome?

    private func finish(_ result: Outcome) {
        guard !isOver else { return }
        isOver = true
        outcome = result
        sink?.close(complete: false)
        sink = nil
    }
}

extension Zmodem {
    public typealias Outcome = ZmodemSession.Outcome
}
