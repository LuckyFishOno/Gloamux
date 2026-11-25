import Foundation
import AppKit
import Combine
import CoreSpotlight
import UniformTypeIdentifiers
import ShellIntents

/// Saved sessions in Spotlight, so typing a host's name there opens it in Gloamux. Only names, users, hosts, and
/// folders are indexed, never passwords or keys, and only while Gloamux runs as an app bundle.
@MainActor final class SpotlightIndex {
    static let key = "Gloamux.spotlight"
    static let domain = "local.gloamux.sessions"
    static let prefix = "session:"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    private var subscription: AnyCancellable?
    private var defaults: AnyCancellable?

    func start(_ store: SessionTreeStore) {
        guard Bundle.main.bundleURL.pathExtension == "app", subscription == nil else { return }
        subscription = store.$nodes
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] nodes in self?.index(nodes, environment: store.effectiveEnvironment) }
        defaults = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in Self.enabled }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.index(store.nodes, environment: store.effectiveEnvironment) }
    }

    private func index(_ nodes: [SessionTreeNode], environment: (UUID?) -> SessionEnvironment?) {
        let index = CSSearchableIndex.default()
        guard Self.enabled else { index.deleteSearchableItems(withDomainIdentifiers: [Self.domain]); return }
        let indexed = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let items = nodes.filter { !$0.isFolder }.prefix(5000).map { node -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .item)
            attributes.title = node.name
            var folders: [String] = [], parent = node.parent
            while let folder = parent.flatMap({ indexed[$0] }) { folders.append(folder.name); parent = folder.parent }
            let address = node.connection.map { "\($0.accountPrefix)\($0.host)" + ($0.port == 22 ? "" : ":\($0.port)") }
                ?? node.container.map { $0.tool.title + " " + $0.summary } ?? ""
            let place = folders.reversed().joined(separator: " / ")
            attributes.contentDescription = place.isEmpty ? address : address + " · " + place
            attributes.keywords = [node.connection?.host, node.connection?.username, node.container?.target,
                                   environment(node.id)?.title, "ssh", "Gloamux"].compactMap { $0 }
            let item = CSSearchableItem(uniqueIdentifier: Self.prefix + node.id.uuidString, domainIdentifier: Self.domain, attributeSet: attributes)
            item.expirationDate = .distantFuture
            return item
        }
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { _ in
            index.indexSearchableItems(Array(items))
        }
    }
}

extension WorkspaceModel {
    /// Hooks the workspace up to Spotlight, Shortcuts, and notifications. Called once after it loads.
    public func startSystemIntegration(activeWorkspace: @escaping () -> WorkspaceModel?) {
        CommandNotifier.shared.model = self
        spotlight.start(sessionTree)
        QuickLookPreview.removeAll()
        RemoteFileDrag.removeAll()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            QuickLookPreview.removeAll()
            RemoteFileDrag.removeAll()
            MainActor.assumeIsolated { RemoteEditor.shared.removeSynced() }
        }
        IntentBridge.open = { id in
            guard let workspace = activeWorkspace(), let node = workspace.sessionTree.node(id), !node.isFolder else { return false }
            workspace.openSaved(node)
            workspace.bringForward()
            return true
        }
        IntentBridge.newLocalTerminal = { if let workspace = activeWorkspace() { workspace.addLocalTab(); workspace.bringForward() } }
        IntentBridge.sessions = {
            guard let workspace = activeWorkspace() else { return [] }
            return workspace.sessionTree.nodes.filter { !$0.isFolder }.map { node in
                IntentSession(id: node.id, name: node.name,
                              detail: node.connection.map { "\($0.accountPrefix)\($0.host)" } ?? node.container?.summary ?? "")
            }
        }
    }

    /// Opens what a Spotlight result points at. Returns whether it was one of Gloamux's.
    @discardableResult public func continueActivity(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              identifier.hasPrefix(SpotlightIndex.prefix),
              let id = UUID(uuidString: String(identifier.dropFirst(SpotlightIndex.prefix.count))),
              let node = sessionTree.node(id), !node.isFolder else { return false }
        openSaved(node)
        bringForward()
        return true
    }

    /// `gloamux://open?id=<saved session>` opens a saved session; `gloamux://new-terminal` opens a local terminal.
    /// Links never carry hosts or commands, so a web page can only open sessions the user already saved.
    @discardableResult public func open(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "gloamux" else { return false }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch url.host?.lowercased() {
        case "open":
            guard let value = components?.queryItems?.first(where: { $0.name == "id" })?.value, let id = UUID(uuidString: value),
                  let node = sessionTree.node(id), !node.isFolder else { error = "That saved session no longer exists."; return false }
            openSaved(node)
        case "new-terminal":
            addLocalTab()
        default:
            return false
        }
        bringForward()
        return true
    }

    func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        workspaceWindow?.makeKeyAndOrderFront(nil)
    }
}
