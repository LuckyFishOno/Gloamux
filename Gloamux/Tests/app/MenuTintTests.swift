import XCTest
import AppKit
@testable import App

/// Native menus take the theme's menu color and light or dark look; their items stay the system's.
@MainActor final class MenuTintTests: XCTestCase {
    func testAnOpenMenuTakesTheThemeAndKeepsItsItems() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        window.orderFrontRegardless()
        let style = MenuTint.Style(color: NSColor(srgbRed: 0.23, green: 0.12, blue: 0.37, alpha: 1), dark: true)
        MenuTint.use(style, for: window)
        XCTAssertEqual(MenuTint.style(for: window), style)

        let menu = NSMenu()
        for title in ["Open", "Rename", "Delete"] { menu.addItem(withTitle: title, action: nil, keyEquivalent: "") }
        var appearances: [NSAppearance.Name] = []
        var tints: [NSColor?] = []
        let check = Timer(timeInterval: 0.3, repeats: false) { _ in
            MainActor.assumeIsolated {
                MenuTint.apply(style)
                let open = NSApp.windows.filter(\.isVisible)
                appearances = open.filter { String(describing: type(of: $0)).contains("Menu") }.compactMap { $0.appearance?.name }
                if #available(macOS 26, *) {
                    tints = open.filter { String(describing: type(of: $0)).contains("GlassEffectWindow") }
                        .flatMap { Self.glass(in: $0.contentView?.superview) }.map(\.tintColor)
                }
                menu.cancelTracking()
            }
        }
        RunLoop.main.add(check, forMode: .common)
        RunLoop.main.add(check, forMode: .eventTracking)
        menu.popUp(positioning: nil, at: NSPoint(x: 20, y: 150), in: window.contentView)

        XCTAssertFalse(appearances.isEmpty, "The menu opened")
        XCTAssertTrue(appearances.allSatisfy { $0 == .darkAqua }, "A dark theme's menu is dark")
        if #available(macOS 26, *) {
            XCTAssertFalse(tints.isEmpty)
            XCTAssertTrue(tints.allSatisfy { $0 == style.tint }, "The glass takes the theme's menu color")
        }
        XCTAssertEqual(menu.items.map(\.title), ["Open", "Rename", "Delete"])
    }

    func testTheMenuBarKeepsTheSystemsLook() {
        let main = NSMenu(), file = NSMenu(), recent = NSMenu()
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file
        file.addItem(withTitle: "Recent", action: nil, keyEquivalent: "").submenu = recent
        let saved = NSApp.mainMenu
        NSApp.mainMenu = main
        defer { NSApp.mainMenu = saved }
        XCTAssertTrue(MenuTint.inMenuBar(recent))
        XCTAssertFalse(MenuTint.inMenuBar(NSMenu()))
    }

    @available(macOS 26, *)
    private static func glass(in view: NSView?) -> [NSGlassEffectView] {
        guard let view else { return [] }
        return (view as? NSGlassEffectView).map { [$0] } ?? view.subviews.flatMap { glass(in: $0) }
    }
}
