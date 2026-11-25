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
        text.textContainerInset = NSSize(width: 18, height: 16)
        // Lay out only the visible part of a long scrollback.
        text.layoutManager?.allowsNonContiguousLayout = true
        text.input = { bytes in model.typeTerminal(tab, bytes: bytes) }
        if resizes { text.sizeChanged = { rows, cols in model.resizeTerminal(tab, rows: rows, columns: cols) } }
        text.openLink = { [weak tab] link in TerminalLinks.open(link, local: tab?.isLocal ?? false) }
        scroll.documentView = text
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
        let fonts = TerminalFonts.make(name: fontName, size: min(max(fontSize, TerminalPreferences.fontSizes.lowerBound), TerminalPreferences.fontSizes.upperBound))
        view.fonts = fonts
        view.screen = screen
        view.applicationCursorKeys = screen.applicationCursorKeys
        view.bracketedPaste = screen.bracketedPaste
        view.reportsMouse = reportsMouse && resizes
        view.inputEnabled = tab.terminalReady
        let theme = model.theme
        let cursorVisible = tab.terminalReady && screen.cursorVisible
        let alpha = min(max(opacity, 0.3), 1)
        let styleKey = "\(theme.id)|\(fonts.key)|\(alpha)"
        let background = tab.colorScheme.map { nsColor($0.background) } ?? theme.terminalBackground.nsColor
        if coordinator.revision != tab.screenRevision || coordinator.styleKey != styleKey || coordinator.cursorVisible != cursorVisible {
            redraw(view, scroll: scroll, coordinator: coordinator, fonts: fonts, background: background, alpha: alpha, styleKey: styleKey,
                   cursorVisible: cursorVisible)
        }
        view.updateCursor(shape: screen.cursorShape ?? CursorShape(rawValue: cursorSetting) ?? .block,
                          blinks: screen.cursorBlinks ?? blinkSetting, color: theme.cursor.nsColor, visible: cursorVisible,
                          background: background)
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
                                            link: { screen.link($0) }, fonts: fonts)
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
        view.showTerminalLines(lines, dropped: dropped, firstChanged: firstChanged, cursorLine: cursorLine,
                               cursorColumnOffset: renderer.lastCursorOffset)
        coordinator.rows = rows; coordinator.lines = lines; coordinator.cursorLine = cursorLine
        coordinator.styleKey = styleKey
        coordinator.cursorVisible = cursorVisible
        if coordinator.revision != tab.screenRevision {
            coordinator.revision = tab.screenRevision
            // Stay on a search result or a selection instead of following new output.
            if view.selectedRange().length == 0 && !view.hasFindResult { view.scrollRangeToVisible(view.terminalInsertionRange) }
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
    private var lastSize = NSSize.zero
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
        let full = string as NSString
        let limit = 65_536
        var lineStart = 0, line = 0
        var wraps = IndexSet()
        while lineStart < full.length {
            let newline = full.range(of: "\n", range: NSRange(location: lineStart, length: full.length - lineStart))
            guard newline.location != NSNotFound else { break }
            // The view can be a moment behind the screen, so a row counts only while it still shows the same text.
            if let screen, newline.location + limit > selection.location, newline.location < NSMaxRange(selection) + limit,
               let cells = screen.row(absolute: screen.trimmedLines + line), cells.last?.wraps == true,
               String(cells.filter { $0.width != 0 }.map(\.character)) == full.substring(with: NSRange(location: lineStart, length: newline.location - lineStart)) {
                wraps.insert(newline.location)
            }
            lineStart = newline.location + 1
            line += 1
        }
        func part(_ start: Int, _ end: Int) -> String {
            var text = "", position = start
            for newline in wraps.intersection(IndexSet(integersIn: start..<end)) {
                text += full.substring(with: NSRange(location: position, length: newline - position))
                position = newline + 1
            }
            return text + full.substring(with: NSRange(location: position, length: end - position))
        }
        let end = NSMaxRange(selection)
        return SecretRedaction.redact(part(selection.location, end), before: part(max(0, selection.location - limit), selection.location),
                                      after: part(end, min(full.length, end + limit)))
    }

    /// UTF-16 length of each line on screen, so an update can find where its first changed line starts.
    private var lineLengths: [Int] = []

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
        guard inputEnabled else { return }
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        // Option as Meta: Option-key sends Escape and the key, for Emacs and readline word commands.
        if !hasMarkedText(), TerminalPreferences.optionIsMeta, event.modifierFlags.contains(.option),
           let bytes = TerminalKeyboard.metaBytes(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "",
                                                  control: event.modifierFlags.contains(.control),
                                                  applicationCursorKeys: applicationCursorKeys) {
            input?(bytes); return
        }
        // While an input method is composing, every key belongs to it, Return and the arrows included.
        if !hasMarkedText(), let bytes = TerminalKeyboard.bytes(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "",
                                                              control: event.modifierFlags.contains(.control),
                                                              applicationCursorKeys: applicationCursorKeys) {
            input?(bytes); return
        }
        interpretKeyEvents([event])
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard inputEnabled else { return }
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        unmarkText(); input?(Array(text.utf8))
    }
    override func cut(_ sender: Any?) { copy(sender) }
    override func paste(_ sender: Any?) {
        guard inputEnabled, let text = NSPasteboard.general.string(forType: .string) else { return }
        if TerminalPreferences.confirmsMultilinePaste, TerminalKeyboard.isMultiline(text), let window {
            PastePreview.confirm(text, in: window) { [weak self] edited in self?.send(paste: edited) }
            return
        }
        send(paste: text)
    }
    private func send(paste text: String) {
        guard let bytes = TerminalKeyboard.pasteBytes(text, bracketed: bracketedPaste) else { NSSound.beep(); return }
        input?(bytes)
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
        let rows = Int((viewport.height - 32) / fonts.lineHeight), cols = Int((viewport.width - 36) / fonts.cellWidth)
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
        super.mouseDown(with: event)
        if selectedRange().length == 0 { setSelectedRange(terminalInsertionRange) }
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

    public static func bytes(keyCode: UInt16, characters: String, control: Bool, applicationCursorKeys: Bool = false) -> [UInt8]? {
        if control, let value = characters.lowercased().unicodeScalars.first?.value, (0x40...0x7f).contains(value) || value == 0x20 { return [UInt8(value & 0x1f)] }
        let arrow = applicationCursorKeys ? "\u{1b}O" : "\u{1b}["
        let value: String
        switch keyCode {
        case 36, 76: value = "\r"
        case 48: value = "\t"
        case 51: value = "\u{7f}"
        case 53: value = "\u{1b}"
        case 123: value = arrow + "D"
        case 124: value = arrow + "C"
        case 125: value = arrow + "B"
        case 126: value = arrow + "A"
        case 115: value = "\u{1b}[H"
        case 119: value = "\u{1b}[F"
        case 116: value = "\u{1b}[5~"
        case 121: value = "\u{1b}[6~"
        case 117: value = "\u{1b}[3~"
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

    init(background: NSColor, foreground: NSColor, ansi: [NSColor], color: @escaping (TerminalColor, NSColor, [NSColor]) -> NSColor,
         link: @escaping (UInt16) -> String? = { _ in nil }, fonts: TerminalFonts = .standard) {
        self.background = background; self.foreground = foreground; self.ansi = ansi; self.color = color; self.link = link
        self.fonts = fonts
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = fonts.lineHeight
        paragraph.maximumLineHeight = fonts.lineHeight
        self.paragraph = paragraph
    }

    mutating func attributes(_ style: CellStyle) -> [NSAttributedString.Key: Any] {
        if let cached = cache[style] { return cached }
        var cellForeground = color(style.foreground, foreground, ansi)
        var cellBackground = color(style.background, background, ansi)
        if style.inverse { swap(&cellForeground, &cellBackground) }
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: style.invisible ? cellBackground : cellForeground,
            .font: style.bold ? fonts.bold : fonts.regular, .paragraphStyle: paragraph]
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
    private mutating func symbol(_ cell: Cell) -> (font: NSFont, kern: CGFloat)? {
        guard let value = cell.character.unicodeScalars.first?.value,
              (0xE000...0xF8FF).contains(value) || (0xF0000...0xFFFFD).contains(value) || (0x100000...0x10FFFD).contains(value) else { return nil }
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
