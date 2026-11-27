import AppKit
import SwiftUI
import XCTest
@testable import App

/// The Recordings and Runbooks windows put a list beside a detail pane in a split view. With nothing to list, the left
/// column held only its header and an empty message, and the whole split view shrank to that height and sat at the
/// bottom of the window.
@MainActor final class ToolWindowLayoutTests: XCTestCase {
    private func workspace() throws -> WorkspaceModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-test-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try WorkspaceModel(storage: root)
    }

    private func host(_ view: some View, kind: ToolWindowKind) async throws -> NSView {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: kind.size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view.frame(maxWidth: .infinity, maxHeight: .infinity).appTextSize())
        window.orderBack(nil)
        addTeardownBlock { window.orderOut(nil) }
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        return content
    }

    private func find<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
        if let match = view as? V { return match }
        for child in view.subviews { if let match = find(type, in: child) { return match } }
        return nil
    }

    /// The split view fills the window, and the column header (its "!" button) is at the top, not the bottom.
    private func assertFills(_ content: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        let split = try XCTUnwrap(find(NSSplitView.self, in: content), file: file, line: line)
        let frame = split.convert(split.bounds, to: content)
        XCTAssertEqual(frame.height, content.bounds.height, accuracy: 1, "The split view fills the window", file: file, line: line)
        let info = try XCTUnwrap(find(InfoButtonView.self, in: content), file: file, line: line)
        let button = info.convert(info.bounds, to: nil)
        let height = try XCTUnwrap(content.window).contentLayoutRect.height
        XCTAssertGreaterThan(button.minY, height - 60, "The header is at the top of the window", file: file, line: line)
    }

    func testAnEmptyRecordingsWindowFillsItsWindow() async throws {
        let model = try workspace()
        XCTAssertTrue(model.recordings.saved.isEmpty && model.videos.saved.isEmpty)
        let content = try await host(RecordingsView(model: model, store: model.recordings, videos: model.videos), kind: .recordings)
        try assertFills(content)
    }

    func testAnEmptyRunbooksWindowFillsItsWindow() async throws {
        let model = try workspace()
        let content = try await host(RunbooksView(model: model, library: model.runbooks), kind: .runbooks)
        XCTAssertTrue(model.runbooks.files.isEmpty)
        try assertFills(content)
    }

    func testARunbooksWindowWithAFileStillFillsItsWindow() async throws {
        let model = try workspace()
        _ = try model.runbooks.create(named: "Probe")
        let content = try await host(RunbooksView(model: model, library: model.runbooks), kind: .runbooks)
        XCTAssertFalse(model.runbooks.files.isEmpty)
        try assertFills(content)
    }
    func testCreatingRunbooksKeepsTheNewRowSelectedAcrossEmptyTransitions() async throws {
        let model = try workspace()
        let content = try await host(RunbooksView(model: model, library: model.runbooks), kind: .runbooks)
        for index in 0..<3 {
            let url = try model.runbooks.create(named: "New \(index)")
            model.runbooks.selected = url
            for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(model.runbooks.selected, url)
            XCTAssertTrue(model.runbooks.files.contains(url), "created=\(url.absoluteString), listed=\(model.runbooks.files.map(\.absoluteString))")
            try assertFills(content)
            try model.runbooks.delete(url)
            model.runbooks.selected = nil
            for _ in 0..<10 { try await Task.sleep(for: .milliseconds(10)) }
        }
    }

    func testEmptyRecordingsThroughTheRealToolWindow() async throws {
        let model = try workspace()
        let controller = ToolWindow(model: model, kind: .recordings,
                                    content: AnyView(RecordingsView(model: model, store: model.recordings, videos: model.videos)))
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        try assertFills(content)
    }

}
