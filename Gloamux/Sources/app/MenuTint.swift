import AppKit

/// Native menus in the colors of the window they open from. Right-click menus, pop-up buttons, and their submenus
/// keep the system's own items, shortcuts, and behavior; only their background takes the theme's menu color, their
/// light or dark look follows the theme, and their text follows the app's text size. The menu bar's menus stay the
/// system's, apart from symbols drawn in their Latin form.
///
/// macOS 26 draws a menu on Liquid Glass in a window of its own, whose `NSGlassEffectView` takes a tint. AppKit offers
/// no menu color, so those views are found when a menu opens. Earlier systems get the theme's light or dark look only.
@MainActor enum MenuTint {
    struct Style: Equatable {
        var color: NSColor
        var dark: Bool
        /// Glass deepens a tint, so a light theme's cream would turn yellow at full strength.
        var tint: NSColor { color.withAlphaComponent(0.7) }
        var appearance: NSAppearance? { NSAppearance(named: dark ? .darkAqua : .aqua) }
    }

    private final class Box { let style: Style; init(_ style: Style) { self.style = style } }
    private static let styles = NSMapTable<NSWindow, Box>.weakToStrongObjects()
    private static var observers: [NSObjectProtocol] = []
    private static var timer: Timer?

    /// Menus opened from `window` take `style`.
    static func use(_ style: Style, for window: NSWindow) {
        styles.setObject(Box(style), forKey: window)
        guard observers.isEmpty else { return }
        observers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                let menu = note.object as? NSMenu
                MainActor.assumeIsolated { begin(menu) }
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { end() }
            },
        ]
    }

    static func style(for window: NSWindow) -> Style? { styles.object(forKey: window)?.style }

    private static func begin(_ menu: NSMenu?) {
        guard let menu else { return }
        let menuBar = inMenuBar(menu)
        // The menu is laid out when it appears, after tracking begins, so it still takes the size and symbols.
        prepare(menu, font: menuBar ? nil : font(scale: AppTextSize.size / AppTextSize.defaultSize))
        guard !menuBar else { return }
        guard let source = NSApp.currentEvent?.window ?? NSApp.keyWindow, let style = style(for: source) else { return }
        // The menu's windows appear once tracking starts, and a submenu's when it opens, so look again while it is open.
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.03, repeats: true) { _ in MainActor.assumeIsolated { apply(style) } }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        self.timer = timer
        RunLoop.main.perform(inModes: [.common, .eventTracking]) { apply(style) }
    }

    private static func end() {
        timer?.invalidate()
        timer = nil
    }

    /// The menu font at the app's text size; the menu bar's menus keep the system's.
    static func font(scale: Double) -> NSFont {
        let base = NSFont.menuFont(ofSize: 0).pointSize
        return NSFont.menuFont(ofSize: (base * scale).rounded())
    }

    /// Sets the text size of a right-click or pop-up menu and its submenus, and draws symbols that change with the
    /// Mac's language (the Font item's 格式 in Chinese) in their Latin form, as the Text pane in Settings does.
    static func prepare(_ menu: NSMenu, font: NSFont?) {
        if let font, menu.font != font { menu.font = font }
        let latin = Locale(identifier: "en")
        for item in menu.items {
            if let image = item.image, image.locale == nil { item.image = image.withLocale(latin) }
            if let submenu = item.submenu { prepare(submenu, font: font) }
        }
    }

    static func inMenuBar(_ menu: NSMenu) -> Bool {
        var current: NSMenu? = menu
        while let item = current {
            if item === NSApp.mainMenu { return true }
            current = item.supermenu
        }
        return false
    }

    /// Tints every open menu: the menu windows themselves, and on macOS 26 the glass windows drawn behind them.
    static func apply(_ style: Style) {
        let windows = NSApp.windows.filter(\.isVisible)
        let menus = windows.filter { String(describing: type(of: $0)).contains("Menu") }
        guard !menus.isEmpty else { return }
        for menu in menus where menu.appearance != style.appearance { menu.appearance = style.appearance }
        guard #available(macOS 26, *) else { return }
        for window in windows where String(describing: type(of: window)).contains("GlassEffectWindow")
            && menus.contains(where: { $0.frame.intersects(window.frame) }) {
            if window.appearance != style.appearance { window.appearance = style.appearance }
            for glass in glassViews(in: window.contentView?.superview) where glass.tintColor != style.tint {
                glass.tintColor = style.tint
            }
        }
    }

    @available(macOS 26, *)
    private static func glassViews(in view: NSView?) -> [NSGlassEffectView] {
        guard let view else { return [] }
        return (view as? NSGlassEffectView).map { [$0] } ?? view.subviews.flatMap(glassViews(in:))
    }
}
