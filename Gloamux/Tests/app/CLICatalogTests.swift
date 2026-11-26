import XCTest
@testable import App

/// The command catalog is the one list of public commands and operations: help, completion, and the workspace
/// commands that run must all agree with it.
@MainActor final class CLICatalogTests: XCTestCase {
    private func workspace() throws -> WorkspaceModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-catalog-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = try WorkspaceModel(storage: root)
        model.confirmOwner = { _ in throw CancellationError() }
        return model
    }

    private func words(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted))
    }

    func testNamesAndOperationsAreUnique() {
        let names = CLICatalog.commands.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(CLICatalog.internalCommands.isDisjoint(with: names), "Internal requests are not public commands")
        for command in CLICatalog.commands {
            XCTAssertEqual(Set(command.operations).count, command.operations.count, command.name)
            XCTAssertFalse(command.summary.isEmpty, command.name)
        }
        XCTAssertEqual(Set(CLICatalog.filePaths.keys), Set(CLICatalog.command("files")?.operations ?? []))
    }

    /// `gloamux web --help --workspace PATH` refused `--help` as an unknown option, because only `--help` alone was
    /// taken as a request for help.
    func testHelpIsRecognizedNextToAWorkspace() {
        XCTAssertTrue(CLICatalog.asksForHelp(["--help"]))
        XCTAssertTrue(CLICatalog.asksForHelp(["-h"]))
        XCTAssertTrue(CLICatalog.asksForHelp(["--help", "--workspace", "/tmp/w"]))
        XCTAssertTrue(CLICatalog.asksForHelp(["--workspace", "/tmp/w", "-h"]))
        XCTAssertFalse(CLICatalog.asksForHelp([]))
        XCTAssertFalse(CLICatalog.asksForHelp(["--workspace", "/tmp/w"]))
        XCTAssertFalse(CLICatalog.asksForHelp(["list", "--help"]))
        XCTAssertFalse(CLICatalog.asksForHelp(["--workspace", "--help"]), "--help here is the workspace path")
    }

    func testTheUsageListsEveryCommand() {
        let lines = CLICatalog.usage.components(separatedBy: "\n")
        for command in CLICatalog.commands {
            let line = "  " + command.name.padding(toLength: 13, withPad: " ", startingAt: 0) + command.summary
            XCTAssertTrue(lines.contains(line), command.name)
        }
        XCTAssertTrue(lines.contains("  --version    Print the app version"))
        XCTAssertFalse(CLICatalog.usage.hasSuffix("…") || CLICatalog.usage.hasSuffix("..."))
    }

    func testEachCommandsHelpExplainsEveryOperation() {
        for command in CLICatalog.commands where !command.operations.isEmpty && command.runner != .completion {
            let help = try? XCTUnwrap(command.help, command.name)
            let mentioned = words(help ?? "")
            for operation in command.operations {
                XCTAssertTrue(mentioned.contains(operation), "\(command.name) --help does not mention \(operation)")
            }
        }
        XCTAssertEqual(CLICatalog.choice("completion"), "Usage: gloamux completion zsh|bash")
        XCTAssertEqual(CLICatalog.choice("xserver"), "Usage: gloamux xserver status|start")
    }

    /// Local file arguments are made absolute at the command line; other arguments and absolute paths stay as typed.
    func testLocalPathArgumentsAreResolvedAtTheCommandLine() {
        let here = URL(fileURLWithPath: "/Users/ops/work", isDirectory: true)
        let resolve = { CLICatalog.resolvingLocalPaths($0, from: here) }
        XCTAssertEqual(resolve(["sessions", "import", "openssh", "config", "Imported"]),
                       ["sessions", "import", "openssh", "/Users/ops/work/config", "Imported"])
        XCTAssertEqual(resolve(["sessions", "export", "csv", "../out.csv"]), ["sessions", "export", "csv", "/Users/ops/out.csv"])
        XCTAssertEqual(resolve(["runbooks", "import", "deploy.md"]), ["runbooks", "import", "/Users/ops/work/deploy.md"])
        XCTAssertEqual(resolve(["config", "export", "/tmp/backup.json"]), ["config", "export", "/tmp/backup.json"])
        XCTAssertEqual(resolve(["tabs", "colors", "TAB", "./dark.xcs"]), ["tabs", "colors", "TAB", "/Users/ops/work/dark.xcs"])
        XCTAssertEqual(resolve(["sessions", "rename", "Web", "web.md"]), ["sessions", "rename", "Web", "web.md"], "Not a path")
        XCTAssertEqual(resolve(["sessions", "import"]), ["sessions", "import"], "Missing arguments stay missing")
        for command in CLICatalog.commands {
            XCTAssertTrue(Set(command.localPaths.keys).isSubset(of: command.operations), command.name)
        }
    }

    /// The help shows how to type a value; the startup option reads a typed \n as a line break.
    func testHelpShowsArgumentsAsTheyAreTyped() throws {
        let help = try XCTUnwrap(CLICatalog.command("sessions")?.help)
        XCTAssertTrue(help.contains(#"startup='COMMAND\nCOMMAND'"#), help)
    }

    /// Every listed operation reaches its handler: whatever it reports about the arguments, it is not unknown.
    func testEveryListedOperationRuns() async throws {
        let missing = "/gloamux-missing-\(UUID())"
        for command in CLICatalog.commands where command.runner == .workspace {
            for operation in command.operations {
                let model = try workspace()
                do {
                    _ = try await WorkspaceCommand.run([command.name, operation, missing], model: model, live: true)
                } catch let usage as WorkspaceCommand.Usage {
                    XCTAssertFalse(usage.detail.hasSuffix(" operation.") || usage.detail == "Unknown workspace command.",
                                   "\(command.name) \(operation): \(usage.detail)")
                } catch {}
            }
        }
    }

    /// An operation that is not listed is a usage error, the same with or without the running app.
    func testAnUnlistedOperationIsAUsageErrorEverywhere() async throws {
        let model = try workspace()
        for command in CLICatalog.commands where command.runner == .workspace {
            for live in [false, true] {
                do {
                    _ = try await WorkspaceCommand.run([command.name, "bogus"], model: model, live: live)
                    XCTFail("\(command.name) bogus ran")
                } catch let usage as WorkspaceCommand.Usage {
                    XCTAssertEqual(usage.detail, "Unknown \(command.name) operation.", "live: \(live)")
                }
            }
        }
        for name in ["files", "xserver", "nonsense"] {
            do {
                _ = try await WorkspaceCommand.run([name, "list"], model: model, live: true)
                XCTFail("\(name) ran as a workspace command")
            } catch let usage as WorkspaceCommand.Usage {
                XCTAssertEqual(usage.detail, "Unknown workspace command.")
            }
        }
    }
}
