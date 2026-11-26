import SwiftUI
import AppKit
import CoreText
import Terminal
import Formats

struct TerminalDisplay: NSViewRepresentable {
    @ObservedObject var tab: SessionTab
    /// Redraws for new output without the views around it.
    @ObservedObject private var output: TerminalOutput
    @ObservedObject var model: WorkspaceModel
    /// False for a recording being played back: it keeps the size it was recorded at.
    var resizes = true
    @AppStorage(TerminalPreferences.fontKey) private var fontName = ""
    @AppStorage(TerminalPreferences.fontSizeKey) private var fontSize = TerminalPreferences.defaultFontSize
    @AppStorage(TerminalPreferences.cursorKey) private var cursorSetting = CursorShape.block.rawValue
    @AppStorage(TerminalPreferences.blinkKey) private var blinkSetting = false
    @AppStorage(TerminalPreferences.opacityKey) private var opacity = 1.0
    @AppStorage(TerminalPreferences.mouseKey) private var reportsMouse = true
    @AppStorage(TerminalPreferences.lineSpacingKey) private var lineSpacing = 1.0
    @AppStorage(TerminalPreferences.characterSpacingKey) private var characterSpacing = 1.0
    @AppStorage(TerminalPreferences.ligaturesKey) private var ligatures = false
    @AppStorage(TerminalPreferences.minimumContrastKey) private var minimumContrast = 1.0

    init(tab: SessionTab, model: WorkspaceModel, resizes: Bool = true) {
        self.tab = tab; self.model = model; self.resizes = resizes
        output = tab.output
    }

