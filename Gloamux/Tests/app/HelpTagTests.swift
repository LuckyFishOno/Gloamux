import XCTest
import AppKit
@testable import App

/// Toolbar help tags: shown after the pointer rests, kept through redraws, and put away when the pointer leaves.
@MainActor final class HelpTagTests: XCTestCase {
    private func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func tag(_ text: String, in window: NSWindow) -> HelpTag.TagView {
        let view = HelpTag.TagView(text: text)
        view.frame = NSRect(x: 0, y: 0, width: 28, height: 26)
        window.contentView?.addSubview(view)
        return view
    }

    func testATagAppearsAfterTheDelayFollowsItsTextAndHidesWhenThePointerLeaves() {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { HelpTagPanel.shared.hide(); window.close() }
        let copy = tag("Copy", in: window)
        HelpTagPanel.shared.hide()
        wait(0.6)

        copy.beginHover(delay: 0.2)
        wait(0.05)
        XCTAssertFalse(HelpTagPanel.shared.isShown, "Nothing shows before the pointer has rested")
        wait(0.3)
        XCTAssertEqual(HelpTagPanel.shared.shownText, "Copy")

        // A redraw that changes the name, such as Show and Hide, updates the tag in place.
        copy.text = "Paste"
        XCTAssertEqual(HelpTagPanel.shared.shownText, "Paste")

        // Moving straight to the next button shows its name without waiting again.
        let next = tag("Settings", in: window)
        copy.endHover()
        XCTAssertFalse(HelpTagPanel.shared.isShown)
        next.beginHover(delay: 5)
        XCTAssertEqual(HelpTagPanel.shared.shownText, "Settings")

        // Leaving a button that is not the one shown leaves the tag alone.
        copy.endHover()
        XCTAssertEqual(HelpTagPanel.shared.shownText, "Settings")
        next.removeFromSuperview()
        XCTAssertFalse(HelpTagPanel.shared.isShown, "A button that goes away takes its tag with it")
    }

    func testLeavingBeforeTheDelayShowsNothing() {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { HelpTagPanel.shared.hide(); window.close() }
        HelpTagPanel.shared.hide()
        wait(0.6)
        let lock = tag("Lock workspace", in: window)
        lock.beginHover(delay: 0.2)
        wait(0.05)
        lock.endHover()
        wait(0.3)
        XCTAssertFalse(HelpTagPanel.shared.isShown)
    }
}
