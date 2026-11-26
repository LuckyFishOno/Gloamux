import Compression
import Foundation
import ImageIO

/// One kitty graphics protocol command: the text of `ESC _ G KEYS ; PAYLOAD ESC \` after the `G`. KEYS are
/// comma-separated `key=value` pairs whose keys are single letters, and case matters (`i` and `I` differ).
struct KittyCommand {
    var keys: [Character: Substring]
    var payload: ArraySlice<UInt8>

    init(_ body: ArraySlice<UInt8>) {
        let semicolon = body.firstIndex(of: 0x3B) ?? body.endIndex
        payload = semicolon < body.endIndex ? body[(semicolon + 1)...] : []
        keys = [:]
        let head = String(decoding: body[..<semicolon], as: UTF8.self)
        for pair in head.split(separator: ",") {
            guard let equals = pair.firstIndex(of: "="), pair.distance(from: pair.startIndex, to: equals) == 1 else { continue }
            keys[pair[pair.startIndex]] = pair[pair.index(after: equals)...]
        }
    }

    /// The first character of a key's value.
    func letter(_ key: Character) -> Character? { keys[key]?.first }

    /// A key's value as a number, or nil when it is missing or not a number. Values are capped so arithmetic on them
    /// cannot overflow.
    func number(_ key: Character) -> Int? {
        guard let value = keys[key], let n = Int(value) else { return nil }
        return min(max(n, -1_000_000_000), 4_000_000_000)
    }

    /// The action: `t` transmit, `T` transmit and display, `p` display, `d` delete, `q` query.
    var action: Character { letter("a") ?? "t" }
    /// More chunks of this transfer follow (`m=1`).
    var more: Bool { letter("m") == "1" }
    /// `q=1` hides OK replies, `q=2` hides errors too.
    var quiet: Int { number("q") ?? 0 }
}

/// Why a kitty graphics command failed, as the reply the program reads.
struct KittyError: Error, Equatable {
    let reply: String
    static let invalid = KittyError(reply: "EINVAL:the image data or its size is not valid")
    static let medium = KittyError(reply: "EINVAL:only direct transmission (t=d) is supported")
    static let tooLarge = KittyError(reply: "EFBIG:the image is larger than Gloamux shows")
    static let notFound = KittyError(reply: "ENOENT:no image with that id")
    static let action = KittyError(reply: "EINVAL:unsupported action")
    static let placeholders = KittyError(reply: "EINVAL:Unicode placeholders are not supported")
}

/// An image sent with the kitty protocol and kept until it is deleted or pushed out by newer ones.
struct KittyStoredImage {
    let content: TerminalImage.Content
    let width: Int, height: Int
    /// The `I=` number it was sent with, if any.
    let number: Int?
    var byteCount: Int { width * height * 4 }
}

/// Decoding for the kitty graphics protocol. The screen keeps the images and places them.
enum KittyGraphics {
    /// The longest kitty command kept, which holds a 10 MB file in base64 with room for its keys.
    static let maximumCommandLength = InlineImages.maximumFileBytes * 4 / 3 + 1024

    /// The pixels and size of the image in `data`, sent as `f=24` (RGB), `f=32` (RGBA, the default), or `f=100` (PNG),
    /// inflated first when `compressed` (`o=z`).
    static func decode(format: Int, width: Int?, height: Int?, compressed: Bool, data input: Data) throws
        -> (content: TerminalImage.Content, width: Int, height: Int) {
        let side = InlineImages.maximumSixelSide
        switch format {
        case 24, 32:
            let channels = format / 8
            guard let width, let height, width > 0, height > 0 else { throw KittyError.invalid }
            guard width <= side, height <= side else { throw KittyError.tooLarge }
            let expected = width * height * channels
            let data = compressed ? try inflate(input, limit: expected) : input
            guard data.count == expected else { throw KittyError.invalid }
            if channels == 4 { return (.rgba([UInt8](data), width: width, height: height), width, height) }
            var pixels = [UInt8](repeating: 0xFF, count: width * height * 4)
            data.withUnsafeBytes { (rgb: UnsafeRawBufferPointer) in
                for index in 0..<(width * height) {
                    pixels[index * 4] = rgb[index * 3]; pixels[index * 4 + 1] = rgb[index * 3 + 1]; pixels[index * 4 + 2] = rgb[index * 3 + 2]
                }
            }
            return (.rgba(pixels, width: width, height: height), width, height)
        case 100:
            let data = compressed ? try inflate(input, limit: InlineImages.maximumFileBytes) : input
            guard let size = InlineImages.pixelSize(of: data) else { throw KittyError.invalid }
            guard size.width <= side, size.height <= side else { throw KittyError.tooLarge }
            return (.encoded(data), size.width, size.height)
        default:
            throw KittyError.invalid
        }
    }

