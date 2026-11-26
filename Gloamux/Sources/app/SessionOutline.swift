import SwiftUI
import AppKit

extension NSPasteboard.PasteboardType {
    /// A saved session or folder dragged inside the session tree. Other apps and panes ignore it.
    static let gloamuxSessionNode = NSPasteboard.PasteboardType("local.gloamux.session-node")
}

/// Where a dragged item lands: inside `parent` (nil is the top level), in front of `before` (nil is last).
/// `childIndex` is the outline's own drop index, -1 meaning "onto the folder" (it then goes last).
struct SessionOutlineDrop: Equatable {
    var parent: UUID?
    var before: UUID?
    var childIndex: Int

    /// Turns the outline's proposal into a drop. `shown` gives the children a folder shows right now, and `fraction`
    /// is how far down the row under the pointer it is (0 top, 1 bottom).
    /// A folder row's top and bottom edges place the item before or after that folder, so folders change places as
    /// easily as sessions; its middle puts the item inside. The edges are wider while dragging a folder.
    /// A gap between rows keeps its meaning while sorted by name: the drop then makes the order on screen the custom one.
    @MainActor static func resolve(_ store: SessionTreeStore, moving id: UUID, onto target: UUID?, index: Int,
                                   fraction: CGFloat? = nil, shown: (UUID?) -> [UUID]) -> SessionOutlineDrop? {
        var parent = target, index = index
        if index < 0, let target, let node = store.node(target) {
            let position = shown(node.parent).firstIndex(of: target)
            if !node.isFolder {
                // Onto a session: just below it, in its own folder.
                parent = node.parent; index = position.map { $0 + 1 } ?? shown(parent).count
            } else if let fraction, let position {
                let edge: CGFloat = store.node(id)?.isFolder == true ? 0.35 : 0.25
                let open = node.expanded || !store.query.isEmpty
                // An open folder's bottom edge sits right above its own first child, so there it still means inside.
                if fraction < edge { parent = node.parent; index = position }
                else if fraction > 1 - edge && !open { parent = node.parent; index = position + 1 }
            }
        }
        guard store.canDrop(id, on: parent, .into) else { return nil }
        if index < 0 { return SessionOutlineDrop(parent: parent, before: nil, childIndex: -1) }
        let siblings = shown(parent)
        let before = siblings.indices.contains(index) ? siblings[index] : nil
        return SessionOutlineDrop(parent: parent, before: before, childIndex: index)
    }
}

/// The saved-session tree, drawn by AppKit's outline view: the selection, disclosure triangles, arrow keys and type
/// select of a Finder sidebar, and drag and drop that keeps working while the list scrolls under it — at its edges,
/// with the scroll wheel, and into a closed folder that opens when the pointer rests on it.
struct SessionOutline: NSViewRepresentable {
    @ObservedObject var store: SessionTreeStore
    /// Shows the dot after each saved host's name; nil hides them.
    var reachability: Reachability?
    var activate: (SessionTreeNode) -> Void = { _ in }
    /// The right-click menu for an item, or for the empty space under the rows when nil.
    var menu: (SessionTreeNode?) -> NSMenu = { _ in NSMenu() }
    /// Return asks to open, Delete asks to remove.
    var delete: (SessionTreeNode) -> Void = { _ in }
    var failed: (Error) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SessionOutlineView()
        outline.coordinator = context.coordinator
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        // The system selection is a strong accent bar, or a gray one in a sidebar; the row view below draws its own.
        outline.selectionHighlightStyle = .none
        outline.backgroundColor = .clear
        outline.usesAutomaticRowHeights = true
        outline.indentationPerLevel = 14
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.autosaveExpandedItems = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.action = #selector(Coordinator.click(_:))
        outline.doubleAction = #selector(Coordinator.doubleClick(_:))
        outline.registerForDraggedTypes([.gloamuxSessionNode])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.draggingDestinationFeedbackStyle = .sourceList
        let menu = NSMenu(); menu.delegate = context.coordinator; outline.menu = menu
        outline.setAccessibilityLabel(T("Session Manager"))
        outline.setAccessibilityIdentifier("sessionTree")

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        context.coordinator.outline = outline
        context.coordinator.refresh()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // The workspace theme picks light or dark in SwiftUI; the outline's rows follow it, not the Mac's own setting.
        let appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        if scroll.appearance?.name != appearance?.name { scroll.appearance = appearance }
        context.coordinator.parent = self
        context.coordinator.refresh()
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: SessionOutline
        weak var outline: SessionOutlineView?
        /// One object per node, so the outline keeps each row's state across reloads.
        private var items: [UUID: Item] = [:]
        private var shown: [UUID?: [UUID]] = [:]
        private var signature: [String] = []
        /// Set while the tree is brought in line with the store, so the outline's own callbacks do not write back.
        private var syncing = false

