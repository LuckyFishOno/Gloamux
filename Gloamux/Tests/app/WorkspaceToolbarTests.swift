import AppKit
import SwiftUI
import XCTest
@testable import App

@MainActor
final class WorkspaceToolbarTests: XCTestCase {
    /// AppKit shows one tooltip per toolbar item. When the four sidebar buttons shared one item, pointing at Files,
    /// Quick commands, or Color theme showed "Browser", and moving between them kept that tooltip up.
    func testEachSidebarButtonHasItsOwnToolbarItemAndTooltip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-toolbar-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = try WorkspaceModel(storage: root)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1400, height: 900),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: DesktopView(model: model))
        window.orderBack(nil)
        addTeardownBlock { window.orderOut(nil) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, (window.toolbar?.items.count ?? 0) < 4 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let items = try XCTUnwrap(window.toolbar?.items)

        // Each button's tooltip belongs to exactly one item, and that item shows no other tooltip.
        for help in ["Browser", "Files", "Quick commands", "Color theme"].map(T) {
            let owners = items.filter { $0.toolTip == help }
            XCTAssertEqual(owners.count, 1, "\(help) has its own toolbar item")
            for item in owners {
                XCTAssertEqual(item.label, help)
                XCTAssertTrue(Self.tooltips(item).allSatisfy { $0 == help }, "\(help) shows only its own tooltip")
            }
        }
    }

    /// The tooltips AppKit can show for an item: the item's own and any set on its views.
    private static func tooltips(_ item: NSToolbarItem) -> [String] {
        var tips = [item.toolTip].compactMap { $0 }.filter { !$0.isEmpty }
        func walk(_ view: NSView) {
            if let tip = view.toolTip, !tip.isEmpty { tips.append(tip) }
            view.subviews.forEach(walk)
        }
        if let view = item.view { walk(view) }
        return tips
    }
}
