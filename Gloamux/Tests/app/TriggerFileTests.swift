import XCTest
import AppKit
@testable import App

/// `gloamux triggers` on a workspace whose triggers.json is damaged: the damage is reported, the file is never
/// replaced, and a repaired file works again without reopening Gloamux.
@MainActor final class TriggerFileTests: XCTestCase {
    private func workspace(damaged: Bool = true) throws -> (WorkspaceModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-triggers-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("triggers.json")
        if damaged { try Data("[{\"id\": \"not finished".utf8).write(to: file) }
        return (try WorkspaceModel(storage: root), file)
    }

    @discardableResult
    private func run(_ argv: [String], _ model: WorkspaceModel) async throws -> Any {
        let data = try await WorkspaceCommand.run(argv, model: model, live: false)
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    func testADamagedTriggerFileIsReportedAndNeverOverwritten() async throws {
        let (model, file) = try workspace()
        let damaged = try Data(contentsOf: file)

        do { try await run(["triggers", "list"], model); XCTFail("A damaged file listed as no triggers") }
        catch WorkspaceError.invalid(let reason) { XCTAssertTrue(reason.contains("damaged"), reason) }
        do { try await run(["triggers", "add", "Errors", "ERROR"], model); XCTFail("A damaged file was replaced") }
        catch WorkspaceError.invalid {}
        XCTAssertEqual(try Data(contentsOf: file), damaged, "The damaged file is left for the user to repair")

        // Repaired on disk: the next command reads it again.
        let kept = OutputTrigger(name: "Deploys", pattern: "deploy done")
        try JSONEncoder().encode([kept]).write(to: file)
        let listed = try await run(["triggers", "list"], model) as? [[String: Any]]
        XCTAssertEqual(listed?.map { $0["name"] as? String }, ["Deploys"])
        try await run(["triggers", "add", "Errors", "ERROR"], model)
        let saved = try JSONDecoder().decode([OutputTrigger].self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.map(\.name), ["Deploys", "Errors"])
    }

    func testAMissingTriggerFileStartsEmpty() async throws {
        let (model, file) = try workspace(damaged: false)
        let listed = try await run(["triggers", "list"], model) as? [Any]
        XCTAssertEqual(listed?.count, 0)
        try await run(["triggers", "add", "Errors", "ERROR"], model)
        XCTAssertEqual(try JSONDecoder().decode([OutputTrigger].self, from: Data(contentsOf: file)).count, 1)
    }
}
