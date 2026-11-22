import AppKit
import XCTest
@testable import App

/// Local terminal output reaches the screen in order, and a program that prints without pause waits for the screen
/// instead of piling its output up in memory.
@MainActor final class TerminalOutputPumpTests: XCTestCase {
    override func setUp() async throws { _ = NSApplication.shared }

    func testAFastProgramArrivesInOrderAndWaitsForASlowScreen() async throws {
        var received: [UInt8] = []
        var largestBatch = 0
        let ended = expectation(description: "the output ended")
        let pump = TerminalOutputPump { bytes, done in
            received += bytes
            largestBatch = max(largestBatch, bytes.count)
            // A screen slower than the program.
            usleep(300_000)
            if done { ended.fulfill() }
        }
        let launch = LocalLaunch(executable: "/usr/bin/seq", arguments: ["seq", "-f", "%.0f", "1", "1000000"],
                                 directory: NSTemporaryDirectory(), environment: ["PATH": "/usr/bin:/bin"])
        let shell = try LocalShell(rows: 24, columns: 80, launch: launch) { pump.push(Array($0)) }
        pump.attach(shell)
        await fulfillment(of: [ended], timeout: 60)
        shell.close()

        let lines = String(decoding: received, as: UTF8.self).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1_000_000)
        XCTAssertEqual(lines.first, "1")
        XCTAssertEqual(lines.last, "1000000")
        XCTAssertEqual(lines.map { Int($0) ?? 0 }, Array(1...1_000_000), "lines out of order")
        // Without the pause, the 6.9 MB would wait in memory and arrive in a few large batches.
        XCTAssertLessThan(largestBatch, TerminalOutputPump.limit + 65536)
    }

    func testClosingWhilePausedDoesNotCrash() throws {
        let launch = LocalLaunch(executable: "/usr/bin/yes", arguments: ["yes"], directory: NSTemporaryDirectory())
        let shell = try LocalShell(rows: 24, columns: 80, launch: launch) { _ in }
        shell.setOutputPaused(true)
        shell.setOutputPaused(true)
        shell.close()
        shell.setOutputPaused(false)
        shell.setOutputPaused(true)
    }
}