    /// Inflates zlib data (RFC 1950), refusing anything that would be larger than `limit` bytes.
    static func inflate(_ data: Data, limit: Int) throws -> Data {
        let bytes = [UInt8](data)
        // A zlib header: deflate (CM 8), a valid check value, and no preset dictionary.
        guard bytes.count > 2, bytes[0] & 0x0F == 8, (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) % 31 == 0, bytes[1] & 0x20 == 0 else {
            throw KittyError.invalid
        }
        // The decoder reads raw deflate and stops at its last block, so the Adler-32 trailer is left unread.
        var output = [UInt8](repeating: 0, count: limit + 1)
        let written = bytes.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                compression_decode_buffer(target.baseAddress!, target.count, source.baseAddress! + 2, source.count - 2, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw KittyError.invalid }
        guard written <= limit else { throw KittyError.tooLarge }
        return Data(output[..<written])
    }

    /// The part of an image inside the rectangle the `x`, `y`, `w`, and `h` keys give in pixels. A missing or zero
    /// width or height runs to the image's edge.
    static func crop(_ image: (content: TerminalImage.Content, width: Int, height: Int), x: Int, y: Int, width: Int, height: Int)
        -> (content: TerminalImage.Content, width: Int, height: Int)? {
        let left = min(max(x, 0), image.width), top = min(max(y, 0), image.height)
        let w = min(width > 0 ? width : image.width - left, image.width - left)
        let h = min(height > 0 ? height : image.height - top, image.height - top)
        guard w > 0, h > 0 else { return nil }
        if left == 0, top == 0, w == image.width, h == image.height { return image }
        switch image.content {
        case .rgba(let pixels, let fullWidth, _):
            var result = [UInt8](); result.reserveCapacity(w * h * 4)
            for row in top..<(top + h) {
                let start = (row * fullWidth + left) * 4
                result.append(contentsOf: pixels[start..<(start + w * 4)])
            }
            return (.rgba(result, width: w, height: h), w, h)
        case .encoded(let data):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let picture = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let part = picture.cropping(to: CGRect(x: left, y: top, width: w, height: h)) else { return nil }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, part, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return (.encoded(png as Data), w, h)
        }
    }

    /// The cells an image covers: `c` columns and `r` rows when both are given (the image is stretched to fill them),
    /// one of them with the other following the image's proportions, or one pixel per point by default.
    static func cells(width: Int, height: Int, columns c: Int?, rows r: Int?, cell: (width: Double, height: Double))
        -> (columns: Int, rows: Int, stretches: Bool) {
        let w = Double(width), h = Double(height)
        func up(_ value: Double) -> Int { max(1, Int(min(value, 100_000).rounded(.up))) }
        switch (c.flatMap { $0 > 0 ? $0 : nil }, r.flatMap { $0 > 0 ? $0 : nil }) {
        case let (columns?, rows?): return (min(columns, 100_000), min(rows, 1000), true)
        case let (columns?, nil): return (min(columns, 100_000), min(up(Double(columns) * cell.width * h / w / cell.height), 1000), false)
        case let (nil, rows?): return (up(Double(rows) * cell.height * w / h / cell.width), min(rows, 1000), false)
        case (nil, nil): return (up(w / cell.width), min(up(h / cell.height), 1000), false)
        }
    }
}
