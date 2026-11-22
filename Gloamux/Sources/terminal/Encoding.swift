import Foundation

/// The character encoding a session uses on the wire. The screen always works in UTF-8, so output is converted
/// before it is parsed and typed text is converted before it is sent. Escape sequences are ASCII in every encoding
/// here and pass through unchanged.
public enum TerminalEncoding: String, CaseIterable, Codable, Sendable {
    case utf8, big5, gb18030, shiftJIS, eucJP, eucKR, latin1

    public var title: String {
        switch self {
        case .utf8: return "UTF-8"
        case .big5: return "Big5"
        case .gb18030: return "GB18030"
        case .shiftJIS: return "Shift JIS"
        case .eucJP: return "EUC-JP"
        case .eucKR: return "EUC-KR"
        case .latin1: return "ISO Latin 1"
        }
    }

    var stringEncoding: String.Encoding {
        func cf(_ value: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue)))
        }
        switch self {
        case .utf8: return .utf8
        case .big5: return cf(.big5_HKSCS_1999)
        case .gb18030: return cf(.GB_18030_2000)
        case .shiftJIS: return .shiftJIS
        case .eucJP: return .japaneseEUC
        case .eucKR: return cf(.EUC_KR)
        case .latin1: return .isoLatin1
        }
    }

    /// Typed or pasted UTF-8 bytes in this encoding. Characters it cannot represent become `?`.
    public func encode(_ utf8: [UInt8]) -> [UInt8] {
        guard self != .utf8 else { return utf8 }
        let text = String(decoding: utf8, as: UTF8.self)
        return Array(text.data(using: stringEncoding, allowLossyConversion: true) ?? Data(text.utf8))
    }

    /// How many bytes the character starting at `index` takes, or nil when `bytes` ends before it does.
    func characterLength(_ bytes: ArraySlice<UInt8>, at index: Int) -> Int? {
        let lead = bytes[index]
        guard lead >= 0x80 else { return 1 }
        let needed: Int
        switch self {
        case .utf8, .latin1: return 1
        case .big5: needed = (0x81...0xFE).contains(lead) ? 2 : 1
        case .eucKR: needed = (0xA1...0xFE).contains(lead) ? 2 : 1
        case .gb18030:
            guard (0x81...0xFE).contains(lead) else { return 1 }
            guard index + 1 < bytes.endIndex else { return nil }
            needed = (0x30...0x39).contains(bytes[index + 1]) ? 4 : 2
        case .shiftJIS: needed = (0x81...0x9F).contains(lead) || (0xE0...0xFC).contains(lead) ? 2 : 1
        case .eucJP: needed = lead == 0x8F ? 3 : lead == 0x8E || (0xA1...0xFE).contains(lead) ? 2 : 1
        }
        return index + needed <= bytes.endIndex ? needed : nil
    }
}

/// Converts a stream of output in a legacy encoding to UTF-8, keeping a character split between chunks for the next one.
public struct TerminalDecoder: Sendable {
    public let encoding: TerminalEncoding
    private var pending: [UInt8] = []

    public init(encoding: TerminalEncoding) { self.encoding = encoding }

    public mutating func decode(_ bytes: [UInt8]) -> [UInt8] {
        guard encoding != .utf8 else { return bytes }
        let input = pending + bytes
        var end = 0
        let slice = input[...]
        while end < input.count, let length = encoding.characterLength(slice, at: end) { end += length }
        pending = Array(input[end...])
        // A partial character longer than any real one is not going to complete.
        if pending.count > 3 { end = input.count; pending = [] }
        return convert(input[..<end])
    }

    private func convert(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        if bytes.isEmpty { return [] }
        if let text = String(data: Data(bytes), encoding: encoding.stringEncoding) { return Array(text.utf8) }
        // Something in the chunk is not valid: convert character by character and mark the bad ones.
        var output: [UInt8] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let length = encoding.characterLength(bytes, at: index) ?? (bytes.endIndex - index)
            let unit = bytes[index..<(index + length)]
            if let text = String(data: Data(unit), encoding: encoding.stringEncoding) { output += Array(text.utf8) }
            else { output += Array("\u{FFFD}".utf8) }
            index += length
        }
        return output
    }
}
