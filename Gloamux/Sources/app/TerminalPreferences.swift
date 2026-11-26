import AppKit
import CoreText
import Foundation
import Terminal

/// What the + buttons open: a terminal on this Mac (the default), the New connection form, or a saved session.
/// Stored as "local", "form", or the saved session's ID.
enum NewTabChoice: Hashable {
    case local, form, saved(UUID)

    init(_ raw: String?) {
        switch raw {
        case "form": self = .form
        case let raw?: self = UUID(uuidString: raw).map(NewTabChoice.saved) ?? .local
        case nil: self = .local
        }
    }

    var raw: String {
        switch self {
        case .local: "local"
        case .form: "form"
        case .saved(let id): id.uuidString
        }
    }
}

/// Terminal settings shared by the Settings window, the terminal view, and the workspace.
enum TerminalPreferences {
    static let fontKey = "Gloamux.terminal.font"
    static let fontSizeKey = "Gloamux.terminal.fontSize"
    static let cursorKey = "Gloamux.terminal.cursor"
    static let blinkKey = "Gloamux.terminal.cursorBlinks"
    static let opacityKey = "Gloamux.terminal.opacity"
    static let scrollbackKey = "Gloamux.terminal.scrollback"
    static let bellKey = "Gloamux.terminal.bell"
    static let pasteKey = "Gloamux.terminal.confirmMultilinePaste"
    static let clipboardKey = "Gloamux.terminal.allowClipboardWrites"
    static let mouseKey = "Gloamux.terminal.mouseReporting"
    static let logKey = "Gloamux.terminal.logEverySession"
    static let logFormatKey = "Gloamux.terminal.logFormat"
    static let confirmCloseKey = "Gloamux.terminal.confirmClose"
    static let rightClickPasteKey = "Gloamux.terminal.rightClickPaste"
    static let optionMetaKey = "Gloamux.terminal.optionAsMeta"
    static let keepAliveKey = "Gloamux.ssh.keepAliveSeconds"
    static let terminalTypeKey = "Gloamux.terminal.type"
    static let terminalTypes = ["xterm-256color", "xterm", "screen-256color", "tmux-256color", "linux", "vt220", "vt100"]
    static let reconnectKey = "Gloamux.ssh.reconnect"
    static let newTabKey = "Gloamux.terminal.newTab"
    static let copyOnSelectKey = "Gloamux.terminal.copyOnSelect"
    static let middleClickPasteKey = "Gloamux.terminal.middleClickPaste"
    static let bellDockKey = "Gloamux.terminal.bellBouncesDock"
    static let ambiguousWideKey = "Gloamux.terminal.ambiguousWide"
    static let pasteTrimKey = "Gloamux.terminal.pasteTrims"
    static let lineSpacingKey = "Gloamux.terminal.lineSpacing"
    static let characterSpacingKey = "Gloamux.terminal.characterSpacing"
    static let ligaturesKey = "Gloamux.terminal.ligatures"
    static let inlineImagesKey = "Gloamux.terminal.inlineImages"
    static let zmodemKey = "Gloamux.terminal.zmodem"
    static let zmodemFolderKey = "Gloamux.terminal.zmodemFolder"
    static let minimumContrastKey = "Gloamux.terminal.minimumContrast"
    static let spacings = 0.8...2.0
    static let contrasts = 1.0...7.0
    static let pasteJoinKey = "Gloamux.terminal.pasteJoinsLines"
    static let wordCharactersKey = "Gloamux.terminal.wordCharacters"
    /// Characters iTerm2 counts as part of a word by default, besides letters and digits.
    static let defaultWordCharacters = "/-+\\~_."

    static let defaultFontSize = 13.0
    static let fontSizes = 6.0...72.0
    static let defaultScrollback = 5000
    static let scrollbackChoices = [1000, 5000, 10_000, 50_000]

