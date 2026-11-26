import AppKit
import CryptoKit
import Foundation
import Network
import WebKit

/// Web addresses the browser panel accepts.
enum WebAddress {
    static let maxLength = 2048

    /// The page a typed address opens. Without a scheme, an IP address, `localhost`, or a name without a dot (a
    /// device on the local network) opens over http, and any other name over https, as browsers do. Other schemes,
    /// and a user name or password in the address, are refused.
    static func url(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxLength, !hasSpaceOrControl(text) else { return nil }
        let lower = text.lowercased()
        let full: String
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            full = text
        } else if text.contains("://") {
            return nil
        } else {
            full = (looksLocal(text) ? "http://" : "https://") + text
        }
        guard let url = URL(string: full), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        if let port = url.port, !(1...65535).contains(port) { return nil }
        return url
    }

    /// What text typed in the address field opens: the web address it names, or a Google search for anything else,
    /// such as words, a single word without a dot, or text with spaces. Text that names another scheme (`ftp://`,
    /// `file:`, `javascript:`), or an http address with a user name or password, opens nothing.
    static func destination(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxLength,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if namesScheme(text) { return url(from: text) }
        if !hasSpaceOrControl(text), !isBareWord(text), let url = url(from: text) { return url }
        return search(text)
    }

    /// A Google search for `text`.
    static func search(_ text: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#?")
        guard let query = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://www.google.com/search?q=" + query)
    }

    /// `host:port`, the key a trusted certificate is kept under; an IPv6 host is in brackets.
    static func endpoint(host: String, port: Int) -> String {
        let host = host.lowercased()
        return (host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host) + ":\(port)"
    }

    /// The address without its scheme, as a page's tab shows it before the page has a title.
    static func display(_ url: URL) -> String {
        var value = url.absoluteString
        for prefix in ["https://", "http://"] where value.lowercased().hasPrefix(prefix) { value.removeFirst(prefix.count) }
        if value.hasSuffix("/"), value.firstIndex(of: "/") == value.index(before: value.endIndex) { value.removeLast() }
        return value
    }

    private static func looksLocal(_ text: String) -> Bool {
        let authority = text.prefix { !"/?#".contains($0) }
        if authority.hasPrefix("[") { return true }
        let host = authority.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        return host.lowercased() == "localhost" || IPv4Address(host) != nil || !host.contains(".")
    }

    /// Text that starts with a scheme: `name://`, or a scheme that takes no slashes, such as `javascript:`.
    private static func namesScheme(_ text: String) -> Bool {
        let lower = text.lowercased()
        if let range = lower.range(of: "://"),
           lower[..<range.lowerBound].allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) { return true }
        return ["javascript:", "vbscript:", "file:", "data:", "about:", "blob:", "mailto:"].contains { lower.hasPrefix($0) }
    }

    /// One word with no dot, port, or path, which browsers search for rather than open; `localhost` is an address.
    private static func isBareWord(_ text: String) -> Bool {
        !text.contains(where: { ".:/[".contains($0) }) && text.lowercased() != "localhost"
    }

    private static func hasSpaceOrControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }
}

/// A web view that knows its page, so menu commands such as zooming find the page from the first responder.
final class GloamuxWebView: WKWebView {
    weak var page: WebPageSession?
}

extension NSResponder {
    /// The web page this responder is in, if any.
    @MainActor var enclosingWebPage: WebPageSession? {
        var view = self as? NSView
        while let current = view {
            if let web = current as? GloamuxWebView { return web.page }
            view = current.superview
        }
        return nil
    }
}

/// A certificate macOS does not trust, waiting for the user to trust it or not.
struct WebCertificatePrompt: Equatable {
    let endpoint: String
    let fingerprint: String
    let reason: String
    /// The certificate differs from the one trusted for this host before.
    let changed: Bool
    let url: URL?
}

/// A page's request for a user name and password (HTTP Basic, Digest, or NTLM).
struct WebSignInPrompt: Identifiable, Equatable {
    let id = UUID()
    let host: String
    let realm: String?
    let failed: Bool
    /// The password would cross the network unencrypted.
    let unencrypted: Bool
}

/// The latest download, shown under the page.
enum WebDownloadState: Equatable {
    case saving(String)
    case saved(URL)
    case failed(String, String)
}

/// Certificates the user trusted in the browser panel although macOS does not, by `host:port`, until Gloamux quits.
@MainActor final class WebCertificates {
    static let limit = 64
    private(set) var fingerprints: [String: String] = [:]

    func trust(_ fingerprint: String, for endpoint: String) {
        // At most `limit`: one is dropped to make room.
        if fingerprints[endpoint] == nil, fingerprints.count >= Self.limit, let first = fingerprints.keys.sorted().first {
            fingerprints[first] = nil
        }
        fingerprints[endpoint] = fingerprint
    }

