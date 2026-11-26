import XCTest
@testable import App

/// The browser panel: the addresses it accepts, its pages, downloads, zoom, and `gloamux web`.
@MainActor
final class WebPageTests: XCTestCase {
    private func workspace() throws -> WorkspaceModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-web-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try WorkspaceModel(storage: root)
    }

    @discardableResult
    private func run(_ argv: [String], _ model: WorkspaceModel, live: Bool = true) async throws -> Any {
        let data = try await WorkspaceCommand.run(argv, model: model, live: live)
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    func testTypedAddressesGetTheSchemeABrowserWouldUse() {
        func address(_ text: String) -> String? { WebAddress.url(from: text)?.absoluteString }
        // Devices on the local network usually answer over http first.
        XCTAssertEqual(address("192.0.2.10"), "http://192.0.2.10")
        XCTAssertEqual(address(" 192.0.2.10:8443/admin "), "http://192.0.2.10:8443/admin")
        XCTAssertEqual(address("router"), "http://router")
        XCTAssertEqual(address("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(address("[2001:db8::1]:8080"), "http://[2001:db8::1]:8080")
        XCTAssertEqual(address("nas.example.com/login"), "https://nas.example.com/login")
        XCTAssertEqual(address("HTTPS://Example.com"), "HTTPS://Example.com")
        XCTAssertEqual(address("http://198.51.100.7:8080/"), "http://198.51.100.7:8080/")
        for bad in ["", "   ", "ftp://files.example", "file:///etc/passwd", "http://admin:secret@192.0.2.10",
                    "http://admin@192.0.2.10", "a b.example", "http://", "javascript:alert(1)", "http://192.0.2.10:70000",
                    "https://" + String(repeating: "a", count: 2100) + ".example"] {
            XCTAssertNil(WebAddress.url(from: bad), bad)
        }
        func destination(_ text: String) -> String? { WebAddress.destination(from: text)?.absoluteString }
        // The address field searches Google for anything that is not an address, as Safari does.
        XCTAssertEqual(destination("192.0.2.10:8443/admin"), "http://192.0.2.10:8443/admin")
        XCTAssertEqual(destination("localhost"), "http://localhost")
        XCTAssertEqual(destination("router:8080"), "http://router:8080")
        XCTAssertEqual(destination("nas/"), "http://nas/")
        XCTAssertEqual(destination("nas.example.com"), "https://nas.example.com")
        XCTAssertEqual(destination("gloamux"), "https://www.google.com/search?q=gloamux")
        XCTAssertEqual(destination("ssh keygen ed25519"), "https://www.google.com/search?q=ssh%20keygen%20ed25519")
        XCTAssertEqual(destination("c++ & rust?"), "https://www.google.com/search?q=c%2B%2B%20%26%20rust%3F")
        XCTAssertEqual(destination("防火牆 設定"), "https://www.google.com/search?q=%E9%98%B2%E7%81%AB%E7%89%86%20%E8%A8%AD%E5%AE%9A")
        for refused in ["", "  ", "ftp://files.example", "file:///etc/passwd", "javascript:alert(1)", "http://admin:secret@192.0.2.10",
                        "a\u{7}b"] {
            XCTAssertNil(WebAddress.destination(from: refused), refused)
        }
        XCTAssertEqual(WebAddress.display(URL(string: "https://nas.example.com/")!), "nas.example.com")
        XCTAssertEqual(WebAddress.display(URL(string: "http://192.0.2.10:8080/admin")!), "192.0.2.10:8080/admin")
        XCTAssertEqual(WebAddress.endpoint(host: "NAS.example.com", port: 443), "nas.example.com:443")
        XCTAssertEqual(WebAddress.endpoint(host: "2001:db8::1", port: 8443), "[2001:db8::1]:8443")
    }

    func testDownloadsGetASafeNameThatIsNotTaken() {
        let folder = URL(fileURLWithPath: "/Downloads-test")
        var taken: Set<String> = ["/Downloads-test/backup.tar.gz", "/Downloads-test/backup.tar 2.gz", "/Downloads-test/Download"]
        let exists: (URL) -> Bool = { taken.contains($0.path) }
        XCTAssertEqual(WebPageSession.downloadDestination("report.pdf", in: folder, exists: exists).path, "/Downloads-test/report.pdf")
        XCTAssertEqual(WebPageSession.downloadDestination("backup.tar.gz", in: folder, exists: exists).lastPathComponent, "backup.tar 3.gz")
        XCTAssertEqual(WebPageSession.downloadDestination("../../etc/passwd", in: folder, exists: exists).path, "/Downloads-test/passwd")
        XCTAssertEqual(WebPageSession.downloadDestination(".profile", in: folder, exists: exists).lastPathComponent, "profile")
        XCTAssertEqual(WebPageSession.downloadDestination("a:b\u{7}.txt", in: folder, exists: exists).lastPathComponent, "a-b.txt")
        XCTAssertEqual(WebPageSession.downloadDestination("", in: folder, exists: exists).lastPathComponent, "Download 2")
        taken.removeAll()
        let long = WebPageSession.downloadDestination(String(repeating: "x", count: 400) + ".bin", in: folder, exists: exists)
        XCTAssertLessThanOrEqual(long.lastPathComponent.utf8.count, 200)
    }

    func testZoomStepsStopAtTheLimits() {
        let page = BrowserPanel().newPage()
        page.zoom(1)
        XCTAssertEqual(page.zoom, 1.1, accuracy: 0.001)
        page.zoom(0)
        XCTAssertEqual(page.zoom, 1)
        for _ in 0..<20 { page.zoom(-1) }
        XCTAssertEqual(page.zoom, 0.5)
        for _ in 0..<20 { page.zoom(1) }
        XCTAssertEqual(page.zoom, 3)
        page.setZoom(9)
        XCTAssertEqual(page.zoom, 3)
    }

    func testThePanelKeepsItsPagesAsTabs() async {
        let browser = BrowserPanel()
        XCTAssertNil(browser.selected)
        let first = browser.currentPage()
        XCTAssertTrue(browser.currentPage() === first, "an empty panel gets one page, not one each time")
        XCTAssertNil(first.webView, "a page makes its web view only when it loads")
        XCTAssertEqual(first.tabTitle, "")
        let second = browser.newPage(URL(string: "http://192.0.2.70/status"))
        XCTAssertEqual(browser.selected?.id, second.id)
        XCTAssertEqual(second.tabTitle, "192.0.2.70/status", "a page without a title shows its address")
        XCTAssertTrue(second.store === browser.store, "pages share the panel's website data")
        XCTAssertFalse(browser.store.isPersistent, "the panel keeps website data in memory only")
        let oldStore = browser.store
        browser.pauseMedia()
        browser.select(first.id)
        let third = browser.newPage()
        XCTAssertEqual(browser.pages.map(\.id), [first.id, third.id, second.id], "a new page opens after the one shown")
        browser.close(third.id)
        XCTAssertEqual(browser.selected?.id, second.id, "the page beside a closed one is shown")
        XCTAssertNil(third.webView)
        browser.close(second.id); browser.close(first.id)
        XCTAssertTrue(browser.pages.isEmpty)
        XCTAssertNil(browser.selection)
        let kept = browser.newPage(URL(string: "http://192.0.2.71/"))
        await browser.clearWebsiteData()
        XCTAssertFalse(browser.store === oldStore, "clearing moves the pages to new website data")
        XCTAssertTrue(kept.store === browser.store)
        XCTAssertFalse(browser.store.isPersistent)
        XCTAssertEqual(kept.pendingURL?.absoluteString, "http://192.0.2.71/", "the page opens its address again")
        XCTAssertNotNil(kept.webView)
        for _ in 0..<(BrowserPanel.pageLimit + 3) { browser.newPage() }
        XCTAssertEqual(browser.pages.count, BrowserPanel.pageLimit, "the oldest pages close past the limit")
    }

    func testCertificatesAreTrustedOnlyForTheFingerprintOnScreen() {
        let page = BrowserPanel().newPage()
        XCTAssertThrowsError(try page.trustCertificate(fingerprint: String(repeating: "0", count: 64)), "no question on screen")
        XCTAssertNil(page.status["certificate"])
        page.refuseCertificate()
        XCTAssertNil(page.error, "nothing to refuse")
        let certificates = WebCertificates()
        for index in 0..<(WebCertificates.limit + 5) { certificates.trust(String(repeating: "a", count: 64), for: "192.0.2.\(index):443") }
        XCTAssertEqual(certificates.fingerprints.count, WebCertificates.limit)
        certificates.forget()
        XCTAssertTrue(certificates.fingerprints.isEmpty)
    }

    func testTheUserAgentNamesSafari() {
        XCTAssertTrue(WebPageSession.userAgentSuffix.hasPrefix("Version/"))
        XCTAssertTrue(WebPageSession.userAgentSuffix.hasSuffix(" Safari/605.1.15"))
    }

    func testWebPagesAreNotAConnectionType() async throws {
        let model = try workspace()
        XCTAssertNil(ContainerSession.Tool(rawValue: "web"))
        XCTAssertNil(NewConnectionType(rawValue: "web"))
        do { try await run(["sessions", "add-other", "Firewall", "web", "https://192.0.2.1"], model); XCTFail("web is not a session kind") } catch {}
    }

    func testTheWebCommandControlsThePanelAndItsPages() async throws {
        let model = try workspace()
        do { try await run(["web", "show"], model, live: false); XCTFail("needs the running app") } catch {}
        let shown = try await run(["web", "show", "192.0.2.60"], model) as? [String: Any]
        XCTAssertEqual(shown?["shown"] as? Bool, true)
        XCTAssertEqual(model.browserPanelRequest, true)
        XCTAssertEqual(model.browser.pages.count, 1)
        XCTAssertEqual(model.browser.selected?.pendingURL?.absoluteString, "http://192.0.2.60")
        try await run(["web", "hide"], model)
        XCTAssertEqual(model.browserPanelRequest, false)

        let opened = try await run(["web", "open", "https://198.51.100.20/status"], model) as? [String: Any]
        let pageID = try XCTUnwrap(opened?["id"] as? String)
        XCTAssertEqual(model.browser.selected?.id.uuidString, pageID)
        XCTAssertTrue(model.tabs.allSatisfy { $0.desktop == nil }, "pages open in the panel, not in tabs")
        let zoomed = try await run(["web", "zoom", pageID, "125"], model) as? [String: Any]
        XCTAssertEqual(zoomed?["zoom"] as? Int, 125)
        let current = try await run(["web", "status", "current"], model) as? [String: Any]
        XCTAssertEqual(current?["id"] as? String, pageID)
        XCTAssertEqual(current?["url"] as? String, "https://198.51.100.20/status")
        let list = try await run(["web", "list"], model) as? [String: Any]
        XCTAssertEqual((list?["pages"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(list?["current"] as? String, pageID)

        let first = try XCTUnwrap(model.browser.pages.first).id.uuidString
        try await run(["web", "select", first], model)
        XCTAssertEqual(model.browser.selected?.id.uuidString, first)
        try await run(["web", "close", pageID], model)
        XCTAssertEqual(model.browser.pages.count, 1)
        let cleared = try await run(["web", "clear-data"], model) as? [String: Any]
        XCTAssertEqual(cleared?["cleared"] as? Bool, true)

        for bad in [["web", "zoom", first, "20"], ["web", "go", first, "ftp://x"], ["web", "status", UUID().uuidString],
                    ["web", "status", "panel"], ["web", "back", first], ["web", "trust", first, String(repeating: "0", count: 64)],
                    ["web", "open", "file:///etc/hosts"], ["web", "clear-data", "panel"]] {
            do { try await run(bad, model); XCTFail("\(bad) was accepted") } catch {}
        }
        let searched = try await run(["web", "go", first, "rack temperature"], model) as? [String: Any]
        XCTAssertEqual(searched?["url"] as? String, "https://www.google.com/search?q=rack%20temperature")
        XCTAssertTrue(CLICatalog.command("web")?.operations.contains("select") == true)
    }
}