    private static var defaults: UserDefaults { .standard }
    static var fontName: String { defaults.string(forKey: fontKey) ?? "" }
    static var fontSize: Double {
        let value = defaults.object(forKey: fontSizeKey) as? Double ?? defaultFontSize
        return min(max(value, fontSizes.lowerBound), fontSizes.upperBound)
    }
    static var cursor: CursorShape { defaults.string(forKey: cursorKey).flatMap(CursorShape.init(rawValue:)) ?? .block }
    static var cursorBlinks: Bool { defaults.bool(forKey: blinkKey) }
    /// What the + buttons open.
    static var newTab: NewTabChoice { NewTabChoice(defaults.string(forKey: newTabKey)) }
    static var opacity: Double { min(max(defaults.object(forKey: opacityKey) as? Double ?? 1, 0.3), 1) }
    static var scrollback: Int { defaults.object(forKey: scrollbackKey) as? Int ?? defaultScrollback }
    static var bell: BellStyle { defaults.string(forKey: bellKey).flatMap(BellStyle.init(rawValue:)) ?? .flash }
    static var confirmsMultilinePaste: Bool { defaults.object(forKey: pasteKey) as? Bool ?? true }
    static var allowsClipboardWrites: Bool { defaults.bool(forKey: clipboardKey) }
    static var reportsMouse: Bool { defaults.object(forKey: mouseKey) as? Bool ?? true }
    static var logsEverySession: Bool { defaults.bool(forKey: logKey) }
    static var confirmsClose: Bool { defaults.object(forKey: confirmCloseKey) as? Bool ?? true }
    static var rightClickPastes: Bool { defaults.bool(forKey: rightClickPasteKey) }
    static var optionIsMeta: Bool { defaults.bool(forKey: optionMetaKey) }
    /// Selecting text with the mouse copies it, as iTerm2 does.
    static var copiesOnSelect: Bool { defaults.bool(forKey: copyOnSelectKey) }
    /// The middle mouse button pastes, as in iTerm2 and Tabby.
    static var middleClickPastes: Bool { defaults.object(forKey: middleClickPasteKey) as? Bool ?? true }
    /// The bell bounces the Dock icon once while Gloamux is in the background.
    static var bellBouncesDock: Bool { defaults.object(forKey: bellDockKey) as? Bool ?? true }
    /// East Asian ambiguous-width characters, such as Greek, Cyrillic, box drawing, and ①, take two cells.
    static var ambiguousIsWide: Bool { defaults.bool(forKey: ambiguousWideKey) }
    /// Pasting leaves out spaces and line breaks around the text.
    static var pasteTrims: Bool { defaults.bool(forKey: pasteTrimKey) }
    /// Pasting turns line breaks into spaces, so the text arrives as one line.
    static var pasteJoinsLines: Bool { defaults.bool(forKey: pasteJoinKey) }
    /// Line height and cell width as a multiple of the font's own, as iTerm2's vertical and horizontal spacing.
    static var lineSpacing: Double { clamp(defaults.object(forKey: lineSpacingKey) as? Double ?? 1, spacings) }
    static var characterSpacing: Double { clamp(defaults.object(forKey: characterSpacingKey) as? Double ?? 1, spacings) }
    /// Fonts such as Fira Code join characters like -> and != into one symbol. Off by default, as in iTerm2 and Tabby.
    static var ligatures: Bool { defaults.bool(forKey: ligaturesKey) }
    /// Sixel and iTerm2 inline images; on unless turned off. Applies to terminals opened afterwards.
    static var inlineImages: Bool { defaults.object(forKey: inlineImagesKey) as? Bool ?? true }
    /// ZMODEM transfers start when sz or rz runs on the server; on unless turned off.
    static var zmodem: Bool { defaults.object(forKey: zmodemKey) as? Bool ?? true }
    /// Where files from sz are saved: the chosen folder, or Downloads.
    static var zmodemFolder: URL {
        if let path = defaults.string(forKey: zmodemFolderKey)?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }
    /// The lowest contrast ratio (WCAG, 1 to 7) between text and its background; 1 leaves colors as the theme sets them.
    static var minimumContrast: Double { clamp(defaults.object(forKey: minimumContrastKey) as? Double ?? 1, contrasts) }
    static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double { min(max(value, range.lowerBound), range.upperBound) }
    /// Characters a double-click selects as part of a word, besides letters and digits.
    static var wordCharacters: String { defaults.string(forKey: wordCharactersKey) ?? defaultWordCharacters }
    /// Seconds without output before a session is checked; 0 turns the check off.
    static var keepAliveInterval: Int { defaults.object(forKey: keepAliveKey) as? Int ?? 30 }
    /// TERM for SSH sessions.
    static var terminalType: String {
        defaults.string(forKey: terminalTypeKey).flatMap { terminalTypes.contains($0) ? $0 : nil } ?? "xterm-256color"
    }
    static var reconnects: Bool { defaults.object(forKey: reconnectKey) as? Bool ?? true }
    static var logFormat: TerminalLogFormat { defaults.string(forKey: logFormatKey).flatMap(TerminalLogFormat.init(rawValue:)) ?? .text }

    /// A screen for a new terminal, with the scrollback from Settings.
    static func newScreen() -> TerminalScreen {
        var options = TerminalOptions()
        options.scrollbackSize = scrollback
        options.cjkAmbiguousAsWide = ambiguousIsWide
        options.inlineImages = inlineImages
        return TerminalScreen(options: options)
    }

    /// Changes the font size by `step` points, or back to the default for 0. ⌘+, ⌘−, and ⌘0.
    static func zoom(_ step: Double) {
        let size = step == 0 ? defaultFontSize : min(max(fontSize + step, fontSizes.lowerBound), fontSizes.upperBound)
        defaults.set(size, forKey: fontSizeKey)
    }