    final class Coordinator {
        var revision = -1
        var styleKey = ""
        var request = -1
        var cursorVisible = false
        /// The rows and attributed lines on screen, reused for rows that have not changed.
        var rows: [[Cell]] = []
        var lines: [NSAttributedString] = []
        var cursorLine: Int?
        var navigation: UUID?
        var search: TerminalSearch?
        var searchedRevision = -1
        var flash = 0
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        // Rows never exceed the terminal width, so there is no horizontal scroller, and the vertical one
        // is an overlay that only appears while scrolling.
        let scroll = TerminalScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.drawsBackground = true
        let text = TerminalTextView(); text.isEditable = true; text.isSelectable = true
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isContinuousSpellCheckingEnabled = false; text.allowsUndo = false
        text.isRichText = false; text.isVerticallyResizable = true; text.isHorizontallyResizable = true
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: 100000, height: CGFloat.greatestFiniteMagnitude)
        // The padding above and below lies outside the scrolling area (see TerminalScrollView), so scrollback never
        // shows through it.
        text.textContainerInset = NSSize(width: 18, height: 0)
        // Lay out only the visible part of a long scrollback.
        text.layoutManager?.allowsNonContiguousLayout = true
        text.input = { bytes in model.typeTerminal(tab, bytes: bytes) }
        if resizes { text.sizeChanged = { rows, cols in model.resizeTerminal(tab, rows: rows, columns: cols) } }
        text.openLink = { [weak tab] link in TerminalLinks.open(link, local: tab?.isLocal ?? false) }
        scroll.documentView = text
        scroll.lineHeight = text.fonts.lineHeight
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? TerminalTextView else { return }
        ViewEvaluations.note("TerminalDisplay")
        let coordinator = context.coordinator
        let screen = tab.screen
        view.input = { bytes in model.typeTerminal(tab, bytes: bytes) }
        view.reply = { bytes in model.sendTerminal(tab, bytes: bytes) }
        view.selectionLinesChanged = { [weak tab] lines in if tab?.selectedLines != lines { tab?.selectedLines = lines } }
        view.closeRequest = model.tabs.contains { $0.id == tab.id } ? { [weak model, weak tab] in
            guard let model, let tab else { return }
            model.requestClose(tab)
        } : nil
        view.sizeChanged = resizes ? { rows, cols in model.resizeTerminal(tab, rows: rows, columns: cols) } : nil
        view.onFocus = { [weak model, weak tab] in
            guard let model, let tab, model.split?.contains(tab.id) == true, model.selection != tab.id else { return }
            model.selectTab(tab.id, focusTerminal: false)
        }
        if coordinator.request != tab.terminalFocusRequest {
            coordinator.request = tab.terminalFocusRequest
            DispatchQueue.main.async { [weak model, weak tab, weak view] in
                guard let model, let tab, let view else { return }
                let workspaceTab = model.tabs.contains { $0.id == tab.id }
                if !workspaceTab || model.selection == tab.id { view.window?.makeFirstResponder(view) }
            }
        }
        if let request = tab.navigation, coordinator.navigation != request.nonce {
            coordinator.navigation = request.nonce
            DispatchQueue.main.async { [weak view] in view?.perform(request.action, marks: screen.commandMarks, trimmed: screen.trimmedLines) }
        }
        let fonts = TerminalFonts.make(name: fontName, size: min(max(fontSize, TerminalPreferences.fontSizes.lowerBound), TerminalPreferences.fontSizes.upperBound),
                                       lineSpacing: lineSpacing, characterSpacing: characterSpacing, ligatures: ligatures)
        view.fonts = fonts
        (scroll as? TerminalScrollView)?.lineHeight = fonts.lineHeight
        view.screen = screen
        view.lineTime = { [weak tab] index in tab.flatMap { $0.lineTimes.time(of: screen.trimmedLines + index) } }
        view.showsTimestamps = tab.showsTimestamps
        screen.cellSize = (Double(fonts.cellWidth), Double(fonts.lineHeight))
        view.firstLine = screen.trimmedLines
        view.images = screen.images.filter { $0.alternate == screen.usingAlternate }
        // Copy mode starts and ends outside the view update, so the tab can follow at once.
        view.copyModeEnded = { [weak tab] in if tab?.copyMode == true { tab?.copyMode = false } }
        if tab.copyMode != (view.copyMode != nil) {
            DispatchQueue.main.async { [weak view, weak tab] in
                guard let view, let tab else { return }
                if tab.copyMode { view.startCopyMode() } else { view.endCopyMode(copying: false) }
            }
        }
        view.applicationCursorKeys = screen.applicationCursorKeys
        view.bracketedPaste = screen.bracketedPaste
        view.reportsMouse = reportsMouse && resizes
        view.inputEnabled = tab.terminalReady
        let theme = model.theme
        let cursorVisible = tab.terminalReady && screen.cursorVisible
        let alpha = min(max(opacity, 0.3), 1)
        let contrast = TerminalPreferences.clamp(minimumContrast, TerminalPreferences.contrasts)
        let styleKey = "\(theme.id)|\(fonts.key)|\(alpha)|\(contrast)"
        let background = tab.colorScheme.map { nsColor($0.background) } ?? theme.terminalBackground.nsColor
        let updateCursor = { [cursorSetting, blinkSetting] (view: TerminalTextView) in
            view.updateCursor(shape: screen.cursorShape ?? CursorShape(rawValue: cursorSetting) ?? .block,
                              blinks: screen.cursorBlinks ?? blinkSetting, color: theme.cursor.nsColor, visible: cursorVisible,
                              background: background)
        }
        let changed = coordinator.revision != tab.screenRevision || coordinator.styleKey != styleKey || coordinator.cursorVisible != cursorVisible
        if view.selectingWithMouse {
            // The text, its scroll position, and the cursor on it wait for the button: see `selectingWithMouse`. Nothing
            // is redrawn meanwhile, so the latest update still sees every change since the last redraw.
            view.heldUpdate = { [weak view, weak scroll] in
                guard let view, let scroll else { return }
                if changed {
                    redraw(view, scroll: scroll, coordinator: coordinator, fonts: fonts, background: background, alpha: alpha,
                           styleKey: styleKey, cursorVisible: cursorVisible)
                }
                updateCursor(view)
            }
        } else {
            if changed {
                redraw(view, scroll: scroll, coordinator: coordinator, fonts: fonts, background: background, alpha: alpha, styleKey: styleKey,
                       cursorVisible: cursorVisible)
            }
            updateCursor(view)
        }
        if tab.bellFlash != coordinator.flash {
            coordinator.flash = tab.bellFlash
            (scroll as? TerminalScrollView)?.flash()
        }
        updateSearch(view, coordinator: coordinator)
    }

    private func redraw(_ view: TerminalTextView, scroll: NSScrollView, coordinator: Coordinator, fonts: TerminalFonts, background: NSColor,
                        alpha: Double, styleKey: String, cursorVisible: Bool) {
        let theme = model.theme
        let foreground = tab.colorScheme.map { nsColor($0.text) } ?? theme.terminalForeground.nsColor
        let ansi: [NSColor]
        if let scheme = tab.colorScheme {
            ansi = (scheme.normal + scheme.bold).map(nsColor)
        } else {
            ansi = (0..<16).map { theme.terminalANSI($0).nsColor }
        }
        let screen = tab.screen
        let rows = screen.scrollback + (0..<screen.rows).map { row in (0..<screen.cols).map { screen.cell(row: row, col: $0) } }
        let cursorLine = screen.scrollback.count + screen.cursorRow
        if coordinator.styleKey != styleKey { coordinator.rows = []; coordinator.lines = []; coordinator.cursorLine = nil }

        // Rows only change at the bottom, and scrollback drops lines from the top once it is full.
        // Find how many old lines fell off the top, then reuse every unchanged row after that.
        let old = coordinator.rows
        var dropped = 0
        if let firstRow = rows.first, !old.isEmpty, old[0] != firstRow {
            dropped = old.indices.dropFirst().prefix(screen.scrollback.count).first { old[$0] == firstRow } ?? old.count
        }
        let oldCursor = coordinator.cursorLine.map { $0 - dropped }
        var renderer = TerminalLineRenderer(background: background, foreground: foreground, ansi: ansi, color: color,
                                            link: { screen.link($0) }, fonts: fonts,
                                            minimumContrast: TerminalPreferences.clamp(minimumContrast, TerminalPreferences.contrasts))
        var lines: [NSAttributedString] = []; lines.reserveCapacity(rows.count)
        var firstChanged = rows.count
        for (index, row) in rows.enumerated() {
            let oldIndex = dropped + index
            let isCursorLine = index == cursorLine || index == oldCursor
            if !isCursorLine, oldIndex < old.count, old[oldIndex] == row {
                lines.append(coordinator.lines[oldIndex]); continue
            }
            firstChanged = min(firstChanged, index)
            let line = renderer.line(row, cursorColumn: index == cursorLine ? screen.cursorCol : nil, cursorColor: nil)
            if let highlights = tab.highlights {
                for match in highlights.matches(in: line.string).matches {
                    let keyword = highlights.keywords[match.keyword]
                    let range = NSRange(location: match.start, length: match.length)
                    if let rgb = highlights.color(index: keyword.textColorIndex) { line.addAttribute(.foregroundColor, value: nsColor(rgb), range: range) }
                    if !keyword.termBackColor, let rgb = highlights.color(index: keyword.backColorIndex) { line.addAttribute(.backgroundColor, value: nsColor(rgb), range: range) }
                    if keyword.bold { line.addAttribute(.font, value: fonts.bold, range: range) }
                }
            }
            lines.append(line)
        }
        if rows.count != old.count - dropped { firstChanged = min(firstChanged, min(rows.count, max(old.count - dropped, 0))) }
        // Below full opacity the window's blurred background shows through the terminal's own color.
        view.drawsBackground = true
        view.backgroundColor = background.withAlphaComponent(alpha)
        scroll.drawsBackground = alpha >= 1
        scroll.backgroundColor = view.backgroundColor
        view.selectedTextAttributes = [.backgroundColor: theme.selection.nsColor]
        // Read before the new lines make the view taller.
        let wasAtBottom = view.showsScreenBottom
        view.showTerminalLines(lines, dropped: dropped, firstChanged: firstChanged, cursorLine: cursorLine,
                               cursorColumnOffset: renderer.lastCursorOffset)
        coordinator.rows = rows; coordinator.lines = lines; coordinator.cursorLine = cursorLine
        coordinator.styleKey = styleKey
        coordinator.cursorVisible = cursorVisible
        if coordinator.revision != tab.screenRevision {
            coordinator.revision = tab.screenRevision
            // Follow new output while the bottom is in sight, as other terminals do, even with text selected: scrolling
            // up into the scrollback, or a search result, keeps the view where it is. Typing follows the output always.
            // The view keeps the whole screen in sight, not just the cursor's row: a program that parks the cursor near
            // the top, such as top, or a prompt after clear, still shows the screen.
            if view.followsNextUpdate || (wasAtBottom && !view.hasFindResult) {
                view.followsNextUpdate = false
                view.scrollToScreen()
            }
        }
    }

    /// Runs the find bar's search: again when the text, the pattern, or the options change, and one step for Find Next or Previous.
    private func updateSearch(_ view: TerminalTextView, coordinator: Coordinator) {
        guard let search = tab.search else {
            if coordinator.search != nil { view.clearFind(); coordinator.search = nil }
            return
        }
        let previous = coordinator.search
        let patternChanged = previous?.query != search.query || previous?.regex != search.regex || previous?.caseSensitive != search.caseSensitive
        let moved = previous?.move != search.move
        let contentChanged = coordinator.searchedRevision != tab.screenRevision
        guard patternChanged || moved || contentChanged else { return }
        coordinator.search = search
        coordinator.searchedRevision = tab.screenRevision
        let report: (TerminalSearchStatus) -> Void = { [weak tab] status in
            DispatchQueue.main.async { if let tab, tab.searchStatus != status { tab.searchStatus = status } }
        }
        if patternChanged { report(view.find(search, mode: .latest)) }
        else if moved { report(view.find(search, mode: search.backwards ? .previous : .next)) }
        else { view.refreshFind(search, report: report) }
    }

    private func nsColor(_ rgb: RGB) -> NSColor { Self.nsColor(rgb) }
    fileprivate static func nsColor(_ rgb: RGB) -> NSColor { NSColor(srgbRed: Double(rgb.red)/255, green: Double(rgb.green)/255, blue: Double(rgb.blue)/255, alpha: 1) }
    private var color: (TerminalColor, NSColor, [NSColor]) -> NSColor { Self.color }
    static func color(_ value: TerminalColor, fallback: NSColor, ansi: [NSColor]) -> NSColor {
        switch value {
        case .default: return fallback
        case .rgb(let rgb): return nsColor(rgb)
        case .indexed(let index):
            let n = Int(index)
            if n < 16 { return ansi[n] }
            if n >= 232 { return NSColor(white: Double(8 + (n-232)*10)/255, alpha: 1) }
            let i = n - 16, levels = [0.0, 95, 135, 175, 215, 255]
            return NSColor(srgbRed: levels[i/36]/255, green: levels[(i/6)%6]/255, blue: levels[i%6]/255, alpha: 1)
        }
    }
}


/// The remote PTY owns echo, line editing and history. Local edits never modify its transcript.
final class TerminalTextView: NSTextView {
    var input: (([UInt8]) -> Void)?
    /// Sends bytes that are not typing, such as focus and mouse reports, to this terminal only.
    var reply: (([UInt8]) -> Void)?
    /// ⌘W while the terminal has the keyboard: closes its tab (asking first when that ends a session).
    var closeRequest: (() -> Void)?
    /// Called with the number of lines in the selection when it changes.
    var selectionLinesChanged: ((Int) -> Void)?
    private var reportedSelectionLines = 0
    var onFocus: (() -> Void)?
    /// Opens a link under a ⌘-click. Returns false when the link is not allowed.
    var openLink: ((String) -> Bool)?
    var sizeChanged: ((Int, Int) -> Void)?
    var inputEnabled = false
    var applicationCursorKeys = false
    var bracketedPaste = false
    var reportsMouse = true
    weak var screen: TerminalScreen?
    var fonts = TerminalFonts.standard {
        didSet {
            guard fonts != oldValue else { return }
            // A new cell size changes how many rows and columns fit.
            lastSize = .zero
            needsLayout = true
        }
    }
    private(set) var terminalInsertionRange = NSRange(location: 0, length: 0)
    /// Set by typing, so the next update follows the output even with text selected.
    var followsNextUpdate = false
    private var lastSize = NSSize.zero

