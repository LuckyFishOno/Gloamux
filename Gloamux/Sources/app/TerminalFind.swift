import SwiftUI
import AppKit

/// What the terminal's find bar searches for. `move` changes for each Find Next or Find Previous.
struct TerminalSearch: Equatable {
    var query = ""
    var regex = false
    var caseSensitive = false
    var move = 0
    var backwards = false
}

/// The result shown in the find bar: which match is selected, how many there are, and whether the pattern is valid.
struct TerminalSearchStatus: Equatable {
    var current = 0
    var total = 0
    var invalid = false
    /// The search stopped at `TerminalTextView.maximumFindMatches`.
    var capped = false
}

extension WorkspaceModel {
    /// ⌘F: shows the find bar for the focused terminal, or focuses it again.
    func showFind(_ tab: SessionTab? = nil) {
        guard let tab = tab ?? selected else { return }
        if tab.search == nil { tab.search = TerminalSearch(query: tab.lastSearchQuery) }
        tab.findFocusRequest += 1
    }

    /// ⌘G and ⇧⌘G. With the bar closed, they open it.
    func findAgain(backwards: Bool, in tab: SessionTab? = nil) {
        guard let tab = tab ?? selected else { return }
        guard var search = tab.search else { showFind(tab); return }
        search.backwards = backwards
        search.move += 1
        tab.search = search
    }

    func closeFind(_ tab: SessionTab) {
        if let query = tab.search?.query, !query.isEmpty { tab.lastSearchQuery = query }
        tab.search = nil
        tab.searchStatus = TerminalSearchStatus()
        tab.terminalFocusRequest += 1
    }
}

/// The find bar over a terminal: the text or pattern, the match count, regular-expression and case options, and
/// buttons for the previous and next match. Return moves up to older output; Shift-Return moves down.
struct TerminalFindBar: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    @FocusState private var focused: Bool

    var body: some View {
        if let search = tab.search {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).appFont(.system(size: 11))
                TextField(T("Find"), text: Binding(get: { search.query }, set: { value in
                    guard var current = tab.search else { return }
                    current.query = value
                    tab.search = current
                }))
                    .textFieldStyle(.plain)
                    .appFont(.system(size: 12, design: search.regex ? .monospaced : .default))
                    .frame(minWidth: 120, idealWidth: 180, maxWidth: 220)
                    .focused($focused)
                    .onSubmit { model.findAgain(backwards: !NSEvent.modifierFlags.contains(.shift), in: tab) }
                    .onKeyPress(.escape) { model.closeFind(tab); return .handled }
                    .accessibilityIdentifier("terminalFindField")
                Text(statusText)
                    .appFont(.system(size: 11).monospacedDigit())
                    .foregroundStyle(tab.searchStatus.invalid || (tab.searchStatus.total == 0 && !search.query.isEmpty) ? Color.red : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                toggle("Aa", on: search.caseSensitive, help: T("Match case")) { $0.caseSensitive.toggle() }
                toggle(".*", on: search.regex, help: T("Regular expression")) { $0.regex.toggle() }
                Divider().frame(height: 14)
                iconButton("chevron.up", help: T("Previous match")) { model.findAgain(backwards: true, in: tab) }
                iconButton("chevron.down", help: T("Next match")) { model.findAgain(backwards: false, in: tab) }
                iconButton("xmark", help: T("Close")) { model.closeFind(tab) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .padding(8)
            .onAppear { focused = true }
            .onChange(of: tab.findFocusRequest) { focused = true }
        }
    }

    private var statusText: String {
        let status = tab.searchStatus
        if status.invalid { return T("Invalid pattern") }
        guard let query = tab.search?.query, !query.isEmpty else { return "" }
        if status.total == 0 { return T("No matches") }
        return "\(status.current)/\(status.total)\(status.capped ? "+" : "")"
    }

    private func toggle(_ label: String, on: Bool, help: String, _ change: @escaping (inout TerminalSearch) -> Void) -> some View {
        Button {
            guard var search = tab.search else { return }
            change(&search)
            tab.search = search
        } label: {
            Text(label).appFont(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 22, height: 18)
                .background(on ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).appFont(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Blurs what is behind the window, under a terminal drawn below full opacity.
struct TerminalBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
