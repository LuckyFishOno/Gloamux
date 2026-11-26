// The "terminal" feature. contractSha256 pins the declared interface below; the self-test reports
// contract-mismatch when it changes.
// Declared interface:
//   input:
//     Bytes from a session
//   output:
//     Screen state
//   state:
//     One screen per tab
//   errors:
//     Unknown sequences ignored and counted
import GloamuxShared
import Foundation
import Formats

// Terminal emulation following common xterm and VT conventions.

public enum TerminalType: String, CaseIterable, Sendable { case xterm, vt100, vt102, vt220, vt320, linux, ansi, scoansi }

public struct TerminalOptions: Equatable, Sendable {
    public var rows = 24
    public var cols = 80
    public var scrollbackSize = 1000
    /// CJKAmbiAsWide: treat East Asian ambiguous-width characters as two cells.
    public var cjkAmbiguousAsWide = false
    /// InitCursorMode: start in application cursor key mode (DECCKM).
    public var applicationCursorKeys = false
    /// BackspaceSends: true sends DEL (0x7F), false sends Ctrl+H (0x08).
    public var backspaceSendsDelete = true
    public var type: TerminalType = .xterm
    /// Shows pictures sent with sixel graphics, the iTerm2 inline image protocol, or the kitty graphics protocol.
    public var inlineImages = true
    public init() {}
}

public enum TerminalColor: Equatable, Hashable, Sendable {
    case `default`
    case indexed(UInt8)
    case rgb(RGB)
}

public struct CellStyle: Equatable, Hashable, Sendable {
    public var foreground: TerminalColor = .default
    public var background: TerminalColor = .default
    public var bold = false, faint = false, italic = false, underline = false, blink = false, inverse = false, invisible = false, strikethrough = false
    /// An OSC 8 hyperlink: an index into `TerminalScreen.links`, or 0 for none.
    public var link: UInt16 = 0
    public init() {}
}

public struct Cell: Equatable, Sendable {
    public var character: Character = " "
    public var style = CellStyle()
    /// 2 for the first cell of a wide character, 0 for its continuation cell, otherwise 1.
    public var width: UInt8 = 1
    /// Set on a row's last cell when text ran past it and continued on the next row, so a resize can rewrap
    /// the two rows as one line. Writing or erasing the cell clears it.
    public var wraps = false
    public static let blank = Cell()
}

public enum TerminalEvent: Equatable, Sendable {
    case bell, title(String), reply([UInt8]), commandFinished(CommandMark)
    /// Text a program asked to put on the clipboard with OSC 52. The app decides whether to allow it.
    case clipboard(String)
}

/// Which mouse events a program asked for (DECSET 1000, 1002, 1003).
public enum MouseTracking: Equatable, Sendable { case off, clicks, drags, motion }

/// The cursor shape a program asked for with DECSCUSR (`CSI Ps SP q`).
public enum CursorShape: String, CaseIterable, Equatable, Sendable { case block, underline, bar }

/// One prompt and the command run from it, as reported by shell integration (OSC 133). Lines are absolute: they keep
/// counting as scrollback is trimmed, so `TerminalScreen.row(absolute:)` finds them while they are still kept.
public struct CommandMark: Equatable, Sendable {
    /// Where the prompt starts (`OSC 133;A`).
    public var promptLine: Int
    /// Where typing starts, after the prompt (`OSC 133;B`).
    public var inputLine: Int?
    public var inputColumn: Int?
    /// The first line of output (`OSC 133;C`).
    public var outputLine: Int?
    /// The line after the last line of output (`OSC 133;D`, or the next prompt).
    public var endLine: Int?
    public var command: String?
    public var exitCode: Int?
    public var startedAt: Date?
    public var finishedAt: Date?
    public init(promptLine: Int) { self.promptLine = promptLine }
    public var duration: TimeInterval? { startedAt.flatMap { start in finishedAt.map { $0.timeIntervalSince(start) } } }
}

public final class TerminalScreen {
    public private(set) var options: TerminalOptions
    public private(set) var rows: Int, cols: Int
    private var primary: [[Cell]], alternate: [[Cell]]
    public private(set) var usingAlternate = false
    public private(set) var scrollback: [[Cell]] = []
    public private(set) var cursorRow = 0, cursorCol = 0
    public private(set) var cursorVisible = true
    public private(set) var applicationCursorKeys: Bool
    public private(set) var bracketedPaste = false
    /// Mouse reporting a program turned on, and whether it wants SGR (1006) coordinates.
    public private(set) var mouseTracking = MouseTracking.off
    public private(set) var sgrMouse = false
    /// Focus in and out reports (DECSET 1004).
    public private(set) var reportsFocus = false
    /// The cursor shape and blinking a program set with DECSCUSR, or nil for the user's setting.
    public private(set) var cursorShape: CursorShape?
    public private(set) var cursorBlinks: Bool?
    public private(set) var title = ""
    /// The shell's current directory as reported with OSC 7 (`file://host/path`), percent-decoded.
    public private(set) var workingDirectory: String?
    /// Escape or control sequences that were recognized as syntax but not implemented, by name.
    public private(set) var unsupported: [String: Int] = [:]
    public private(set) var events: [TerminalEvent] = []
    /// Lines dropped from the top of the scrollback so far. Adding it to a scrollback index gives an absolute line.
    public private(set) var trimmedLines = 0
    /// Prompts and commands reported with OSC 133, oldest first. At most `maximumCommandMarks` are kept.
    public private(set) var commandMarks: [CommandMark] = []
    public static let maximumCommandMarks = 1000
    /// OSC 8 link targets. Index 0 means no link.
    public private(set) var links: [String] = [""]
    private var linkIndex: [String: UInt16] = [:]
    /// Pictures shown with sixel or OSC 1337, oldest first.
    public private(set) var images: [TerminalImage] = []
    private var nextImageID = 1
    /// One cell's size in points, which the display sets, so a picture covers as many cells as its pixels need.
    public var cellSize: (width: Double, height: Double) = (8, 16)
    /// A file sent in parts with `MultipartFile=`, `FilePart=`, and `FileEnd`.
    private var multipart: (arguments: [String: String], data: Data)?
    /// Images sent with the kitty graphics protocol by id, and their ids oldest first.
    private var kittyImages: [UInt32: KittyStoredImage] = [:]
    private var kittyOrder: [UInt32] = []
    /// Ids given to images sent without one, counting down from the top so they do not meet a program's own.
    private var nextKittyID: UInt32 = .max
    /// A kitty transfer sent in chunks (`m=1`): the first chunk's keys and the base64 so far.
    private var kittyTransfer: (command: KittyCommand, data: [UInt8])?

    private var style = CellStyle()
    private var scrollTop = 0, scrollBottom: Int
    private var autowrap = true, wrapPending = false, originMode = false, insertMode = false
    private var saved: (row: Int, col: Int, style: CellStyle, origin: Bool) = (0, 0, CellStyle(), false)
    private var tabStops: Set<Int> = []
    private var lineDrawing = false

    // Parser state
    private enum State { case ground, escape, escapeIntermediate, csi, osc, oscEscape, string, stringEscape, dcs, dcsEscape, apc, apcEscape }
    private var state = State.ground
    private var params = "", intermediates = ""
    private var oscBytes: [UInt8] = [], dcsBytes: [UInt8] = [], apcBytes: [UInt8] = []
    /// A UTF-8 sequence being read: the bits so far, its full length, and how many bytes are still to come.
    private var utf8Value: UInt32 = 0, utf8Length = 0, utf8Need = 0

    public init(options: TerminalOptions = TerminalOptions()) {
        self.options = options
        rows = max(1, options.rows); cols = max(1, options.cols)
        primary = Array(repeating: Array(repeating: .blank, count: cols), count: rows)
        alternate = primary
        scrollBottom = rows - 1
        applicationCursorKeys = options.applicationCursorKeys
        resetTabs()
    }

    private var grid: [[Cell]] {
        get { usingAlternate ? alternate : primary }
        set { if usingAlternate { alternate = newValue } else { primary = newValue } }
    }

    /// Mutates the active grid in place. Copying it into a local first (`var g = grid`) made every
    /// written character copy its row, which dominated the cost of large output.
    /// The body must not read `grid`, `primary` or `alternate`.
    private func mutateGrid(_ body: (inout [[Cell]]) -> Void) {
        if usingAlternate { body(&alternate) } else { body(&primary) }
    }

    public func takeEvents() -> [TerminalEvent] { defer { events = [] }; return events }