    /// Scrolls to the bottom, where the terminal's screen fills the view.
    func scrollToScreen() {
        guard let storage = textStorage, let clip = enclosingScrollView?.contentView else { return }
        scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, frame.height - clip.bounds.height)))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// True when the screen's last row is in sight, give or take a line, so new output should keep it there.
    var showsScreenBottom: Bool {
        guard let clip = enclosingScrollView?.contentView else { return true }
        return clip.bounds.maxY >= frame.height - fonts.lineHeight * 1.5
    }

    /// Sends typing to the terminal and brings the screen back into view, as other terminals do.
    private func type(_ bytes: [UInt8]) {
        followsNextUpdate = true
        scrollToScreen()
        input?(bytes)
    }
    override var acceptsFirstResponder: Bool { true }
    override var shouldDrawInsertionPoint: Bool { false }
    // Dropping a tab on the terminal splits the pane, so the text view must not take drops itself.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }
    override func updateDragTypeRegistration() { unregisterDraggedTypes() }

    /// The selected text with recognized secrets removed, nil without a selection. Rows the terminal wrapped are joined
    /// and the text around the selection is read too, so a wrapped or partly selected secret is recognized.
    func redactedSelection() -> String? {
        let selection = selectedRange()
        guard selection.length > 0 else { return nil }
        let limit = 65_536
        let part = joinedText(near: selection, limit: limit)
        let end = NSMaxRange(selection), length = (string as NSString).length
        return SecretRedaction.redact(part(selection.location, end), before: part(max(0, selection.location - limit), selection.location),
                                      after: part(end, min(length, end + limit)))
    }

    /// What Copy puts on the clipboard, as iTerm2 copies: rows the terminal wrapped joined into one line, and the blank
    /// cells at the end of each line left out.
    func copiedSelection() -> String? {
        let selection = selectedRange()
        guard selection.length > 0 else { return nil }
        let text = joinedText(near: selection, limit: 0)(selection.location, NSMaxRange(selection))
        return text.components(separatedBy: "\n").map { line in
            var line = Substring(line)
            while line.last == " " { line.removeLast() }
            return String(line)
        }.joined(separator: "\n")
    }
    /// Where Copy and Paste go; tests use a private one.
    var pasteboard = NSPasteboard.general
    override func copy(_ sender: Any?) {
        guard let text = copiedSelection() else { return }
        PasteHistory.shared.add(text)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Reads text between two offsets with the line breaks of rows the terminal wrapped removed. Only breaks within
    /// `limit` characters of `selection` are checked.
    private func joinedText(near selection: NSRange, limit: Int) -> (Int, Int) -> String {
        let full = string as NSString
        var lineStart = 0, line = 0
        var wraps = IndexSet()
        while lineStart < full.length {
            let newline = full.range(of: "\n", range: NSRange(location: lineStart, length: full.length - lineStart))
            guard newline.location != NSNotFound else { break }
            // The view can be a moment behind the screen, so a row counts only while it still shows the same text.
            if let screen, newline.location + limit >= selection.location, newline.location <= NSMaxRange(selection) + limit,
               let cells = screen.row(absolute: screen.trimmedLines + line), cells.last?.wraps == true,
               String(cells.filter { $0.width != 0 }.map(\.character)) == full.substring(with: NSRange(location: lineStart, length: newline.location - lineStart)) {
                wraps.insert(newline.location)
            }
            lineStart = newline.location + 1
            line += 1
        }
        return { start, end in
            var text = "", position = start
            for newline in wraps.intersection(IndexSet(integersIn: start..<max(start, end))) {
                text += full.substring(with: NSRange(location: position, length: newline - position))
                position = newline + 1
            }
            return text + full.substring(with: NSRange(location: position, length: end - position))
        }
    }

    /// Double-click selects a word with the characters in Settings (iTerm2's by default) counted as part of one, so a
    /// path or a host name with dots and dashes is selected whole.
    override func selectionRange(forProposedRange proposedCharRange: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        guard granularity == .selectByWord, proposedCharRange.length <= 1 else {
            return super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
        }
        let text = string as NSString, words = TerminalPreferences.wordCharacters
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < text.length, let scalar = UnicodeScalar(text.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || words.unicodeScalars.contains(scalar)
        }
        let location = proposedCharRange.location
        guard isWord(location) else { return super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity) }
        var start = location, end = location + 1
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// UTF-16 length of each line on screen, so an update can find where its first changed line starts.
    private(set) var lineLengths: [Int] = []
    /// Terminal › Copy mode, while it is on, and what to do when it ends.
    var copyMode: TerminalCopyMode?
    var copyModeEnded: (() -> Void)?
    /// Terminal › Show timestamps, and when each line last changed by its index in the view.
    var showsTimestamps = false { didSet { if showsTimestamps != oldValue { needsDisplay = true } } }
    var lineTime: (Int) -> Date? = { _ in nil }
    /// Pictures from sixel and OSC 1337 on the screen being shown, and the absolute number of the view's first line.
    var images: [TerminalImage] = [] {
        didSet {
            guard images.map(\.id) != oldValue.map(\.id) || images.map(\.line) != oldValue.map(\.line) else { return }
            let kept = Set(images.map(\.id))
            decodedImages = decodedImages.filter { kept.contains($0.key) }
            needsDisplay = true
        }
    }
    var firstLine = 0
    var decodedImages: [Int: NSImage] = [:]

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if !images.isEmpty { drawImages(in: dirtyRect) }
        if showsTimestamps { drawTimestamps(in: dirtyRect) }
    }

    /// Draws each visible line's time at its right end, over the text, in the line's own height.
    private func drawTimestamps(in dirtyRect: NSRect) {
        guard let manager = layoutManager, let container = textContainer, !lineLengths.isEmpty else { return }
        let glyphs = manager.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y), in: container)
        guard glyphs.length > 0 else { return }
        var number = line(containing: manager.characterIndexForGlyph(at: glyphs.location))
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, fonts.regular.pointSize - 2), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let fill = (backgroundColor.usingColorSpace(.sRGB) ?? backgroundColor).withAlphaComponent(0.9)
        let now = Date()
        manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
            defer { number += 1 }
            guard let date = self.lineTime(number) else { return }
            let text = LineTimes.label(date, now: now) as NSString
            let size = text.size(withAttributes: attributes)
            let x = self.bounds.maxX - size.width - 10
            let y = rect.minY + self.textContainerOrigin.y + (rect.height - size.height) / 2
            fill.setFill()
            NSRect(x: x - 4, y: rect.minY + self.textContainerOrigin.y, width: size.width + 8, height: rect.height).fill()
            text.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
        }
    }

    /// Replaces only what changed: lines that scrolled off the top, then everything from the first
    /// changed line down. Untouched lines keep their layout, which keeps long scrollback cheap.
    func showTerminalLines(_ lines: [NSAttributedString], dropped: Int, firstChanged: Int, cursorLine: Int, cursorColumnOffset: Int?) {
        guard let storage = textStorage else { return }
        let selection = selectedRange()
        storage.beginEditing()
        var lengths = lineLengths
        var removedFromTop = 0
        if dropped > 0, dropped <= lengths.count {
            removedFromTop = lengths.prefix(dropped).reduce(0, +) + min(dropped, max(lengths.count - 1, 0))
            if dropped == lengths.count { removedFromTop = storage.length }
            storage.deleteCharacters(in: NSRange(location: 0, length: min(removedFromTop, storage.length)))
            lengths.removeFirst(dropped)
        } else if dropped > lengths.count {
            lengths = []
        }
        let kept = min(firstChanged, lengths.count, lines.count)
        let start = kept == 0 ? 0 : lengths.prefix(kept).reduce(0, +) + kept - 1
        let tail = NSMutableAttributedString()
        for index in kept..<lines.count {
            if index > 0 { tail.append(Self.newline) }
            tail.append(lines[index])
        }
        storage.replaceCharacters(in: NSRange(location: min(start, storage.length), length: storage.length - min(start, storage.length)), with: tail)
        storage.endEditing()
        lineLengths = lines.map(\.length)
        let cursorStart = lineLengths.prefix(min(cursorLine, lineLengths.count)).reduce(0, +) + min(cursorLine, lineLengths.count)
        terminalInsertionRange = NSRange(location: min(cursorStart + (cursorColumnOffset ?? lineLengths[safe: cursorLine] ?? 0), storage.length), length: 0)
        let shifted = NSRange(location: selection.location - removedFromTop, length: selection.length)
        setSelectedRange(selection.length > 0 && shifted.location >= 0 && NSMaxRange(shifted) <= storage.length ? shifted : terminalInsertionRange)
        findMatches = findMatches.compactMap { range in
            range.location - removedFromTop >= 0 ? NSRange(location: range.location - removedFromTop, length: range.length) : nil
        }
    }
    private static let newline = NSAttributedString(string: "\n")

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            DispatchQueue.main.async { [weak self] in self?.onFocus?() }
            if screen?.reportsFocus == true { reply?(Array("\u{1b}[I".utf8)) }
            DispatchQueue.main.async { [weak self] in self?.windowKeyChanged() }
        }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            if screen?.reportsFocus == true { reply?(Array("\u{1b}[O".utf8)) }
            DispatchQueue.main.async { [weak self] in self?.windowKeyChanged() }
        }
        return resigned
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: name, object: window)
        }
    }
    /// A solid cursor while this terminal has the keyboard; a hollow or dimmed one otherwise.
    @objc private func windowKeyChanged() {
        cursorView.focused = window?.isKeyWindow == true && window?.firstResponder === self
    }

    // MARK: Keyboard and paste

    override func keyDown(with event: NSEvent) {
        if copyMode != nil, !event.modifierFlags.contains(.command) { copyModeKey(event); return }
        guard inputEnabled else { return }
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        // Option as Meta: Option-key sends Escape and the key, for Emacs and readline word commands.
        if !hasMarkedText(), TerminalPreferences.optionIsMeta, event.modifierFlags.contains(.option),
           let bytes = TerminalKeyboard.metaBytes(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "",
                                                  control: event.modifierFlags.contains(.control),
                                                  applicationCursorKeys: applicationCursorKeys) {
            type(bytes); return
        }
        // While an input method is composing, every key belongs to it, Return and the arrows included.
        if !hasMarkedText(), let bytes = TerminalKeyboard.bytes(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "",
                                                              control: event.modifierFlags.contains(.control),
                                                              applicationCursorKeys: applicationCursorKeys,
                                                              shift: event.modifierFlags.contains(.shift),
                                                              option: event.modifierFlags.contains(.option)) {
            type(bytes); return
        }
        interpretKeyEvents([event])
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard inputEnabled else { return }
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        unmarkText(); type(Array(text.utf8))
    }
    /// Voice Control, dictation, and other assistive apps set the selected text or the whole value through
    /// accessibility. The transcript belongs to the remote program, so their text is typed into it instead.
    override func setAccessibilitySelectedText(_ text: String?) {
        guard inputEnabled, let text, !text.isEmpty else { return }
        type(Array(text.utf8))
    }
    override func setAccessibilityValue(_ value: Any?) { }
    override func cut(_ sender: Any?) { copy(sender) }
    override func paste(_ sender: Any?) {
        guard inputEnabled, let copied = pasteboard.string(forType: .string) else { return }
        let text = TerminalKeyboard.prepared(paste: copied, trims: TerminalPreferences.pasteTrims, joinsLines: TerminalPreferences.pasteJoinsLines)
        guard !text.isEmpty else { return }
        PasteHistory.shared.add(copied)
        if TerminalPreferences.confirmsMultilinePaste, TerminalKeyboard.isMultiline(text), let window {
            PastePreview.confirm(text, in: window) { [weak self] edited in self?.send(paste: edited) }
            return
        }
        send(paste: text)
    }
    private func send(paste text: String) {
        guard let bytes = TerminalKeyboard.pasteBytes(text, bracketed: bracketedPaste) else { NSSound.beep(); return }
        type(bytes)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": paste(nil); return true
            case "c", "x": copy(nil); return true
            case "a": selectAll(nil); return true
            case "w" where closeRequest != nil && event.modifierFlags.intersection([.shift, .option, .control]).isEmpty:
                closeRequest?(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    override func doCommand(by selector: Selector) { }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        let lines = Self.lineCount(of: selectedRanges.map(\.rangeValue), in: string as NSString)
        guard lines != reportedSelectionLines else { return }
        reportedSelectionLines = lines
        // Selection also changes while the text is rebuilt during a view update; report it afterwards.
        DispatchQueue.main.async { [weak self] in self?.selectionLinesChanged?(lines) }
    }

    /// Lines touched by the selected ranges; 0 with nothing selected.
    static func lineCount(of ranges: [NSRange], in text: NSString) -> Int {
        ranges.reduce(0) { total, range in
            guard range.length > 0, NSMaxRange(range) <= text.length else { return total }
            var lines = 0, index = range.location
            while index < NSMaxRange(range) {
                lines += 1
                index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            }
            return total + lines
        }
    }

    // MARK: Input method composition

    /// Text an input method is composing. It is drawn over the cursor and never enters the transcript.
    private var marked: NSAttributedString?
    private lazy var markedLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.drawsBackground = true
        label.isHidden = true
        addSubview(label)
        return label
    }()

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = text.isEmpty ? nil : NSAttributedString(string: text)
        showMarkedText()
    }
    override func unmarkText() {
        marked = nil
        showMarkedText()
    }
    override func hasMarkedText() -> Bool { marked != nil }
    override func markedRange() -> NSRange {
        guard let marked else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: terminalInsertionRange.location, length: marked.length)
    }
    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = cursorRect() ?? NSRect(x: textContainerInset.width, y: textContainerInset.height, width: fonts.cellWidth, height: fonts.lineHeight)
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }

    private func showMarkedText() {
        guard let marked, let rect = cursorRect() else {
            markedLabel.isHidden = true
            cursorView.isHidden = !cursorShown
            return
        }
        // The composition is drawn like the block cursor: the cursor color behind, the terminal background as text.
        markedLabel.backgroundColor = cursorView.color
        markedLabel.attributedStringValue = NSAttributedString(string: marked.string, attributes: [
            .font: fonts.regular, .foregroundColor: cursorView.textColor, .underlineStyle: NSUnderlineStyle.single.rawValue])
        markedLabel.sizeToFit()
        markedLabel.frame = NSRect(x: rect.minX, y: rect.minY, width: markedLabel.frame.width, height: rect.height)
        markedLabel.isHidden = false
        cursorView.isHidden = true
    }

    // MARK: Cursor

    private lazy var cursorView: TerminalCursorView = {
        let view = TerminalCursorView()
        addSubview(view)
        return view
    }()
    private var cursorShown = false

    /// Places the cursor over its cell. A block shows the character under it in the background color.
    func updateCursor(shape: CursorShape, blinks: Bool, color: NSColor, visible: Bool, background: NSColor) {
        cursorShown = visible
        guard visible, let rect = cursorRect() else { cursorView.isHidden = true; return }
        cursorView.focused = window?.isKeyWindow == true && window?.firstResponder === self
        let location = terminalInsertionRange.location
        var character = " ", under = background
        if let storage = textStorage, location < storage.length {
            let range = (storage.string as NSString).rangeOfComposedCharacterSequence(at: location)
            character = (storage.string as NSString).substring(with: range)
            if character == "\n" { character = " " }
            under = storage.attribute(.backgroundColor, at: location, effectiveRange: nil) as? NSColor ?? background
        }
        cursorView.update(frame: rect, shape: shape, color: color, textColor: under.withAlphaComponent(1),
                          character: NSAttributedString(string: character, attributes: [.font: fonts.regular, .foregroundColor: under.withAlphaComponent(1)]),
                          blinks: blinks)
        cursorView.isHidden = marked != nil
        if marked != nil { showMarkedText() }
    }

    /// The cell at the terminal cursor, in this view's coordinates.
    private func cursorRect() -> NSRect? {
        guard let storage = textStorage, let manager = layoutManager, let container = textContainer else { return nil }
        let origin = textContainerOrigin
        guard storage.length > 0 else {
            return NSRect(x: origin.x + container.lineFragmentPadding, y: origin.y, width: fonts.cellWidth, height: fonts.lineHeight)
        }
        let location = min(terminalInsertionRange.location, storage.length - 1)
        let character = (storage.string as NSString).rangeOfComposedCharacterSequence(at: location)
        manager.ensureLayout(forCharacterRange: character)
        let glyphs = manager.glyphRange(forCharacterRange: character, actualCharacterRange: nil)
        var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        if terminalInsertionRange.location >= storage.length || (storage.string as NSString).character(at: location) == 0x0A {
            rect.origin.x = terminalInsertionRange.location >= storage.length ? rect.maxX : rect.minX
            rect.size.width = fonts.cellWidth
        }
        rect.size.width = max(rect.width, fonts.cellWidth)
        return rect.offsetBy(dx: origin.x, dy: origin.y).integral
    }

    // MARK: Size

    /// Resizing the terminal redraws it and makes the shell repaint, so wait until the size settles:
    /// the end of a window resize, or a short pause while panes and sidebars move.
    private var pendingResize: DispatchWorkItem?
    override func layout() {
        super.layout()
        guard let viewport = enclosingScrollView?.contentView.bounds.size, viewport != lastSize else { return }
        lastSize = viewport
        pendingResize?.cancel()
        guard !inLiveResize else { return }
        // The scroll view makes the viewport a whole number of rows tall.
        let rows = Int((viewport.height / fonts.lineHeight + 0.01).rounded(.down)), cols = Int((viewport.width - 36) / fonts.cellWidth)
        let work = DispatchWorkItem { [weak self] in self?.sizeChanged?(max(5, rows), max(20, cols)) }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        lastSize = .zero
        needsLayout = true
    }

    // MARK: Mouse

    /// Whether mouse events go to the program instead of selecting text. Holding Option selects text anyway.
    func sendsMouse(_ event: NSEvent) -> Bool {
        reportsMouse && inputEnabled && (screen?.mouseTracking ?? .off) != .off && !event.modifierFlags.contains(.option)
    }

    /// The screen row and column under the pointer, or nil above the screen (in the scrollback).
    private func cell(at event: NSEvent) -> (row: Int, column: Int)? {
        guard let screen, let manager = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x; point.y -= textContainerOrigin.y
        let index = manager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        let line = line(containing: index)
        let row = line - (lineLengths.count - screen.rows)
        guard row >= 0, row < screen.rows else { return nil }
        let column = point.x < 0 ? 0 : screen.column(ofUTF16Offset: index - offset(ofLine: line), inRow: row)
        return (row, column)
    }

    private var lastReportedCell: (row: Int, column: Int)?
    private func report(_ button: TerminalScreen.MouseButton, _ action: TerminalScreen.MouseAction, _ event: NSEvent) {
        guard let screen, let cell = cell(at: event) else { return }
        if action == .drag || action == .move {
            if let last = lastReportedCell, last == cell { return }
        }
        lastReportedCell = cell
        let flags = event.modifierFlags
        if let bytes = screen.mouseReport(button, action, row: cell.row, column: cell.column,
                                          shift: flags.contains(.shift), control: flags.contains(.control)) {
            reply?(bytes)
        }
    }

    private var pressedButton: TerminalScreen.MouseButton?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let link = link(at: convert(event.locationInWindow, from: nil)) {
            if openLink?(link) != true { NSSound.beep() }
            return
        }
        window?.makeFirstResponder(self)
        if sendsMouse(event) { pressedButton = .left; report(.left, .press, event); return }
        selectingWithMouse = true
        super.mouseDown(with: event)
        selectingWithMouse = false
        // NSTextView tracks the drag inside mouseDown, so the selection is final here.
        selectionFinished()
        if let update = heldUpdate { heldUpdate = nil; update() }
    }
    /// True while the left button is down to select text. AppKit keeps where the button went down as a character
    /// offset and ends the selection under the pointer, so output must not change the text or scroll it until the
    /// button is up: a line moving under a plain click used to select it, and Copy on select copied it.
    private(set) var selectingWithMouse = false
    /// The latest view update that arrived while selecting, run once the button is up.
    var heldUpdate: (() -> Void)?
    /// After a mouse selection: an empty one returns to the cursor, and a real one is copied when Copy on select is on.
    func selectionFinished() {
        if selectedRange().length == 0 { setSelectedRange(terminalInsertionRange) }
        else if TerminalPreferences.copiesOnSelect { copy(nil) }
    }
    override func mouseDragged(with event: NSEvent) {
        if pressedButton != nil { report(pressedButton ?? .left, .drag, event); return }
        super.mouseDragged(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        if let button = pressedButton { pressedButton = nil; report(button, .release, event); return }
        super.mouseUp(with: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        if sendsMouse(event) { pressedButton = .right; report(.right, .press, event); return }
        // Right-click to paste, as in PuTTY. Control-click still shows the menu.
        if TerminalPreferences.rightClickPastes, !event.modifierFlags.contains(.control) { paste(nil); return }
        super.rightMouseDown(with: event)
    }
    override func rightMouseDragged(with event: NSEvent) {
        if pressedButton != nil { report(.right, .drag, event); return }
        super.rightMouseDragged(with: event)
    }
    override func rightMouseUp(with event: NSEvent) {
        if pressedButton == .right { pressedButton = nil; report(.right, .release, event); return }
        super.rightMouseUp(with: event)
    }
    override func otherMouseDown(with event: NSEvent) {
        if sendsMouse(event) { pressedButton = .middle; report(.middle, .press, event); return }
        if event.buttonNumber == 2, TerminalPreferences.middleClickPastes { window?.makeFirstResponder(self); paste(nil); return }
        super.otherMouseDown(with: event)
    }
    override func otherMouseUp(with event: NSEvent) {
        if pressedButton == .middle { pressedButton = nil; report(.middle, .release, event); return }
        super.otherMouseUp(with: event)
    }
    override func mouseMoved(with event: NSEvent) {
        if screen?.mouseTracking == .motion, sendsMouse(event) { report(.none, .move, event) }
        super.mouseMoved(with: event)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["terminal"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self,
                                       userInfo: ["terminal": true]))
    }

    private var wheelRemainder: CGFloat = 0
    /// With mouse reporting the wheel goes to the program. On the alternate screen without it (less, man, a pager in
    /// tmux), the wheel sends arrow keys, as other macOS terminals do.
    override func scrollWheel(with event: NSEvent) {
        guard let screen, inputEnabled, !event.modifierFlags.contains(.option),
              sendsMouse(event) || screen.usingAlternate else { super.scrollWheel(with: event); return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / fonts.lineHeight : event.scrollingDeltaY
        wheelRemainder += delta
        let steps = Int(wheelRemainder.rounded(.towardZero))
        guard steps != 0 else { return }
        wheelRemainder -= CGFloat(steps)
        for _ in 0..<min(abs(steps), 10) {
            if sendsMouse(event) { report(steps > 0 ? .wheelUp : .wheelDown, .press, event) }
            else { reply?(screen.cursorKey(steps > 0 ? "A" : "B")) }
        }
        lastReportedCell = nil
    }

    // MARK: Find

    private(set) var findMatches: [NSRange] = []
    private var findIndex = -1
    private var pendingFindRefresh: DispatchWorkItem?
    var hasFindResult: Bool { findIndex >= 0 && findIndex < findMatches.count }
    static let maximumFindMatches = 10_000
    private static let matchColor = NSColor.systemYellow.withAlphaComponent(0.35)
    private static let currentMatchColor = NSColor.systemOrange.withAlphaComponent(0.75)

    enum FindMode { case latest, next, previous, refresh }

    /// Highlights every match and moves to one: the latest for a new search, then up or down for Find Previous and Find Next.
    @discardableResult func find(_ search: TerminalSearch, mode: FindMode) -> TerminalSearchStatus {
        pendingFindRefresh?.cancel()
        guard let storage = textStorage, let manager = layoutManager else { return TerminalSearchStatus() }
        let full = NSRange(location: 0, length: storage.length)
        manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        let previous = hasFindResult ? findMatches[findIndex] : nil
        findMatches = []; findIndex = -1
        guard !search.query.isEmpty else { return TerminalSearchStatus() }
        let pattern = search.regex ? search.query : NSRegularExpression.escapedPattern(for: search.query)
        guard let expression = try? NSRegularExpression(pattern: pattern, options: search.caseSensitive ? [] : [.caseInsensitive]) else {
            return TerminalSearchStatus(invalid: true)
        }
        var capped = false
        expression.enumerateMatches(in: storage.string, range: full) { match, _, stop in
            guard let range = match?.range, range.length > 0 else { return }
            findMatches.append(range)
            if findMatches.count >= Self.maximumFindMatches { capped = true; stop.pointee = true }
        }
        guard !findMatches.isEmpty else { return TerminalSearchStatus(capped: capped) }
        switch mode {
        case .latest: findIndex = findMatches.count - 1
        case .refresh:
            let location = previous?.location ?? Int.max
            findIndex = findMatches.firstIndex { $0.location >= location } ?? findMatches.count - 1
        case .next, .previous:
            let location = previous?.location ?? storage.length
            if mode == .next { findIndex = findMatches.firstIndex { $0.location > location } ?? 0 }
            else { findIndex = findMatches.lastIndex { $0.location < location } ?? findMatches.count - 1 }
        }
        for range in findMatches { manager.addTemporaryAttribute(.backgroundColor, value: Self.matchColor, forCharacterRange: range) }
        let current = findMatches[findIndex]
        manager.addTemporaryAttribute(.backgroundColor, value: Self.currentMatchColor, forCharacterRange: current)
        if mode != .refresh {
            scrollRangeToVisible(current)
            showFindIndicator(for: current)
        }
        return TerminalSearchStatus(current: findIndex + 1, total: findMatches.count, capped: capped)
    }

    /// Searches again a moment after new output, so a busy terminal is not searched for every chunk.
    func refreshFind(_ search: TerminalSearch, report: @escaping (TerminalSearchStatus) -> Void) {
        pendingFindRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            report(self.find(search, mode: .refresh))
        }
        pendingFindRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func clearFind() {
        pendingFindRefresh?.cancel()
        if let storage = textStorage {
            layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        }
        findMatches = []; findIndex = -1
        window?.makeFirstResponder(self)
    }

    // MARK: Links and prompt navigation

    private func link(at point: NSPoint) -> String? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = characterIndexForInsertion(at: point)
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            if let link = storage.attribute(TerminalLinks.attribute, at: candidate, effectiveRange: nil) as? String { return link }
        }
        return nil
    }

    /// The character offset where a text line starts.
    private func offset(ofLine line: Int) -> Int {
        let line = max(0, min(line, lineLengths.count))
        return lineLengths.prefix(line).reduce(0, +) + line
    }

    private func line(containing offset: Int) -> Int {
        var start = 0
        for (index, length) in lineLengths.enumerated() {
            if offset <= start + length { return index }
            start += length + 1
        }
        return max(0, lineLengths.count - 1)
    }

    /// The first line in view, or the end when the view follows the bottom, so ⌘↑ first finds the latest prompt.
    private func referenceLine() -> Int {
        guard let scroll = enclosingScrollView, let manager = layoutManager, let container = textContainer else { return lineLengths.count }
        let visible = scroll.contentView.bounds
        if visible.maxY >= bounds.maxY - fonts.lineHeight { return lineLengths.count }
        let y = max(0, visible.minY - textContainerInset.height + 1)
        let glyph = manager.glyphIndex(for: NSPoint(x: 1, y: y), in: container)
        return line(containing: manager.characterIndexForGlyph(at: glyph))
    }

    private func scroll(toLine line: Int) {
        guard let manager = layoutManager, let container = textContainer, let storage = textStorage else { return }
        let start = min(offset(ofLine: line), storage.length)
        let character = NSRange(location: start, length: start < storage.length ? 1 : 0)
        manager.ensureLayout(forCharacterRange: character)
        let glyphs = manager.glyphRange(forCharacterRange: character, actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        scroll(NSPoint(x: 0, y: max(0, rect.minY + textContainerInset.height - 4)))
    }

    private func range(lines: Range<Int>) -> NSRange {
        let start = offset(ofLine: lines.lowerBound)
        let end = max(start, offset(ofLine: lines.upperBound) - 1)
        return NSRange(location: start, length: min(end, textStorage?.length ?? 0) - start)
    }

    /// Jumps between prompts and selects output, from marks whose lines are absolute.
    func perform(_ action: TerminalNavigation, marks: [CommandMark], trimmed: Int) {
        let prompts = marks.map { $0.promptLine - trimmed }.filter { $0 >= 0 && $0 < lineLengths.count }
        switch action {
        case .previousPrompt, .nextPrompt:
            let reference = referenceLine()
            let target = action == .previousPrompt ? prompts.last { $0 < reference } : prompts.first { $0 > reference }
            guard let target else { NSSound.beep(); return }
            scroll(toLine: target)
            showFindIndicator(for: range(lines: target..<(target + 1)))
        case .selectLastOutput:
            guard let mark = marks.last(where: { $0.outputLine != nil && $0.endLine != nil }),
                  let output = mark.outputLine.map({ $0 - trimmed }), let end = mark.endLine.map({ $0 - trimmed }),
                  output >= 0, end > output else { NSSound.beep(); return }
            let selection = range(lines: output..<min(end, lineLengths.count))
            window?.makeFirstResponder(self)
            setSelectedRange(selection)
            scroll(toLine: max(0, output - 1))
        case .lines(let first, let through):
            let start = first - trimmed
            guard start >= 0, start < lineLengths.count else { NSSound.beep(); return }
            scroll(toLine: start)
            if let through {
                let end = min(through - trimmed, lineLengths.count)
                if end > start { window?.makeFirstResponder(self); setSelectedRange(range(lines: start..<end)) }
            } else {
                showFindIndicator(for: range(lines: start..<(start + 1)))
            }
        }
    }
}

