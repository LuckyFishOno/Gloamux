import XCTest
import AppKit
import SwiftUI
@testable import App

/// Terminal output redraws the terminal, not the rest of the window: the pane's header, sign-in form, and sheets are
/// not evaluated again for each chunk of output.
@MainActor final class TerminalOutputViewTests: XCTestCase {
    private func host<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1400, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.orderBack(nil)
        addTeardownBlock { window.orderOut(nil) }
        return window
    }

    private func settle() async throws { for _ in 0..<10 { try await Task.sleep(nanoseconds: 10_000_000) } }

    func testOutputRedrawsOnlyTheTerminal() async throws {
        #if !DEBUG
        throw XCTSkip("View evaluations are counted in debug builds")
        #else
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-output-views-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = try WorkspaceModel(storage: root)
        let tab = SessionTab()
        tab.host = "web.example"; tab.username = "ops"; tab.connected = true; tab.terminalReady = true; tab.status = "Connected"
        model.tabs.append(tab)
        model.selectTab(tab.id)
        let window = host(DesktopView(model: model).frame(width: 1400, height: 900))
        try await settle()

        ViewEvaluations.counts = [:]
        for n in 0..<40 {
            model.terminalReceived(tab, bytes: Array("line \(n)\r\n".utf8))
            await Task.yield()
            RunLoop.main.run(until: Date())
        }
        try await settle()
        XCTAssertGreaterThanOrEqual(ViewEvaluations.counts["TerminalDisplay", default: 0], 10, "The terminal draws the output")
        XCTAssertEqual(ViewEvaluations.counts["SessionPane", default: 0], 0, "The pane around it does not")
        let text = try XCTUnwrap(textView(in: window.contentView)).string
        XCTAssertTrue(text.contains("line 39"), "The last output is on screen")

        // A change to the tab itself still updates the pane.
        tab.status = "Connected again"
        try await settle()
        XCTAssertGreaterThan(ViewEvaluations.counts["SessionPane", default: 0], 0)
        #endif
    }

    private func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView, text.isEditable { return text }
        for child in view.subviews { if let found = textView(in: child) { return found } }
        return nil
    }

    func testResetOutputRedrawsAfterTheTerminalWasResized() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-reset-view-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = try WorkspaceModel(storage: root)
        let tab = SessionTab()
        tab.connected = true; tab.terminalReady = true
        let window = host(TerminalDisplay(tab: tab, model: model, resizes: false))
        try await settle()
        for (rows, cols) in [(40, 120), (10, 30), (24, 80), (30, 80)] {
            model.resizeTerminal(tab, rows: rows, columns: cols)
            model.terminalReceived(tab, bytes: Array("\u{1B}c\u{1B}[\(rows);1HRESET_OK".utf8))
            try await settle()
            let text = try XCTUnwrap(textView(in: window.contentView)).string
            XCTAssertTrue(text.contains("RESET_OK"))
            XCTAssertEqual(tab.screen.rows, rows)
            XCTAssertEqual(tab.screen.cols, cols)
        }
    }

    func testAnUnchangedWindowTitleDoesNotRedrawTheTab() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-output-title-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = try WorkspaceModel(storage: root)
        let tab = SessionTab()
        var changes = 0
        let watch = tab.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }
        model.terminalReceived(tab, bytes: Array("\u{1b}]0;ops@web: ~\u{07}".utf8))
        XCTAssertEqual(tab.programTitle, "ops@web: ~")
        let afterFirst = changes
        for _ in 0..<5 { model.terminalReceived(tab, bytes: Array("\u{1b}]0;ops@web: ~\u{07}$ ".utf8)) }
        XCTAssertEqual(changes, afterFirst, "Output and a repeated title do not announce a tab change")
        let revision = tab.screenRevision
        model.terminalReceived(tab, bytes: Array("more\r\n".utf8))
        XCTAssertGreaterThan(tab.screenRevision, revision)
    }

    /// AppKit's selection tracking keeps where the button went down as a character offset and ends the selection under
    /// the pointer. Output that arrived while the button was down used to scroll a line under the pointer, so a plain
    /// click selected a line and Copy on select put it on the clipboard.
    func testOutputWhileTheButtonIsDownDoesNotTurnAClickIntoASelection() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: TerminalPreferences.copyOnSelectKey)
        defer { defaults.set(saved, forKey: TerminalPreferences.copyOnSelectKey) }
        defaults.set(true, forKey: TerminalPreferences.copyOnSelectKey)
        let board = NSPasteboard(name: NSPasteboard.Name("gloamux-test-\(UUID())"))
        defer { board.releaseGlobally() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-click-output-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = try WorkspaceModel(storage: root)
        let tab = SessionTab()
        tab.connected = true; tab.terminalReady = true
        let window = host(TerminalDisplay(tab: tab, model: model, resizes: false).frame(width: 700, height: 400))
        try await settle()
        model.terminalReceived(tab, bytes: Array((0..<120).map { "line \($0)\r\n" }.joined().utf8))
        try await settle()
        let view = try XCTUnwrap(textView(in: window.contentView) as? TerminalTextView)
        view.pasteboard = board
        let clip = try XCTUnwrap(view.enclosingScrollView?.contentView)
        XCTAssertTrue(view.showsScreenBottom)

        for round in 0..<3 {
            // Blank cells right of the text, halfway down what is in sight.
            let point = view.convert(NSPoint(x: clip.bounds.maxX - 40, y: clip.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: round, clickCount: 1, pressure: 1)!
            }
            let up = event(.leftMouseUp)
            // AppKit's tracking loop runs the run loop, not the main queue, so timers stand in for output and the release.
            func later(_ seconds: TimeInterval, _ action: @escaping () -> Void) {
                RunLoop.main.add(Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { action() } }, forMode: .common)
            }
            later(0.05) {
                model.terminalReceived(tab, bytes: Array("during click \(round)\r\nmore \(round)\r\n".utf8))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            later(0.4) { NSApp.postEvent(up, atStart: false) }
            view.mouseDown(with: event(.leftMouseDown))
            XCTAssertEqual(view.selectedRange().length, 0, "round \(round): a click selects nothing")
            XCTAssertNil(board.string(forType: .string), "round \(round): the clipboard is left alone")
            try await settle()
            XCTAssertTrue(view.string.contains("more \(round)"), "round \(round): the output is shown once the button is up")
            XCTAssertTrue(view.showsScreenBottom, "round \(round): and the view still follows it")
        }
    }
}
