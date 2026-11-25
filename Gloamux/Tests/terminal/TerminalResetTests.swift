import XCTest
@testable import Terminal

final class TerminalResetTests: XCTestCase {
    func testResetAfterGrowingUsesCurrentGridSize() {
        checkReset("\u{1B}c", initial: (2, 5), resized: (6, 14))
    }

    func testResetAfterShrinkingUsesCurrentGridSize() {
        checkReset("\u{1B}c", initial: (6, 14), resized: (2, 5))
    }

    func testSoftResetAfterResizeUsesCurrentGridSize() {
        checkReset("\u{1B}[!p", initial: (2, 5), resized: (6, 14))
    }

    func testResetFromAlternateScreenAfterResize() {
        checkReset("\u{1B}c", initial: (2, 5), resized: (6, 14), alternate: true)
    }

    func testHeightOnlyResizeAndReset() {
        checkReset("\u{1B}c", initial: (2, 10), resized: (8, 10))
        checkReset("\u{1B}[!p", initial: (8, 10), resized: (2, 10))
    }

    func testRepeatedResizeResetAndScreenSwitches() {
        let screen = TerminalScreen()
        for iteration in 0..<500 {
            let rows = 1 + iteration * 7 % 40, cols = 1 + iteration * 13 % 120
            screen.feed("\u{1B}[?1049h")
            screen.resize(rows: rows, cols: cols)
            screen.feed(iteration.isMultiple(of: 2) ? "\u{1B}c" : "\u{1B}[!p")
            screen.feed("\u{1B}[\(rows);\(cols)HX")
            for row in 0..<rows {
                XCTAssertEqual(screen.row(absolute: screen.absoluteLine(ofRow: row))?.count, cols)
                for col in 0..<cols {
                    XCTAssertEqual(screen.cell(row: row, col: col).character, row == rows - 1 && col == cols - 1 ? "X" : " ")
                }
            }
            screen.feed("\u{1B}[?1049l\r\nnext\r\n")
        }
    }

    private func checkReset(_ sequence: String, initial: (Int, Int), resized: (Int, Int), alternate: Bool = false,
                            file: StaticString = #filePath, line: UInt = #line) {
        var options = TerminalOptions()
        options.rows = initial.0; options.cols = initial.1
        let screen = TerminalScreen(options: options)
        screen.feed("old\r\noutput\r\nmore")
        if alternate { screen.feed("\u{1B}[?1049h") }
        screen.resize(rows: resized.0, cols: resized.1)
        let history = screen.scrollback
        screen.feed(sequence)
        XCTAssertEqual(screen.rows, resized.0, file: file, line: line)
        XCTAssertEqual(screen.cols, resized.1, file: file, line: line)
        XCTAssertFalse(screen.usingAlternate, file: file, line: line)
        XCTAssertEqual(screen.scrollback, history, file: file, line: line)
        // Check a safe row first: the old implementation recreates the initial-size buffers.
        let first = screen.row(absolute: screen.absoluteLine(ofRow: 0))
        XCTAssertEqual(first?.count, resized.1, file: file, line: line)
        guard first?.count == resized.1 else { return }
        for row in 0..<screen.rows {
            for col in 0..<screen.cols { XCTAssertEqual(screen.cell(row: row, col: col), .blank, file: file, line: line) }
        }
        screen.feed("\u{1B}[\(resized.0);\(resized.1)HX")
        XCTAssertEqual(screen.cell(row: resized.0 - 1, col: resized.1 - 1).character, "X", file: file, line: line)
        screen.feed("\u{1B}[?47h")
        XCTAssertEqual(screen.cell(row: resized.0 - 1, col: resized.1 - 1), .blank, file: file, line: line)
        screen.feed("\u{1B}[?47l")
        XCTAssertEqual(screen.cell(row: resized.0 - 1, col: resized.1 - 1).character, "X", file: file, line: line)
    }
}
