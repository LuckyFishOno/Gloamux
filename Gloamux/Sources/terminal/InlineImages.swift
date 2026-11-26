import Foundation
import ImageIO

/// A picture a program showed in the terminal with the iTerm2 inline image protocol (OSC 1337 File) or with sixel
/// graphics. It covers a block of cells whose top row is an absolute line, so it scrolls with the text.
public struct TerminalImage: Sendable {
    public enum Content: Sendable {
        /// A PNG, JPEG, GIF, or other file ImageIO reads.
        case encoded(Data)
        /// Decoded sixel pixels, four bytes (RGBA) each, row by row.
        case rgba([UInt8], width: Int, height: Int)
    }
    public let id: Int
    public let content: Content
    /// The absolute line of the top row: it keeps counting as scrollback is trimmed, like `CommandMark` lines.
    public internal(set) var line: Int
    public let column: Int
    public let columns: Int, rows: Int
    /// Fills its cells exactly instead of keeping its proportions (`preserveAspectRatio=0`).
    public let stretches: Bool
    /// Shown on the alternate screen, which discards it when the program leaves.
    public let alternate: Bool

    /// Bytes once decoded, which is what the display keeps.
    let byteCount: Int
}

/// Size limits and parsing for the two image protocols. The screen places the result.
enum InlineImages {
    /// The largest image file accepted, decoded from base64.
    static let maximumFileBytes = 10 * 1_048_576
    /// The largest image, in pixels on either side.
    static let maximumSixelSide = 4096
    /// Kept images, newest last; the oldest go first past either limit. A file counts at four bytes a pixel, as decoded.
    static let maximumImages = 64
    static let maximumTotalBytes = 64 * 1_048_576

    /// The arguments of `File=` or `MultipartFile=`: `key=value` pairs separated by `;`.
    static func arguments(_ text: Substring) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: ";") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            result[String(pair[..<equals]).lowercased()] = String(pair[pair.index(after: equals)...])
        }
        return result
    }

    /// The pixel size ImageIO reads from a file's header, or nil when it is not an image.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    /// A `width=` or `height=` value in points: `N` cells, `Npx`, `N%` of the terminal, or nil for `auto`.
    static func length(_ value: String?, cell: Double, whole: Double) -> Double? {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty, value != "auto" else { return nil }
        if value.hasSuffix("px"), let n = Double(value.dropLast(2)), n > 0 { return n }
        if value.hasSuffix("%"), let n = Double(value.dropLast()), n > 0 { return whole * min(n, 100) / 100 }
        if let n = Double(value), n > 0 { return n * cell }
        return nil
    }

    /// The cells a picture of `pixels` covers, from the requested width and height. Without a requested size it is
    /// shown at one pixel per point, shrunk to fit the terminal's width.
    static func cells(pixels: (width: Int, height: Int), width: String?, height: String?, preserves: Bool,
                      cell: (width: Double, height: Double), columns: Int) -> (columns: Int, rows: Int) {
        let whole = cell.width * Double(columns), tall = cell.height * 1000
        let imageWidth = Double(pixels.width), imageHeight = Double(pixels.height)
        var w = length(width, cell: cell.width, whole: whole)
        var h = length(height, cell: cell.height, whole: cell.height * 24)
        switch (w, h) {
        case (nil, nil): w = imageWidth; h = imageHeight
        case (let w0?, nil): h = preserves ? w0 * imageHeight / imageWidth : imageHeight
        case (nil, let h0?): w = preserves ? h0 * imageWidth / imageHeight : imageWidth
        case (let w0?, let h0?):
            if preserves {
                let scale = min(w0 / imageWidth, h0 / imageHeight)
                w = imageWidth * scale; h = imageHeight * scale
            }
        }
        var finalWidth = w ?? imageWidth, finalHeight = h ?? imageHeight
        if finalWidth > whole {
            if preserves { finalHeight *= whole / finalWidth }
            finalWidth = whole
        }
        finalHeight = min(finalHeight, tall)
        return (max(1, Int((finalWidth / cell.width).rounded(.up))), max(1, Int((finalHeight / cell.height).rounded(.up))))
    }
}

/// Decodes sixel graphics: the data after `DCS P1;P2;P3 q` up to the string terminator.
struct SixelDecoder {
    private(set) var width = 0, height = 0
    private var stride = 0, capacityHeight = 0
    private var pixels: [UInt8] = []
    private var palette: [UInt32]
    private var color: UInt32
    private var x = 0, band = 0
    private var failed = false

    /// VT340 colors, which most sixel programs assume for the first sixteen registers.
    private static let vt340: [(Int, Int, Int)] = [(0, 0, 0), (20, 20, 80), (80, 13, 13), (20, 80, 20), (80, 20, 80), (20, 80, 80),
                                                   (80, 80, 20), (53, 53, 53), (26, 26, 26), (33, 33, 60), (60, 26, 26), (33, 60, 33),
                                                   (60, 33, 60), (33, 60, 60), (60, 60, 33), (80, 80, 80)]

    init() {
        palette = Array(repeating: Self.rgba(0, 0, 0), count: 256)
        for (index, value) in Self.vt340.enumerated() { palette[index] = Self.rgba(value.0, value.1, value.2) }
        color = palette[0]
    }