    // MARK: Input

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buffer in
            var index = 0
            while index < buffer.count {
                let b = buffer[index]
                // Most output is runs of printable ASCII between control sequences: write each run in bulk.
                if b >= 0x20, b < 0x7F, state == .ground, utf8Need == 0, !lineDrawing, !insertMode {
                    var end = index + 1
                    while end < buffer.count, buffer[end] >= 0x20, buffer[end] < 0x7F { end += 1 }
                    putASCII(UnsafeBufferPointer(rebasing: buffer[index..<end]))
                    index = end
                } else if b >= 0xC2, b < 0xF5, state == .ground, utf8Need == 0, !lineDrawing, !insertMode, autowrap {
                    // Runs of other text, such as Chinese, Japanese, or Korean, are written a row at a time too.
                    let end = putText(buffer, from: index)
                    if end == index { byte(b); index += 1 } else { index = end }
                } else {
                    byte(b); index += 1
                }
            }
        }
    }

    /// Printable ASCII, one character per cell: the same result as `put` for each byte, a row at a time.
    private func putASCII(_ text: UnsafeBufferPointer<UInt8>) {
        var next = 0
        while next < text.count {
            if wrapPending || cursorCol + 1 > cols {
                if autowrap {
                    let row = cursorRow, last = cols - 1
                    mutateGrid { g in g[row][last].wraps = true }
                    cursorCol = 0; lineFeed()
                } else { cursorCol = max(0, cols - 1) }
                wrapPending = false
            }
            let row = cursorRow, start = cursorCol, width = cols, current = style, blank = blankCell()
            let count = min(text.count - next, width - start)
            let first = next
            mutateGrid { g in
                // Only the cells at the ends can be half of a wide character that is not overwritten.
                Self.clearWide(&g, row, start, cols: width, blank: blank)
                Self.clearWide(&g, row, start + count - 1, cols: width, blank: blank)
                for offset in 0..<count {
                    g[row][start + offset] = Cell(character: Self.ascii[Int(text[first + offset])], style: current, width: 1)
                }
            }
            next += count
            let column = start + count
            if column >= width { cursorCol = width - 1; wrapPending = autowrap } else { cursorCol = column }
        }
    }

    /// Decoded text from `start` on, written a row at a time: the same result as `put` for each character. It stops
    /// before a control byte, a combining mark, or a UTF-8 sequence that is invalid or cut off by the end of the
    /// buffer, and returns the index it stopped at, which is `start` when it wrote nothing.
    private func putText(_ buffer: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start
        let ambiguous = options.cjkAmbiguousAsWide
        while index < buffer.count {
            if wrapPending {
                let row = cursorRow, last = cols - 1
                mutateGrid { g in g[row][last].wraps = true }
                cursorCol = 0; lineFeed(); wrapPending = false
            }
            let row = cursorRow, first = cursorCol, width = cols
            var column = first, full = false
            while index < buffer.count {
                let b = buffer[index]
                var value: UInt32, length: Int
                switch b {
                case 0x20..<0x7F: value = UInt32(b); length = 1
                case 0xC2..<0xE0: value = UInt32(b & 0x1F); length = 2
                case 0xE0..<0xF0: value = UInt32(b & 0x0F); length = 3
                case 0xF0..<0xF5: value = UInt32(b & 0x07); length = 4
                default: length = 0; value = 0
                }
                guard length > 0, index + length <= buffer.count else { break }
                var valid = true
                for offset in 1..<max(length, 1) where valid {
                    let next = buffer[index + offset]
                    if next & 0xC0 == 0x80 { value = value << 6 | UInt32(next & 0x3F) } else { valid = false }
                }
                guard valid, length == 1 || Self.scalar(value, length: length) == value else { break }
                let w = length == 1 ? 1 : Self.width(scalar: value, ambiguousWide: ambiguous)
                // A combining mark joins the previous cell, and a terminal one column wide cannot hold a wide
                // character: both go through `put`.
                guard w > 0, w <= width else { break }
                guard column + w <= width else { full = true; break }
                textRun.append((length == 1 ? Self.ascii[Int(value)] : Character(Unicode.Scalar(value)!), UInt8(w)))
                column += w; index += length
            }
            if textRun.isEmpty {
                // A wide character that does not fit in the last column goes to the next line, as `put` does.
                guard full else { return index }
                let last = cols - 1
                mutateGrid { g in g[row][last].wraps = true }
                cursorCol = 0; lineFeed()
                continue
            }
            let current = style, blank = blankCell(), end = column
            mutateGrid { g in
                Self.clearWide(&g, row, first, cols: width, blank: blank)
                Self.clearWide(&g, row, end - 1, cols: width, blank: blank)
                var at = first
                for (character, w) in textRun {
                    g[row][at] = Cell(character: character, style: current, width: w)
                    if w == 2 { g[row][at + 1] = Cell(character: " ", style: current, width: 0) }
                    at += Int(w)
                }
            }
            textRun.removeAll(keepingCapacity: true)
            if column >= width { cursorCol = width - 1; wrapPending = true } else { cursorCol = column }
            if !full, index < buffer.count { return index }
        }
        return index
    }

    /// Characters decoded by `putText`, kept between calls so its buffer is reused.
    private var textRun: [(Character, UInt8)] = []

    /// Characters for the ASCII bytes, made once.
    private static let ascii: [Character] = (0..<128).map { Character(Unicode.Scalar(UInt8($0))) }
    public func feed(_ text: String) { feed(Array(text.utf8)) }

    private func byte(_ b: UInt8) {
        // Strings (OSC/DCS/APC/PM) and escape states consume raw bytes.
        switch state {
        case .osc:
            if b == 0x07 { finishOSC(); return }
            if b == 0x1B { state = .oscEscape; return }
            if oscBytes.count < Self.maximumOSCLength
                || (oscBytes.count < Self.maximumImageOSCLength && oscBytes.starts(with: Self.imageOSCPrefix)) { oscBytes.append(b) }
            return
        case .oscEscape:
            if b == 0x5C { finishOSC() } else { state = .ground; byte(0x1B); byte(b) }
            return
        case .string:
            if b == 0x07 { state = .ground } else if b == 0x1B { state = .stringEscape }
            return
        case .stringEscape:
            state = b == 0x5C ? .ground : .string; return
        case .dcs:
            if b == 0x1B { state = .dcsEscape } else if b == 0x18 || b == 0x1A { state = .ground; dcsBytes = [] }
            else if dcsBytes.count < Self.maximumDCSLength { dcsBytes.append(b) }
            return
        case .dcsEscape:
            if b == 0x5C { finishDCS() } else { state = .ground; dcsBytes = []; byte(0x1B); byte(b) }
            return
        case .apc:
            if b == 0x07 { finishAPC(); return }
            if b == 0x1B { state = .apcEscape; return }
            if b == 0x18 || b == 0x1A { state = .ground; apcBytes = []; return }
            // Only kitty graphics (`G`) are read; other APC strings are skipped without being kept.
            if apcBytes.isEmpty || (apcBytes[0] == 0x47 && apcBytes.count < KittyGraphics.maximumCommandLength) { apcBytes.append(b) }
            return
        case .apcEscape:
            if b == 0x5C { finishAPC() } else { state = .ground; apcBytes = []; byte(0x1B); byte(b) }
            return
        default: break
        }
        if b < 0x20 || b == 0x7F { control(b); return }
        switch state {
        case .escape: escape(b)
        case .escapeIntermediate: escapeFinal(b)
        case .csi: csiByte(b)
        default: text(b)
        }
    }

    private func control(_ b: UInt8) {
        switch b {
        case 0x1B: state = .escape; params = ""; intermediates = ""
        case 0x07: events.append(.bell)
        case 0x08: if cursorCol > 0 { cursorCol -= 1 }; wrapPending = false
        case 0x09: tab()
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x0D: cursorCol = 0; wrapPending = false
        case 0x0E, 0x0F: lineDrawing = b == 0x0E && false // SO/SI: G1 not tracked
        case 0x18, 0x1A: state = .ground
        case 0x00, 0x7F: break
        default: count("C0 0x" + String(b, radix: 16))
        }
    }

    private func text(_ b: UInt8) {
        if utf8Need == 0 {
            if b < 0x80 { put(Character(Unicode.Scalar(b))); return }
            if b & 0xE0 == 0xC0 { utf8Value = UInt32(b & 0x1F); utf8Length = 2; utf8Need = 1 }
            else if b & 0xF0 == 0xE0 { utf8Value = UInt32(b & 0x0F); utf8Length = 3; utf8Need = 2 }
            else if b & 0xF8 == 0xF0 { utf8Value = UInt32(b & 0x07); utf8Length = 4; utf8Need = 3 }
            else { put("\u{FFFD}") }
            return
        }
        guard b & 0xC0 == 0x80 else { utf8Need = 0; put("\u{FFFD}"); text(b); return }
        utf8Value = utf8Value << 6 | UInt32(b & 0x3F); utf8Need -= 1
        if utf8Need == 0 {
            let value = Self.scalar(utf8Value, length: utf8Length)
            // Nothing outside ASCII is redrawn by the line-drawing set, so the width is known from the value.
            putCell(Character(Unicode.Scalar(value)!), width: Self.width(scalar: value, ambiguousWide: options.cjkAmbiguousAsWide))
        }
    }

    /// A decoded UTF-8 value, or U+FFFD when it was overlong, a surrogate, or out of range.
    private static func scalar(_ value: UInt32, length: Int) -> UInt32 {
        let smallest: UInt32 = length == 2 ? 0x80 : length == 3 ? 0x800 : 0x10000
        guard value >= smallest, value <= 0x10FFFF, !(0xD800...0xDFFF).contains(value) else { return 0xFFFD }
        return value
    }

    private func escape(_ b: UInt8) {
        state = .ground
        switch b {
        case 0x5B: state = .csi; params = ""; intermediates = ""
        case 0x5D: state = .osc; oscBytes = []
        case 0x50: state = .dcs; dcsBytes = []
        case 0x5F: state = .apc; apcBytes = []
        case 0x5E, 0x58: state = .string
        case 0x20...0x2F: intermediates = String(UnicodeScalar(b)); state = .escapeIntermediate
        case 0x37: saveCursor()
        case 0x38: restoreCursor()
        case 0x44: lineFeed()
        case 0x45: cursorCol = 0; lineFeed()
        case 0x48: tabStops.insert(cursorCol)
        case 0x4D: reverseIndex()
        case 0x63: reset()
        case 0x3D, 0x3E: break // keypad modes: not tracked
        default: count("ESC " + String(UnicodeScalar(b)))
        }
    }

    private func escapeFinal(_ b: UInt8) {
        if b >= 0x20 && b <= 0x2F { intermediates.unicodeScalars.append(UnicodeScalar(b)); return }
        state = .ground
        if intermediates == "(" { lineDrawing = b == 0x30; return }
        if intermediates == "#" && b == 0x38 { // DECALN
            grid = Array(repeating: Array(repeating: Cell(character: "E"), count: cols), count: rows); return
        }
        if intermediates == ")" || intermediates == "*" || intermediates == "+" { return }
        count("ESC " + intermediates + String(UnicodeScalar(b)))
    }

    private func csiByte(_ b: UInt8) {
        switch b {
        case 0x30...0x3F: params.unicodeScalars.append(UnicodeScalar(b))
        case 0x20...0x2F: intermediates.unicodeScalars.append(UnicodeScalar(b))
        case 0x40...0x7E: state = .ground; csi(Character(UnicodeScalar(b)))
        default: state = .ground
        }
    }

    private func finishOSC() {
        state = .ground
        let bytes = oscBytes
        oscBytes = []
        let separator = bytes.firstIndex(of: 0x3B)
        let code = String(decoding: bytes[..<(separator ?? bytes.endIndex)], as: UTF8.self)
        if code == "1337" {
            if let separator { iTermImage(bytes[(separator + 1)...]) }
            return
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let value = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        if code == "0" || code == "2", value.count == 2 { title = String(value[1]); events.append(.title(title)) }
        else if code == "7", value.count == 2, let path = Self.directory(fromOSC7: String(value[1])) { workingDirectory = path }
        else if code == "133" { commandMark(value.count == 2 ? String(value[1]) : "") }
        else if code == "8" { hyperlink(value.count == 2 ? String(value[1]) : "") }
        else if code == "52" { clipboard(value.count == 2 ? String(value[1]) : "") }
        else { count("OSC " + code) }
    }

    /// A DCS string. Only sixel graphics (`DCS P1;P2;P3 q DATA ST`) are shown.
    private func finishDCS() {
        state = .ground
        let bytes = dcsBytes
        dcsBytes = []
        guard let final = bytes.firstIndex(where: { (0x40...0x7E).contains($0) }) else { count("DCS"); return }
        guard bytes[final] == 0x71, bytes[..<final].allSatisfy({ (0x30...0x3F).contains($0) }) else {
            count("DCS " + String(UnicodeScalar(bytes[final]))); return
        }
        guard options.inlineImages, let image = SixelDecoder.decode(bytes[(final + 1)...]) else { return }
        let cell = cellSize
        let columns = max(1, Int((Double(image.width) / cell.width).rounded(.up)))
        let rows = max(1, Int((Double(image.height) / cell.height).rounded(.up)))
        place(.rgba(image.pixels, width: image.width, height: image.height), bytes: image.pixels.count, columns: min(columns, cols), rows: rows,
              stretches: false, cursorBelow: true)
    }

    /// OSC 1337 `File=ARGS:BASE64`, or the same file in parts. Only files marked `inline=1` are shown; others would be
    /// downloads, which are not taken from a terminal.
    private func iTermImage(_ body: ArraySlice<UInt8>) {
        let colon = body.firstIndex(of: 0x3A) ?? body.endIndex
        let head = String(decoding: body[..<colon], as: UTF8.self)
        let payload = colon < body.endIndex ? body[(colon + 1)...] : []
        func decoded(_ bytes: ArraySlice<UInt8>) -> Data? { Data(base64Encoded: Data(bytes), options: .ignoreUnknownCharacters) }
        if head.hasPrefix("File=") {
            multipart = nil
            show(InlineImages.arguments(head.dropFirst(5)), decoded(payload))
        } else if head.hasPrefix("MultipartFile=") {
            multipart = (InlineImages.arguments(head.dropFirst(14)), Data())
        } else if head.hasPrefix("FilePart="), var part = multipart {
            let chunk = Data(base64Encoded: String(head.dropFirst(9)), options: .ignoreUnknownCharacters) ?? Data()
            guard part.data.count + chunk.count <= InlineImages.maximumFileBytes else { multipart = nil; return }
            part.data.append(chunk)
            multipart = part
        } else if head == "FileEnd", let part = multipart {
            multipart = nil
            show(part.arguments, part.data)
        } else {
            count("OSC 1337 " + (head.split(separator: "=").first.map(String.init) ?? ""))
        }
    }

    private func show(_ arguments: [String: String], _ data: Data?) {
        guard options.inlineImages, arguments["inline"] == "1", let data, data.count <= InlineImages.maximumFileBytes,
              let pixels = InlineImages.pixelSize(of: data),
              pixels.width <= InlineImages.maximumSixelSide, pixels.height <= InlineImages.maximumSixelSide else { return }
        let preserves = arguments["preserveaspectratio"] != "0"
        let size = InlineImages.cells(pixels: pixels, width: arguments["width"], height: arguments["height"], preserves: preserves,
                                      cell: cellSize, columns: cols)
        place(.encoded(data), bytes: pixels.width * pixels.height * 4, columns: min(size.columns, cols), rows: size.rows, stretches: !preserves,
              cursorBelow: arguments["donotmovecursor"] == "1" ? nil : false)
    }

    // MARK: Connections

    /// Puts the terminal back the way a new program expects it after the one that used it is gone, as when a
    /// connection ends: it leaves the alternate screen, drops a half-read escape sequence, resets the scroll region,
    /// colors, and modes, and moves to the start of a new line. The text, scrollback, and pictures stay. Unlike
    /// `ESC [?1049l` on its own, it does not move the cursor back to a saved position when the alternate screen was
    /// not in use.
    public func endProgram() {
        if usingAlternate { switchScreen(false, clear: false); restoreCursor() }
        state = .ground; params = ""; intermediates = ""; oscBytes = []; dcsBytes = []; apcBytes = []; utf8Need = 0
        multipart = nil; kittyTransfer = nil
        style = CellStyle(); scrollTop = 0; scrollBottom = rows - 1
        originMode = false; insertMode = false; autowrap = true; lineDrawing = false
        bracketedPaste = false; mouseTracking = .off; sgrMouse = false; reportsFocus = false
        cursorVisible = true; cursorShape = nil; cursorBlinks = nil; applicationCursorKeys = options.applicationCursorKeys
        if cursorCol > 0 || wrapPending { cursorCol = 0; wrapPending = false; lineFeed() }
    }

    /// Moves the lines in use on the screen into the scrollback and starts again at the top, as `clear` does in most
    /// terminals, so nothing is lost. On the alternate screen it only clears.
    public func clearKeepingScrollback() {
        endProgram()
        let screen = grid
        let used = (0..<rows).last { row in screen[row].contains { $0.character != " " } } ?? -1
        let count = max(used + 1, cursorRow)
        scrollTop = 0; scrollBottom = rows - 1
        if count > 0 { scrollUp(count) }
        cursorRow = 0; cursorCol = 0; wrapPending = false
    }

    // MARK: Kitty graphics

    /// An APC string. Only kitty graphics commands (`ESC _ G ... ESC \`) are read.
    private func finishAPC() {
        state = .ground
        let bytes = apcBytes
        apcBytes = []
        guard bytes.first == 0x47 else { return }
        // With inline images off, programs get no reply, so they see a terminal without kitty graphics.
        guard options.inlineImages else { kittyTransfer = nil; return }
        guard bytes.count < KittyGraphics.maximumCommandLength else {
            kittyTransfer = nil
            kittyReply(KittyCommand(bytes.dropFirst().prefix(256)), KittyError.tooLarge.reply)
            return
        }
        let command = KittyCommand(bytes.dropFirst())
        if var transfer = kittyTransfer {
            // Later chunks carry only `m` (and perhaps `q`); the first chunk's keys apply to the whole transfer.
            guard transfer.data.count + command.payload.count < KittyGraphics.maximumCommandLength else {
                kittyTransfer = nil
                kittyReply(transfer.command, KittyError.tooLarge.reply)
                return
            }
            transfer.data.append(contentsOf: command.payload)
            if command.more { kittyTransfer = transfer; return }
            kittyTransfer = nil
            var whole = transfer.command
            whole.payload = transfer.data[...]
            kittyRun(whole)
        } else if command.more, "tTq".contains(command.action) {
            kittyTransfer = (command, Array(command.payload))
        } else {
            kittyRun(command)
        }
    }

    private func kittyRun(_ command: KittyCommand) {
        do {
            switch command.action {
            case "t", "T", "q": try kittyTransmit(command)
            case "p":
                guard let id = kittyID(command), let image = kittyImages[id] else { throw KittyError.notFound }
                try kittyDisplay(id, image, command)
                kittyReply(command, "OK", id: id)
            case "d": kittyDelete(command)
            default: throw KittyError.action
            }
        } catch let error as KittyError {
            kittyReply(command, error.reply)
        } catch {
            kittyReply(command, KittyError.invalid.reply)
        }
    }

    /// The image a command names with `i=`, or with `I=` for the newest image sent with that number.
    private func kittyID(_ command: KittyCommand) -> UInt32? {
        if let id = command.number("i"), id > 0, id <= Int(UInt32.max) { return UInt32(id) }
        if let number = command.number("I"), number > 0 { return kittyOrder.last { kittyImages[$0]?.number == number } }
        return nil
    }

    private func kittyTransmit(_ command: KittyCommand) throws {
        guard command.letter("t") ?? "d" == "d" else { throw KittyError.medium }
        guard let data = Data(base64Encoded: Data(command.payload), options: .ignoreUnknownCharacters) else { throw KittyError.invalid }
        guard data.count <= InlineImages.maximumFileBytes else { throw KittyError.tooLarge }
        let decoded = try KittyGraphics.decode(format: command.number("f") ?? 32, width: command.number("s"), height: command.number("v"),
                                               compressed: command.letter("o") == "z", data: data)
        let image = KittyStoredImage(content: decoded.content, width: decoded.width, height: decoded.height,
                                     number: command.number("I").flatMap { $0 > 0 ? $0 : nil })
        // A query checks the data and answers without keeping anything.
        if command.action == "q" { kittyReply(command, "OK"); return }
        let id: UInt32
        if let given = command.number("i"), given > 0, given <= Int(UInt32.max) { id = UInt32(given) }
        else { id = nextKittyID; nextKittyID -= 1 }
        kittyOrder.removeAll { $0 == id }
        kittyOrder.append(id)
        kittyImages[id] = image
        while kittyOrder.count > InlineImages.maximumImages
                || kittyOrder.reduce(0, { $0 + (kittyImages[$1]?.byteCount ?? 0) }) > InlineImages.maximumTotalBytes {
            kittyImages[kittyOrder.removeFirst()] = nil
        }
        if command.action == "T" { try kittyDisplay(id, image, command) }
        kittyReply(command, "OK", id: id)
    }

    /// Shows a kept image at the cursor. A placement id (`p=`) replaces the image's earlier placement with that id.
    private func kittyDisplay(_ id: UInt32, _ stored: KittyStoredImage, _ command: KittyCommand) throws {
        // Unicode placeholders (`U=1`) need placeholder characters drawn as image cells, which the display does not do.
        guard command.letter("U") != "1" else { throw KittyError.placeholders }
        var image = (content: stored.content, width: stored.width, height: stored.height)
        if command.keys["x"] != nil || command.keys["y"] != nil || command.keys["w"] != nil || command.keys["h"] != nil {
            guard let part = KittyGraphics.crop(image, x: command.number("x") ?? 0, y: command.number("y") ?? 0,
                                                width: command.number("w") ?? 0, height: command.number("h") ?? 0) else { throw KittyError.invalid }
            image = part
        }
        let placement = UInt32(clamping: max(command.number("p") ?? 0, 0))
        if placement != 0 { images.removeAll { $0.kittyImage == id && $0.kittyPlacement == placement } }
        let size = KittyGraphics.cells(width: image.width, height: image.height, columns: command.number("c"), rows: command.number("r"), cell: cellSize)
        place(image.content, bytes: image.width * image.height * 4, columns: min(size.columns, cols), rows: size.rows, stretches: size.stretches,
              cursorBelow: command.letter("C") == "1" ? nil : false, kitty: (id, placement))
    }

    /// `a=d`: removes placements on the screen being shown. The lowercase forms keep the image data for later
    /// placements; the uppercase forms also drop the data of images left with no placement.
    private func kittyDelete(_ command: KittyCommand) {
        let what = command.letter("d") ?? "a"
        let alternate = usingAlternate
        func covers(_ image: TerminalImage, line: Int?, column: Int?) -> Bool {
            (line.map { image.line <= $0 && $0 < image.line + image.rows } ?? true)
                && (column.map { image.column <= $0 && $0 < image.column + image.columns } ?? true)
        }
        var matches: (TerminalImage) -> Bool
        switch what.lowercased() {
        case "a": matches = { _ in true }
        case "i", "n":
            guard let id = kittyID(command) else { return }
            let placement = command.number("p").flatMap { $0 > 0 ? UInt32(clamping: $0) : nil }
            matches = { $0.kittyImage == id && (placement == nil || $0.kittyPlacement == placement) }
            if what.isUppercase, placement == nil { kittyImages[id] = nil; kittyOrder.removeAll { $0 == id } }
        case "c": let line = absoluteLine(ofRow: cursorRow), column = cursorCol; matches = { covers($0, line: line, column: column) }
        case "p":
            let line = absoluteLine(ofRow: (command.number("y") ?? 1) - 1), column = (command.number("x") ?? 1) - 1
            matches = { covers($0, line: line, column: column) }
        case "x": let column = (command.number("x") ?? 1) - 1; matches = { covers($0, line: nil, column: column) }
        case "y": let line = absoluteLine(ofRow: (command.number("y") ?? 1) - 1); matches = { covers($0, line: line, column: nil) }
        default: count("kitty graphics delete " + String(what)); return
        }
        images.removeAll { $0.kittyImage != nil && $0.alternate == alternate && matches($0) }
        if what.isUppercase {
            let shown = Set(images.compactMap(\.kittyImage))
            kittyOrder.removeAll { id in
                guard !shown.contains(id) else { return false }
                kittyImages[id] = nil
                return true
            }
        }
    }

    /// Answers a command that named its image with `i=` or `I=`, unless `q=` asked for quiet.
    private func kittyReply(_ command: KittyCommand, _ message: String, id: UInt32? = nil) {
        let quiet = command.quiet
        guard message == "OK" ? quiet < 1 : quiet < 2 else { return }
        var keys: [String] = []
        if let given = command.keys["i"] { keys.append("i=\(given)") }
        else if command.keys["I"] != nil, let id { keys.append("i=\(id)") }
        if let number = command.keys["I"] { keys.append("I=\(number)") }
        guard !keys.isEmpty else { return }
        if let placement = command.keys["p"] { keys.append("p=\(placement)") }
        events.append(.reply(Array("\u{1B}_G\(keys.joined(separator: ","));\(message)\u{1B}\\".utf8)))
    }

    /// Puts a picture at the cursor, scrolling so all of it fits. `cursorBelow` true leaves the cursor on the line
    /// under it, as sixel does; false leaves it after the picture's last row, as iTerm2 does; nil leaves it in place.
    private func place(_ content: TerminalImage.Content, bytes: Int, columns: Int, rows height: Int, stretches: Bool, cursorBelow: Bool?,
                       kitty: (image: UInt32, placement: UInt32)? = nil) {
        if wrapPending { cursorCol = 0; lineFeed() }
        let row = cursorRow, column = cursorCol
        for _ in 1..<max(1, height) { lineFeed() }
        let top = absoluteLine(ofRow: cursorRow) - (height - 1)
        let image = TerminalImage(id: nextImageID, content: content, line: top, column: column, columns: max(1, min(columns, cols - column)),
                                  rows: height, stretches: stretches, alternate: usingAlternate, byteCount: bytes,
                                  kittyImage: kitty?.image, kittyPlacement: kitty?.placement)
        nextImageID += 1
        images.append(image)
        pruneImages()
        switch cursorBelow {
        case true?: lineFeed(); cursorCol = column
        case false?:
            let end = column + image.columns
            if end >= cols { cursorCol = cols - 1; wrapPending = autowrap } else { cursorCol = end }
        case nil: cursorRow = row; cursorCol = column
        }
    }

    /// Drops pictures that scrolled out of the kept lines, then the oldest past the count and size limits.
    private func pruneImages() {
        let first = trimmedLines
        images.removeAll { $0.line + $0.rows <= first }
        while images.count > InlineImages.maximumImages || images.reduce(0, { $0 + $1.byteCount }) > InlineImages.maximumTotalBytes {
            images.removeFirst()
        }
    }

    /// Removes the pictures that have a row in `lines` on the screen being shown.
    private func removeImages(lines: Range<Int>) {
        let alternate = usingAlternate
        images.removeAll { $0.alternate == alternate && $0.line < lines.upperBound && $0.line + $0.rows > lines.lowerBound }
    }

    /// Reads the path from an OSC 7 report such as `file://host/home/me/My%20Files`.
    static func directory(fromOSC7 value: String) -> String? {
        guard value.hasPrefix("file://") else { return nil }
        let rest = value.dropFirst("file://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let path = String(rest[slash...])
        return path.removingPercentEncoding ?? path
    }

    private func count(_ name: String) { unsupported[name, default: 0] += 1 }

    /// The largest clipboard write accepted from OSC 52, in decoded bytes.
    public static let maximumClipboardBytes = 1_048_576

    /// OSC 52 `Pc;Pd`: base64 text for the clipboard. Reading the clipboard (`?`) is never answered.
    private func clipboard(_ body: String) {
        guard let separator = body.firstIndex(of: ";") else { return }
        let payload = body[body.index(after: separator)...]
        guard payload != "?", payload.utf8.count <= Self.maximumClipboardBytes * 4 / 3 + 4,
              let data = Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters),
              data.count <= Self.maximumClipboardBytes, let text = String(data: data, encoding: .utf8) else { return }
        events.append(.clipboard(text))
    }

    // MARK: Shell integration and links

    /// The absolute line of a row on screen.
    public func absoluteLine(ofRow row: Int) -> Int { trimmedLines + scrollback.count + row }

    /// A line by absolute number, from the scrollback or the screen; nil once it has been trimmed.
    public func row(absolute line: Int) -> [Cell]? {
        let index = line - trimmedLines
        guard index >= 0 else { return nil }
        if index < scrollback.count { return scrollback[index] }
        let row = index - scrollback.count
        return row < rows ? grid[row] : nil
    }

    /// Plain text of absolute lines, without trailing spaces. Lines no longer kept are skipped.
    public func text(lines range: Range<Int>, fromColumn column: Int = 0) -> String {
        range.compactMap { line -> String? in
            guard let cells = row(absolute: line) else { return nil }
            var text = ""
            for (index, cell) in cells.enumerated() where cell.width != 0 && (line != range.lowerBound || index >= column) {
                text.append(cell.character)
            }
            while text.last == " " { text.removeLast() }
            return text
        }.joined(separator: "\n")
    }

    /// Text of absolute lines with rows that ran past the edge joined again, so a long word is whole. Each line ends with
    /// a newline, except a last row that continues below the range.
    public func unwrappedText(lines range: Range<Int>) -> String {
        range.map { line in
            let cells = row(absolute: line)
            guard let cells else { return "" }
            let text = String(cells.filter { $0.width != 0 }.map(\.character))
            if cells.last?.wraps == true { return text }
            return text.replacingOccurrences(of: " +$", with: "", options: .regularExpression) + "\n"
        }.joined()
    }

    /// The URL of an OSC 8 link index.
    public func link(_ index: UInt16) -> String? { index == 0 || Int(index) >= links.count ? nil : links[Int(index)] }

    /// OSC 133 (FinalTerm) marks: A prompt, B input, C output, D finished with an optional exit code.
    private func commandMark(_ body: String) {
        guard !usingAlternate, let kind = body.first else { return }
        let fields = body.split(separator: ";", omittingEmptySubsequences: false)
        let line = absoluteLine(ofRow: cursorRow)
        switch kind {
        case "A":
            if var last = commandMarks.last, last.outputLine != nil, last.endLine == nil {
                last.endLine = max(last.outputLine ?? line, cursorCol > 0 ? line + 1 : line)
                commandMarks[commandMarks.count - 1] = last
            }
            // A prompt drawn again on the same line (a resize, say) replaces the previous mark.
            if let last = commandMarks.last, last.promptLine == line, last.outputLine == nil { commandMarks.removeLast() }
            commandMarks.append(CommandMark(promptLine: line))
            if commandMarks.count > Self.maximumCommandMarks { commandMarks.removeFirst(commandMarks.count - Self.maximumCommandMarks) }
        case "B":
            guard var last = commandMarks.last, last.outputLine == nil else { return }
            last.inputLine = line; last.inputColumn = cursorCol
            commandMarks[commandMarks.count - 1] = last
        case "C":
            guard var last = commandMarks.last, last.outputLine == nil else { return }
            let output = cursorCol > 0 && !wrapPending ? line + 1 : line
            last.outputLine = output
            last.startedAt = Date()
            if let input = last.inputLine {
                let command = text(lines: input..<max(input + 1, output), fromColumn: last.inputColumn ?? 0)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                last.command = command.isEmpty ? nil : String(command.prefix(4096))
            }
            commandMarks[commandMarks.count - 1] = last
        case "D":
            guard var last = commandMarks.last, last.finishedAt == nil else { return }
            if let output = last.outputLine { last.endLine = max(output, cursorCol > 0 ? line + 1 : line) }
            last.exitCode = fields.count > 1 ? Int(fields[1]) : nil
            last.finishedAt = Date()
            commandMarks[commandMarks.count - 1] = last
            if last.startedAt != nil { events.append(.commandFinished(last)) }
        default:
            count("OSC 133;" + String(kind))
        }
    }

    /// OSC 8: `params;URI` opens a link, an empty URI closes it. Long or excess targets are ignored.
    private func hyperlink(_ body: String) {
        guard let separator = body.firstIndex(of: ";") else { style.link = 0; return }
        let uri = String(body[body.index(after: separator)...])
        guard !uri.isEmpty, uri.utf8.count <= 2048, !uri.unicodeScalars.contains(where: { $0.value < 0x20 }) else { style.link = 0; return }
        if let index = linkIndex[uri] { style.link = index; return }
        guard links.count < 4096 else { style.link = 0; return }
        links.append(uri)
        let index = UInt16(links.count - 1)
        linkIndex[uri] = index
        style.link = index
    }

    // MARK: Printing

    /// Longer OSC strings are cut off; the largest is a 1 MB OSC 52 clipboard write in base64.
    static let maximumOSCLength = 1_400_000
    /// OSC 1337 inline images may be longer: a 10 MB file in base64.
    static let maximumImageOSCLength = InlineImages.maximumFileBytes * 4 / 3 + 4096
    static let imageOSCPrefix = Array("1337;".utf8)
    /// A sixel image of the largest size in many colors.
    static let maximumDCSLength = 32 * 1_048_576

    private static let lineDrawingMap: [Character: Character] = [
        "j": "┘", "k": "┐", "l": "┌", "m": "└", "n": "┼", "q": "─", "t": "├", "u": "┤", "v": "┴", "w": "┬", "x": "│", "a": "▒", "`": "◆", "~": "·", "f": "°", "g": "±", "y": "≤", "z": "≥", "{": "π", "|": "≠", "}": "£",
    ]

    private static let wideRanges: [ClosedRange<UInt32>] = [0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD]
    /// A small subset of East Asian ambiguous characters (Greek, Cyrillic, box drawing, symbols).
    private static let ambiguousRanges: [ClosedRange<UInt32>] = [0x00A1...0x00A1, 0x00B0...0x00B4, 0x0391...0x03C9, 0x0401...0x0451, 0x2010...0x2027, 0x2030...0x203E, 0x2100...0x2199, 0x2460...0x24FF, 0x2500...0x257F, 0x25A0...0x25FF, 0x2600...0x26FF]

    public static func width(of c: Character, ambiguousWide: Bool) -> Int {
        guard let s = c.unicodeScalars.first else { return 1 }
        return width(scalar: s.value, ambiguousWide: ambiguousWide)
    }

    /// The cells a character starting with `v` takes. Everything below U+20000 is looked up in a table built once.
    static func width(scalar v: UInt32, ambiguousWide: Bool) -> Int {
        // Latin text needs no lookup: nothing below U+0300 is a combining mark or wide.
        if v < 0x300 { return ambiguousWide && (v == 0xA1 || (0xB0...0xB4).contains(v)) ? 2 : 1 }
        let kind = v < UInt32(widthTable.count) ? widthTable[Int(v)] : widthKind(v)
        return kind == 3 ? (ambiguousWide ? 2 : 1) : Int(kind)
    }

    /// The width kind of every value below U+20000: 0 zero width, 1 narrow, 2 wide, 3 ambiguous. Building it takes a
    /// few milliseconds the first time any terminal shows a character from U+0300 up.
    private static let widthTable: [UInt8] = (0..<0x20000).map { widthKind(UInt32($0)) }

    private static func widthKind(_ v: UInt32) -> UInt8 {
        guard v >= 0x300, let s = Unicode.Scalar(v) else { return 1 }
        let category = s.properties.generalCategory
        if category == .nonspacingMark || category == .enclosingMark || v == 0x200B { return 0 }
        if v >= 0x1100 && wideRanges.contains(where: { $0.contains(v) }) { return 2 }
        if ambiguousRanges.contains(where: { $0.contains(v) }) { return 3 }
        return 1
    }

    private func put(_ input: Character) {
        var c = input
        if lineDrawing, let m = Self.lineDrawingMap[c] { c = m }
        putCell(c, width: Self.width(of: c, ambiguousWide: options.cjkAmbiguousAsWide))
    }

    /// Writes a character `w` cells wide at the cursor; zero joins it to the previous cell. In a terminal one column
    /// wide, a wide character takes the one cell.
    private func putCell(_ c: Character, width: Int) {
        let w = min(width, cols)
        if w == 0 {
            // Combine with the previous cell.
            let col = wrapPending ? cursorCol : max(0, cursorCol - 1)
            let row = cursorRow
            mutateGrid { g in g[row][col].character = Character(String(g[row][col].character) + String(c)) }
            return
        }
        if wrapPending || cursorCol + w > cols {
            if autowrap {
                let row = cursorRow, last = cols - 1
                mutateGrid { g in g[row][last].wraps = true }
                cursorCol = 0; lineFeed()
            } else { cursorCol = max(0, cols - w) }
            wrapPending = false
        }
        let row = cursorRow, col = cursorCol, insert = insertMode, current = style, blank = blankCell(), width = cols
        mutateGrid { g in
            if insert {
                g[row].insert(contentsOf: Array(repeating: Cell.blank, count: w), at: col)
                g[row].removeLast(w)
            }
            Self.clearWide(&g, row, col, cols: width, blank: blank)
            if w == 2 { Self.clearWide(&g, row, col + 1, cols: width, blank: blank) }
            g[row][col] = Cell(character: c, style: current, width: UInt8(w))
            if w == 2 { g[row][col + 1] = Cell(character: " ", style: current, width: 0) }
        }
        if cursorCol + w >= cols { cursorCol = cols - 1; wrapPending = autowrap } else { cursorCol += w }
    }

    /// Overwriting either half of a wide character blanks the other half.
    private static func clearWide(_ g: inout [[Cell]], _ r: Int, _ c: Int, cols: Int, blank: Cell) {
        guard c < cols else { return }
        if g[r][c].width == 0, c > 0 { g[r][c - 1] = blank }
        if g[r][c].width == 2, c + 1 < cols { g[r][c + 1] = blank }
    }

    private func blankCell() -> Cell { var c = Cell.blank; c.style.background = style.background; return c }

    // MARK: Movement and scrolling

    private func lineFeed() {
        wrapPending = false
        if cursorRow == scrollBottom { scrollUp(1) } else if cursorRow < rows - 1 { cursorRow += 1 }
    }

    private func reverseIndex() {
        wrapPending = false
        if cursorRow == scrollTop { scrollDown(1) } else if cursorRow > 0 { cursorRow -= 1 }
    }

    private func scrollUp(_ n: Int) {
        let top = scrollTop, bottom = scrollBottom, blankRow = Array(repeating: blankCell(), count: cols)
        let keeps = !usingAlternate && top == 0 && options.scrollbackSize > 0
        var removed: [[Cell]] = []
        mutateGrid { g in
            for _ in 0..<min(n, bottom - top + 1) {
                let line = g.remove(at: top)
                if keeps { removed.append(line) }
                g.insert(blankRow, at: bottom)
            }
        }
        if !removed.isEmpty {
            scrollback.append(contentsOf: removed)
            if scrollback.count > options.scrollbackSize {
                let excess = scrollback.count - options.scrollbackSize
                scrollback.removeFirst(excess); trimmedLines += excess
            }
        }
    }

    private func scrollDown(_ n: Int) {
        let top = scrollTop, bottom = scrollBottom, blankRow = Array(repeating: blankCell(), count: cols)
        mutateGrid { g in
            for _ in 0..<min(n, bottom - top + 1) {
                g.remove(at: bottom)
                g.insert(blankRow, at: top)
            }
        }
    }

    private func tab() {
        wrapPending = false
        var c = cursorCol + 1
        while c < cols - 1 && !tabStops.contains(c) { c += 1 }
        cursorCol = min(c, cols - 1)
    }

    private func resetTabs() { tabStops = Set(stride(from: 8, to: cols, by: 8)) }

    private func moveTo(row: Int, col: Int) {
        wrapPending = false
        let top = originMode ? scrollTop : 0, bottom = originMode ? scrollBottom : rows - 1
        cursorRow = min(max(row + top, top), bottom)
        cursorCol = min(max(col, 0), cols - 1)
    }

    private func saveCursor() { saved = (cursorRow, cursorCol, style, originMode) }
    private func restoreCursor() { cursorRow = min(saved.row, rows - 1); cursorCol = min(saved.col, cols - 1); style = saved.style; originMode = saved.origin; wrapPending = false }

    private func reset() {
        var o = options
        // RIS/DECSTR reset terminal state, not the window size. The initial options can predate several resizes.
        o.rows = rows; o.cols = cols
        let sb = scrollback
        let fresh = TerminalScreen(options: o)
        primary = fresh.primary; alternate = fresh.alternate; usingAlternate = false
        cursorRow = 0; cursorCol = 0; cursorVisible = true; applicationCursorKeys = o.applicationCursorKeys
        style = CellStyle(); scrollTop = 0; scrollBottom = rows - 1; autowrap = true; wrapPending = false; originMode = false; insertMode = false
        lineDrawing = false; bracketedPaste = false; resetTabs(); title = ""; scrollback = sb
        images = []; multipart = nil; kittyImages = [:]; kittyOrder = []; kittyTransfer = nil
        mouseTracking = .off; sgrMouse = false; reportsFocus = false; cursorShape = nil; cursorBlinks = nil
    }

    // MARK: CSI

    private func csi(_ final: Character) {
        let isPrivate = params.hasPrefix("?")
        let p = Self.parameters(params)
        func arg(_ i: Int, _ d: Int = 1) -> Int { i < p.count ? (p[i].map { $0 == 0 ? d : $0 } ?? d) : d }
        func raw(_ i: Int) -> Int { i < p.count ? (p[i] ?? 0) : 0 }
        if !intermediates.isEmpty {
            if intermediates == " " && final == "q" { cursorStyle(raw(0)); return }
            if intermediates == "!" && final == "p" { reset(); return } // DECSTR (approximate: full reset)
            count("CSI \(params)\(intermediates)\(final)"); return
        }
        if params.hasPrefix(">") || params.hasPrefix("=") {
            if final == "c" { events.append(.reply(Array("\u{1B}[>0;10;1c".utf8))) } else { count("CSI \(params)\(final)") }
            return
        }
        var g = grid
        switch final {
        case "A": cursorRow = max(cursorRow - arg(0), cursorRow >= scrollTop ? scrollTop : 0); wrapPending = false
        case "B", "e": cursorRow = min(cursorRow + arg(0), cursorRow <= scrollBottom ? scrollBottom : rows - 1); wrapPending = false
        case "C", "a": cursorCol = min(cursorCol + arg(0), cols - 1); wrapPending = false
        case "D": cursorCol = max(cursorCol - arg(0), 0); wrapPending = false
        case "E": cursorRow = min(cursorRow + arg(0), scrollBottom); cursorCol = 0; wrapPending = false
        case "F": cursorRow = max(cursorRow - arg(0), scrollTop); cursorCol = 0; wrapPending = false
        case "G", "`": cursorCol = min(arg(0) - 1, cols - 1); wrapPending = false
        case "d": moveTo(row: arg(0) - 1, col: cursorCol)
        case "H", "f": moveTo(row: arg(0) - 1, col: arg(1) - 1)
        case "I": for _ in 0..<arg(0) { tab() }
        case "Z": for _ in 0..<arg(0) { var c = cursorCol - 1; while c > 0 && !tabStops.contains(c) { c -= 1 }; cursorCol = max(c, 0) }
        case "J":
            let b = blankCell()
            switch raw(0) {
            case 0: for c in cursorCol..<cols { g[cursorRow][c] = b }; for r in (cursorRow + 1)..<max(rows, cursorRow + 1) { g[r] = Array(repeating: b, count: cols) }
            case 1: for r in 0..<cursorRow { g[r] = Array(repeating: b, count: cols) }; for c in 0...cursorCol { g[cursorRow][c] = b }
            case 2: g = Array(repeating: Array(repeating: b, count: cols), count: rows)
                removeImages(lines: absoluteLine(ofRow: 0)..<absoluteLine(ofRow: rows))
            case 3: removeImages(lines: trimmedLines..<absoluteLine(ofRow: 0)); trimmedLines += scrollback.count; scrollback = []
            default: break
            }
            grid = g
        case "K":
            let b = blankCell()
            switch raw(0) {
            case 0: for c in cursorCol..<cols { g[cursorRow][c] = b }
            case 1: for c in 0...cursorCol { g[cursorRow][c] = b }
            case 2: g[cursorRow] = Array(repeating: b, count: cols)
            default: break
            }
            grid = g
        case "X": for c in cursorCol..<min(cols, cursorCol + arg(0)) { g[cursorRow][c] = blankCell() }; grid = g
        case "@": let n = min(arg(0), cols - cursorCol); g[cursorRow].insert(contentsOf: Array(repeating: blankCell(), count: n), at: cursorCol); g[cursorRow].removeLast(n); grid = g
        case "P": let n = min(arg(0), cols - cursorCol); g[cursorRow].removeSubrange(cursorCol..<(cursorCol + n)); g[cursorRow].append(contentsOf: Array(repeating: blankCell(), count: n)); grid = g
        case "L", "M":
            guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { break }
            let n = min(arg(0), scrollBottom - cursorRow + 1)
            for _ in 0..<n {
                if final == "L" { g.remove(at: scrollBottom); g.insert(Array(repeating: blankCell(), count: cols), at: cursorRow) }
                else { g.remove(at: cursorRow); g.insert(Array(repeating: blankCell(), count: cols), at: scrollBottom) }
            }
            grid = g; cursorCol = 0
        case "S": scrollUp(arg(0))
        case "T": scrollDown(arg(0))
        case "r":
            let top = arg(0) - 1, bottom = (p.count > 1 && raw(1) > 0 ? raw(1) : rows) - 1
            if top < bottom && bottom < rows { scrollTop = top; scrollBottom = bottom; moveTo(row: 0, col: 0) }
        case "s": saveCursor()
        case "u": restoreCursor()
        case "g": if raw(0) == 3 { tabStops = [] } else { tabStops.remove(cursorCol) }
        case "m": sgr(p.isEmpty ? [0] : p.map { $0 ?? 0 })
        case "h", "l": setMode(isPrivate, p.map { $0 ?? 0 }, final == "h")
        case "n":
            if raw(0) == 6 { events.append(.reply(Array("\u{1B}[\(cursorRow + 1 - (originMode ? scrollTop : 0));\(cursorCol + 1)R".utf8))) }
            else if raw(0) == 5 { events.append(.reply(Array("\u{1B}[0n".utf8))) }
        case "c": events.append(.reply(Array((options.inlineImages ? "\u{1B}[?62;4;22c" : "\u{1B}[?62;22c").utf8)))
        case "t":
            // Size reports that image programs use to fit pictures to the cells: the text area and one cell in
            // pixels (one pixel per point, as pictures are shown), and the text area in cells.
            let cell = cellSize
            switch raw(0) {
            case 14: events.append(.reply(Array("\u{1B}[4;\(Int(cell.height * Double(rows)));\(Int(cell.width * Double(cols)))t".utf8)))
            case 16: events.append(.reply(Array("\u{1B}[6;\(Int(cell.height.rounded()));\(Int(cell.width.rounded()))t".utf8)))
            case 18: events.append(.reply(Array("\u{1B}[8;\(rows);\(cols)t".utf8)))
            default: count("CSI t (window ops)")
            }
        default: count("CSI \(params)\(final)")
        }
    }

    /// DECSCUSR: 0 restores the user's cursor, 1 and 2 are a block, 3 and 4 an underline, 5 and 6 a bar. Odd values blink.
    private func cursorStyle(_ value: Int) {
        switch value {
        case 0: cursorShape = nil; cursorBlinks = nil
        case 1...6:
            cursorShape = value <= 2 ? .block : value <= 4 ? .underline : .bar
            cursorBlinks = value % 2 == 1
        default: count("DECSCUSR \(value)")
        }
    }

    private func setMode(_ isPrivate: Bool, _ modes: [Int], _ on: Bool) {
        for m in modes {
            if !isPrivate {
                if m == 4 { insertMode = on } else if m != 20 { count("SM/RM \(m)") }
                continue
            }
            switch m {
            case 1: applicationCursorKeys = on
            case 6: originMode = on; moveTo(row: 0, col: 0)
            case 7: autowrap = on; if !on { wrapPending = false }
            case 25: cursorVisible = on
            case 2004: bracketedPaste = on
            case 47, 1047: switchScreen(on, clear: m == 1047)
            case 1048: if on { saveCursor() } else { restoreCursor() }
            case 1049: if on { saveCursor(); switchScreen(true, clear: true) } else { switchScreen(false, clear: false); restoreCursor() }
            case 1000: mouseTracking = on ? .clicks : .off
            case 1002: mouseTracking = on ? .drags : .off
            case 1003: mouseTracking = on ? .motion : .off
            case 1006: sgrMouse = on
            case 1004: reportsFocus = on
            case 12, 1005, 1015, 3, 5, 8, 9: break // not used
            default: count("DECSET \(m)")
            }
        }
    }

    private func switchScreen(_ alt: Bool, clear: Bool) {
        guard alt != usingAlternate else { return }
        if alt && clear { alternate = Array(repeating: Array(repeating: Cell.blank, count: cols), count: rows) }
        if !alt { images.removeAll { $0.alternate } }
        usingAlternate = alt
        wrapPending = false
    }

    /// CSI parameters split at `;`, after a leading `?`, `>` or `=`. Only the first part of a `:` group counts, and an
    /// empty, malformed, or huge parameter is nil. Parsed byte by byte: SGR sequences in colored output are frequent.
    static func parameters(_ params: String) -> [Int?] {
        var result: [Int?] = []
        var value = 0, digits = 0, valid = true, inSubparameter = false, first = true
        for b in params.utf8 {
            defer { first = false }
            if first, b == 0x3F || b == 0x3E || b == 0x3D { continue }
            switch b {
            case 0x30...0x39:
                guard !inSubparameter else { continue }
                if value > 99_999_999 { valid = false } else { value = value * 10 + Int(b - 0x30) }
                digits += 1
            case 0x3B:
                result.append(valid && digits > 0 ? value : nil)
                value = 0; digits = 0; valid = true; inSubparameter = false
            case 0x3A:
                inSubparameter = true
            default:
                if !inSubparameter { valid = false }
            }
        }
        result.append(valid && digits > 0 ? value : nil)
        return result
    }

    private func sgr(_ p: [Int]) {
        var i = 0
        while i < p.count {
            let v = p[i]
            switch v {
            case 0: let link = style.link; style = CellStyle(); style.link = link
            case 1: style.bold = true
            case 2: style.faint = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 5, 6: style.blink = true
            case 7: style.inverse = true
            case 8: style.invisible = true
            case 9: style.strikethrough = true
            case 21, 24: style.underline = false
            case 22: style.bold = false; style.faint = false
            case 23: style.italic = false
            case 25: style.blink = false
            case 27: style.inverse = false
            case 28: style.invisible = false
            case 29: style.strikethrough = false
            case 30...37: style.foreground = .indexed(UInt8(v - 30))
            case 39: style.foreground = .default
            case 40...47: style.background = .indexed(UInt8(v - 40))
            case 49: style.background = .default
            case 90...97: style.foreground = .indexed(UInt8(v - 90 + 8))
            case 100...107: style.background = .indexed(UInt8(v - 100 + 8))
            case 38, 48:
                var color: TerminalColor?
                if i + 2 < p.count && p[i + 1] == 5 { color = .indexed(UInt8(clamping: p[i + 2])); i += 2 }
                else if i + 4 < p.count && p[i + 1] == 2 { color = .rgb(RGB(red: UInt8(clamping: p[i + 2]), green: UInt8(clamping: p[i + 3]), blue: UInt8(clamping: p[i + 4]))); i += 4 }
                else { i = p.count }
                if let c = color { if v == 38 { style.foreground = c } else { style.background = c } }
            default: count("SGR \(v)")
            }
            i += 1
        }
    }

    // MARK: Resize and output

    public func resize(rows newRows: Int, cols newCols: Int) {
        let r = max(1, newRows), c = max(1, newCols)
        if c != cols { reflowPrimary(rows: r, cols: c); return }
        func fit(_ g: [[Cell]], keepBottom: Bool) -> [[Cell]] {
            var g = g.map { line in line.count >= c ? Array(line.prefix(c)) : line + Array(repeating: Cell.blank, count: c - line.count) }
            if g.count > r {
                let extra = g.count - r
                if keepBottom { if !usingAlternate { scrollback.append(contentsOf: g.prefix(extra)) }; g.removeFirst(extra) } else { g.removeLast(extra) }
            }
            while g.count < r { g.append(Array(repeating: Cell.blank, count: c)) }
            return g
        }
        let shift = max(0, cursorRow - (r - 1))
        primary = fit(primary, keepBottom: shift > 0 && !usingAlternate)
        alternate = fit(alternate, keepBottom: false)
        rows = r; cols = c
        cursorRow -= shift; cursorRow = min(cursorRow, r - 1); cursorCol = min(cursorCol, c - 1)
        scrollTop = 0; scrollBottom = r - 1; wrapPending = false
        resetTabs()
    }

    /// A width change: the main screen and its scrollback rewrap to the new width, so lines that wrapped join again
    /// and long lines wrap instead of being cut. The cursor and shell integration marks move with their text.
    /// The alternate screen belongs to a full-screen program, which redraws it, so it is only cut or padded.
    private func reflowPrimary(rows r: Int, cols c: Int) {
        let blankRow = Array(repeating: Cell.blank, count: c)
        // Blank rows under the text and the cursor are dropped and padded back afterwards.
        var used = usingAlternate ? 0 : cursorRow + 1
        if let last = primary.lastIndex(where: { row in row.contains { $0 != .blank } }) { used = max(used, last + 1) }
        let source = scrollback + primary.prefix(used)
        let cursor = usingAlternate ? nil : (row: scrollback.count + cursorRow, col: wrapPending ? cursorCol + 1 : cursorCol)
        let result = Self.reflow(source, width: c, cursor: cursor)
        var lines = result.rows
        // Keep the bottom of the text on screen, and the cursor on screen even when text runs far below it.
        var top = max(0, lines.count - r)
        if let row = result.cursor?.row { top = min(top, row) }
        let screen = lines.count > top ? Array(lines[top..<min(lines.count, top + r)]) : []
        lines.removeSubrange(min(top, lines.count)...)
        primary = screen.map { Self.fit($0, width: c) } + Array(repeating: blankRow, count: max(0, r - screen.count))

        let base = trimmedLines
        func moved(_ line: Int) -> Int {
            let index = line - base
            guard index >= 0 else { return line }
            return base + (index < result.lineStarts.count ? result.lineStarts[index] : result.rows.count + index - source.count)
        }
        commandMarks = commandMarks.map { mark in
            var mark = mark
            mark.promptLine = moved(mark.promptLine)
            mark.inputLine = mark.inputLine.map(moved)
            mark.outputLine = mark.outputLine.map(moved)
            mark.endLine = mark.endLine.map(moved)
            return mark
        }
        images = images.map { image in
            guard !image.alternate else { return image }
            var image = image
            image.line = moved(image.line)
            return image
        }
        scrollback = lines
        if scrollback.count > options.scrollbackSize {
            let excess = scrollback.count - options.scrollbackSize
            scrollback.removeFirst(excess); trimmedLines += excess
        }
        alternate = alternate.map { Self.fit($0, width: c) }
        if alternate.count > r { alternate.removeLast(alternate.count - r) }
        while alternate.count < r { alternate.append(blankRow) }
        rows = r; cols = c
        if let position = result.cursor {
            cursorRow = min(max(0, position.row - top), r - 1); cursorCol = min(position.col, c - 1)
        } else {
            cursorRow = min(cursorRow, r - 1); cursorCol = min(cursorCol, c - 1)
        }
        scrollTop = 0; scrollBottom = r - 1; wrapPending = false
        resetTabs()
    }

    /// A row cut or padded with blanks to exactly `width` cells. A wide character cut in half becomes a blank.
    private static func fit(_ row: [Cell], width: Int) -> [Cell] {
        if row.count == width { return row }
        if row.count < width { return row + Array(repeating: .blank, count: width - row.count) }
        var cut = Array(row.prefix(width))
        if cut[width - 1].width == 2 { cut[width - 1] = .blank }
        cut[width - 1].wraps = false
        return cut
    }

    /// Rewraps rows to `width`. Rows whose last cell `wraps` join the next row into one line, and each line is cut
    /// into rows of `width` again, moving a wide character that would straddle the edge to the next row. A single
    /// row that already fits is kept as it is. `lineStarts[i]` is where old row `i` starts among the new rows.
    static func reflow(_ rows: [[Cell]], width: Int, cursor: (row: Int, col: Int)?)
        -> (rows: [[Cell]], lineStarts: [Int], cursor: (row: Int, col: Int)?) {
        let width = max(1, width)
        var out: [[Cell]] = []; out.reserveCapacity(rows.count)
        var lineStarts = Array(repeating: 0, count: rows.count)
        var newCursor: (row: Int, col: Int)?
        var index = 0
        while index < rows.count {
            let first = index
            if rows[index].last?.wraps != true, contentLength(rows[index]) <= width {
                lineStarts[index] = out.count
                if cursor?.row == index, let cursor { newCursor = (out.count, cursor.col) }
                out.append(rows[index]); index += 1
                continue
            }
            // Join the rows of one line, remembering where each started and where the cursor is.
            var cells: [Cell] = []
            var rowOffsets: [Int] = []
            var cursorOffset: Int?
            repeat {
                let row = rows[index]
                rowOffsets.append(cells.count)
                if cursor?.row == index, let cursor { cursorOffset = cells.count + cursor.col }
                let continues = row.last?.wraps == true
                if continues {
                    // A wide character that did not fit left a blank at the end of the row; drop it so the
                    // character goes back next to the text before it.
                    var last = row[row.count - 1]; last.wraps = false
                    let padded = last == .blank && index + 1 < rows.count && rows[index + 1].first?.width == 2
                    cells.append(contentsOf: padded ? row.dropLast() : row[...])
                    if !padded { cells[cells.count - 1].wraps = false }
                } else {
                    cells.append(contentsOf: row.prefix(contentLength(row)))
                }
                index += 1
                if !continues { break }
            } while index < rows.count
            // Cut it again, noting the new row and column of every cell.
            var positions: [(row: Int, col: Int)] = []; positions.reserveCapacity(cells.count)
            var current: [Cell] = []; current.reserveCapacity(width)
            for cell in cells {
                if cell.width != 0, !current.isEmpty, current.count + Int(max(cell.width, 1)) > width {
                    current += Array(repeating: .blank, count: max(0, width - current.count))
                    current[current.count - 1].wraps = true
                    out.append(current); current = []
                }
                positions.append((out.count, current.count))
                current.append(cell)
            }
            let end = (row: out.count, col: current.count)
            out.append(current + Array(repeating: .blank, count: max(0, width - current.count)))
            for (offset, start) in rowOffsets.enumerated() {
                lineStarts[first + offset] = start < positions.count ? positions[start].row : end.row
            }
            if let cursorOffset {
                var position = cursorOffset < positions.count ? positions[cursorOffset]
                    : (row: end.row, col: end.col + cursorOffset - cells.count)
                if position.col >= width { position = (position.row + position.col / width, position.col % width) }
                while out.count <= position.row { out.append(Array(repeating: .blank, count: width)) }
                newCursor = position
            }
        }
        return (out, lineStarts, newCursor)
    }

    /// Cells up to the last one that is not a plain blank.
    private static func contentLength(_ row: [Cell]) -> Int {
        var length = row.count
        while length > 0, row[length - 1] == .blank { length -= 1 }
        return length
    }

    public func cell(row: Int, col: Int) -> Cell { grid[row][col] }

    /// Changes how many lines of scrollback are kept, dropping the oldest when it shrinks.
    public func setScrollbackSize(_ size: Int) {
        options.scrollbackSize = max(0, size)
        if scrollback.count > options.scrollbackSize {
            let excess = scrollback.count - options.scrollbackSize
            scrollback.removeFirst(excess); trimmedLines += excess
        }
    }

    /// The column of a UTF-16 offset within a row's text as the display builds it: one string per cell, skipping
    /// the continuation cells of wide characters.
    public func column(ofUTF16Offset offset: Int, inRow row: Int) -> Int {
        guard row >= 0, row < rows else { return 0 }
        var length = 0
        for (column, cell) in grid[row].enumerated() where cell.width != 0 {
            let next = length + String(cell.character).utf16.count
            if offset < next { return column }
            length = next
        }
        return cols - 1
    }

    public enum MouseButton: Sendable { case left, middle, right, none, wheelUp, wheelDown }
    public enum MouseAction: Sendable { case press, release, drag, move }

    /// Bytes reporting a mouse event to the program, or nil when it did not ask for this kind of event.
    /// `row` and `column` count from 0 on the screen.
    public func mouseReport(_ button: MouseButton, _ action: MouseAction, row: Int, column: Int,
                            shift: Bool = false, option: Bool = false, control: Bool = false) -> [UInt8]? {
        switch (mouseTracking, action) {
        case (.off, _): return nil
        case (.clicks, .drag), (.clicks, .move), (.drags, .move): return nil
        default: break
        }
        var code: Int
        switch button {
        case .left: code = 0
        case .middle: code = 1
        case .right: code = 2
        case .none: code = 3
        case .wheelUp: code = 64
        case .wheelDown: code = 65
        }
        if action == .drag || action == .move { code += 32 }
        if action == .release && !sgrMouse { code = 3 }
        if shift { code += 4 }
        if option { code += 8 }
        if control { code += 16 }
        let x = min(max(column, 0), cols - 1) + 1, y = min(max(row, 0), rows - 1) + 1
        if sgrMouse { return Array("\u{1B}[<\(code);\(x);\(y)\(action == .release ? "m" : "M")".utf8) }
        guard x <= 223, y <= 223 else { return nil }
        return [0x1B, 0x5B, 0x4D, UInt8(32 + code), UInt8(32 + x), UInt8(32 + y)]
    }

    public func lineText(_ row: Int) -> String {
        var s = ""
        for cell in grid[row] where cell.width != 0 { s.append(cell.character) }
        while s.last == " " { s.removeLast() }
        return s
    }

    public var lines: [String] { (0..<rows).map(lineText) }

    /// Bytes to send for a cursor key, honoring DECCKM.
    public func cursorKey(_ key: Character) -> [UInt8] { Array(((applicationCursorKeys ? "\u{1B}O" : "\u{1B}[") + String(key)).utf8) }
    public var backspaceBytes: [UInt8] { options.backspaceSendsDelete ? [0x7F] : [0x08] }
}

