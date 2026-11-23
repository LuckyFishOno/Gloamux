import SwiftUI
import AppKit

/// The size of the app's own text: lists, forms, toolbars, and Settings. Sessions keep their own font size.
///
/// macOS does not scale SwiftUI's text styles with Dynamic Type, so views name their fonts with `appFont(_:)`, which
/// sizes them from the scale each window puts in its environment with `appTextSize()`.
enum AppTextSize {
    static let key = "Gloamux.app.fontSize"
    static let defaultSize = 13.0
    static let sizes = 10.0...20.0

    static var size: Double {
        let value = UserDefaults.standard.object(forKey: key) as? Double ?? defaultSize
        return clamped(value)
    }

    static func clamped(_ value: Double) -> Double { min(max(value, sizes.lowerBound), sizes.upperBound) }

    /// Changes the size by `step` points, or back to the default for 0.
    static func zoom(_ step: Double) {
        UserDefaults.standard.set(step == 0 ? defaultSize : clamped(size + step), forKey: key)
    }

    /// ⌘+, ⌘−, and ⌘0: the session's font while working in its terminal, and the app's text everywhere else.
    @MainActor static func zoomFocused(_ step: Double, window: NSWindow? = NSApp.keyWindow) {
        if inSession(window) { TerminalPreferences.zoom(step) } else { zoom(step) }
    }

    /// Whether the user is working in a session's terminal: it has the keyboard, and the last click or typing in
    /// the window was there. Clicking the sidebar, the tab bar, or a toolbar leaves the terminal with the keyboard,
    /// as those do not take it, but the user has moved on from the session.
    @MainActor static func inSession(_ window: NSWindow?) -> Bool {
        guard let window, window.firstResponder is TerminalTextView else { return false }
        return Activity.lastWindow !== window || Activity.lastInSession
    }

    /// Where the user last clicked or typed, watched app-wide from the first window on.
    @MainActor enum Activity {
        private(set) static weak var lastWindow: NSWindow?
        private(set) static var lastInSession = false
        private static var monitor: Any?

        static func watch() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { event in
                MainActor.assumeIsolated { note(event) }
                return event
            }
        }

        static func note(_ event: NSEvent) {
            guard let window = event.window else { return }
            if event.type == .keyDown {
                // Typing other than a shortcut goes to whatever has the keyboard.
                guard !event.modifierFlags.contains(.command) else { return }
                lastInSession = window.firstResponder is TerminalTextView
            } else {
                lastInSession = isSession(at: event.locationInWindow, in: window)
            }
            lastWindow = window
        }

        static func isSession(at point: NSPoint, in window: NSWindow) -> Bool {
            guard let content = window.contentView, let frame = content.superview else { return false }
            var view = content.hitTest(frame.convert(point, from: nil))
            while let current = view {
                if current is TerminalTextView || current is TerminalScrollView { return true }
                view = current.superview
            }
            return false
        }
    }
}

extension EnvironmentValues {
    /// The app's text size over the default 13 points.
    @Entry var appTextScale: CGFloat = 1
}

/// A font sized from the app's text size, written like SwiftUI's: `.caption`, `.headline.monospaced()`, or
/// `.system(size: 11, weight: .semibold)`. The sizes are macOS's own for each style at the default size.
struct ScaledFont {
    var size: CGFloat
    var weight: Font.Weight?
    var design: Font.Design?
    var digits = false

    static let title = ScaledFont(size: 22)
    static let title2 = ScaledFont(size: 17)
    static let title3 = ScaledFont(size: 15)
    static let headline = ScaledFont(size: 13, weight: .bold)
    static let body = ScaledFont(size: 13)
    static let callout = ScaledFont(size: 12)
    static let subheadline = ScaledFont(size: 11)
    static let footnote = ScaledFont(size: 10)
    static let caption = ScaledFont(size: 10)
    static let caption2 = ScaledFont(size: 10)

    static func system(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> ScaledFont {
        ScaledFont(size: size, weight: weight, design: design)
    }

    static func system(_ style: ScaledFont, design: Font.Design? = nil) -> ScaledFont {
        var font = style
        font.design = design
        return font
    }

    func weight(_ weight: Font.Weight) -> ScaledFont { var font = self; font.weight = weight; return font }
    func bold() -> ScaledFont { weight(.bold) }
    func monospaced() -> ScaledFont { var font = self; font.design = .monospaced; return font }
    func monospacedDigit() -> ScaledFont { var font = self; font.digits = true; return font }

    func font(scale: CGFloat) -> Font {
        let font = Font.system(size: (size * scale).rounded(.toNearestOrEven), weight: weight, design: design)
        return digits ? font.monospacedDigit() : font
    }
}

private struct AppFontModifier: ViewModifier {
    let font: ScaledFont
    @Environment(\.appTextScale) private var scale
    func body(content: Content) -> some View { content.font(font.font(scale: scale)) }
}

private struct AppTextSizeModifier: ViewModifier {
    @AppStorage(AppTextSize.key) private var size = AppTextSize.defaultSize

    func body(content: Content) -> some View {
        let scale = AppTextSize.clamped(size) / AppTextSize.defaultSize
        content
            .environment(\.appTextScale, scale)
            .environment(\.font, .system(size: (13 * scale).rounded()))
            // Bordered buttons, menus, and segmented controls draw their own text at the control size.
            .controlSize(scale >= 1.25 ? .large : scale <= 0.85 ? .small : .regular)
            .onAppear { AppTextSize.Activity.watch() }
    }
}

extension View {
    /// Sets the font, sized with the app's text size.
    func appFont(_ font: ScaledFont) -> some View { modifier(AppFontModifier(font: font)) }

    /// Sizes the text in this window with the app's text size. Put it at the root of each window.
    public func appTextSize() -> some View { modifier(AppTextSizeModifier()) }
}