    /// The image, or nil when it is empty or larger than the limit.
    static func decode(_ data: ArraySlice<UInt8>) -> (pixels: [UInt8], width: Int, height: Int)? {
        var decoder = SixelDecoder()
        decoder.run(data)
        guard !decoder.failed, decoder.width > 0, decoder.height > 0 else { return nil }
        return (decoder.packed(), decoder.width, decoder.height)
    }

    private static func rgba(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        func scale(_ v: Int) -> UInt32 { UInt32(min(max(v, 0), 100) * 255 / 100) }
        return scale(r) << 24 | scale(g) << 16 | scale(b) << 8 | 0xFF
    }

    /// DEC hue puts blue at 0°, red at 120°, and green at 240°.
    private static func hls(_ hue: Int, _ lightness: Int, _ saturation: Int) -> UInt32 {
        let h = Double((hue + 240) % 360) / 360, l = Double(min(lightness, 100)) / 100, s = Double(min(saturation, 100)) / 100
        guard s > 0 else { let v = Int(l * 100); return rgba(v, v, v) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        func channel(_ t0: Double) -> Int {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            let v = t < 1.0 / 6 ? p + (q - p) * 6 * t : t < 0.5 ? q : t < 2.0 / 3 ? p + (q - p) * (2.0 / 3 - t) * 6 : p
            return Int((v * 100).rounded())
        }
        return rgba(channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
    }

    private mutating func run(_ data: ArraySlice<UInt8>) {
        var index = data.startIndex
        func number() -> Int? {
            var value: Int?
            while index < data.endIndex, (0x30...0x39).contains(data[index]) {
                value = min((value ?? 0) * 10 + Int(data[index] - 0x30), 1_000_000)
                index += 1
            }
            return value
        }
        func numbers() -> [Int] {
            var result = [number() ?? 0]
            while index < data.endIndex, data[index] == 0x3B { index += 1; result.append(number() ?? 0) }
            return result
        }
        while index < data.endIndex, !failed {
            let byte = data[index]
            index += 1
            switch byte {
            case 0x3F...0x7E: put(byte - 0x3F, count: 1)
            case 0x21: // ! repeat
                let count = number() ?? 1
                if index < data.endIndex, (0x3F...0x7E).contains(data[index]) { put(data[index] - 0x3F, count: max(1, count)); index += 1 }
            case 0x23: // # color
                let values = numbers()
                let register = min(max(values[0], 0), 255)
                if values.count >= 5 {
                    palette[register] = values[1] == 1 ? Self.hls(values[2], values[3], values[4]) : Self.rgba(values[2], values[3], values[4])
                }
                color = palette[register]
            case 0x22: // " raster attributes: Pan;Pad;Ph;Pv
                let values = numbers()
                if values.count >= 4 { reserve(width: values[2], height: values[3]) }
            case 0x24: x = 0 // $ graphics carriage return
            case 0x2D: x = 0; band += 1 // - next six rows
            default: break
            }
        }
    }

    private mutating func reserve(width w: Int, height h: Int) {
        guard w <= Self.maximumSide, h <= Self.maximumSide else { failed = true; return }
        guard w > stride || h > capacityHeight else { return }
        let newStride = max(stride, w, 64), newHeight = max(capacityHeight, h, 6)
        var grown = [UInt8](repeating: 0, count: newStride * newHeight * 4)
        for row in 0..<capacityHeight where stride > 0 {
            let from = row * stride * 4, to = row * newStride * 4
            grown.replaceSubrange(to..<(to + stride * 4), with: pixels[from..<(from + stride * 4)])
        }
        pixels = grown; stride = newStride; capacityHeight = newHeight
    }

    private static var maximumSide: Int { InlineImages.maximumSixelSide }

    private mutating func put(_ bits: UInt8, count: Int) {
        let top = band * 6
        let end = x + count
        guard end <= Self.maximumSide, top + 6 <= Self.maximumSide else { failed = true; return }
        if end > stride || top + 6 > capacityHeight {
            reserve(width: end > stride ? max(end, stride * 2) : stride, height: top + 6 > capacityHeight ? max(top + 6, capacityHeight * 2) : capacityHeight)
            if failed { return }
        }
        if bits != 0 {
            let r = UInt8(color >> 24), g = UInt8(color >> 16 & 0xFF), b = UInt8(color >> 8 & 0xFF)
            for bit in 0..<6 where bits & (1 << bit) != 0 {
                let row = top + bit
                var offset = (row * stride + x) * 4
                for _ in 0..<count {
                    pixels[offset] = r; pixels[offset + 1] = g; pixels[offset + 2] = b; pixels[offset + 3] = 0xFF
                    offset += 4
                }
                height = max(height, row + 1)
            }
        }
        x = end
        width = max(width, end)
    }

    /// The pixels with rows exactly `width` wide.
    private func packed() -> [UInt8] {
        if stride == width { return Array(pixels.prefix(width * height * 4)) }
        var result = [UInt8](); result.reserveCapacity(width * height * 4)
        for row in 0..<height { let from = row * stride * 4; result.append(contentsOf: pixels[from..<(from + width * 4)]) }
        return result
    }
}