    func forget() { fingerprints = [:] }
}

/// The browser panel of a window: its pages, the one shown, and the website data they share, which stays in memory
/// until Gloamux quits.
@MainActor final class BrowserPanel: ObservableObject {
    /// More pages than anyone reads at once in a side panel; a new page past it closes the oldest.
    static let pageLimit = 20

    @Published private(set) var pages: [WebPageSession] = []
    @Published var selection: UUID?
    /// The website data the pages share. Clearing it puts a new one in its place.
    private(set) var store: WKWebsiteDataStore
    let certificates = WebCertificates()

    init(store: WKWebsiteDataStore = .nonPersistent()) {
        self.store = store
    }

    var selected: WebPageSession? { pages.first { $0.id == selection } ?? pages.first }

    /// Opens a page after the one shown and shows it, with `url` when given.
    @discardableResult func newPage(_ url: URL? = nil) -> WebPageSession {
        let page = WebPageSession(store: store, certificates: certificates)
        let index = selected.flatMap { current in pages.firstIndex { $0 === current } }.map { $0 + 1 } ?? pages.endIndex
        pages.insert(page, at: index)
        if pages.count > Self.pageLimit, let oldest = pages.first(where: { $0 !== page }) { close(oldest.id) }
        selection = page.id
        if let url { page.load(url) }
        return page
    }

    /// The page shown, or a new empty page when there is none.
    @discardableResult func currentPage() -> WebPageSession { selected ?? newPage() }

    func page(_ id: UUID) -> WebPageSession? { pages.first { $0.id == id } }

    func select(_ id: UUID) {
        guard page(id) != nil else { return }
        selection = id
    }

    /// Closes a page; the one beside it is shown next.
    func close(_ id: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        let page = pages.remove(at: index)
        page.close()
        if selection == id {
            selection = pages.isEmpty ? nil : pages[min(index, pages.count - 1)].id
        }
    }

    /// Deletes the cookies, sign-ins, and caches of every page in the panel, and the certificates trusted in it, and
    /// opens each page again. WebKit keeps an answered sign-in for as long as its data store lives, so the pages move
    /// to a new store rather than only emptying the old one.
    func clearWebsiteData() async {
        certificates.forget()
        let old = store
        store = .nonPersistent()
        for page in pages { page.restart(with: store) }
        await old.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// Pauses sound and video on every page, as when the panel is hidden.
    func pauseMedia() {
        for page in pages { page.webView?.pauseAllMediaPlayback(completionHandler: nil) }
    }
}

/// One page of the browser panel: a WebKit view and its state.
@MainActor final class WebPageSession: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var title = ""
    @Published private(set) var url: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var loading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var zoom = 1.0
    /// Why the page did not open.
    @Published var error: String?
    @Published private(set) var certificate: WebCertificatePrompt?
    @Published private(set) var signIn: WebSignInPrompt?
    @Published private(set) var download: WebDownloadState?
    /// Changes when the web view is made, so the view that hosts it puts the new one in place.
    @Published private(set) var viewGeneration = 0

    private(set) var store: WKWebsiteDataStore
    private let certificates: WebCertificates
    private(set) var webView: GloamuxWebView?
    /// The address the main frame is loading, which a trusted certificate opens again.
    private(set) var pendingURL: URL?
    private var observations: [NSKeyValueObservation] = []
    private var signInReply: ((URLSession.AuthChallengeDisposition, URLCredential?) -> Void)?
    private var downloadTargets: [ObjectIdentifier: URL] = [:]
    private var lastCrashReload = Date.distantPast

    init(store: WKWebsiteDataStore, certificates: WebCertificates) {
        self.store = store
        self.certificates = certificates
        super.init()
    }

    /// What the page's tab shows: its title, or its address until it has one.
    var tabTitle: String {
        if !title.isEmpty { return title }
        return (url ?? pendingURL).map(WebAddress.display) ?? ""
    }

    /// Stops the page and lets go of its web view.
    func close() {
        answerSignIn(nil)
        certificate = nil
        if let view = webView {
            view.stopLoading()
            view.navigationDelegate = nil; view.uiDelegate = nil
            view.removeFromSuperview()
        }
        observations = []
        webView = nil
        viewGeneration += 1
        loading = false; progress = 0
    }

    /// Moves the page to other website data, opening its address again if it had one open.
    func restart(with store: WKWebsiteDataStore) {
        let address = webView == nil ? nil : url ?? pendingURL
        close()
        self.store = store
        error = nil
        if let address { load(address) }
    }

