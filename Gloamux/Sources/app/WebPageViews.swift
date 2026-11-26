import AppKit
import SwiftUI
import WebKit

/// Holds a page's web view, putting a new one in place when the page makes one.
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        guard let webView else { container.subviews.forEach { $0.removeFromSuperview() }; return }
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

/// The browser panel at the right of the window: its pages as tabs in the header, and the page shown below them.
struct WebBrowserPanel: View {
    let model: WorkspaceModel
    @ObservedObject var browser: BrowserPanel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            pageStrip
            if let page = browser.selected {
                WebPageView(model: model, browser: browser, page: page).id(page.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.theme.sidebar.color)
        .onAppear { browser.currentPage() }
        // A hidden panel keeps its pages, but not their sound.
        .onDisappear { browser.pauseMedia() }
        .onChange(of: browser.pages.isEmpty) { _, empty in if empty { browser.newPage() } }
    }

    /// The pages as tabs drawn like the session tabs: they share the bar evenly and shrink down to an icon
    /// instead of scrolling out of view.
    private var pageStrip: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let buttons: CGFloat = 32 + 32
                let width = max(StripTab.minimumWidth, min(StripTab.maximumWidth,
                                                           (proxy.size.width - buttons) / CGFloat(max(browser.pages.count, 1))))
                HStack(spacing: 0) {
                    ForEach(browser.pages) { page in
                        WebPageTab(page: page, width: width, selected: page.id == browser.selected?.id, theme: model.theme,
                                   select: { browser.select(page.id) }, close: { browser.close(page.id) })
                    }
                    stripButton("plus", help: "New page") { browser.newPage() }
                        .accessibilityIdentifier("browserNewPage")
                    Spacer(minLength: 0)
                    stripButton("xmark", help: "Hide browser", action: close)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.86), value: browser.pages.map(\.id))
            }
            .frame(height: TabChrome.flat.height)
            .background(model.theme.tabs.color)
            Rectangle().fill(model.theme.foreground.color.opacity(0.08)).frame(height: 1)
        }
    }

    private func stripButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).appFont(.system(size: symbol == "plus" ? 12 : 10, weight: .medium))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .frame(width: 32)
        .help(T(help)).accessibilityLabel(T(help))
    }
}

/// One page's tab in the panel's header, drawn like a session tab.
private struct WebPageTab: View {
    @ObservedObject var page: WebPageSession
    let width: CGFloat
    let selected: Bool
    let theme: WorkspaceTheme
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        StripTab(title: page.tabTitle.isEmpty ? T("New page") : page.tabTitle,
                 symbol: page.loading ? "arrow.triangle.2.circlepath" : "globe", connected: true, width: width,
                 selected: selected, theme: theme, showsConnection: false, closeHelp: "Close page",
                 select: select, close: close)
            .accessibilityAction(named: T("Close page"), close)
    }
}

/// A page of the browser panel with its address bar.
struct WebPageView: View {
    let model: WorkspaceModel
    let browser: BrowserPanel
    @ObservedObject var page: WebPageSession
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack(alignment: .top) {
                content
                if page.webView != nil, let error = page.error, page.certificate == nil {
                    errorBanner(error)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let download = page.download { downloadBar(download) }
        }
        .sheet(item: Binding(get: { page.signIn }, set: { _ in })) { prompt in
            WebSignInSheet(prompt: prompt) { page.answerSignIn($0) }
                .onDisappear { if page.signIn?.id == prompt.id { page.answerSignIn(nil) } }
        }
        .onAppear {
            address = (page.url ?? page.pendingURL)?.absoluteString ?? ""
            if address.isEmpty { addressFocused = true }
        }
        .onChange(of: page.url) { _, url in
            if !addressFocused, let url { address = url.absoluteString }
        }
    }

    // MARK: Address bar

