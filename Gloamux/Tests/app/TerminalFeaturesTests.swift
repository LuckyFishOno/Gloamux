import XCTest
import Terminal
import Darwin
@testable import App

/// Recording redaction and format, runbooks, risky commands, container sessions, discovery, environments, host key
/// history, the command palette's search, and reachability probes.
@MainActor final class TerminalFeaturesTests: XCTestCase {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("features-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: Recording

    func testRedactionMasksSecretsAndKeepsOrdinaryText() {
        let text = """
        export AWS_ACCESS_KEY_ID=AKIAABCDEFGHIJKLMNOP
        token: ghp_abcdefghijklmnopqrstuvwxyz0123456789
        Authorization: Bearer abc.def-ghi_jkl
        password=hunter22 user=alice
        ls -la /var/log
        """
        let redacted = SecretRedaction.redact(text)
        XCTAssertFalse(redacted.contains("AKIAABCDEFGHIJKLMNOP"))
        XCTAssertFalse(redacted.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertFalse(redacted.contains("abc.def-ghi_jkl"))
        XCTAssertFalse(redacted.contains("hunter22"))
        XCTAssertTrue(redacted.contains("Bearer [REDACTED]"))
        XCTAssertTrue(redacted.contains("password=[REDACTED] user=alice"))
        XCTAssertTrue(redacted.contains("ls -la /var/log"))
    }

    func testRedactionFindsASecretSplitAcrossChunks() {
        let chunks: [(TimeInterval, String)] = [(0, "key AKIAABCDEF"), (0.5, "GHIJKLMNOP done\n"), (1, "next line\n")]
        let redacted = SecretRedaction.redact(chunks)
        XCTAssertEqual(redacted.count, 3)
        XCTAssertEqual(redacted[0].1, "key [REDACTED]")
        XCTAssertEqual(redacted[1].1, " done\n")
        XCTAssertEqual(redacted[2].1, "next line\n")
        XCTAssertEqual(redacted.map(\.0), [0, 0.5, 1])
    }

    func testPrivateKeyBlockIsRemovedWhole() {
        let text = "before\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n-----END OPENSSH PRIVATE KEY-----\nafter"
        XCTAssertEqual(SecretRedaction.redact(text), "before\n[REDACTED]\nafter")
    }

    func testAsciicastRoundTripKeepsSplitUTF8AndResizes() throws {
        let recorder = TerminalRecorder(title: "demo", columns: 100, rows: 30)
        let bytes = Array("終端 ok\r\n".utf8)
        recorder.output(Array(bytes[0..<2]))   // half of the first character
        recorder.output(Array(bytes[2...]))
        recorder.resize(rows: 40, columns: 120)
        recorder.output(Array("password=secret1\r\n".utf8))
        let url = try folder().appendingPathComponent("demo.cast")
        try recorder.asciicast().write(to: url)
        let (header, events) = try Asciicast.read(url)
        XCTAssertEqual(header.width, 100)
        XCTAssertEqual(header.height, 30)
        XCTAssertEqual(header.title, "demo")
        let output = events.filter { $0.kind == "o" }.map(\.data).joined()
        XCTAssertEqual(output, "終端 ok\r\npassword=[REDACTED]\r\n")
        XCTAssertEqual(events.first { $0.kind == "r" }?.data, "120x40")
        XCTAssertEqual(Asciicast.header(of: url)?.title, "demo")
    }

    func testAsciicastRejectsOtherFiles() throws {
        let url = try folder().appendingPathComponent("not.cast")
        try Data("{\"version\": 1}\n".utf8).write(to: url)
        XCTAssertThrowsError(try Asciicast.read(url))
        XCTAssertNil(Asciicast.header(of: url))
    }

    // MARK: Runbooks

    func testRunbookFindsShellBlocksAndShowsOthers() {
        let markdown = """
        # Restart web

        Check first.

        ```bash
        systemctl status nginx
        ```

        ```console
        $ uptime
         10:00 up 3 days
        # whoami
        ```

        ```json
        {"a": 1}
        ```

        ~~~sh
        echo done
        ~~~
        """
        let runbook = Runbook(markdown: markdown, fallbackTitle: "file")
        XCTAssertEqual(runbook.title, "Restart web")
        let code = runbook.blocks.compactMap { block -> String? in
            if case .code(_, _, let code) = block { return code }
            return nil
        }
        XCTAssertEqual(code, ["systemctl status nginx", "uptime\nwhoami", "echo done"])
        XCTAssertTrue(runbook.blocks.contains(.listing("{\"a\": 1}")))
        XCTAssertTrue(runbook.blocks.contains(.text("Check first.")))
        XCTAssertEqual(Runbook(markdown: "no heading", fallbackTitle: "file").title, "file")
    }

    // MARK: Risky commands and environments

    func testRiskyPatternsMatchDestructiveCommandsOnly() {
        for command in ["rm -rf /var/www", "sudo rm -fr build", "kubectl delete pod web-1", "DROP TABLE users;",
                        "delete from orders;", "terraform destroy", "git push --force origin main", "systemctl restart nginx",
                        "dd if=/dev/zero of=/dev/sda", "shutdown -h now"] {
            XCTAssertNotNil(RiskyCommands.match(command, patterns: RiskyCommands.defaults), command)
        }
        for command in ["ls -la", "rm notes.txt", "delete from orders where id = 4;", "kubectl get pods", "git push origin main",
                        "systemctl status nginx", "echo rmdir"] {
            XCTAssertNil(RiskyCommands.match(command, patterns: RiskyCommands.defaults), command)
        }
        XCTAssertNil(RiskyCommands.match("rm -rf x", patterns: ["(unclosed"]))
    }

    func testRiskyCommandIsHeldInConfirmingEnvironment() throws {
        let saved = UserDefaults.standard.object(forKey: "Gloamux.confirmEnvironments")
        defer { UserDefaults.standard.set(saved, forKey: "Gloamux.confirmEnvironments") }
        SessionEnvironment.confirming = [.production]
        let model = try WorkspaceModel(storage: folder())
        let tab = SessionTab()
        tab.environment = .production
        tab.typedLine = "rm -rf /srv/app"
        XCTAssertEqual(model.riskyCommand(in: tab, typing: [0x0D]), "rm -rf /srv/app")
        XCTAssertNil(model.riskyCommand(in: tab, typing: Array("x".utf8)), "nothing runs without Return")
        tab.environment = .development
        XCTAssertNil(model.riskyCommand(in: tab, typing: [0x0D]))
        tab.environment = .production
        tab.typedLine = "ls"
        XCTAssertNil(model.riskyCommand(in: tab, typing: [0x0D]))
    }

    func testEnvironmentIsInheritedFromFolders() throws {
        let store = try SessionTreeStore(url: folder().appendingPathComponent("sessions.json"))
        let prod = try store.add(name: "Prod", parent: nil)
        let web = try store.add(name: "Web", parent: prod)
        let host = try store.add(name: "web-1", parent: web, connection: SavedConnection(host: "web-1", port: 22, username: "ops"))
        XCTAssertNil(store.effectiveEnvironment(host))
        try store.setEnvironment(prod, .production)
        XCTAssertEqual(store.effectiveEnvironment(host), .production)
        try store.setEnvironment(host, .staging)
        XCTAssertEqual(store.effectiveEnvironment(host), .staging)
    }

    // MARK: Container sessions

    func testContainerCommandLinesAreQuoted() throws {
        let docker = ContainerSession(tool: .docker, target: "web", context: "prod", shell: "/bin/bash", user: "app")
        XCTAssertEqual(docker.commandLine, "docker --context prod exec -it -u app web /bin/bash")
        let pod = ContainerSession(tool: .kubectl, target: "api-7d9", context: "eks", namespace: "shop", container: "api")
        XCTAssertEqual(pod.commandLine, "kubectl --context eks -n shop exec -it api-7d9 -c api -- /bin/sh")
        let ssm = ContainerSession(tool: .ssm, target: "i-0abc", context: "dev", namespace: "ap-northeast-1")
        XCTAssertEqual(ssm.commandLine, "aws --profile dev --region ap-northeast-1 ssm start-session --target i-0abc")
        XCTAssertEqual(ContainerSession(tool: .docker, target: "web$(id)").commandLine, "docker exec -it 'web$(id)' /bin/sh")
        XCTAssertNoThrow(try docker.validate())
        XCTAssertThrowsError(try ContainerSession(tool: .docker, target: "--privileged").validate())
        XCTAssertThrowsError(try ContainerSession(tool: .docker, target: "web; rm").validate())
        XCTAssertThrowsError(try ContainerSession(tool: .docker, target: "").validate())
        XCTAssertNil(ContainerSession(tool: .docker, target: "web", context: "  ").context)
    }

    func testContainerSessionsAreSavedAsSessionsNotFolders() throws {
        let store = try SessionTreeStore(url: folder().appendingPathComponent("sessions.json"))
        let id = try store.add(name: "web", parent: nil, container: ContainerSession(tool: .docker, target: "web"), environment: .test)
        let node = try XCTUnwrap(store.node(id))
        XCTAssertFalse(node.isFolder)
        XCTAssertEqual(node.environment, .test)
        XCTAssertEqual(node.container?.target, "web")
    }

    // MARK: Discovery

    func testTailscaleStatusListsOnlinePeersFirst() throws {
        let json = """
        {"Peer": {
          "k1": {"ID": "1", "HostName": "zeta", "DNSName": "zeta.tail.ts.net.", "TailscaleIPs": ["100.64.0.2"], "Online": true, "OS": "linux"},
          "k2": {"ID": "2", "HostName": "alpha", "DNSName": "", "TailscaleIPs": ["100.64.0.3"], "Online": false, "OS": "macOS"},
          "k3": {"ID": "3", "HostName": "beta", "DNSName": "beta.tail.ts.net.", "Online": true}
        }}
        """
        let hosts = try HostDiscoveryParser.tailscale(Data(json.utf8))
        XCTAssertEqual(hosts.map(\.name), ["beta", "zeta", "alpha"])
        XCTAssertEqual(hosts[1].host, "zeta.tail.ts.net")
        XCTAssertEqual(hosts[2].host, "100.64.0.3")
        XCTAssertThrowsError(try HostDiscoveryParser.tailscale(Data("[]".utf8)))
    }

    func testEC2InstancesUseNameTagsAndBestAddress() throws {
        let json = """
        {"Reservations": [{"Instances": [
          {"InstanceId": "i-1", "State": {"Name": "running"}, "Tags": [{"Key": "Name", "Value": "web"}],
           "PublicDnsName": "", "PublicIpAddress": "3.3.3.3", "PrivateIpAddress": "10.0.0.1", "InstanceType": "t3.micro"},
          {"InstanceId": "i-2", "State": {"Name": "stopped"}, "PrivateIpAddress": "10.0.0.2"}
        ]}]}
        """
        let hosts = try HostDiscoveryParser.ec2(Data(json.utf8), region: "us-east-1")
        XCTAssertEqual(hosts.map(\.name), ["i-2", "web"])
        let web = try XCTUnwrap(hosts.first { $0.name == "web" })
        XCTAssertEqual(web.host, "3.3.3.3")
        XCTAssertTrue(web.online)
        XCTAssertEqual(web.instanceID, "i-1")
        XCTAssertEqual(web.region, "us-east-1")
        XCTAssertFalse(hosts[0].online)
    }

    // MARK: Host key history

    func testHostKeyHistoryIsRecordedAndCleared() throws {
        let dir = try folder()
        let known = try KnownHosts(url: dir.appendingPathComponent("known-hosts.json"))
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
        let other = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA4d7lMa3qVkn+R1XHlIlYOFGVUGBJx8rQm7z+r6yA3V"
        known.record(.trusted, endpoint: "[web]:22", key: key)
        known.record(.blocked, endpoint: "[web]:22", key: other, previous: key)
        known.record(.trusted, endpoint: "[bad]:22", key: "not a key")
        XCTAssertEqual(known.history.map(\.action), [.trusted, .blocked])
        XCTAssertEqual(known.history[1].previousFingerprint, known.history[0].fingerprint)
        let reloaded = try KnownHosts(url: dir.appendingPathComponent("known-hosts.json"))
        XCTAssertEqual(reloaded.history.count, 2)
        reloaded.clearHistory()
        XCTAssertTrue(try KnownHosts(url: dir.appendingPathComponent("known-hosts.json")).history.isEmpty)
    }

    // MARK: Command palette and links

    func testPaletteSearchRanksPrefixesFirstAndNeedsEveryWord() {
        let commands = ["Split side by side", "New connection", "Previous prompt", "Production web"].enumerated().map { index, title in
            PaletteCommand(id: "\(index)", title: title, symbol: "circle", section: "Test") {}
        }
        XCTAssertEqual(Set(PaletteSearch.filter(commands, query: "pr").map(\.title).prefix(2)), ["Previous prompt", "Production web"])
        XCTAssertEqual(PaletteSearch.filter(commands, query: "web").first?.title, "Production web")
        XCTAssertEqual(PaletteSearch.filter(commands, query: "split side").map(\.title), ["Split side by side"])
        XCTAssertEqual(PaletteSearch.filter(commands, query: "nwcn").map(\.title), ["New connection"])
        XCTAssertTrue(PaletteSearch.filter(commands, query: "zzz").isEmpty)
        XCTAssertEqual(PaletteSearch.filter(commands, query: "").count, 4)
    }

    func testURLSchemeOpensOnlySavedSessions() throws {
        let model = try WorkspaceModel(storage: folder())
        let before = model.tabs.count
        XCTAssertFalse(model.open(url: URL(string: "gloamux://open?id=\(UUID().uuidString)")!))
        XCTAssertFalse(model.open(url: URL(string: "gloamux://connect?host=evil.example")!))
        XCTAssertFalse(model.open(url: URL(string: "https://example.com")!))
        XCTAssertEqual(model.tabs.count, before)
    }

    // MARK: Reachability

    func testReachabilityProbeSeesAListeningPortAndAClosedOne() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, length) } }
        XCTAssertEqual(listen(listener, 4), 0)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        let port = Int(UInt16(bigEndian: address.sin_port))
        let open = await Reachability.probe(host: "127.0.0.1", port: port, timeout: 2)
        XCTAssertTrue(open)
        close(listener)
        let closed = await Reachability.probe(host: "127.0.0.1", port: port, timeout: 2)
        XCTAssertFalse(closed)
        let invalid = await Reachability.probe(host: "", port: 22, timeout: 1)
        XCTAssertFalse(invalid)
    }

    // MARK: Benchmark

    func testBenchmarkWorkloadsParseAndRender() {
        for workload in TerminalBenchmark.workloads(columns: 80) {
            let screen = TerminalBenchmark.screen(columns: 80, rows: 24)
            screen.feed(workload.chunk)
            XCTAssertLessThan(TerminalBenchmark.redrawMilliseconds(screen, frames: 1), 1000, workload.name)
        }
        let echo = TerminalBenchmark.keystrokeLatency(columns: 80, rows: 24, samples: 50)
        XCTAssertLessThanOrEqual(echo.p50, echo.p99)
    }
}

