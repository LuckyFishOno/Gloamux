import XCTest
@testable import App

final class SFTPCommandTests: XCTestCase {
    private let key = "12345678exampleKEYexampleKEY0123"

    private var pasted: String {
        """
        sftp -P 4997 \\
          -o PreferredAuthentications=keyboard-interactive \\
          -o KbdInteractiveAuthentication=yes \\
          \(key)@192.0.2.10
        lcd /Users/someone/Downloads
        get "/tmp/report_29Sep2026_10-38-13.csv"
        """
    }

    func testAWholePastedCommand() throws {
        let command = try SFTPCommand.parse(pasted)
        XCTAssertEqual(command.connection.host, "192.0.2.10")
        XCTAssertEqual(command.connection.port, 4997)
        XCTAssertEqual(command.connection.username, key)
        XCTAssertEqual(command.connection.signIn, .questions)
        XCTAssertEqual(command.connection.fileProtocol, .sftp)
        XCTAssertEqual(command.localFolder, "/Users/someone/Downloads")
        XCTAssertEqual(command.startFolder, "/tmp")
        XCTAssertEqual(command.transfers, [.get(remote: "/tmp/report_29Sep2026_10-38-13.csv", local: nil, recursive: false)])
        XCTAssertEqual(command.ignored, [])
    }

    /// A one-line field turns line ends into spaces.
    func testLinesJoinedByAOneLineField() throws {
        XCTAssertEqual(try SFTPCommand.parse(pasted.replacingOccurrences(of: "\n", with: " ")), try SFTPCommand.parse(pasted))
    }

    func testOtherForms() throws {
        let plain = try SFTPCommand.parse("sftp -oPort=2022 deploy@example.com:/srv/files")
        XCTAssertEqual(plain.connection.port, 2022)
        XCTAssertNil(plain.connection.signIn)
        XCTAssertEqual(plain.remotePath, "/srv/files")
        let address = try SFTPCommand.parse("sftp://deploy@example.com:2022/srv")
        XCTAssertEqual([address.connection.username, address.connection.host, address.remotePath], ["deploy", "example.com", "/srv"])
        XCTAssertEqual(address.connection.port, 2022)
        let gateway = try SFTPCommand.parse("sftp admin@target@gateway.example.com")
        XCTAssertEqual([gateway.connection.username, gateway.connection.host], ["admin@target", "gateway.example.com"])
        XCTAssertEqual(try SFTPCommand.parse("sftp u@[2001:db8::1]:/x").connection.host, "2001:db8::1")
        XCTAssertEqual(try SFTPCommand.parse("$ sftp u@h\nsftp> get “/a b.csv”").transfers, [.get(remote: "/a b.csv", local: nil, recursive: false)])
        XCTAssertEqual(try SFTPCommand.parse("sftp u@h\nget -r /logs out\nput a\\ b.txt /in/\nget *.csv\n!rm -rf x\nbye").ignored, ["get *.csv", "!rm -rf x"])
    }

    /// Options that change where the connection goes or run a program are refused, not dropped.
    func testRefusesWhatItCannotFollow() {
        for text in ["sftp -J jump u@h", "sftp -o ProxyCommand=evil u@h", "sftp -oProxyJump=x u@h", "sftp -F /tmp/config u@h", "sftp -S /bin/x u@h",
                     "sftp -o 'LocalCommand x' u@h", "sftp", "sftp -P 99999 u@h", "sftp u@-oProxyCommand=x", "sftp \"u@h", "ssh u@h", "rm -rf /"] {
            XCTAssertThrowsError(try SFTPCommand.parse(text), text)
        }
        XCTAssertFalse(SFTPCommand.looksLike("sftpserver"))
        XCTAssertTrue(SFTPCommand.looksLike("sftp -P 1 u@h"))
    }

    func testReadingASessionKey() throws {
        func read(_ text: String) throws -> String { try SessionKey.read(text, host: "192.0.2.10", port: 4997).key }
        XCTAssertEqual(try read(" \(key)\n"), key)
        XCTAssertEqual(try read("\(key)@192.0.2.10"), key)
        XCTAssertEqual(try read(pasted), key)
        XCTAssertEqual(try SessionKey.read(pasted.replacingOccurrences(of: "\n", with: ""), host: "192.0.2.10", port: 4997).key, key)
        XCTAssertEqual(try SessionKey.read(pasted, host: "192.0.2.10", port: 4997).command?.transfers.count, 1)
        // A command for another server does not send its key to this one.
        XCTAssertThrowsError(try SessionKey.read(pasted, host: "192.0.2.11", port: 4997))
        XCTAssertThrowsError(try SessionKey.read(pasted, host: "192.0.2.10", port: 22))
        for bad in ["", "  ", "two words"] { XCTAssertThrowsError(try read(bad)) }
    }

    func testMasking() {
        XCTAssertEqual(SessionKey.masked(key), "1234••••")
        for name in ["root", "deploy", "firstname.lastname.department", "admin@target.example.com1234"] { XCTAssertEqual(SessionKey.masked(name), name) }
    }

    func testSessionKeySettings() throws {
        var connection = SavedConnection(host: "h", username: "")
        XCTAssertThrowsError(try connection.validate())
        connection.signIn = .sessionKey
        connection.remoteFolder = "/tmp"
        XCTAssertNoThrow(try connection.validate())
        XCTAssertEqual(try JSONDecoder().decode(SavedConnection.self, from: JSONEncoder().encode(connection)), connection)
        connection.identityPath = "/key"
        XCTAssertThrowsError(try connection.validate())
    }
}