public enum TerminalKeyboard {
    /// Whether pasted text holds more than one line, ignoring one final line break.
    static func isMultiline(_ text: String) -> Bool {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasSuffix("\n") { text.removeLast() }
        return text.contains("\n") || text.contains("\r")
    }

    /// Pasted text with the spaces and line breaks around it left out, and its line breaks turned into spaces, as
    /// Settings asks.
    static func prepared(paste text: String, trims: Bool, joinsLines: Bool) -> String {
        var text = text
        if trims { text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if joinsLines {
            text = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }
        return text
    }

    static func pasteBytes(_ text: String, bracketed: Bool) -> [UInt8]? {
        var payload = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r")
        if bracketed {
            // An embedded escape must not allow pasted text to close the bracket early.
            payload = payload.replacingOccurrences(of: "\u{1b}", with: "")
            payload = "\u{1b}[200~" + payload + "\u{1b}[201~"
        }
        guard payload.utf8.count <= 262_144 else { return nil }
        return Array(payload.utf8)
    }


    /// Option as Meta: Escape followed by what the key sends without Option.
    public static func metaBytes(keyCode: UInt16, characters: String, control: Bool, applicationCursorKeys: Bool = false) -> [UInt8]? {
        if let bytes = bytes(keyCode: keyCode, characters: characters, control: control, applicationCursorKeys: applicationCursorKeys) {
            return [0x1B] + bytes
        }
        guard !characters.isEmpty else { return nil }
        return [0x1B] + Array(characters.utf8)
    }

    /// What a key sends, as xterm and iTerm2 send it. Shift, Option, and Control on the cursor, editing, and function keys
    /// add xterm's modifier parameter (2 Shift, 3 Option, 5 Control, and their sums), as in `ESC [1;5D` for Control-←.
    public static func bytes(keyCode: UInt16, characters: String, control: Bool, applicationCursorKeys: Bool = false,
                             shift: Bool = false, option: Bool = false) -> [UInt8]? {
        if control, let value = characters.lowercased().unicodeScalars.first?.value, (0x40...0x7f).contains(value) || value == 0x20 { return [UInt8(value & 0x1f)] }
        // Control with a digit or a symbol, as xterm and iTerm2 send them: ⌃2 NUL, ⌃6 RS, ⌃- and ⌃/ US.
        if control, let byte = ["2": 0x00, "6": 0x1e, "-": 0x1f, "/": 0x1f][characters] as UInt8? { return [byte] }
        let modifier = 1 + (shift ? 1 : 0) + (option ? 2 : 0) + (control ? 4 : 0)
        /// `ESC [ 1 ; m X` with modifiers; otherwise `ESC O X` in application mode or `ESC [ X`.
        func cursor(_ final: String, application: Bool = applicationCursorKeys) -> String {
            modifier > 1 ? "\u{1b}[1;\(modifier)\(final)" : (application ? "\u{1b}O" : "\u{1b}[") + final
        }
        /// `ESC [ n ~`, or `ESC [ n ; m ~` with modifiers.
        func tilde(_ number: Int) -> String { modifier > 1 ? "\u{1b}[\(number);\(modifier)~" : "\u{1b}[\(number)~" }
        let value: String
        switch keyCode {
        case 36, 76: value = "\r"
        case 48: value = shift ? "\u{1b}[Z" : "\t"
        case 51: value = "\u{7f}"
        case 53: value = "\u{1b}"
        case 123: value = cursor("D")
        case 124: value = cursor("C")
        case 125: value = cursor("B")
        case 126: value = cursor("A")
        case 115: value = cursor("H")
        case 119: value = cursor("F")
        case 114: value = tilde(2)
        case 117: value = tilde(3)
        case 116: value = tilde(5)
        case 121: value = tilde(6)
        // F1 to F4 send SS3 P to S, as xterm does; with modifiers, CSI 1;m P to S.
        case 122: value = cursor("P", application: true)
        case 120: value = cursor("Q", application: true)
        case 99: value = cursor("R", application: true)
        case 118: value = cursor("S", application: true)
        case 96: value = tilde(15)
        case 97: value = tilde(17)
        case 98: value = tilde(18)
        case 100: value = tilde(19)
        case 101: value = tilde(20)
        case 109: value = tilde(21)
        case 103: value = tilde(23)
        case 111: value = tilde(24)
        default: return nil
        }
        return Array(value.utf8)
    }
}


/// A scroll view whose scrollers always overlay the text and fade out, whatever the system setting,
/// so no scroll bar appears in a terminal that is not being scrolled.
final class TerminalScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    /// Space above and below the text. It sits outside the clip view, so nothing scrolls through it.
    static let padding: CGFloat = 16

