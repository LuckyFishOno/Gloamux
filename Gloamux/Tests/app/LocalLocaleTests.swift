import AppKit
import XCTest
@testable import App

/// Local shells get a UTF-8 locale as they do in Terminal, so non-ASCII names show in `ls` and in prompts with any
/// zsh theme, not only with themes that set the locale themselves.
@MainActor final class LocalLocaleTests: XCTestCase {
    override func setUp() async throws { _ = NSApplication.shared }

    func testALocaleFollowsTheMacAndKeepsOneAlreadySet() {
        XCTAssertEqual(LocalLaunch.localeEnvironment([:], locale: Locale(identifier: "zh_TW")), ["LANG": "zh_TW.UTF-8"])
        XCTAssertEqual(LocalLaunch.localeEnvironment([:], locale: Locale(identifier: "ja_JP")), ["LANG": "ja_JP.UTF-8"])
        XCTAssertEqual(LocalLaunch.localeEnvironment([:], locale: Locale(identifier: "en_US")), ["LANG": "en_US.UTF-8"])
        // A language and region this Mac has no locale for.
        XCTAssertEqual(LocalLaunch.localeEnvironment([:], locale: Locale(identifier: "xx_ZZ")), ["LANG": "en_US.UTF-8"])
        XCTAssertEqual(LocalLaunch.localeEnvironment(["LANG": ""], locale: Locale(identifier: "en_US")), ["LANG": "en_US.UTF-8"])
        for name in ["LANG", "LC_ALL", "LC_CTYPE"] {
            XCTAssertEqual(LocalLaunch.localeEnvironment([name: "C"], locale: Locale(identifier: "zh_TW")), [:], name)
        }
    }

    func testSSHSessionsSendTheAppsOwnLocaleOrTheMacs() {
        XCTAssertEqual(LocalLaunch.sshEnvironment(["LANG": "de_DE.UTF-8", "LC_CTYPE": "UTF-8", "LC_EMPTY": "", "HOME": "/x"], locale: Locale(identifier: "zh_TW")),
                       ["LANG": "de_DE.UTF-8", "LC_CTYPE": "UTF-8"], "Variables the app was started with go as they are.")
        XCTAssertEqual(LocalLaunch.sshEnvironment(["HOME": "/x"], locale: Locale(identifier: "zh_TW")), ["LANG": "zh_TW.UTF-8"],
                       "Started from Finder, the Mac's language and region.")
    }

    func testNonASCIINamesShowInALocalTerminal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("檔案.txt"))

        var received = Data()
        let ended = expectation(description: "the output ended")
        let launch = LocalLaunch(executable: "/bin/ls", arguments: ["ls"], directory: folder.path)
        let shell = try LocalShell(rows: 24, columns: 80, launch: launch) { data in
            Task { @MainActor in if data.isEmpty { ended.fulfill() } else { received.append(data) } }
        }
        await fulfillment(of: [ended], timeout: 10)
        shell.close()
        // In the C locale, ls prints each byte of the name as "?".
        XCTAssertEqual(String(decoding: received, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "檔案.txt")
    }
}
