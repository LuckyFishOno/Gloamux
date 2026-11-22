import XCTest
import AppKit
@testable import App

/// Dropping on the server pane of the File Transfer window uploads rows from This Mac and files from Finder.
@MainActor final class LocalFileDragTests: XCTestCase {
    private func file() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-drag-\(UUID().uuidString).txt")
        try Data("drag".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRowFromThisMacCarriesItsFile() async throws {
        let url = try file()
        let files = await LocalFileDrag.files(in: [LocalFileDrag.provider(url)])
        XCTAssertEqual(files.map(\.standardizedFileURL), [url.standardizedFileURL])
    }

    func testFinderFileIsAccepted() async throws {
        let url = try file()
        let files = await LocalFileDrag.files(in: [NSItemProvider(object: url as NSURL)])
        XCTAssertEqual(files.map(\.standardizedFileURL), [url.standardizedFileURL])
    }

    func testServerRowsAndPlainTextAreIgnored() async {
        let remote = NSItemProvider(object: (RemoteFileDrag.prefix + "f:/home/tester/a.txt") as NSString)
        let text = NSItemProvider(object: "just text" as NSString)
        let files = await LocalFileDrag.files(in: [remote, text])
        XCTAssertEqual(files, [])
    }
}