    /// The terminal's line height. The clip view is a whole number of lines tall, so at the bottom it shows exactly the
    /// screen's rows: no part of a scrollback line above them, and none of them cut off. What is left over goes below.
    var lineHeight: CGFloat = 0 {
        didSet { if lineHeight != oldValue { tile() } }
    }

    override func tile() {
        super.tile()
        let frame = contentView.frame
        guard frame.height > Self.padding * 2 else { return }
        let available = frame.height - Self.padding * 2
        let height = lineHeight > 0 ? max(lineHeight, (available / lineHeight).rounded(.down) * lineHeight) : available
        // The padding stays the same at the top; what is left over goes to the bottom.
        let y = isFlipped ? frame.minY + Self.padding : frame.maxY - Self.padding - height
        contentView.frame = NSRect(x: frame.minX, y: y, width: frame.width, height: height)
    }

    /// With a see-through background the scroll view does not paint it, so the padding is painted here like the text area.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !drawsBackground else { return }
        backgroundColor.setFill()
        let clip = contentView.frame
        NSBezierPath(rect: NSRect(x: bounds.minX, y: clip.maxY, width: bounds.width, height: bounds.maxY - clip.maxY)).fill()
        NSBezierPath(rect: NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: clip.minY - bounds.minY)).fill()
    }

    private lazy var flashView: NSView = {
        let view = NSView(frame: bounds)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        view.layer?.opacity = 0
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .above, relativeTo: nil)
        return view
    }()

    /// The visual bell: the terminal brightens and fades back in a fifth of a second, drawn by Core Animation.
    func flash() {
        flashView.frame = bounds
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 0.2
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flashView.layer?.add(animation, forKey: "bell")
    }
}