/// Session logs, the paste check, and the escape stripper.
@MainActor final class TerminalLogTests: XCTestCase {
    func testPlainLogStripsEscapesAndMasksSecrets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("logs-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.log")
        let logger = try TerminalLogger(url: url, title: "test", format: .text)
        _ = logger.output(Array("\u{1b}[1;32mok\u{1b}[0m\r\nexport TOKEN=abcdef123\r\n\u{1b}]0;title\u{07}".utf8))
        _ = logger.output(Array("-----BEGIN OPENSSH PRIVATE KEY-----\r\nAAAA\r\n".utf8))
        _ = logger.output(Array("BBBB\r\n-----END OPENSSH PRIVATE KEY-----\r\ndone".utf8))
        logger.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# Gloamux log · test · "))
        XCTAssertTrue(text.contains("\nok\n"))
        XCTAssertTrue(text.contains("TOKEN=[REDACTED]"))
        XCTAssertFalse(text.contains("AAAA"))
        XCTAssertFalse(text.contains("BBBB"))
        XCTAssertTrue(text.hasSuffix("done"))
        XCTAssertFalse(text.contains("\u{1b}"))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testRawLogKeepsEscapes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("logs-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.ansi.log")
        let logger = try TerminalLogger(url: url, title: "test", format: .raw)
        _ = logger.output(Array("\u{1b}[31mred\u{1b}[0m\r\n".utf8))
        logger.close()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "\u{1b}[31mred\u{1b}[0m\r\n")
    }

    func testEscapeStripperWorksAcrossChunks() {
        var stripper = EscapeStripper()
        let out = stripper.strip(Array("a\u{1b}[3".utf8)) + stripper.strip(Array("1mb\u{1b}]8;;http://x\u{1b}".utf8)) + stripper.strip(Array("\\c".utf8))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "abc")
    }

    func testMultilinePasteDetection() {
        XCTAssertFalse(TerminalKeyboard.isMultiline("ls -la"))
        XCTAssertFalse(TerminalKeyboard.isMultiline("ls -la\n"))
        XCTAssertTrue(TerminalKeyboard.isMultiline("cd /tmp\nrm -rf x"))
        XCTAssertTrue(TerminalKeyboard.isMultiline("a\r\nb\r\n"))
    }

    func testZoomStaysWithinLimits() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: TerminalPreferences.fontSizeKey)
        defer { if let saved { defaults.set(saved, forKey: TerminalPreferences.fontSizeKey) } else { defaults.removeObject(forKey: TerminalPreferences.fontSizeKey) } }
        let top = TerminalPreferences.fontSizes.upperBound
        defaults.set(top - 1, forKey: TerminalPreferences.fontSizeKey)
        TerminalPreferences.zoom(1); TerminalPreferences.zoom(1)
        XCTAssertEqual(TerminalPreferences.fontSize, top)
        defaults.set(TerminalPreferences.fontSizes.lowerBound + 1, forKey: TerminalPreferences.fontSizeKey)
        TerminalPreferences.zoom(-1); TerminalPreferences.zoom(-1)
        XCTAssertEqual(TerminalPreferences.fontSize, TerminalPreferences.fontSizes.lowerBound)
        TerminalPreferences.zoom(0)
        XCTAssertEqual(TerminalPreferences.fontSize, 13)
        let fonts = TerminalFonts.make(name: "", size: 20)
        XCTAssertGreaterThan(fonts.cellWidth, TerminalFonts.standard.cellWidth)
    }
}
