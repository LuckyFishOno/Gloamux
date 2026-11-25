import XCTest
import Terminal
@testable import App

@MainActor final class CommandCaptureTests: XCTestCase {
    private var commands: [String] = []
    private var screen = TerminalScreen()
    private var capture: CommandCapture!

    override func setUp() async throws {
        commands = []
        screen = TerminalScreen()
        capture = CommandCapture { [unowned self] in commands.append($0) }
    }

    private func type(_ text: String) { capture.sent(Array(text.utf8), on: screen) }
    private func show(_ text: String) { capture.feed(Array(text.utf8), to: screen) }

    func testTypedRecalledAndCompletedCommands() {
        show("Welcome\r\ndeploy@web:~$ ")
        for key in "ls -la" { type(String(key)); show(String(key)) }
        type("\r"); show("\r\ntotal 0\r\ndeploy@web:~$ ")
        // Up arrow: the shell shows the line, which was never typed.
        type("\u{1b}[A"); show("ls -la")
        type("\r"); show("\r\ntotal 0\r\ndeploy@web:~$ ")
        // Tab completes the word; a second one lists the choices and draws the prompt again.
        type("cat no"); show("cat no"); type("\t"); show("tes")
        type("\t"); show("\r\nnotes.md notes.txt\r\ndeploy@web:~$ cat notes")
        type(".md\r"); show(".md\r\nhello\r\ndeploy@web:~$ ")
        // Return alone and an interrupted line are not commands.
        type("\r"); show("\r\ndeploy@web:~$ ")
        type("rm x"); show("rm x"); type("\u{3}"); show("^C\r\ndeploy@web:~$ ")
        type("uptme\u{7f}\u{7f}ime\r"); show("uptme\u{8} \u{8}\u{8} \u{8}ime\r\n 10:00 up\r\ndeploy@web:~$ ")
        XCTAssertEqual(commands, ["ls -la", "ls -la", "cat notes.md", "uptime"])
    }

    func testPasswordsAreNeverPartOfIt() {
        show("deploy@web:~$ ")
        type("sudo id\r"); show("sudo id\r\n[sudo] password for deploy: ")
        type("hunter22\r"); show("\r\nuid=0(root)\r\ndeploy@web:~$ ")
        show("Password:")
        type("hunter22\r"); show("********\r\nhunter22 is wrong\r\n")
        show("Passphrase\r\n")
        type("hunter22\r"); show("\r\nhunter23\r\n")
        XCTAssertEqual(commands, ["sudo id"])
        commands = []
        // `read -s` echoes no line end, so the next prompt follows on the same line.
        show("$ "); type("read -s X\r"); show("read -s X\r\n"); type("hunter22\r"); show("$ ")
        for key in "ls /" { type(String(key)); show(String(key)) }
        type("\r"); show("\r\nbin\r\n$ ")
        type("\u{1b}[A"); show("pwd"); type("\r"); show("\r\n/\r\n")
        XCTAssertEqual(commands, ["read -s X", "ls /", "pwd"])
    }

    func testTypedAheadAndSeveralLines() {
        // Startup commands are sent before the shell has drawn its prompt.
        type("cd /srv\rgit status\r")
        show("cd /srv\r\ngit status\r\nLast login\r\n\r\n$ cd /srv\r\n$ git status\r\nclean\r\n$ ")
        XCTAssertEqual(commands, ["cd /srv", "git status"])
        commands = []
        type("\u{1b}[200~echo a\recho b\u{1b}[201~\r")
        show("echo a\r\n> echo b\r\na\r\nb\r\n$ ")
        XCTAssertEqual(commands, ["echo a", "echo b"])
        commands = []
        // The echo of the last keys comes after Return was sent, in pieces.
        type("make test"); show("make"); type("\r"); show(" te"); show("st\r"); show("\nok\r\n$ ")
        XCTAssertEqual(commands, ["make test"])
        commands = []
        // Continuation lines are read one by one.
        type("for i in 1 2; do"); show("for i in 1 2; do"); type("\r"); show("\r\n> ")
        type("echo $i; done\r"); show("echo $i; done\r\n1\r\n2\r\n$ ")
        XCTAssertEqual(commands, ["for i in 1 2; do", "echo $i; done"])
    }

    func testLongLinesRightPromptsAndOtherPrompts() {
        screen.resize(rows: 10, cols: 30)
        let long = "echo " + String(repeating: "abcdefghij", count: 6)
        show("$ "); type("\u{1b}[A"); show(long); type("\r"); show("\r\nok\r\n")
        XCTAssertEqual(commands, [long])
        commands = []
        show("% \u{1b}[22G10:22:31\u{1b}[3G")
        type("\u{1b}[A"); show("ls"); type("\r"); show("\r\n")
        XCTAssertEqual(commands, ["ls"])
        commands = []
        // A prompt that changes when the line is accepted.
        show("~/src main ❯ "); type("\u{1b}[A"); show("git pull"); type("\r"); show("\r\u{1b}[K❯ git pull\r\n")
        XCTAssertEqual(commands, ["git pull"])
        commands = []
        show("$ "); type("ls\u{c}"); show("ls\u{1b}[H\u{1b}[2J$ ls"); type(" -a\r"); show(" -a\r\n")
        XCTAssertEqual(commands, ["ls -a"])
        commands = []
        show("$ \u{1b}]133;A\u{7}host> \u{1b}]133;B\u{7}"); type("\u{1b}[A"); show("id"); type("\r"); show("\r\n\u{1b}]133;C\u{7}uid\r\n")
        XCTAssertEqual(commands, ["id"])
    }

    func testFullScreenPrograms() {
        show("$ "); type("vim a\r"); show("vim a\r\n\u{1b}[?1049h\u{1b}[H")
        type("isecret text\r"); show("secret text\r\n")
        XCTAssertEqual(commands, ["vim a"])
        // tmux: a shell prompt inside a full-screen program.
        show("\u{1b}[2J\u{1b}[Hdeploy@web:~$ "); type("df -h"); show("df -h"); type("\r"); show("\r\n")
        show("[sudo] password for deploy: "); type("hunter22\r"); show("\r\n")
        XCTAssertEqual(commands, ["vim a", "df -h"])
        show("\u{1b}[?1049l$ "); type("q"); show("q\u{1b}[?1049hfile"); type("q"); show("\u{1b}[?1049l\r\n$ ")
        type("id\r"); show("id\r\n\u{1b}[?1049h")
        XCTAssertEqual(commands, ["vim a", "df -h", "id"])
        // Focus reports are not keys.
        show("\u{1b}[?1049l\r\n$ "); type("\u{1b}[I\r"); show("\r\n$ ")
        XCTAssertEqual(commands.count, 3)
    }
}