/// The terminal cursor, drawn over the text so its shape, focus, and blinking change without redrawing any lines.
final class TerminalCursorView: NSView {
    private(set) var shape = CursorShape.block
    private(set) var color = NSColor.white
    private(set) var textColor = NSColor.black
    private var character = NSAttributedString(string: " ")
    private var blinks = false
    var focused = true { didSet { if focused != oldValue { needsDisplay = true; updateBlink(restart: true) } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("TerminalCursorView is created in code.") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(frame newFrame: NSRect, shape: CursorShape, color: NSColor, textColor: NSColor, character: NSAttributedString, blinks: Bool) {
        let moved = newFrame != frame
        let changed = shape != self.shape || color != self.color || textColor != self.textColor || character != self.character
        if moved { frame = newFrame }
        self.shape = shape; self.color = color; self.textColor = textColor; self.character = character
        if changed || moved { needsDisplay = true }
        if blinks != self.blinks || moved { self.blinks = blinks; updateBlink(restart: moved) }
    }

    /// Blinking is a layer animation, so it costs no drawing. Moving the cursor shows it solid again, as typing does.
    private func updateBlink(restart: Bool) {
        guard let layer else { return }
        guard blinks && focused else { layer.removeAnimation(forKey: "blink"); return }
        if !restart, layer.animation(forKey: "blink") != nil { return }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 0]
        animation.keyTimes = [0, 0.5]
        animation.calculationMode = .discrete
        animation.duration = 1.06
        animation.repeatCount = .infinity
        animation.beginTime = CACurrentMediaTime() + 0.5
        animation.fillMode = .backwards
        layer.add(animation, forKey: "blink")
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = focused ? color : color.withAlphaComponent(0.6)
        switch shape {
        case .block:
            if focused {
                fill.setFill(); bounds.fill()
                character.draw(at: .zero)
            } else {
                fill.setStroke()
                let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); path.lineWidth = 1; path.stroke()
            }
        case .underline:
            fill.setFill(); NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
        case .bar:
            fill.setFill(); NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        }
    }
}

