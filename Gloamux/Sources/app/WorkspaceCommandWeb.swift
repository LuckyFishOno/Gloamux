import Foundation

/// `gloamux web`: the browser panel of the running app's active window and its pages.
extension WorkspaceCommand {
    @MainActor static func web(_ action: String, _ args: [String], _ model: WorkspaceModel) async throws -> Any {
        let browser = model.browser
        /// The page PAGE names: `current` for the page the panel shows, or a page's ID from `gloamux web list`.
        func page(_ selector: String) throws -> WebPageSession {
            if selector == "current" {
                guard let page = browser.selected else { throw WorkspaceError.invalid("The browser panel has no page.") }
                return page
            }
            guard let id = UUID(uuidString: selector), let page = browser.page(id) else {
                throw Usage("Give a page ID from gloamux web list, or current.")
            }
            return page
        }
        func address(_ text: String) throws -> URL {
            guard let url = WebAddress.destination(from: text) else { throw Usage("Enter a web address, such as https://192.0.2.10.") }
            return url
        }
        func listing() -> [String: Any] {
            ["shown": model.browserPanelShown, "current": browser.selected?.id.uuidString ?? "",
             "pages": browser.pages.map(\.status)]
        }
        switch action {
        case "show":
            try count(args, 0...1)
            if let text = args.first { browser.currentPage().load(try address(text)) }
            model.browserPanelRequest = true
            return listing().merging(["shown": true]) { _, new in new }
        case "hide":
            try count(args, 0...0)
            model.browserPanelRequest = false
            return ["shown": false]
        case "list":
            try count(args, 0...0)
            return listing()
        case "open":
            try count(args, 1...1)
            let page = browser.newPage(try address(args[0]))
            model.browserPanelRequest = true
            return ["id": page.id.uuidString]
        case "select":
            try count(args, 1...1)
            let page = try page(args[0])
            browser.select(page.id)
            model.browserPanelRequest = true
            return page.status
        case "close":
            try count(args, 1...1)
            let page = try page(args[0])
            browser.close(page.id)
            return listing()
        case "status":
            try count(args, 1...1)
            return try page(args[0]).status
        case "go":
            try count(args, 2...2)
            let page = try page(args[0])
            page.load(try address(args[1]))
            return page.status
        case "back", "forward", "reload", "stop", "external", "refuse":
            try count(args, 1...1)
            let page = try page(args[0])
            switch action {
            case "back":
                guard page.canGoBack else { throw WorkspaceError.invalid("There is no earlier page.") }
                page.goBack()
            case "forward":
                guard page.canGoForward else { throw WorkspaceError.invalid("There is no later page.") }
                page.goForward()
            case "reload": page.reload()
            case "stop": page.stopLoading()
            case "external": page.openInDefaultBrowser()
            default:
                guard page.certificate != nil else { throw WorkspaceError.invalid("The page is not asking about a certificate.") }
                page.refuseCertificate()
            }
            return page.status
        case "zoom":
            try count(args, 2...2)
            let page = try page(args[0])
            guard let percent = Int(args[1].replacingOccurrences(of: "%", with: "")), (50...300).contains(percent) else {
                throw Usage("Give a zoom from 50 to 300 percent.")
            }
            page.setZoom(Double(percent) / 100)
            return page.status
        case "trust":
            try count(args, 2...2)
            let page = try page(args[0])
            try page.trustCertificate(fingerprint: args[1])
            return page.status
        case "clear-data":
            try count(args, 0...0)
            await browser.clearWebsiteData()
            return ["cleared": true]
        default: throw Usage("Unknown web operation.")
        }
    }
}
