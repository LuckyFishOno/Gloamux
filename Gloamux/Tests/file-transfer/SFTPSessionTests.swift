import Citadel
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import XCTest
@testable import App
@testable import Ssh

/// A gateway that takes a session key in place of the user name and asks one question, and allows one key only.
private final class GatewayAuth: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [.password, .keyboardInteractive]
    private let lock = NSLock()
    private var keys: Set<String>
    init(keys: Set<String>) { self.keys = keys }
    func replace(_ keys: Set<String>) { lock.withLock { self.keys = keys } }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        responsePromise.succeed(.failure)
    }
    func keyboardInteractive(username: String, responses: [String]?, stepPromise: EventLoopPromise<NIOSSHKeyboardInteractiveStep>) {
        let known = lock.withLock { keys.contains(username) }
        if let responses { stepPromise.succeed(.outcome(known && responses == ["42"] ? .success : .failure)) }
        else if known { stepPromise.succeed(.challenge(.init(name: "", instruction: "", prompts: [.init(text: "Code: ", echo: false)]))) }
        else { stepPromise.succeed(.outcome(.failure)) }
    }
}

@MainActor final class SFTPSessionTests: XCTestCase {
    private let key = "12345678exampleKEYexampleKEY0123"
    private let nextKey = "87654321exampleKEYexampleKEY9999"

    private func wait(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<500 { if condition() { return }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTFail("timed out: \(what)")
    }

    /// Paste once, then open the saved session with only a new key: the key is never stored, and each connection is recorded.
    func testPastedOnceThenOnlyTheKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-sftp-\(UUID())", isDirectory: true)
        let downloads = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = GatewayAuth(keys: [key])
        let files = MemorySFTP()
        files.put("/tmp/a.csv", Array("one".utf8)); files.put("/tmp/b.csv", Array("two!".utf8))
        var server: SSHServer?
        var port = 0
        for _ in 0..<12 where server == nil {
            port = Int.random(in: 49152...65500)
            server = try? await SSHServer.host(host: "127.0.0.1", port: port, hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], authenticationDelegate: auth)
        }
        let running = try XCTUnwrap(server)
        running.enableSFTP(withDelegate: files)

        let workspace = root.appendingPathComponent("workspace")
        let model = try WorkspaceModel(storage: workspace)
        let command = try SFTPCommand.parse("sftp -P \(port) -o PreferredAuthentications=keyboard-interactive \(key)@127.0.0.1\nlcd \(downloads.path)\nget /tmp/a.csv")
        let id = try model.saveSFTPSession(command, name: "Gateway", parent: nil, asksKey: true, localFolder: downloads.path,
                                           connects: true, copies: true, replaces: false)
        let saved = try XCTUnwrap(model.sessionTree.node(id)?.connection)
        XCTAssertEqual(saved.username, "")
        XCTAssertEqual(saved.remoteFolder, "/tmp")
        XCTAssertEqual(saved.localFolder, downloads.path)
        let first = try XCTUnwrap(model.selected)
        await wait("host key") { first.hostKeyPrompt != nil }
        model.answerHostKey(first, approve: true)
        await wait("question") { first.loginChallenge != nil }
        XCTAssertEqual(first.loginChallenge?.asksSessionKey, false)
        model.answerLogin(first, answers: ["42"])
        let copy = downloads.appendingPathComponent("a.csv")
        await wait("copy") { FileManager.default.fileExists(atPath: copy.path) && !model.transfers.isActive }
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "one")
        XCTAssertFalse(first.account.contains(key))
        await first.savedConnectionTask?.value
        await model.disconnect(first)

        // The key stopped working: it is refused once, forgotten, and asked for the next time.
        auth.replace([nextKey])
        let node = try XCTUnwrap(model.sessionTree.node(id))
        let refused = try XCTUnwrap(model.openSaved(node))
        await refused.savedConnectionTask?.value
        XCTAssertEqual(refused.error, SignInRefused().errorDescription)
        XCTAssertNil(model.sessionTree.sessionKeys[id])
        let second = try XCTUnwrap(model.openSaved(node))
        await wait("session key") { second.loginChallenge?.asksSessionKey == true }
        model.answerLogin(second, answers: ["sftp -P \(port) \(nextKey)@127.0.0.1\nget /tmp/b.csv"])
        await wait("question") { second.loginChallenge?.asksSessionKey == false }
        model.answerLogin(second, answers: ["42"])
        await wait("copy") { FileManager.default.fileExists(atPath: downloads.appendingPathComponent("b.csv").path) && !model.transfers.isActive }
        await second.savedConnectionTask?.value
        XCTAssertEqual(model.sessionTree.sessionKeys[id], nextKey)
        await model.disconnect(second)

        model.history.reload()
        XCTAssertEqual(model.history.records.map { $0.state(open: false) }, [.closed, .failed, .closed])
        XCTAssertEqual(model.history.records.map { $0.transfers.compactMap(\.detail) }, [["/tmp/b.csv"], [], ["/tmp/a.csv"]])
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: workspace, includingPropertiesForKeys: nil))
        for case let url as URL in walker {
            guard let data = try? Data(contentsOf: url) else { continue }
            for secret in [key, nextKey] { XCTAssertNil(data.range(of: Data(secret.utf8)), "\(url.lastPathComponent) holds a session key") }
        }

        // The same through the command, which asks for the key and then the server's question.
        let asked = Asked([nextKey, "42"])
        let fingerprint = try KnownHosts.fingerprint(try XCTUnwrap(model.knownHosts.trustedKey(for: KnownHosts.endpoint(host: "127.0.0.1", port: port))))
        let names = try await model.withFileConnection(node, protocol: "sftp", secret: nil, allowPlainFTP: false,
                                                       access: FileCommandAccess(hostKeys: [fingerprint], answer: { _ in [asked.next()] })) { fs in
            try await fs.listDirectory("/tmp").map(\.name).sorted()
        }
        XCTAssertEqual(names, ["a.csv", "b.csv"])
        model.history.reload()
        XCTAssertEqual(model.history.records.first?.source, "cli")
        XCTAssertEqual(model.history.records.first?.state(open: false), .closed)
        try await running.close()
    }

    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String]
        init(_ answers: [String]) { self.answers = answers }
        func next() -> String { lock.withLock { answers.isEmpty ? "" : answers.removeFirst() } }
    }
}
