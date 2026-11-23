import XCTest
import SwiftUI
import AppKit
@testable import App

/// The app's own text size: separate from a session's font, changed with ⌘+ and ⌘− outside a session.
@MainActor final class AppTextSizeTests: XCTestCase {
    private let defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        for key in [AppTextSize.key, TerminalPreferences.fontSizeKey] {
            let saved = defaults.object(forKey: key)
            addTeardownBlock { [defaults] in
                if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            defaults.removeObject(forKey: key)
        }
    }

    func testFontsKeepMacOSSizesAtTheDefaultAndGrowWithTheScale() {
        XCTAssertEqual(ScaledFont.body.size, 13)
        XCTAssertEqual(ScaledFont.caption.size, 10)
        XCTAssertEqual(ScaledFont.title2.weight(.semibold).weight, .semibold)
        let code = ScaledFont.system(.body, design: .monospaced)
        XCTAssertEqual(code.size, 13)
        XCTAssertEqual(code.design, .monospaced)
        XCTAssertEqual(ScaledFont.caption.monospacedDigit().digits, true)
        XCTAssertEqual(ScaledFont.system(size: 11, weight: .medium).font(scale: 1), Font.system(size: 11, weight: .medium))
        XCTAssertEqual(ScaledFont.system(size: 11).font(scale: 20.0 / 13), Font.system(size: 17))
    }

    func testZoomStepsWithinItsRangeAndZeroGoesBackToTheDefault() {
        XCTAssertEqual(AppTextSize.size, 13)
        AppTextSize.zoom(1)
        XCTAssertEqual(AppTextSize.size, 14)
        for _ in 0..<20 { AppTextSize.zoom(1) }
        XCTAssertEqual(AppTextSize.size, AppTextSize.sizes.upperBound)
        for _ in 0..<20 { AppTextSize.zoom(-1) }
        XCTAssertEqual(AppTextSize.size, AppTextSize.sizes.lowerBound)
        AppTextSize.zoom(0)
        XCTAssertEqual(AppTextSize.size, 13)
        defaults.set(99.0, forKey: AppTextSize.key)
        XCTAssertEqual(AppTextSize.size, AppTextSize.sizes.upperBound, "A value set by hand stays in range")
    }

    func testCommandPlusChangesTheFocusedSessionsFontAndTheAppsTextElsewhere() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        let terminal = TerminalTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let field = NSTextField(frame: NSRect(x: 0, y: 150, width: 200, height: 24))
        window.contentView?.addSubview(terminal)
        window.contentView?.addSubview(field)

        func click(_ point: NSPoint) {
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            AppTextSize.Activity.note(event)
        }
        func type(_ modifiers: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
            AppTextSize.Activity.note(event)
        }

        window.makeFirstResponder(terminal)
        click(NSPoint(x: 50, y: 50))
        AppTextSize.zoomFocused(1, window: window)
        XCTAssertEqual(TerminalPreferences.fontSize, 14)
        XCTAssertEqual(AppTextSize.size, 13, "A session's zoom leaves the app's text alone")

        // A click on something that does not take the keyboard, such as the sidebar, leaves the terminal with it,
        // but the user is no longer in the session.
        click(NSPoint(x: 300, y: 250))
        XCTAssertTrue(window.firstResponder === terminal)
        AppTextSize.zoomFocused(1, window: window)
        XCTAssertEqual(AppTextSize.size, 14)
        XCTAssertEqual(TerminalPreferences.fontSize, 14, "Outside the session its font stays")
        type(.command)
        AppTextSize.zoomFocused(-1, window: window)
        XCTAssertEqual(AppTextSize.size, 13, "A shortcut is not typing in the session")
        type()
        AppTextSize.zoomFocused(1, window: window)
        XCTAssertEqual(TerminalPreferences.fontSize, 15, "Typing in the terminal is working in the session again")

        window.makeFirstResponder(field)
        click(NSPoint(x: 50, y: 160))
        AppTextSize.zoomFocused(1, window: window)
        AppTextSize.zoomFocused(1, window: window)
        XCTAssertEqual(AppTextSize.size, 15)
        XCTAssertEqual(TerminalPreferences.fontSize, 15, "Outside a session the terminal font stays")

        AppTextSize.zoomFocused(0, window: nil)
        XCTAssertEqual(AppTextSize.size, 13, "With no window in front, ⌘0 resets the app's text")
        XCTAssertEqual(TerminalPreferences.fontSize, 15)
    }

    func testAWindowsTextFollowsTheSetting() {
        func width() -> CGFloat {
            let view = NSHostingView(rootView: VStack { Text("Gloamux sessions"); Text("caption").appFont(.caption) }.fixedSize().appTextSize())
            return view.fittingSize.width
        }
        let standard = width()
        defaults.set(20.0, forKey: AppTextSize.key)
        let large = width()
        XCTAssertGreaterThan(large, standard * 1.3, "Plain text and named styles both grow")
        defaults.set(10.0, forKey: AppTextSize.key)
        XCTAssertLessThan(width(), standard)
    }
}