    private func makeWebView() -> GloamuxWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.isElementFullscreenEnabled = true
        // Without Safari's name, sites such as Google treat the view as an old browser and send their basic pages.
        configuration.applicationNameForUserAgent = Self.userAgentSuffix
        let view = GloamuxWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.page = self
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.pageZoom = zoom
        observations = [
            view.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.title = view.title ?? "" }
            },
            view.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.url = view.url }
            },
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            view.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.loading = view.isLoading }
            },
            view.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
        ]
        webView = view
        viewGeneration += 1
        return view
    }

    /// What WebKit adds to its user agent: the Safari on this Mac, as Safari itself reports it.
    static let userAgentSuffix: String = {
        let info = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        let version = (info?["CFBundleShortVersionString"] as? String).flatMap { $0.allSatisfy { $0.isNumber || $0 == "." } ? $0 : nil } ?? "18.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    // MARK: Navigation

    /// Opens a typed address, or searches Google for text that is not one. Returns false when it names another
    /// scheme or carries a user name or password.
    @discardableResult func go(_ text: String) -> Bool {
        guard let url = WebAddress.destination(from: text) else {
            error = "Enter a web address, such as https://192.0.2.10."
            return false
        }
        load(url)
        return true
    }

    func load(_ url: URL) {
        error = nil; certificate = nil
        pendingURL = url
        (webView ?? makeWebView()).load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func stopLoading() { webView?.stopLoading() }

    func reload() {
        error = nil
        guard let webView, webView.url != nil else {
            if let url = pendingURL { load(url) }
            return
        }
        webView.reload()
    }

    static let zoomSteps = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// One step bigger (1) or smaller (-1), or actual size (0).
    func zoom(_ step: Int) {
        if step == 0 { setZoom(1); return }
        let next = step > 0 ? Self.zoomSteps.first { $0 > zoom + 0.001 } : Self.zoomSteps.last { $0 < zoom - 0.001 }
        if let next { setZoom(next) }
    }

    func setZoom(_ value: Double) {
        zoom = min(3, max(0.5, value))
        webView?.pageZoom = zoom
    }

    func openInDefaultBrowser() {
        guard let url = url ?? pendingURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Certificates

    /// Trusts the certificate on screen for its host until Gloamux quits, and opens the page again.
    func trustCertificate() {
        guard let prompt = certificate else { return }
        certificates.trust(prompt.fingerprint, for: prompt.endpoint)
        certificate = nil
        if let url = prompt.url ?? pendingURL { load(url) }
    }

    /// Trusts the certificate on screen when it has this fingerprint, as `gloamux web trust` does.
    func trustCertificate(fingerprint: String) throws {
        guard let prompt = certificate else { throw WorkspaceError.invalid("The page is not asking about a certificate.") }
        guard prompt.fingerprint == fingerprint.lowercased().replacingOccurrences(of: ":", with: "") else {
            throw WorkspaceError.invalid("The fingerprint does not match the certificate on screen.")
        }
        trustCertificate()
    }

    func refuseCertificate() {
        guard certificate != nil else { return }
        certificate = nil
        error = "The page was not opened because its certificate is not trusted."
    }

    /// The SHA-256 fingerprint of a server's own certificate, in lowercase hexadecimal.
    nonisolated static func fingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let data = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Sign-in

    /// Answers the page's sign-in, or cancels it with nil.
    func answerSignIn(_ credentials: (user: String, password: String)?) {
        let reply = signInReply
        signInReply = nil; signIn = nil
        if let credentials {
            reply?(.useCredential, URLCredential(user: credentials.user, password: credentials.password, persistence: .forSession))
        } else {
            reply?(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Hides the latest download once it has finished.
    func dismissDownload() {
        if case .saving = download { return }
        download = nil
    }

    // MARK: Downloads

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    /// A file name the page suggested, made safe, in `folder`, with a number added when the name is taken.
    nonisolated static func downloadDestination(_ suggested: String, in folder: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var name = (suggested as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Download" }
        if name.utf8.count > 200 { name = String(name.prefix(120)) }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while exists(candidate), number < 10_000 {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    /// What `gloamux web status` prints.
    var status: [String: Any] {
        var info: [String: Any] = ["id": id.uuidString, "loading": loading, "zoom": Int((zoom * 100).rounded()),
                                   "canGoBack": canGoBack, "canGoForward": canGoForward, "title": title]
        if let url = url ?? pendingURL { info["url"] = url.absoluteString }
        if let error { info["error"] = error }
        if let certificate {
            info["certificate"] = ["endpoint": certificate.endpoint, "sha256": certificate.fingerprint,
                                   "reason": certificate.reason, "changed": certificate.changed]
        }
        if let signIn { info["signIn"] = signIn.host }
        switch download {
        case .saving(let name): info["download"] = ["state": "saving", "name": name]
        case .saved(let url): info["download"] = ["state": "saved", "path": url.path]
        case .failed(let name, let reason): info["download"] = ["state": "failed", "name": name, "error": reason]
        case nil: break
        }
        return info
    }
}

// MARK: - WebKit delegates

extension WebPageSession: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { decisionHandler(.download); return }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { decisionHandler(.cancel); return }
        switch scheme {
        case "http", "https", "about", "data", "blob":
            if action.targetFrame?.isMainFrame == true { pendingURL = url }
            decisionHandler(.allow)
        default:
            // mailto:, tel:, and other apps' links go to the app that opens them, when the user clicked them.
            if action.navigationType == .linkActivated, scheme != "file", scheme != "javascript" { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if response.isForMainFrame, disposition.lowercased().hasPrefix("attachment") { decisionHandler(.download); return }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        error = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    private func failed(_ error: Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        // A page that became a download, or a navigation another one replaced.
        if error.domain == "WebKitErrorDomain", [102, 204].contains(error.code) { return }
        guard certificate == nil, signIn == nil else { return }
        self.error = error.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Reload once; a page that keeps crashing the web process shows an error instead of reloading forever.
        guard Date().timeIntervalSince(lastCrashReload) > 10 else {
            error = "The page stopped working. Reload to try again."
            return
        }
        lastCrashReload = Date()
        webView.reload()
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust else { completionHandler(.performDefaultHandling, nil); return }
            var failure: CFError?
            if SecTrustEvaluateWithError(trust, &failure) { completionHandler(.performDefaultHandling, nil); return }
            guard let fingerprint = Self.fingerprint(trust) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
            let endpoint = WebAddress.endpoint(host: space.host, port: space.port)
            let trusted = certificates.fingerprints[endpoint]
            if trusted == fingerprint { completionHandler(.useCredential, URLCredential(trust: trust)); return }
            let reason = (failure as Error?)?.localizedDescription ?? ""
            certificate = WebCertificatePrompt(endpoint: endpoint, fingerprint: fingerprint, reason: reason, changed: trusted != nil,
                                               url: pendingURL)
            completionHandler(.cancelAuthenticationChallenge, nil)
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM:
            answerSignIn(nil)
            let unencrypted = space.protocol?.lowercased() != "https" && space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
            signIn = WebSignInPrompt(host: space.host, realm: space.realm, failed: challenge.previousFailureCount > 0,
                                     unencrypted: unencrypted)
            signInReply = completionHandler
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: Windows and dialogs

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A link meant for a new window opens here.
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor () -> Void) {
        Self.ask(webView, from: frame, message: message, buttons: ["OK"]) { _, _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (Bool) -> Void) {
        Self.ask(webView, from: frame, message: message, buttons: ["OK", "Cancel"]) { response, _ in completionHandler(response == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        Self.ask(webView, from: frame, message: prompt, buttons: ["OK", "Cancel"], text: defaultText ?? "") { response, text in
            completionHandler(response == .alertFirstButtonReturn ? text : nil)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let window = webView.window {
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { completionHandler(response == .OK ? panel.urls : nil) }
            }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    /// A page's alert, confirmation, or question, as a sheet on its window.
    private static func ask(_ webView: WKWebView, from frame: WKFrameInfo, message: String, buttons: [String], text: String? = nil,
                            reply: @escaping @MainActor (NSApplication.ModalResponse, String) -> Void) {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? T("This page says") : String(format: T("%@ says"), host)
        alert.informativeText = String(message.prefix(2000))
        for button in buttons { alert.addButton(withTitle: T(button)) }
        let field = text.map { value -> NSTextField in
            let field = NSTextField(string: value)
            field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            return field
        }
        alert.accessoryView = field
        if let window = webView.window {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { reply(response, field?.stringValue ?? "") }
            }
            if let field { alert.window.makeFirstResponder(field) }
        } else {
            reply(alert.runModal(), field?.stringValue ?? "")
        }
    }

    // MARK: Downloads

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let destination = Self.downloadDestination(suggestedFilename, in: Self.downloadsFolder)
        downloadTargets[ObjectIdentifier(download)] = destination
        self.download = .saving(destination.lastPathComponent)
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let destination = downloadTargets.removeValue(forKey: ObjectIdentifier(download)) else { return }
        self.download = .saved(destination)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let destination = downloadTargets.removeValue(forKey: ObjectIdentifier(download))
        self.download = .failed(destination?.lastPathComponent ?? "", error.localizedDescription)
    }
}
