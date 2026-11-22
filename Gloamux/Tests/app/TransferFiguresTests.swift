import XCTest
@testable import App

final class TransferFiguresTests: XCTestCase {
    func testPercentTimeAndSizeLeft() {
        // 25 MB of 100 MB in 10 s: 2.5 MB/s, so 75 MB takes 30 s.
        let line = TransferFigures.line(done: 25_000_000, total: 100_000_000, elapsed: 10, unknown: false)
        XCTAssertTrue(line.hasPrefix("25% · "), line)
        XCTAssertTrue(line.contains(String(format: T("%@ left"), TransferFigures.duration(30))), line)
        XCTAssertTrue(line.contains(String(format: T("%@ of %@ left"), TransferFigures.bytes(75_000_000), TransferFigures.bytes(100_000_000))), line)
    }

    func testNoTimeUntilThereIsASpeed() {
        let line = TransferFigures.line(done: 0, total: 100, elapsed: 30, unknown: false)
        XCTAssertFalse(line.contains(TransferFigures.duration(0)), line)
        XCTAssertEqual(TransferFigures.line(done: 0, total: 0, elapsed: 0, unknown: false), T("Preparing…"))
        // A folder not yet listed: the percent is a lower bound and no time is guessed.
        XCTAssertTrue(TransferFigures.line(done: 50, total: 100, elapsed: 10, unknown: true).hasPrefix("50%+"))
    }

    func testDurations() {
        XCTAssertEqual(TransferFigures.duration(9.2), String(format: T("%d s"), 10))
        XCTAssertEqual(TransferFigures.duration(125), String(format: T("%d min %d s"), 2, 5))
        XCTAssertEqual(TransferFigures.duration(7_260), String(format: T("%d h %d min"), 2, 1))
    }

    func testFinishedLine() {
        XCTAssertEqual(TransferFigures.finished, T("Done"))
    }
}
