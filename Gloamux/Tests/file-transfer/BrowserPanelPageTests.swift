import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import App

/// A page in the browser panel loads a real page and reports what a browser shows: its title, address, and history.
@MainActor final class BrowserPanelPageTests: XCTestCase {
    /// Answers every request with a small page whose title is its path, and notes the User-Agent it was sent.
    private final class TinyPage: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        static let lock = NSLock()
        nonisolated(unsafe) static var agents: [String] = []
        private var request = ""

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            request += buffer.readString(length: buffer.readableBytes) ?? ""
            guard request.contains("\r\n\r\n") else { return }
            let lines = request.split(separator: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let agent = lines.first { $0.lowercased().hasPrefix("user-agent:") }.map { String($0.dropFirst(11)).trimmingCharacters(in: .whitespaces) } ?? ""
            Self.lock.lock(); Self.agents.append(agent); Self.lock.unlock()
            // Pages under /private need HTTP Basic sign-in as admin.
            let signedIn = lines.contains { $0.lowercased().hasPrefix("authorization: basic ") }
            let response: String
            if path.hasPrefix("/private"), !signedIn {
                let body = "sign in"
                response = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"Gloamux test\"\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            } else {
                let body = "<!doctype html><html><head><title>Page \(path)</title></head><body><a href=\"/next\">next</a></body></html>"
                response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            }
            context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string: response))).whenComplete { _ in context.close(promise: nil) }
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1500 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func startServer() async throws -> (Channel, Int) {
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { $0.pipeline.addHandler(TinyPage()) }
            .bind(host: "127.0.0.1", port: 0).get()
        return (server, try XCTUnwrap(server.localAddress?.port))
    }

    func testClearingWebsiteDataForgetsASignIn() async throws {
        let (server, port) = try await startServer()
        defer { server.close(promise: nil) }
        let browser = BrowserPanel()
        let page = browser.newPage(URL(string: "http://127.0.0.1:\(port)/private/a"))
        try await wait { page.signIn != nil }
        XCTAssertEqual(page.signIn?.host, "127.0.0.1")
        XCTAssertEqual(page.signIn?.unencrypted, true)
        page.answerSignIn(("admin", "secret"))
        try await wait { page.title == "Page /private/a" }
        XCTAssertEqual(page.title, "Page /private/a")

        // The same site does not ask again while the sign-in is kept.
        page.load(URL(string: "http://127.0.0.1:\(port)/private/b")!)
        try await wait { page.title == "Page /private/b" || page.signIn != nil }
        XCTAssertEqual(page.title, "Page /private/b")
        XCTAssertNil(page.signIn)

        let oldView = page.webView
        await browser.clearWebsiteData()
        XCTAssertTrue(page.store === browser.store)
        XCTAssertFalse(page.webView === oldView, "the page opens again in the new website data")
        try await wait { page.signIn != nil }
        XCTAssertNotNil(page.signIn, "Clear website data must forget the sign-in")
        page.answerSignIn(nil)
        browser.close(page.id)
    }

    func testAPageLoadsWithSafarisUserAgentAndGoesBack() async throws {
        let (server, port) = try await startServer()
        defer { server.close(promise: nil) }
        TinyPage.lock.lock(); TinyPage.agents = []; TinyPage.lock.unlock()

        let browser = BrowserPanel()
        let page = browser.newPage(URL(string: "http://127.0.0.1:\(port)/first"))
        try await wait { page.title == "Page /first" && !page.loading }
        XCTAssertEqual(page.title, "Page /first")
        XCTAssertEqual(page.tabTitle, "Page /first")
        XCTAssertEqual(page.url?.absoluteString, "http://127.0.0.1:\(port)/first")
        XCTAssertNil(page.error)
        let agents = { TinyPage.lock.lock(); defer { TinyPage.lock.unlock() }; return TinyPage.agents }()
        XCTAssertTrue(agents.first?.hasSuffix(WebPageSession.userAgentSuffix) == true, "\(agents)")

        XCTAssertTrue(page.go("127.0.0.1:\(port)/second"))
        try await wait { page.title == "Page /second" && page.canGoBack }
        XCTAssertTrue(page.canGoBack)
        page.goBack()
        try await wait { page.title == "Page /first" }
        XCTAssertEqual(page.title, "Page /first")
        XCTAssertTrue(page.canGoForward)

        XCTAssertFalse(page.go("ftp://127.0.0.1"))
        XCTAssertEqual(page.error, "Enter a web address, such as https://192.0.2.10.")
        browser.close(page.id)
        XCTAssertNil(page.webView)
        await browser.clearWebsiteData()
    }
}
