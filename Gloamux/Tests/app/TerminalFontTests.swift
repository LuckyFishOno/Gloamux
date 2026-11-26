import AppKit
import CoreText
import Terminal
import XCTest
@testable import App

/// Prompt symbols must work with the default font on a Mac with no Nerd Font installed, and their fallback
/// metrics must not move the text, cursor, or subsequent rows away from the terminal's cell grid.
@MainActor final class TerminalFontTests: XCTestCase {
    private let symbols = "\u{E0A0}\u{E0B0}\u{E0B2}\u{F015}\u{F017}\u{F179}\u{F0001}"

    override func setUp() { _ = NSApplication.shared }

    func testDefaultRegularAndBoldFontsResolveNerdSymbols() {
        let fonts = TerminalFonts.make(name: "", size: 13)
        for base in [fonts.regular, fonts.bold, fonts.italic, fonts.boldItalic] {
            for character in symbols {
                let text = String(character) as NSString
                let actual = CTFontCreateForString(base as CTFont, text, CFRange(location: 0, length: text.length))
                let name = CTFontCopyPostScriptName(actual) as String
                XCTAssertFalse(name.contains("LastResort"), "\(base.fontName) could not display \(text)")
                XCTAssertEqual(CTFontCopyFamilyName(actual) as String, "Symbols Nerd Font Mono", "Use the shipped symbol font, not unrelated CJK private-use glyphs")
            }
        }
        XCTAssertEqual(fonts.regular.familyName, NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).familyName)
    }

    func testFallbackSymbolsKeepEveryCellAndTheCursorAligned() {
        for size in [13.0, 20.0] {
            let fonts = TerminalFonts.make(name: "", size: size)
            for bold in [false, true] {
                var style = CellStyle(); style.bold = bold
                let text = "M" + symbols + "M"
                let cells = cells(text, style: style)
                var renderer = renderer(fonts)
                let line = renderer.line(cells, cursorColumn: cells.count - 1, cursorColor: nil)
                let (storage, manager, container) = layout(line)
                manager.ensureLayout(for: container)
                for (column, character) in text.enumerated() {
                    let offset = String(text.prefix(column)).utf16.count
                    let glyph = manager.glyphIndexForCharacter(at: offset)
                    XCTAssertEqual(manager.location(forGlyphAt: glyph).x, CGFloat(column) * fonts.cellWidth,
                                   accuracy: 0.02, "\(character), size \(size), bold \(bold)")
                    XCTAssertNotEqual(manager.cgGlyph(at: glyph), 0)
                    let actual = storage.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
                    XCTAssertFalse(actual?.fontName.contains("LastResort") ?? true)
                }
                XCTAssertEqual(renderer.lastCursorOffset, text.utf16.count - 1)
            }
        }
    }

    func testSymbolRowsKeepTheSameHeightAsOrdinaryRows() {
        let fonts = TerminalFonts.make(name: "", size: 13)
        var renderer = renderer(fonts)
        let text = NSMutableAttributedString()
        for row in ["M", symbols, "M", "中文"] {
            if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(renderer.line(cells(row), cursorColumn: nil, cursorColor: nil))
        }
        let (storage, manager, container) = layout(text)
        manager.ensureLayout(for: container)
        var origins: [CGFloat] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { rect, _, _, _, _ in
            origins.append(rect.minY)
        }
        XCTAssertEqual(origins.count, 4)
        for index in origins.indices.dropFirst() {
            XCTAssertEqual(origins[index] - origins[index - 1], fonts.lineHeight, accuracy: 0.02)
        }
        XCTAssertEqual(storage.string, text.string)
    }

    func testColoredLeftAndRightPromptsRedrawWithoutChangingTheirCells() {
        var options = TerminalOptions(); options.rows = 4; options.cols = 60
        let screen = TerminalScreen(options: options)
        for n in 0..<12 {
            // zsh redraws a prompt in place: carriage return, clear the line, left prompt, right prompt, return to input.
            screen.feed("\r\u{1b}[2K\u{1b}[1;32m\u{E0A0} ~ \u{E0B0}\u{1b}[0m\u{1b}[45G\u{F017} 09:51:\(String(format: "%02d", n))\r\u{1b}[6C")
        }
        XCTAssertEqual(screen.cursorRow, 0)
        XCTAssertEqual(screen.cursorCol, 6)
        XCTAssertTrue(screen.lineText(0).hasSuffix("\u{F017} 09:51:11"))
        XCTAssertTrue(screen.lines.dropFirst().allSatisfy(\.isEmpty))
        XCTAssertTrue(screen.unsupported.isEmpty)
        var renderer = renderer(.standard)
        let line = renderer.line((0..<screen.cols).map { screen.cell(row: 0, col: $0) }, cursorColumn: screen.cursorCol, cursorColor: nil)
        let (storage, manager, container) = layout(line)
        manager.ensureLayout(for: container)
        let glyph = manager.glyphIndexForCharacter(at: renderer.lastCursorOffset!)
        XCTAssertEqual(manager.location(forGlyphAt: glyph).x, 6 * TerminalFonts.standard.cellWidth, accuracy: 0.02)
        XCTAssertEqual(storage.string, line.string)
    }

    func testCustomTextFontsKeepTheirFaceAndOrdinaryUnicodeFallback() {
        let fonts = TerminalFonts.make(name: "Menlo", size: 17)
        for font in [fonts.regular, fonts.bold, fonts.italic, fonts.boldItalic] {
            XCTAssertEqual(font.familyName, "Menlo")
            for character in "中🐟✔" {
                let text = String(character) as NSString
                let actual = CTFontCreateForString(font as CTFont, text, CFRange(location: 0, length: text.length))
                XCTAssertFalse((CTFontCopyPostScriptName(actual) as String).contains("LastResort"))
                XCTAssertNotEqual(CTFontCopyFamilyName(actual) as String, "Symbols Nerd Font Mono")
            }
        }
        XCTAssertFalse(TerminalPreferences.monospacedFamilies().contains("Symbols Nerd Font Mono"), "Icons alone are not a text font")
    }

    func testAnExplicitlyWideSymbolKeepsItsTwoCells() {
        let fonts = TerminalFonts.standard
        var cells = cells("M\u{E0B0} M")
        cells[1].width = 2; cells[2].width = 0
        var renderer = renderer(fonts)
        let line = renderer.line(cells, cursorColumn: 3, cursorColor: nil)
        let (storage, manager, container) = layout(line)
        manager.ensureLayout(for: container)
        let glyph = manager.glyphIndexForCharacter(at: renderer.lastCursorOffset!)
        XCTAssertEqual(manager.location(forGlyphAt: glyph).x, 3 * fonts.cellWidth, accuracy: 0.02)
        XCTAssertEqual(storage.string, "M\u{E0B0}M")
    }

    private func renderer(_ fonts: TerminalFonts) -> TerminalLineRenderer {
        TerminalLineRenderer(background: .black, foreground: .white, ansi: Array(repeating: .gray, count: 16),
                             color: { _, fallback, _ in fallback }, fonts: fonts)
    }

    private func cells(_ text: String, style: CellStyle = CellStyle()) -> [Cell] {
        text.map { var cell = Cell.blank; cell.character = $0; cell.style = style; return cell }
    }

    private func layout(_ text: NSAttributedString) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100000, height: 100000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        return (storage, manager, container)
    }
}
