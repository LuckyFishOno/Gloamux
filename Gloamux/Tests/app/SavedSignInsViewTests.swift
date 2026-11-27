import XCTest

/// The Saved passwords sheet froze the app when an accessibility client read it.
final class SavedSignInsViewTests: XCTestCase {
    /// `ContentUnavailableView`, inserted into the sheet once its list loaded empty, sent SwiftUI's accessibility update
    /// into an attribute-graph cycle without end whenever VoiceOver, a window manager, or an automation tool read the
    /// window. A view hosted in a test window does not show the cycle, only the app's own sheet does, so this keeps the
    /// view out of the sheet's source.
    func testTheEmptySheetDoesNotUseContentUnavailableView() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/app/SavedSignInsView.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        XCTAssertTrue(code.contains("struct SavedSignInsView"), url.path)
        XCTAssertFalse(code.contains("ContentUnavailableView("), "Use the sheet's own empty message instead")
    }
}
