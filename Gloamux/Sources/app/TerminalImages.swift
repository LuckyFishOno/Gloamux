import AppKit
import Terminal

/// Draws the pictures programs showed with sixel or the iTerm2 inline image protocol over the cells they cover.
extension TerminalTextView {
    func drawImages(in dirtyRect: NSRect) {
        guard let manager = layoutManager, let container = textContainer, !lineLengths.isEmpty else { return }
        let left = textContainerOrigin.x + container.lineFragmentPadding
        var starts: [Int] = [], offset = 0
        starts.reserveCapacity(lineLengths.count)
        for length in lineLengths { starts.append(offset); offset += length + 1 }
        for image in images {
            let index = image.line - firstLine
            guard index + image.rows > 0, index < starts.count else { continue }
            // A picture whose top scrolled out of the kept lines is drawn from where that line would be.
            let anchor = max(0, index)
            let glyph = manager.glyphIndexForCharacter(at: min(starts[anchor], max(0, (textStorage?.length ?? 1) - 1)))
            let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let top = fragment.minY + textContainerOrigin.y - CGFloat(anchor - index) * fonts.lineHeight
            let box = NSRect(x: left + CGFloat(image.column) * fonts.cellWidth, y: top,
                             width: CGFloat(image.columns) * fonts.cellWidth, height: CGFloat(image.rows) * fonts.lineHeight)
            guard box.intersects(dirtyRect), let picture = decoded(image) else { continue }
            var target = box
            if !image.stretches, picture.size.width > 0, picture.size.height > 0 {
                let scale = min(box.width / picture.size.width, box.height / picture.size.height)
                target.size = NSSize(width: picture.size.width * scale, height: picture.size.height * scale)
            }
            picture.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
    }

    private func decoded(_ image: TerminalImage) -> NSImage? {
        if let cached = decodedImages[image.id] { return cached }
        let picture: NSImage?
        switch image.content {
        case .encoded(let data): picture = NSImage(data: data)
        case .rgba(let pixels, let width, let height):
            let provider = CGDataProvider(data: Data(pixels) as CFData)
            picture = provider.flatMap {
                CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                        provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }.map { NSImage(cgImage: $0, size: NSSize(width: width, height: height)) }
        }
        decodedImages[image.id] = picture
        return picture
    }
}