    private var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                PaneIconButton(symbol: "chevron.left", help: "Back") { page.goBack() }
                    .disabled(!page.canGoBack).opacity(page.canGoBack ? 1 : 0.4)
                PaneIconButton(symbol: "chevron.right", help: "Forward") { page.goForward() }
                    .disabled(!page.canGoForward).opacity(page.canGoForward ? 1 : 0.4)
                if page.loading {
                    PaneIconButton(symbol: "xmark", help: "Stop loading") { page.stopLoading() }
                } else {
                    PaneIconButton(symbol: "arrow.clockwise", help: "Reload") { page.reload() }
                }
                addressField.padding(.horizontal, 4)
                menu
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            ProgressView(value: page.loading ? max(0.05, page.progress) : 0)
                .progressViewStyle(.linear).controlSize(.mini)
                .opacity(page.loading ? 1 : 0)
                .frame(height: 2)
        }
        .background(model.theme.header.color.opacity(0.6))
        .overlay(alignment: .bottom) { Rectangle().fill(model.theme.foreground.color.opacity(0.07)).frame(height: 1) }
    }

    private var addressField: some View {
        TextField(T("Address"), text: $address, prompt: Text(T("Search or enter a web address")))
            .textFieldStyle(.plain)
            .focused($addressFocused)
            .onSubmit {
                if page.go(address) { addressFocused = false }
            }
            .accessibilityIdentifier("webAddressField")
            .appFont(.callout)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(addressFocused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
    }

    private var menu: some View {
        let hasAddress = page.url != nil || page.pendingURL != nil
        return Menu {
            Button(T("Zoom in")) { page.zoom(1) }.disabled(page.zoom >= 3)
            Button(T("Zoom out")) { page.zoom(-1) }.disabled(page.zoom <= 0.5)
            Button(T("Actual size") + " (\(Int((page.zoom * 100).rounded()))%)") { page.zoom(0) }.disabled(page.zoom == 1)
            Divider()
            Button(T("Open in the default browser")) { page.openInDefaultBrowser() }.disabled(!hasAddress)
            Button(T("Copy address")) {
                guard let url = page.url ?? page.pendingURL else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            .disabled(!hasAddress)
            Divider()
            Button(T("Clear website data")) { Task { await browser.clearWebsiteData() } }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(T("More"))
        .accessibilityLabel(T("More"))
        .accessibilityIdentifier("webPageMenu")
    }

    // MARK: Page

    @ViewBuilder private var content: some View {
        ZStack {
            WebViewHost(webView: page.webView).id(page.viewGeneration)
            if let prompt = page.certificate {
                WebCertificateCard(prompt: prompt, trust: page.trustCertificate, refuse: page.refuseCertificate)
            } else if page.webView == nil {
                VStack(spacing: 10) {
                    Image(systemName: "globe").appFont(.system(size: 28)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(T("Search or enter a web address")).appFont(.headline)
                        InfoButton(T("Pages in this panel keep their sign-ins and cookies only until Gloamux quits, apart from Safari."))
                    }
                    if let error = page.error {
                        Text(T(error)).appFont(.callout).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 360)
                    }
                }
                .padding(13)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(model.theme.sidebar.color)
            }
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(T(error)).appFont(.callout).lineLimit(3).textSelection(.enabled)
            Spacer(minLength: 8)
            Button(T("Try again")) { page.reload() }.buttonStyle(.app)
            Button { page.error = nil } label: { Image(systemName: "xmark").iconHitArea() }
                .buttonStyle(.plain).help(T("Dismiss")).accessibilityLabel(T("Dismiss"))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    private func downloadBar(_ download: WebDownloadState) -> some View {
        HStack(spacing: 8) {
            switch download {
            case .saving(let name):
                ProgressView().controlSize(.small)
                Text(String(format: T("Downloading %@"), name)).lineLimit(1).truncationMode(.middle)
            case .saved(let url):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(String(format: T("Downloaded %@"), url.lastPathComponent)).lineLimit(1).truncationMode(.middle)
                Button(T("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.app)
            case .failed(let name, let reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(String(format: T("Could not download %@"), name) + " " + reason).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button { page.dismissDownload() } label: { Image(systemName: "xmark").iconHitArea() }
                .buttonStyle(.plain).help(T("Dismiss")).accessibilityLabel(T("Dismiss"))
        }
        .appFont(.callout)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(model.theme.header.color.opacity(0.6))
    }
}

/// An HTTPS certificate macOS does not trust, with its fingerprint to compare before trusting it.
private struct WebCertificateCard: View {
    let prompt: WebCertificatePrompt
    let trust: () -> Void
    let refuse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(T(prompt.changed ? "This site's certificate changed" : "This site's certificate is not trusted"),
                  systemImage: "exclamationmark.shield").appFont(.title3.weight(.semibold))
                .foregroundStyle(prompt.changed ? .red : .primary)
            HStack(spacing: 6) {
                Text(prompt.endpoint).appFont(.headline)
                InfoButton(T("Devices often use a certificate they made themselves. Compare this fingerprint with the one the device shows before trusting it. Gloamux then trusts this certificate for this address until it quits."))
            }
            if !prompt.reason.isEmpty {
                Text(prompt.reason).appFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("SHA-256").appFont(.caption).foregroundStyle(.secondary)
            Text(prompt.fingerprint).appFont(.caption.monospaced()).textSelection(.enabled)
            DialogActions(cancel: refuse, title: T("Trust this certificate"), warns: prompt.changed, returnConfirms: false,
                          identifier: "webTrustCertificate", confirm: trust)
        }
        .padding(20)
        .frame(maxWidth: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.08))
    }
}

/// A page's request for a user name and password.
private struct WebSignInSheet: View {
    let prompt: WebSignInPrompt
    let answer: ((user: String, password: String)?) -> Void
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(String(format: T("Sign in to %@"), prompt.host), systemImage: "person.badge.key").appFont(.title2.weight(.semibold))
            if let realm = prompt.realm, !realm.isEmpty {
                Text(realm).foregroundStyle(.secondary).lineLimit(2)
            }
            TextField(T("User name"), text: $user).textFieldStyle(.roundedBorder)
            SecureField(T("Password"), text: $password).textFieldStyle(.roundedBorder).onSubmit(send)
            if prompt.failed {
                Text(T("The user name or password was not accepted.")).appFont(.callout).foregroundStyle(.red)
            }
            if prompt.unencrypted {
                HStack(spacing: 6) {
                    Label(T("Not encrypted"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    InfoButton(T("This page uses http, so the password crosses the network as plain text. Open it with https to protect it."))
                }
                .appFont(.callout)
            }
            DialogActions(cancel: { answer(nil) }, title: T("Sign in"), enabled: !user.isEmpty, confirm: send)
        }
        .padding(24).frame(width: 420)
    }

    private func send() {
        guard !user.isEmpty else { return }
        answer((user, password))
    }
}