/// Asks before pasting more than one line, showing the text so it can be checked or edited first.
enum PastePreview {
    static func confirm(_ text: String, in window: NSWindow, paste: @escaping (String) -> Void) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).count
        let alert = NSAlert()
        alert.messageText = String(format: T("Paste %d lines?"), lines)
        alert.informativeText = T("Each line break can run a command. Check the text, or edit it here.")
        alert.addButton(withTitle: T("Paste"))
        alert.addButton(withTitle: T("Cancel"))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: scroll.bounds)
        editor.isRichText = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isContinuousSpellCheckingEnabled = false
        editor.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.string = text
        editor.autoresizingMask = [.width]
        scroll.documentView = editor
        alert.accessoryView = scroll
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            paste(editor.string)
        }
    }
}

/// Builds one attributed line per terminal row. Cells that share a style become a single run, and
/// fonts and attribute dictionaries are reused, so drawing costs a few allocations per style change
/// instead of one per cell.
struct TerminalLineRenderer {
    let background: NSColor
    let foreground: NSColor
    let ansi: [NSColor]
    let color: (TerminalColor, NSColor, [NSColor]) -> NSColor
    /// The target of an OSC 8 link index.
    let link: (UInt16) -> String?
    let fonts: TerminalFonts
    private var cache: [CellStyle: [NSAttributedString.Key: Any]] = [:]
    private let paragraph: NSParagraphStyle
    private struct SymbolKey: Hashable { let character: Character; let bold: Bool; let width: UInt8 }
    private var symbols: [SymbolKey: (font: NSFont, kern: CGFloat)] = [:]
    /// UTF-16 offset of the cursor within the last line built with a cursor column.
    private(set) var lastCursorOffset: Int?

