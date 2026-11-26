import XCTest
import SwiftUI
import AppKit
@testable import App

@MainActor final class SessionTreeInteractionTests: XCTestCase {
    /// The clicks need a key window, so the test process must become the active app. macOS can refuse that
    /// while the user works in another app; the tests then wait up to this many 50 ms tries and skip instead of failing.
    private static let activationTries = 200
    private static let activationRefused = "macOS kept another app active, so the test window could not become key."

    private func store() throws -> SessionTreeStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tree-ui-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try SessionTreeStore(url: dir.appendingPathComponent("sessions.json"))
    }

    func testDropsBetweenOntoAndBelowRows() throws {
        let tree = try store()
        let folder = try tree.add(name: "Folder", parent: nil)
        let inner = try tree.add(name: "Inner", parent: folder)
        let first = try tree.add(name: "a1", parent: folder, connection: SavedConnection(host: "a1.test", username: "u"))
        let second = try tree.add(name: "a2", parent: folder, connection: SavedConnection(host: "a2.test", username: "u"))
        let loose = try tree.add(name: "loose", parent: nil, connection: SavedConnection(host: "loose.test", username: "u"))
        let shown: (UUID?) -> [UUID] = { parent in tree.children(of: parent).map(\.id) }
        func resolve(_ id: UUID, _ target: UUID?, _ index: Int, _ fraction: CGFloat? = nil) -> SessionOutlineDrop? {
            SessionOutlineDrop.resolve(tree, moving: id, onto: target, index: index, fraction: fraction, shown: shown)
        }

        XCTAssertEqual(resolve(loose, folder, -1), SessionOutlineDrop(parent: folder, before: nil, childIndex: -1), "Onto a folder goes inside it.")
        XCTAssertEqual(resolve(loose, nil, 0), SessionOutlineDrop(parent: nil, before: folder, childIndex: 0), "A gap goes in front of the row below.")
        XCTAssertEqual(resolve(loose, folder, 3), SessionOutlineDrop(parent: folder, before: nil, childIndex: 3), "Below the last child goes last.")
        let order = shown(folder)
        XCTAssertEqual(resolve(loose, first, -1), SessionOutlineDrop(parent: folder, before: order[order.firstIndex(of: first)! + 1],
                                                                     childIndex: order.firstIndex(of: first)! + 1),
                       "Onto a session means just below it.")
        XCTAssertNil(resolve(folder, folder, 0), "A folder never goes inside itself.")
        XCTAssertNil(resolve(folder, inner, -1), "Nor inside its own subfolder.")

        let other = try tree.add(name: "Other", parent: nil)
        let roots = shown(nil)
        XCTAssertEqual(resolve(other, folder, -1, 0.1), SessionOutlineDrop(parent: nil, before: folder, childIndex: roots.firstIndex(of: folder)!),
                       "A folder's top edge places a dragged folder in front of it.")
        XCTAssertEqual(resolve(other, folder, -1, 0.5), SessionOutlineDrop(parent: folder, before: nil, childIndex: -1), "Its middle puts it inside.")
        XCTAssertEqual(resolve(other, folder, -1, 0.9), SessionOutlineDrop(parent: folder, before: nil, childIndex: -1),
                       "An open folder's bottom edge sits above its children, so it still means inside.")
        try tree.setExpanded(folder, false)
        XCTAssertEqual(resolve(other, folder, -1, 0.9), SessionOutlineDrop(parent: nil, before: roots[roots.firstIndex(of: folder)! + 1],
                                                                          childIndex: roots.firstIndex(of: folder)! + 1),
                       "A closed folder's bottom edge places it after.")

        try tree.setSorting(.nameAscending)
        let named = shown(nil)
        XCTAssertEqual(resolve(other, nil, 0), SessionOutlineDrop(parent: nil, before: named[0], childIndex: 0),
                       "Sorted by name, a gap still means a place in the order.")
        try tree.keepShownOrder()
        XCTAssertEqual(tree.sorting, .custom, "Rearranging a name-sorted tree turns it custom.")
        XCTAssertEqual(shown(nil), named, "And keeps the order it showed.")
        try tree.move(other, into: nil, before: named[0])
        XCTAssertEqual(shown(nil).first, other)
    }

    func testClicksToggleFoldersSelectAndOpenSessions() throws {
        let tree = try store()
        let folder = try tree.add(name: "Folder", parent: nil)
        let session = try tree.add(name: "Server", parent: folder, connection: SavedConnection(host: "server.test", username: "u"))
        try tree.setExpanded(folder, false)
        var refused = false, opened: [UUID] = []
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let view = NSHostingView(rootView: SessionOutline(store: tree, activate: { opened.append($0.id) }).frame(width: 260, height: 200))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 260, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        var number = 0
        func click(row: Int, count: Int = 1, in outline: NSOutlineView) {
            let rect = outline.rect(ofRow: row)
            let point = outline.convert(NSPoint(x: rect.maxX - 30, y: rect.midY), to: nil)
            for clicks in 1...count {
                number += 2
                let time = ProcessInfo.processInfo.systemUptime
                NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: number, clickCount: clicks, pressure: 1)!, atStart: false)
                NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.001, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: number + 1, clickCount: clicks, pressure: 0)!, atStart: false)
            }
        }
        func stop() {
            NSApp.stop(nil)
            NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
        }
        func outline(in view: NSView) -> NSOutlineView? {
            if let found = view as? NSOutlineView { return found }
            return view.subviews.lazy.compactMap { outline(in: $0) }.first
        }
        NSApp.finishLaunching()
        func startWhenReady(_ remaining: Int) {
            guard NSApp.isActive, window.isKeyWindow else {
                guard remaining > 0 else { refused = true; stop(); return }
                NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { startWhenReady(remaining - 1) }
                return
            }
            view.layoutSubtreeIfNeeded()
            guard let list = outline(in: view) else { XCTFail("The tree is an outline view."); stop(); return }
            XCTAssertEqual(list.numberOfRows, 1, "A closed folder hides its sessions.")
            click(row: 0, in: list)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                XCTAssertEqual(tree.node(folder)?.expanded, true, "A click on a folder row opens it and remembers that.")
                XCTAssertEqual(tree.selection, folder)
                XCTAssertEqual(list.numberOfRows, 2)
                click(row: 1, in: list)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    XCTAssertEqual(tree.selection, session, "A click selects a session.")
                    XCTAssertEqual(opened, [], "A single click does not open it.")
                    click(row: 1, count: 2, in: list)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        XCTAssertEqual(opened, [session], "A double click opens it.")
                        stop()
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { startWhenReady(Self.activationTries) }
        NSApp.run()
        if refused { throw XCTSkip(Self.activationRefused) }
    }
}