        final class Item: NSObject { let id: UUID; init(_ id: UUID) { self.id = id } }

        init(_ parent: SessionOutline) { self.parent = parent }

        private var store: SessionTreeStore { parent.store }
        private var searching: Bool { !store.query.isEmpty }
        private func item(_ id: UUID?) -> Item? {
            guard let id else { return nil }
            if let item = items[id] { return item }
            let item = Item(id); items[id] = item; return item
        }
        private func node(_ item: Any?) -> SessionTreeNode? { store.node((item as? Item)?.id) }
        func children(_ parent: UUID?) -> [UUID] { shown[parent] ?? [] }

        /// Rebuilds the rows when anything they show changed, then matches expansion and selection to the store.
        func refresh() {
            guard let outline else { return }
            var next: [UUID?: [UUID]] = [:]
            var lines = ["\(store.query)|\(store.sorting)|\(store.clipboard?.uuidString ?? "")|\(store.cutting)|\(parent.reachability != nil)"]
            func walk(_ id: UUID?) {
                let kids = store.children(of: id).filter { store.matches($0.id) }
                next[id] = kids.map(\.id)
                for kid in kids {
                    lines.append("\(id?.uuidString ?? "")>\(kid.id)|\(kid.name)|\(kid.environment?.rawValue ?? "")|\(kid.isFolder)|\(kid.container?.tool.symbol ?? "")|\(kid.connection?.isFTP == true)")
                    if kid.isFolder { walk(kid.id) }
                }
            }
            walk(nil)
            syncing = true
            defer { syncing = false }
            if lines != signature {
                let scroll = outline.enclosingScrollView?.contentView.bounds.origin
                shown = next; signature = lines
                items = items.filter { id, _ in store.node(id) != nil }
                outline.reloadData()
                if let scroll { outline.enclosingScrollView?.contentView.scroll(to: scroll) }
            }
            syncExpansion(nil)
            outline.sizeLastColumnToFit()
            let row = store.selection.flatMap { outline.row(forItem: item($0)) } ?? -1
            if row != outline.selectedRow {
                if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) } else { outline.deselectAll(nil) }
            }
        }

        private func syncExpansion(_ parent: UUID?) {
            guard let outline else { return }
            for id in children(parent) {
                guard let node = store.node(id), node.isFolder else { continue }
                let open = searching || node.expanded
                if open != outline.isItemExpanded(item(id)) {
                    if open { outline.expandItem(item(id)) } else { outline.collapseItem(item(id)) }
                }
                if open { syncExpansion(id) }
            }
        }

        // MARK: Data

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children((item as? Item)?.id).count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            self.item(children((item as? Item)?.id)[index])!
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { node(item)?.isFolder == true }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = node(item) else { return nil }
            let cell = outlineView.makeView(withIdentifier: SessionOutlineCell.identifier, owner: nil) as? SessionOutlineCell ?? SessionOutlineCell()
            cell.show(SessionTreeRowLabel(node: node, clipboard: store.clipboard == node.id ? (store.cutting ? "scissors" : "doc.on.doc") : nil,
                                          reachability: node.isFolder ? nil : parent.reachability))
            cell.setAccessibilityLabel(node.name)
            return cell
        }
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let row = outlineView.makeView(withIdentifier: SessionOutlineRowView.identifier, owner: nil) as? SessionOutlineRowView ?? SessionOutlineRowView()
            row.lifted = (item as? Item)?.id == liftedID
            return row
        }
        func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? { node(item)?.name }

        // MARK: Selection and clicks

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let outline else { return }
            store.selection = (outline.item(atRow: outline.selectedRow) as? Item)?.id
        }
        func outlineViewItemDidExpand(_ notification: Notification) { remember(notification, expanded: true) }
        func outlineViewItemDidCollapse(_ notification: Notification) { remember(notification, expanded: false) }
        private func remember(_ notification: Notification, expanded: Bool) {
            // While searching every folder shows open; that is not the folder's own state.
            guard !syncing, !searching, let id = (notification.userInfo?["NSObject"] as? Item)?.id,
                  store.node(id)?.expanded != expanded else { return }
            do { try store.setExpanded(id, expanded) } catch { parent.failed(error) }
        }

        /// A folder opens and closes with a click anywhere on its row, like a Finder sidebar section.
        @objc func click(_ sender: Any?) {
            guard let outline, !searching, let event = NSApp.currentEvent, event.clickCount == 1 else { return }
            let row = outline.clickedRow
            guard row >= 0, let item = outline.item(atRow: row) as? Item, node(item)?.isFolder == true else { return }
            // The disclosure triangle already toggled it.
            let point = outline.convert(event.locationInWindow, from: nil)
            guard !outline.frameOfOutlineCell(atRow: row).insetBy(dx: -2, dy: -2).contains(point) else { return }
            toggle(item)
        }
        @objc func doubleClick(_ sender: Any?) {
            guard let outline, outline.clickedRow >= 0, let node = node(outline.item(atRow: outline.clickedRow)), !node.isFolder else { return }
            parent.activate(node)
        }
        private func toggle(_ item: Item) {
            guard let outline else { return }
            if outline.isItemExpanded(item) { outline.animator().collapseItem(item) } else { outline.animator().expandItem(item) }
        }
        /// Return opens the selected session, or opens and closes the selected folder.
        func openSelection() {
            guard let outline, let item = outline.item(atRow: outline.selectedRow) as? Item, let node = node(item) else { return }
            if node.isFolder { if !searching { toggle(item) } } else { parent.activate(node) }
        }
        func deleteSelection() {
            guard let outline, let node = node(outline.item(atRow: outline.selectedRow)) else { return }
            parent.delete(node)
        }

        // MARK: Menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let outline else { return }
            let row = outline.clickedRow
            let built = parent.menu(row >= 0 ? node(outline.item(atRow: row)) : nil)
            menu.removeAllItems()
            menu.autoenablesItems = false
            for entry in built.items { built.removeItem(entry); menu.addItem(entry) }
        }

        // MARK: Drag and drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let id = (item as? Item)?.id else { return nil }
            let entry = NSPasteboardItem()
            entry.setString(id.uuidString, forType: .gloamuxSessionNode)
            return entry
        }

        /// The item being dragged: its row fades so the blue insertion line and target stand out.
        private var liftedID: UUID?
        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
            liftedID = (draggedItems.first as? Item)?.id
            lift(true)
        }
        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            lift(false); liftedID = nil
        }
        private func lift(_ on: Bool) {
            guard let outline, let id = liftedID else { return }
            let row = outline.row(forItem: item(id))
            (row >= 0 ? outline.rowView(atRow: row, makeIfNecessary: false) as? SessionOutlineRowView : nil)?.lifted = on
        }

        private func dragged(_ info: NSDraggingInfo) -> UUID? {
            guard (info.draggingSource as? NSView) === outline else { return nil }
            return info.draggingPasteboard.string(forType: .gloamuxSessionNode).flatMap(UUID.init(uuidString:))
        }

        private func drop(_ info: NSDraggingInfo, onto item: Any?, index: Int) -> SessionOutlineDrop? {
            guard let id = dragged(info), let outline else { return nil }
            // How far down the row under the pointer it is, for a folder's before, inside and after zones.
            let point = outline.convert(info.draggingLocation, from: nil)
            let row = outline.row(at: point)
            let rect = row >= 0 ? outline.rect(ofRow: row) : .zero
            let fraction = row >= 0 && (outline.item(atRow: row) as? Item)?.id == (item as? Item)?.id && rect.height > 0
                ? (point.y - rect.minY) / rect.height : nil
            return SessionOutlineDrop.resolve(store, moving: id, onto: (item as? Item)?.id, index: index, fraction: fraction, shown: children)
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                         proposedChildIndex index: Int) -> NSDragOperation {
            guard let drop = drop(info, onto: item, index: index) else { return [] }
            outlineView.setDropItem(self.item(drop.parent), dropChildIndex: drop.childIndex)
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard let id = dragged(info), let drop = drop(info, onto: item, index: index) else { return false }
            if drop.before == id { return true }   // Dropped where it already is.
            do {
                // A drop between rows rearranges, so a tree sorted by name keeps what it shows and turns custom.
                if drop.childIndex >= 0 { try store.keepShownOrder() }
                try store.move(id, into: drop.parent, before: drop.before)
                // The folder it went into opens, so the moved item stays in view and selected.
                if let folder = drop.parent, store.node(folder)?.expanded == false, !searching { try store.setExpanded(folder, true) }
                store.selection = id
            } catch { parent.failed(error); return false }
            refresh()
            let row = outlineView.row(forItem: self.item(id))
            if row >= 0 { outlineView.scrollRowToVisible(row) }
            return true
        }
    }
}