    /// The lowest contrast ratio between text and its background; 1 leaves colors alone.
    let minimumContrast: Double

    init(background: NSColor, foreground: NSColor, ansi: [NSColor], color: @escaping (TerminalColor, NSColor, [NSColor]) -> NSColor,
         link: @escaping (UInt16) -> String? = { _ in nil }, fonts: TerminalFonts = .standard, minimumContrast: Double = 1) {
        self.background = background; self.foreground = foreground; self.ansi = ansi; self.color = color; self.link = link
        self.fonts = fonts; self.minimumContrast = minimumContrast
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = fonts.lineHeight
        paragraph.maximumLineHeight = fonts.lineHeight
        self.paragraph = paragraph
    }

    mutating func attributes(_ style: CellStyle) -> [NSAttributedString.Key: Any] {
        if let cached = cache[style] { return cached }
        // Bold text in one of the eight basic colors shows in its bright version, as xterm and iTerm2 do by default.
        var foregroundColor = style.foreground
        if style.bold, case .indexed(let index) = foregroundColor, index < 8 { foregroundColor = .indexed(index + 8) }
        var cellForeground = color(foregroundColor, foreground, ansi)
        var cellBackground = color(style.background, background, ansi)
        if style.inverse { swap(&cellForeground, &cellBackground) }
        // Faint text is drawn halfway to its background, as in xterm and iTerm2.
        var text = style.faint ? (cellForeground.blended(withFraction: 0.5, of: cellBackground) ?? cellForeground) : cellForeground
        if minimumContrast > 1 { text = Self.contrasting(text, on: cellBackground, ratio: minimumContrast) }
        let font = style.italic ? (style.bold ? fonts.boldItalic : fonts.italic) : (style.bold ? fonts.bold : fonts.regular)
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: style.invisible ? cellBackground : text,
            .font: font, .paragraphStyle: paragraph, .ligature: fonts.ligatures ? 1 : 0]
        if fonts.extraWidth != 0 { attributes[.kern] = fonts.extraWidth }
        if fonts.baselineOffset != 0 { attributes[.baselineOffset] = fonts.baselineOffset }
        if style.italic && fonts.slantsItalic { attributes[.obliqueness] = 0.2 }
        // The default background is the view's own, so it can be see-through; only colored cells paint their own.
        if style.background != .default || style.inverse { attributes[.backgroundColor] = cellBackground }
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if style.link != 0, let target = link(style.link) {
            attributes[TerminalLinks.attribute] = target
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
        }
        cache[style] = attributes
        return attributes
    }

    /// A private-use prompt icon still occupies the parser's cell width when its fallback font has different
    /// advances. Resolve the actual face explicitly: measuring the primary font would measure a missing glyph.
    /// WCAG relative luminance.
    static func luminance(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }
    static func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    /// The text color moved toward white or black, whichever the background allows more of, until it reaches `ratio`.
    static func contrasting(_ text: NSColor, on background: NSColor, ratio: Double) -> NSColor {
        guard contrast(text, background) < ratio else { return text }
        let target: NSColor = contrast(.white, background) >= contrast(.black, background) ? .white : .black
        var low = 0.0, high = 1.0
        for _ in 0..<12 {
            let middle = (low + high) / 2
            let candidate = text.blended(withFraction: middle, of: target) ?? target
            if contrast(candidate, background) >= ratio { high = middle } else { low = middle }
        }
        return text.blended(withFraction: high, of: target) ?? target
    }

    private mutating func symbol(_ cell: Cell) -> (font: NSFont, kern: CGFloat)? {
        // Private-use icons, and ambiguous-width characters drawn two cells wide, are spaced to fill their cells.
        guard let value = cell.character.unicodeScalars.first?.value,
              (0xE000...0xF8FF).contains(value) || (0xF0000...0xFFFFD).contains(value) || (0x100000...0x10FFFD).contains(value)
              || (cell.width == 2 && TerminalScreen.width(of: cell.character, ambiguousWide: false) == 1) else { return nil }
        let key = SymbolKey(character: cell.character, bold: cell.style.bold, width: cell.width)
        if let cached = symbols[key] { return cached }
        let text = String(cell.character) as NSString
        let base = cell.style.bold ? fonts.bold : fonts.regular
        let font = CTFontCreateForString(base as CTFont, text, CFRange(location: 0, length: text.length)) as NSFont
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text as String, attributes: [.font: font]))
        let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
        let metrics = (font: font, kern: CGFloat(cell.width) * fonts.cellWidth - CGFloat(advance))
        symbols[key] = metrics
        return metrics
    }

    mutating func line(_ cells: [Cell], cursorColumn: Int?, cursorColor: NSColor?) -> NSMutableAttributedString {
        let line = NSMutableAttributedString()
        var run = "", runStyle: CellStyle?, length = 0
        var cursor: NSRange?
        func flush() {
            guard let style = runStyle, !run.isEmpty else { return }
            line.append(NSAttributedString(string: run, attributes: attributes(style)))
            run = ""
        }
        for (column, cell) in cells.enumerated() where cell.width != 0 {
            let glyph = String(cell.character), glyphLength = glyph.utf16.count
            if let cursorColumn, (column..<(column + Int(cell.width))).contains(cursorColumn) {
                cursor = NSRange(location: length, length: glyphLength)
            }
            if let symbol = symbol(cell) {
                flush(); runStyle = nil
                var attributes = attributes(cell.style)
                attributes[.font] = symbol.font
                attributes[.kern] = symbol.kern
                line.append(NSAttributedString(string: glyph, attributes: attributes))
            } else if cell.width == 2 && fonts.extraWidth != 0 {
                // A wide character gets the extra space of both its cells.
                flush(); runStyle = nil
                var attributes = attributes(cell.style)
                attributes[.kern] = fonts.extraWidth * 2
                line.append(NSAttributedString(string: glyph, attributes: attributes))
            } else {
                if cell.style != runStyle { flush(); runStyle = cell.style }
                run += glyph
            }
            length += glyphLength
        }
        flush()
        // Plain web addresses can be ⌘-clicked too.
        for (range, target) in TerminalLinks.detect(in: line.string)
        where line.attribute(TerminalLinks.attribute, at: range.location, effectiveRange: nil) == nil {
            line.addAttribute(TerminalLinks.attribute, value: target, range: range)
        }
        if cursorColumn != nil { lastCursorOffset = cursor?.location ?? length }
        if let cursor, let cursorColor {
            let under = line.attribute(.backgroundColor, at: cursor.location, effectiveRange: nil) as? NSColor ?? background
            line.addAttributes([.backgroundColor: cursorColor, .foregroundColor: under], range: cursor)
        }
        return line
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