    /// Fixed-pitch font families installed on this Mac, for the font picker.
    static func monospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            // The bundled fallback contains icons, not a complete text face.
            guard family != "Symbols Nerd Font Mono" else { return false }
            guard let member = manager.availableMembers(ofFontFamily: family)?.first, let name = member.first as? String,
                  let font = NSFont(name: name, size: 13) else { return false }
            return font.isFixedPitch && !family.hasPrefix(".")
        }.sorted()
    }
}

enum BellStyle: String, CaseIterable { case flash, sound, off }

enum TerminalLogFormat: String, CaseIterable { case text, raw }

/// The terminal font in regular, bold, italic, and bold italic, and the size of one cell. Built once per family, size,
/// spacing, and ligature setting.
struct TerminalFonts: Equatable {
    let regular: NSFont
    let bold: NSFont
    let italic: NSFont
    let boldItalic: NSFont
    /// The family has no italic face, so italic text is slanted instead, as iTerm2 does.
    let slantsItalic: Bool
    /// Space added after each cell for character spacing; wide characters get it twice.
    let extraWidth: CGFloat
    /// Raises text so extra line spacing is split above and below it.
    let baselineOffset: CGFloat
    /// Ligatures and contextual alternates are on.
    let ligatures: Bool
    let cellWidth: CGFloat
    let lineHeight: CGFloat
    let key: String

    private static var cache: [String: TerminalFonts] = [:]

    /// macOS deliberately falls back to LastResort for private-use characters unless a font is named explicitly.
    /// Keep this process-local and ship the symbols with the app, so a fresh Mac needs no system font installation.
    private static let symbols: NSFontDescriptor? = {
        guard let url = Bundle.module.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf") else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let font = NSFont(name: "SymbolsNFM", size: 13) else { return nil }
        return font.fontDescriptor.withSize(0)
    }()

    private static func withSymbols(_ font: NSFont) -> NSFont {
        guard let symbols else { return font }
        let existing = font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor] ?? []
        let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: [symbols] + existing])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// Turns off the ligatures and contextual alternates that fonts such as Fira Code use to join characters.
    private static func withoutLigatures(_ font: NSFont) -> NSFont {
        let off: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: kLigaturesType, .selectorIdentifier: kCommonLigaturesOffSelector],
            [.typeIdentifier: kLigaturesType, .selectorIdentifier: kRareLigaturesOffSelector],
            [.typeIdentifier: kContextualAlternatesType, .selectorIdentifier: kContextualAlternatesOffSelector],
        ]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: off])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    static var current: TerminalFonts { make(name: TerminalPreferences.fontName, size: TerminalPreferences.fontSize) }

    static func make(name: String, size: Double, lineSpacing: Double = TerminalPreferences.lineSpacing,
                     characterSpacing: Double = TerminalPreferences.characterSpacing,
                     ligatures: Bool = TerminalPreferences.ligatures) -> TerminalFonts {
        let lineSpacing = TerminalPreferences.clamp(lineSpacing, TerminalPreferences.spacings)
        let characterSpacing = TerminalPreferences.clamp(characterSpacing, TerminalPreferences.spacings)
        let key = "\(name)|\(size)|\(lineSpacing)|\(characterSpacing)|\(ligatures)"
        if let cached = cache[key] { return cached }
        let size = CGFloat(size)
        var regular = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        var bold = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        if !name.isEmpty, let font = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) {
            regular = font
            bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        var italic = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
        var boldItalic = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
        let slants = !NSFontManager.shared.traits(of: italic).contains(.italicFontMask)
        if slants { italic = regular; boldItalic = bold }
        // Converting to bold can discard the cascade, so add it after the text faces have been chosen.
        func prepared(_ font: NSFont) -> NSFont { withSymbols(ligatures ? font : withoutLigatures(font)) }
        regular = prepared(regular)
        bold = prepared(bold)
        italic = prepared(italic)
        boldItalic = prepared(boldItalic)
        let advance = ("M" as NSString).size(withAttributes: [.font: regular]).width
        let natural = NSLayoutManager().defaultLineHeight(for: regular)
        let lineHeight = lineSpacing == 1 ? natural : (natural * lineSpacing).rounded()
        let cellWidth = advance * characterSpacing
        let fonts = TerminalFonts(regular: regular, bold: bold, italic: italic, boldItalic: boldItalic, slantsItalic: slants,
                                  extraWidth: cellWidth - advance, baselineOffset: max(0, ((lineHeight - natural) / 2).rounded(.down)),
                                  ligatures: ligatures,
                                  cellWidth: cellWidth, lineHeight: lineHeight, key: key)
        cache[key] = fonts
        return fonts
    }

    static let standard = make(name: "", size: TerminalPreferences.defaultFontSize)
}

