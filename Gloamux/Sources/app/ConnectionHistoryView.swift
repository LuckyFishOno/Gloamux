import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Every connection, newest first, with what happened in the selected one and its terminal log when there is one.
struct ConnectionHistoryView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var history: ConnectionHistory
    @AppStorage(ConnectionHistory.enabledKey) private var enabled = true
    @AppStorage(ConnectionHistory.commandsKey) private var keepsCommands = true
    @AppStorage(TerminalPreferences.logKey) private var logsEverySession = false
    @State private var selection: UUID?
    /// Narrow: the chosen connection's details fill the view instead of the list.
    @State private var showsDetail = false
    @State private var confirmsClear = false
    @State private var error: String?

    private var shown: [ConnectionRecord] { history.matching(history.search) }

    /// The list's and the details' least widths side by side. Below it, as when the browser panel leaves the log little
    /// room, one shows at a time, so neither is pushed under the panels around the log.
    static let sideBySideWidth: CGFloat = listMinWidth + detailMinWidth + 10
    static let listMinWidth: CGFloat = 180
    static let detailMinWidth: CGFloat = 320

    var body: some View {
        let records = shown
        GeometryReader { space in
            if space.size.width >= Self.sideBySideWidth {
                HSplitView {
                    list(records, compact: false)
                        .frame(minWidth: Self.listMinWidth, idealWidth: 300, maxWidth: 420)
                    detail(compact: false)
                        .frame(minWidth: Self.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if showsDetail, selection != nil {
                detail(compact: true)
            } else {
                list(records, compact: true)
            }
        }
        .clipped()
        .onAppear { history.reload(); if selection == nil { selection = shown.first?.id } }
        .onChange(of: history.search) { _, _ in
            let records = shown
            if !records.contains(where: { $0.id == selection }) { selection = records.first?.id }
        }
        .alert(T("Clear the connection history?"), isPresented: $confirmsClear) {
            Button(T("Clear"), role: .destructive) { perform { try history.clear() } }
            Button(T("Cancel"), role: .cancel) {}
        } message: { Text(T("Terminal logs stay in their folder. This cannot be undone.")) }
        .alert(T("The history could not be changed."), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(T("OK")) { error = nil }
        } message: { Text(error.map(T) ?? "") }
    }

    private func list(_ records: [ConnectionRecord], compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(T("Session Log")).appFont(.headline).lineLimit(1)
                InfoButton(T("Each connection is saved as one record: when, where, through which jump hosts or proxy, how it ended, the commands run in it, and the files copied or changed and ports forwarded. Passwords, session keys, and command output are not part of it. Records are kept for a year, up to 2,000."))
                Spacer(minLength: 0)
                Menu {
                    Button(T("Export as CSV")) { export(csv: true) }.disabled(records.isEmpty)
                    Button(T("Export as JSON")) { export(csv: false) }.disabled(records.isEmpty)
                    Divider()
                    Toggle(T("Keep connection history"), isOn: $enabled)
                    Toggle(T("Record commands"), isOn: $keepsCommands).disabled(!enabled)
                    Toggle(T("Log every session"), isOn: $logsEverySession)
                    Divider()
                    Button(T("Clear history"), role: .destructive) { confirmsClear = true }.disabled(history.records.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(T("History options"))
            }
            .padding(12)
            TextField(T("Search"), text: $history.search).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            if records.isEmpty {
                ContentUnavailableView(T(history.search.isEmpty ? "No connections yet" : "No matches"), systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Narrow, choosing a connection opens its details; side by side, it only selects it.
                List(records, selection: Binding(get: { selection }, set: { id in
                    selection = id
                    if compact, id != nil { showsDetail = true }
                })) { record in
                    row(record).tag(record.id)
                        .contextMenu {
                            Button(T("Download log")) { download(record) }
                            Button(T("Delete"), role: .destructive) { remove(record) }.disabled(history.open.contains(record.id))
                        }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("historyList")
            }
        }
    }

    @ViewBuilder private func detail(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if compact {
                Button { showsDetail = false } label: {
                    Label(T("Session Log"), systemImage: "chevron.left").lineLimit(1)
                }
                .buttonStyle(.borderless)
                .help(T("Back"))
                .accessibilityIdentifier("historyBack")
                .padding([.horizontal, .top], 12)
            }
            if let record = history.records.first(where: { $0.id == selection }) {
                ConnectionRecordView(history: history, record: record) { download(record) }.id(record.id)
            } else {
                ContentUnavailableView(T("Choose a connection"), systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func row(_ record: ConnectionRecord) -> some View {
        let state = record.state(open: history.open.contains(record.id))
        return HStack(spacing: 9) {
            Image(systemName: state.symbol).foregroundStyle(state.color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).lineLimit(1).truncationMode(.middle)
                Text(verbatim: "\(record.kind.uppercased())  \(record.address)").appFont(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.started, format: .dateTime.year().month().day().hour().minute())
                    Text(T(state.title))
                }
                .appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func download(_ record: ConnectionRecord) {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let safe = String(record.name.map { "/:\\".contains($0) ? "_" : $0 }.prefix(60))
        panel.nameFieldStringValue = "\(formatter.string(from: record.started)) \(safe).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try writePrivate(Data(history.report(record).utf8), to: url) }
    }

    private func export(csv: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Gloamux history." + (csv ? "csv" : "json")
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let records = shown
        perform { try writePrivate(csv ? Data(history.csv(records).utf8) : history.exportJSON(records), to: url) }
    }

    private func remove(_ record: ConnectionRecord) {
        perform { try history.remove([record.id]) }
        if selection == record.id { selection = history.records.first?.id }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
}

extension ConnectionHistory {
    /// Records whose name, address, kind, or events contain every word.
    func matching(_ search: String) -> [ConnectionRecord] {
        let words = search.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return records }
        return records.filter { record in
            let text = [record.name, record.address, record.kind] + record.events.compactMap(\.detail)
            return words.allSatisfy { word in text.contains { $0.localizedStandardContains(String(word)) } }
        }
    }

    func exportJSON(_ records: [ConnectionRecord]) throws -> Data {
        try JSONSerialization.data(withJSONObject: records.map { json($0, events: true) }, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

extension ConnectionRecord.State {
    var title: String {
        switch self {
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .failed: return "Connection failed"
        case .closed: return "Ended"
        case .lost: return "Connection lost"
        case .unknown: return "Ended unexpectedly"
        }
    }
    var symbol: String {
        switch self {
        case .connecting: return "circle.dotted"
        case .connected: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .closed: return "circle"
        case .lost: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    var color: Color {
        switch self {
        case .connected: return .green
        case .failed: return .red
        case .lost: return .orange
        default: return .secondary
        }
    }
}

extension ConnectionRecord.Event.Kind {
    /// A copy, or a change to a file or folder on the server.
    var isFileEvent: Bool {
        [.downloaded, .uploaded, .transferFailed, .skipped, .folderCreated, .renamed, .deleted, .permissions].contains(self)
    }
    var title: String {
        switch self {
        case .opened: return "Connection started"
        case .connected: return "Signed in"
        case .failed: return "Connection failed"
        case .closed: return "Disconnected"
        case .lost: return "Connection lost"
        case .log: return "Session log"
        case .downloaded: return "Downloaded"
        case .uploaded: return "Uploaded"
        case .transferFailed: return "Transfer failed"
        case .skipped: return "Skipped"
        case .direct: return "Direct connection"
        case .jump: return "Jump host"
        case .proxy: return "Proxy"
        case .command: return "Command"
        case .folderCreated: return "Folder created"
        case .renamed: return "Renamed"
        case .deleted: return "Deleted"
        case .permissions: return "Permissions changed"
        case .forwardStarted: return "Port forwarding started"
        case .forwardStopped: return "Port forwarding stopped"
        case .forwardFailed: return "Port forwarding failed"
        case .sshConnected: return "SSH connected"
        case .sshFailed: return "SSH connection failed"
        }
    }
}

private struct ConnectionRecordView: View {
    @ObservedObject var history: ConnectionHistory
    let record: ConnectionRecord
    let download: () -> Void
    @State private var log: String?
    @State private var shows = Shows.all

    /// Which events are listed.
    private enum Shows: String, CaseIterable {
        case all = "All", commands = "Commands", files = "Files", connection = "Connection"

        func includes(_ kind: ConnectionRecord.Event.Kind) -> Bool {
            switch self {
            case .all: return true
            case .commands: return kind == .command
            case .files: return kind.isFileEvent
            case .connection: return kind != .command && !kind.isFileEvent
            }
        }
    }

    var body: some View {
        let state = record.state(open: history.open.contains(record.id))
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    summary(state)
                    Spacer(minLength: 0)
                    status(state)
                    Button(T("Download log"), systemImage: "square.and.arrow.down", action: download)
                        .fixedSize().accessibilityIdentifier("downloadHistoryLog")
                }
                VStack(alignment: .leading, spacing: 8) {
                    summary(state)
                    HStack(spacing: 10) {
                        status(state)
                        Spacer(minLength: 0)
                        Button(T("Download log"), systemImage: "square.and.arrow.down", action: download)
                            .labelStyle(.iconOnly).help(T("Download log")).accessibilityIdentifier("downloadHistoryLog")
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                showsPicker.pickerStyle(.segmented).fixedSize()
                showsPicker.pickerStyle(.menu).fixedSize()
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if shows.includes(.opened) { event(record.started, "Connection started", nil, nil) }
                    ForEach(Array(record.events.enumerated()).filter { shows.includes($0.element.kind) }, id: \.offset) { _, entry in
                        if entry.kind == .command, let command = entry.detail { commandRow(entry.time, command) }
                        else if entry.kind == .sshConnected || entry.kind == .sshFailed { sshRow(entry) }
                        else {
                            event(entry.time, entry.kind.title, entry.kind == .log ? entry.detail.map { ($0 as NSString).lastPathComponent } : entry.detail, entry.bytes)
                        }
                    }
                    if shows == .all, let log {
                        Divider().padding(.vertical, 6)
                        Text(T("Session log")).appFont(.headline)
                        Text(verbatim: log).appFont(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .task(id: record.logPath) { log = history.logText(record, limit: 256 * 1024) }
    }

    /// The connection's name, kind and address, and the route it took.
    private func summary(_ state: ConnectionRecord.State) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.name).appFont(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Text(verbatim: "\(record.kind.uppercased())  \(record.address)").appFont(.callout.monospaced())
                .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            if let route = record.route {
                Label {
                    Text(verbatim: route.isEmpty ? T("Direct connection") : (route + [record.host]).joined(separator: " → "))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: route.isEmpty ? "arrow.right" : "point.topleft.down.to.point.bottomright.curvepath") }
                    .appFont(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("historyRoute")
            }
        }
    }

    private func status(_ state: ConnectionRecord.State) -> some View {
        Label(T(state.title), systemImage: state.symbol).foregroundStyle(state.color).lineLimit(1).fixedSize()
    }

    private var showsPicker: some View {
        Picker(T("Show"), selection: $shows) {
            ForEach(Shows.allCases, id: \.self) { choice in
                let count = record.events.filter { choice.includes($0.kind) }.count
                Text(verbatim: choice == .commands || choice == .files ? "\(T(choice.rawValue)) (\(count))" : T(choice.rawValue)).tag(choice)
            }
        }
        .labelsHidden()
    }

    private func commandRow(_ time: Date, _ command: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            stamp(time)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right").appFont(.caption2.weight(.bold)).foregroundStyle(.tint)
                    .accessibilityLabel(T("Command"))
                Text(verbatim: command).appFont(.callout.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// How an `ssh` run in the terminal went, under its command.
    private func sshRow(_ entry: ConnectionRecord.Event) -> some View {
        let connected = entry.kind == .sshConnected
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            stamp(entry.time)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: connected ? "checkmark.circle.fill" : "xmark.circle.fill").appFont(.caption)
                    .foregroundStyle(connected ? .green : .red).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(T(entry.kind.title))
                    if let detail = entry.detail {
                        Text(verbatim: detail).appFont(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func stamp(_ time: Date) -> some View {
        Text(time, format: .dateTime.hour().minute().second()).appFont(.callout.monospacedDigit()).foregroundStyle(.secondary)
            .frame(width: 92, alignment: .leading)
    }

    private func event(_ time: Date, _ title: String, _ detail: String?, _ bytes: UInt64?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            stamp(time)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(T(title))
                    if let bytes {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)).foregroundStyle(.secondary)
                    }
                }
                if let detail {
                    Text(verbatim: T(detail)).appFont(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
