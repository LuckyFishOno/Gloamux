import XCTest
import Foundation
@testable import App

final class PrivateFileTests: XCTestCase {
    func testWritesAPrivateFileWholeAndLeavesNoTemporaryFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-private-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("note.json")
        try writePrivate(Data("first".utf8), to: file)
        try writePrivate(Data("second".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "second")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["note.json"])
    }

    /// Gloamux reads and removes a CLI request the moment it appears. Writing it must not fail when that happens
    /// right after the file lands, as `gloamux mcp` calls once did now and then.
    func testWritingSucceedsWhenAnotherProcessTakesTheFileAtOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-private-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let done = ManagedAtomicFlag()
        let taker = Thread {
            while !done.value {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".request") {
                    unlink(folder.appendingPathComponent(name).path)
                }
            }
        }
        taker.start()
        defer { done.value = true }
        for index in 0..<3000 {
            XCTAssertNoThrow(try writePrivate(Data("{}".utf8), to: folder.appendingPathComponent("\(index).request")), "write \(index)")
        }
    }
}

private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}