/// Removes escape sequences from terminal output for a plain-text log, across chunk boundaries.
struct EscapeStripper {
    private enum State { case text, escape, csi, string, stringEscape }
    private var state = State.text

    mutating func strip(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        for byte in bytes {
            switch state {
            case .text:
                switch byte {
                case 0x1B: state = .escape
                case 0x0D, 0x07, 0x00, 0x7F: break
                default: output.append(byte)
                }
            case .escape:
                switch byte {
                case 0x5B: state = .csi
                case 0x5D, 0x50, 0x5F, 0x5E, 0x58: state = .string
                case 0x20...0x2F: break
                default: state = .text
                }
            case .csi:
                if (0x40...0x7E).contains(byte) { state = .text }
            case .string:
                if byte == 0x07 { state = .text } else if byte == 0x1B { state = .stringEscape }
            case .stringEscape:
                state = byte == 0x5C ? .text : .string
            }
        }
        return output
    }
}

/// Writes one terminal's output to a log file as it arrives. Likely secrets are masked line by line; a private key
/// block is held until it ends so the whole block can be masked.
final class TerminalLogger {
    let url: URL
    private let handle: FileHandle
    private let format: TerminalLogFormat
    private var stripper = EscapeStripper()
    private var pending = ""
    private(set) var size = 0
    /// A log stops by itself at this size.
    static let limit = 256 * 1024 * 1024
    private static let heldLimit = 64 * 1024

    init(url: URL, title: String, format: TerminalLogFormat) throws {
        try writePrivate(Data(), to: url)
        handle = try FileHandle(forWritingTo: url)
        self.url = url
        self.format = format
        let formatter = ISO8601DateFormatter()
        if format == .text { write("# Gloamux log · \(title) · \(formatter.string(from: Date()))\n") }
    }

    /// Takes decoded UTF-8 output. Returns false once the log is full.
    func output(_ bytes: [UInt8]) -> Bool {
        let kept = format == .text ? stripper.strip(bytes) : bytes
        pending += String(decoding: kept, as: UTF8.self)
        flush(final: false)
        return size < Self.limit
    }

    func close() {
        flush(final: true)
        try? handle.close()
    }

    private func flush(final: Bool) {
        guard !pending.isEmpty else { return }
        var cut = pending.endIndex
        if !final {
            guard let newline = pending.lastIndex(of: "\n") else {
                guard pending.utf8.count > Self.heldLimit else { return }
                write(SecretRedaction.redact(pending)); pending = ""
                return
            }
            cut = pending.index(after: newline)
            // Hold an unfinished private key so the whole block is masked.
            let ready = pending[..<cut]
            if let begin = ready.range(of: "PRIVATE KEY-----", options: .backwards),
               ready[begin.upperBound...].range(of: "-----END") == nil, pending.utf8.count < Self.heldLimit {
                return
            }
        }
        write(SecretRedaction.redact(String(pending[..<cut])))
        pending = String(pending[cut...])
    }

    private func write(_ text: String) {
        let data = Data(text.utf8)
        size += data.count
        try? handle.write(contentsOf: data)
    }
}

/// Session logs for every terminal that has one open: started from the Terminal menu, or for every session when
/// that is turned on in Settings.
@MainActor final class TerminalLogs: ObservableObject {
    let folder: URL
    @Published private(set) var active: [UUID: TerminalLogger] = [:]

    init(folder: URL) { self.folder = folder }

    func isLogging(_ tab: SessionTab) -> Bool { active[tab.id] != nil }

    @discardableResult func start(_ tab: SessionTab) -> URL? {
        if let logger = active[tab.id] { return logger.url }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"; formatter.locale = Locale(identifier: "en_US_POSIX")
            let title = UIStrings.text(tab.title, language: UIStrings.language)
            let safe = String(title.map { "/:\\".contains($0) ? "_" : $0 }.prefix(60))
            let format = TerminalPreferences.logFormat
            var url = folder.appendingPathComponent("\(formatter.string(from: Date())) \(safe).\(format == .text ? "log" : "ansi.log")")
            var number = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(formatter.string(from: Date())) \(safe) \(number).\(format == .text ? "log" : "ansi.log")")
                number += 1
            }
            active[tab.id] = try TerminalLogger(url: url, title: title, format: format)
            tab.objectWillChange.send()
            return url
        } catch { return nil }
    }

    func output(_ tab: SessionTab, bytes: [UInt8]) {
        guard let logger = active[tab.id] else { return }
        if !logger.output(bytes) { stop(tab) }
    }

    func stop(_ tab: SessionTab) {
        guard let logger = active.removeValue(forKey: tab.id) else { return }
        logger.close()
        tab.objectWillChange.send()
    }

    func stopAll() {
        for logger in active.values { logger.close() }
        active = [:]
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
