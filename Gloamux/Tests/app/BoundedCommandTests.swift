import XCTest
@testable import App

/// External programs run with bounded output, a deadline, and cancellation that stops them and everything they started.
final class BoundedCommandTests: XCTestCase {
    private func sh(_ script: String, timeout: TimeInterval = 10, limit: Int = 1024 * 1024, errors: Int = 4096) async throws -> BoundedCommand.Output {
        try await BoundedCommand.run("/bin/sh", ["-c", script], timeout: timeout, outputLimit: limit, errorLimit: errors)
    }

    /// Waits up to `seconds` for a process to be gone.
    private func gone(_ pid: pid_t, within seconds: Double = 4) async throws -> Bool {
        for _ in 0..<Int(seconds * 20) {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func pid(in file: URL) async throws -> pid_t {
        for _ in 0..<100 {
            if let text = try? String(contentsOf: file, encoding: .utf8), let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw XCTSkip("The test program did not write its process ID")
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-bounded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testOutputAndExitStatusAreReturned() async throws {
        let result = try await sh("printf 'hello'; printf 'oops' >&2; exit 3")
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "hello")
        XCTAssertEqual(String(decoding: result.errors, as: UTF8.self), "oops")
        XCTAssertEqual(result.status, 3)
    }

    func testOutputOverTheLimitStopsTheProgramWithAnError() async throws {
        let start = Date()
        do {
            _ = try await sh("while :; do printf '%01024d' 0; done", limit: 256 * 1024)
            XCTFail("Endless output was accepted")
        } catch let failure as BoundedCommand.Failure {
            XCTAssertEqual(failure, .outputTooLarge(256 * 1024))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "It stops at the limit, not at the deadline")
    }

    func testHeavyOutputOnBothStreamsDoesNotStall() async throws {
        // 2 MB on each stream, interleaved: neither pipe may fill up and block the other.
        let result = try await sh("i=0; while [ $i -lt 2048 ]; do printf '%01024d' 0; printf '%01024d' 1 >&2; i=$((i+1)); done",
                                  timeout: 20, limit: 4 * 1024 * 1024, errors: 8192)
        XCTAssertEqual(result.output.count, 2 * 1024 * 1024)
        XCTAssertEqual(result.errors.count, 8192, "Error text is kept up to its limit")
        XCTAssertEqual(result.status, 0)
    }

    func testTheDeadlineStopsTheProgram() async throws {
        let folder = try scratch(), file = folder.appendingPathComponent("pid")
        let start = Date()
        do {
            _ = try await sh("echo $$ > '\(file.path)'; exec sleep 30", timeout: 0.5)
            XCTFail("A program past its deadline finished")
        } catch let failure as BoundedCommand.Failure {
            XCTAssertEqual(failure, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let ended = try await gone(try await pid(in: file))
        XCTAssertTrue(ended, "The program was stopped")
    }

    func testABackgroundChildHoldingThePipesDoesNotHoldTheResult() async throws {
        let folder = try scratch(), file = folder.appendingPathComponent("pid")
        let start = Date()
        let result = try await sh("sleep 30 & echo $! > '\(file.path)'; echo done", timeout: 20)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "done\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), BoundedCommand.lingering + 2)
        let ended = try await gone(try await pid(in: file))
        XCTAssertTrue(ended, "The background child was stopped with its group")
    }

    func testCancellingStopsTheProgram() async throws {
        let folder = try scratch(), file = folder.appendingPathComponent("pid")
        let task = Task { try await self.sh("echo $$ > '\(file.path)'; exec sleep 30", timeout: 20) }
        let child = try await pid(in: file)
        let start = Date()
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let ended = try await gone(child)
        XCTAssertTrue(ended)
    }

    func testAProgramThatCannotStartFailsOnce() async throws {
        do {
            _ = try await BoundedCommand.run("/nonexistent/gloamux-tool", [], timeout: 5, outputLimit: 1024)
            XCTFail("A missing program started")
        } catch let failure as BoundedCommand.Failure {
            guard case .launch = failure else { return XCTFail("\(failure)") }
        }
    }

    func testRacingEndingsDeliverOneResultEach() async throws {
        // Programs that end at once while being cancelled and timing out: every call returns exactly once.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<60 {
                group.addTask {
                    let task = Task { try await BoundedCommand.run("/usr/bin/true", [], timeout: index % 3 == 0 ? 0.001 : 5, outputLimit: 1024) }
                    if index % 2 == 0 { task.cancel() }
                    _ = await task.result
                }
            }
            try await group.waitForAll()
        }
    }

    func testTheLoginShellCommandReportsFailures() async throws {
        do {
            _ = try await LoginShellCommand.run("echo 'no such tool' >&2; exit 7", timeout: 20)
            XCTFail("A failing command succeeded")
        } catch WorkspaceError.invalid(let reason) {
            XCTAssertTrue(reason.hasSuffix("no such tool"), reason)
        }
    }
}

/// Host discovery keeps one search at a time: an earlier search's late result never replaces a newer one.
@MainActor final class HostDiscoveryOrderTests: XCTestCase {
    /// Commands that wait until the test answers them.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [(command: String, reply: CheckedContinuation<String, Error>)] = []
        func run(_ command: String) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in lock.withLock { waiting.append((command, continuation)) } }
        }
        var count: Int { lock.withLock { waiting.count } }
        func answer(_ index: Int, _ text: String) {
            let reply = lock.withLock { waiting[index].reply }
            reply.resume(returning: text)
        }
    }

    private func requests(_ gate: Gate, _ count: Int) async throws {
        for _ in 0..<500 { if gate.count >= count { return }; try await Task.sleep(nanoseconds: 2_000_000) }
        XCTFail("The search did not start")
    }

    func testAnEarlierSearchFinishingLateIsIgnored() async throws {
        let gate = Gate()
        let discovery = HostDiscoveryModel()
        discovery.runCommand = { try await gate.run($0) }
        let tailscale = #"{"Self": {"ID": "n0", "HostName": "self", "TailscaleIPs": ["100.64.0.1"], "Online": true}, "Peer": {"p": {"ID": "n1", "HostName": "old-peer", "DNSName": "old-peer.tail.ts.net.", "TailscaleIPs": ["100.64.0.2"], "Online": true}}}"#
        discovery.source = .tailscale
        discovery.scan()
        try await requests(gate, 1)
        discovery.source = .aws
        discovery.scan()
        try await requests(gate, 2)
        XCTAssertTrue(discovery.busy)

        gate.answer(0, tailscale)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(discovery.busy, "The old search does not end the new one")
        XCTAssertEqual(discovery.hosts, [], "The old search's hosts do not appear")

        gate.answer(1, #"{"Reservations": []}"#)
        for _ in 0..<100 where discovery.busy { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(discovery.busy)
        XCTAssertEqual(discovery.hosts, [])
        XCTAssertNil(discovery.error)
    }

    func testStopEndsTheSearchAndIgnoresItsResult() async throws {
        let gate = Gate()
        let discovery = HostDiscoveryModel()
        discovery.runCommand = { try await gate.run($0) }
        discovery.source = .aws
        discovery.scan()
        try await requests(gate, 1)
        discovery.stop()
        XCTAssertFalse(discovery.busy)
        gate.answer(0, "not json")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(discovery.error, "A stopped search reports nothing")
        XCTAssertFalse(discovery.busy)
    }
}