// Feature entry: payload is JSON {"rows": Int?, "cols": Int?, "input": String}. An empty payload reports readiness.
public enum TerminalFeature: GloamuxFeature {
    public static let id = "terminal"
    public static let contractSha256 = "cb3383995fe3330e86edffddb98ee6ba98bb58c7d2cfb9c708b35e8d0f231431"
    public static let dependsOn: [String] = ["formats"]

    public static func run(_ request: FeatureRequest, dependencies: FeatureOutputs) throws -> FeatureResponse {
        if request.payload.isEmpty { return FeatureResponse(payload: #"{"ready":true,"types":["xterm","vt100","vt102","vt220","vt320","linux","ansi","scoansi"]}"#) }
        guard let obj = try JSONSerialization.jsonObject(with: Data(request.payload.utf8)) as? [String: Any], let input = obj["input"] as? String else {
            throw FeatureError.failed(id, "expected JSON {rows?, cols?, input}")
        }
        var o = TerminalOptions()
        if let r = obj["rows"] as? Int { o.rows = r }
        if let c = obj["cols"] as? Int { o.cols = c }
        let screen = TerminalScreen(options: o)
        screen.feed(input)
        let out: [String: Any] = ["lines": screen.lines, "cursor": [screen.cursorRow, screen.cursorCol], "title": screen.title, "unsupported": screen.unsupported]
        return FeatureResponse(payload: String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), as: UTF8.self))
    }
}
