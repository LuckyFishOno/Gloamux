import SwiftUI
import XCTest
@testable import App

final class TreeKeysTests: XCTestCase {
    private let rows: [(path: String, isDirectory: Bool)] = [("/a", true), ("/a/x", false), ("/b", true), ("/c.txt", false)]

    private func keys(_ selection: String?, expanded: Set<String> = ["/a"]) -> TreeKeys {
        TreeKeys(rows: rows, selection: selection, isExpanded: { expanded.contains($0) })
    }

    func testArrowsMoveAndStopAtTheEnds() {
        XCTAssertEqual(keys(nil).action(for: .downArrow, command: false), .select("/a"))
        XCTAssertEqual(keys(nil).action(for: .upArrow, command: false), .select("/c.txt"))
        XCTAssertEqual(keys("/a").action(for: .downArrow, command: false), .select("/a/x"))
        XCTAssertEqual(keys("/c.txt").action(for: .downArrow, command: false), .select("/c.txt"))
        XCTAssertEqual(keys("/a").action(for: .upArrow, command: false), .select("/a"))
    }

    func testRightExpandsThenEntersAndLeftCollapsesThenClimbs() {
        XCTAssertEqual(keys("/b").action(for: .rightArrow, command: false), .toggle("/b"))
        XCTAssertEqual(keys("/a").action(for: .rightArrow, command: false), .select("/a/x"))
        XCTAssertNil(keys("/c.txt").action(for: .rightArrow, command: false))
        XCTAssertEqual(keys("/a").action(for: .leftArrow, command: false), .toggle("/a"))
        XCTAssertEqual(keys("/a/x").action(for: .leftArrow, command: false), .select("/a"))
        XCTAssertNil(keys("/b").action(for: .leftArrow, command: false))
    }

    func testOpenParentAndPreview() {
        XCTAssertEqual(keys("/b").action(for: .return, command: false), .open("/b"))
        XCTAssertEqual(keys("/b").action(for: .downArrow, command: true), .open("/b"))
        XCTAssertEqual(keys(nil).action(for: .upArrow, command: true), .parent)
        XCTAssertNil(keys(nil).action(for: .return, command: false))
        XCTAssertEqual(keys("/c.txt").action(for: .space, command: false), .preview("/c.txt"))
        XCTAssertNil(keys("/b").action(for: .space, command: false))
    }
}