/// The outline itself, with Return to open and Delete to remove the selected item.
final class SessionOutlineView: NSOutlineView {
    weak var coordinator: SessionOutline.Coordinator?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: coordinator?.openSelection()
        case 51, 117: coordinator?.deleteSelection()
        default: super.keyDown(with: event)
        }
    }
}

/// A row with a quiet selection under unchanged text, so the strong blue
/// stays for the insertion line and the drop target while dragging. A dragged row fades.
final class SessionOutlineRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("sessionRowView")
    var lifted = false { didSet { alphaValue = lifted ? 0.4 : 1 } }

    override init(frame: NSRect) { super.init(frame: frame); identifier = Self.identifier }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// How strong the selection's accent tint is. Dark sidebars need more for the same weight. Both stay well under
    /// the solid accent of the insertion line, and the tint is lighter while the window is in the background.
    static func tint(dark: Bool, key: Bool) -> CGFloat {
        dark ? (key ? 0.7 : 0.5) : (key ? 0.5 : 0.35)
    }

    override var isEmphasized: Bool { get { false } set {} }
    override var isSelected: Bool { didSet { if isSelected != oldValue { needsDisplay = true } } }
    /// The tint is stronger while the window is in front, so it redraws when the window gains or loses key.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: name, object: window)
        }
    }
    @objc private func keyChanged() { if isSelected { needsDisplay = true } }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: 4, dy: 1)
        let dark = [.darkAqua, .vibrantDark].contains(effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]))
        let key = window?.isKeyWindow == true
        NSColor.controlAccentColor.withAlphaComponent(Self.tint(dark: dark, key: key)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }
}

/// A row's cell: SwiftUI draws the label, and every click goes to the outline so it selects, drags and opens.
final class SessionOutlineCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("sessionRow")
    private let host = PassiveHostingView(rootView: AnyView(EmptyView()))

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ label: SessionTreeRowLabel) { host.rootView = AnyView(label.appTextSize()) }
}

final class PassiveHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What a row shows: its kind, name, environment tag, whether the host answers, and whether it is on the clipboard.
struct SessionTreeRowLabel: View {
    let node: SessionTreeNode
    /// The symbol of a copied or cut item.
    var clipboard: String?
    var reachability: Reachability?

    private var symbol: String {
        if node.isFolder { return "folder.fill" }
        if let tool = node.container?.tool { return tool.symbol }
        return node.connection?.isFTP == true ? "externaldrive.connected.to.line.below" : "terminal"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(node.isFolder ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 16)
            Text(node.name).lineLimit(1).truncationMode(.tail)
            if let environment = node.environment { EnvironmentBadge(environment: environment, compact: true) }
            if let reachability { ReachabilityDot(monitor: reachability, id: node.id) }
            Spacer(minLength: 0)
            if let clipboard { Image(systemName: clipboard).appFont(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
