import XCTest
import Foundation
@testable import App

/// Gloamux was called Termac, and MShell before that; data saved under those names must come along.
final class LegacyNameTests: XCTestCase {
    private struct Scratch {
        let support: URL
        let defaults: UserDefaults
        let new: String
        /// Stand-ins for the Termac and MShell settings domains, so the real ones are never read or written.
        let earlier: [(folder: String, bundleID: String)]
    }

    private func scratch() throws -> Scratch {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-legacy-\(UUID())")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let new = "gloamux-legacy-test-\(UUID().uuidString)"
        let earlier = [(folder: "Termac", bundleID: new + ".termac"), (folder: "MShell", bundleID: new + ".mshell")]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: new))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: support)
            for domain in [new] + earlier.map(\.bundleID) { defaults.removePersistentDomain(forName: domain) }
        }
        return Scratch(support: support, defaults: defaults, new: new, earlier: earlier)
    }

    private func migrate(_ s: Scratch, running: Bool = false) {
        LegacyName.migrate(support: s.support, newBundleID: s.new, earlier: s.earlier, defaults: s.defaults, oldAppRunning: { running })
    }

    private func folder(_ s: Scratch, _ name: String, file: String) throws {
        let url = s.support.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(name.utf8).write(to: url.appendingPathComponent(file))
    }

    private func exists(_ s: Scratch, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: s.support.appendingPathComponent(path).path)
    }

    func testTheOldFolderMovesOnceAndALiveOldAppBlocksIt() throws {
        let s = try scratch()
        try folder(s, "MShell", file: "sessions.json")

        migrate(s, running: true)
        XCTAssertTrue(exists(s, "MShell"), "Nothing moves while an earlier app runs")

        migrate(s)
        XCTAssertFalse(exists(s, "MShell"))
        XCTAssertTrue(exists(s, "Gloamux/sessions.json"))

        // A Gloamux folder that already exists is never replaced.
        try folder(s, "Termac", file: "other.json")
        migrate(s)
        XCTAssertTrue(exists(s, "Termac/other.json"))
        XCTAssertFalse(exists(s, "Gloamux/other.json"))
    }

    func testTheNewestEarlierFolderWins() throws {
        let s = try scratch()
        try folder(s, "MShell", file: "old.json")
        try folder(s, "Termac", file: "newer.json")
        migrate(s)
        XCTAssertTrue(exists(s, "Gloamux/newer.json"))
        XCTAssertTrue(exists(s, "MShell/old.json"), "The older folder is left alone")
    }

    func testSettingsComeFromTheNewestEarlierNameOnlyWhenGloamuxHasNone() throws {
        let s = try scratch()
        s.defaults.setPersistentDomain(["terminal.font-size": 13], forName: s.earlier[1].bundleID)
        // A window frame macOS saved on its own does not count as a Gloamux setting.
        s.defaults.setPersistentDomain(["NSWindow Frame main": "0 0 100 100"], forName: s.new)
        migrate(s)
        XCTAssertEqual(s.defaults.persistentDomain(forName: s.new)?["NSWindow Frame main"] as? String, "0 0 100 100")
        XCTAssertEqual(s.defaults.persistentDomain(forName: s.new)?["terminal.font-size"] as? Int, 13, "MShell's settings when Termac has none")

        s.defaults.removePersistentDomain(forName: s.new)
        s.defaults.setPersistentDomain(["terminal.font-size": 15], forName: s.earlier[0].bundleID)
        migrate(s)
        XCTAssertEqual(s.defaults.persistentDomain(forName: s.new)?["terminal.font-size"] as? Int, 15, "Termac's settings first")

        s.defaults.setPersistentDomain(["terminal.font-size": 12], forName: s.new)
        migrate(s)
        XCTAssertEqual(s.defaults.persistentDomain(forName: s.new)?["terminal.font-size"] as? Int, 12, "Existing Gloamux settings stay")
    }

    func testExportsWithEarlierNamesStillImport() throws {
        var file = SessionsFile(name: "Team", exported: Date(), folders: [], items: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        for format in ["termac-sessions", "mshell-sessions"] {
            file.format = format
            XCTAssertNoThrow(try SessionsFile.read(try encoder.encode(file)), format)
        }
        file.format = "something-else"
        XCTAssertThrowsError(try SessionsFile.read(try encoder.encode(file)))
    }
}
