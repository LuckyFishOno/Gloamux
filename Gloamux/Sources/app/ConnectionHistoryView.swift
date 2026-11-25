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
    @State private var confirmsClear = false
    @State private var error: String?

    private var shown: [ConnectionRecord] { history.matching(history.search) }

    var body: some View {
        let records = shown
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(T("Session Log")).appFont(.headline)
                    InfoButton(T("Each connection is saved as one record: when, where, through which jump hosts or proxy, how it ended, the commands run in it, and the files copied or changed and ports forwarded. Passwords, session keys, and command output are not part of it. Records are kept for a year, up to 2,000."))
                    Spacer()
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
                    List(records, selection: $selection) { record in
                        row(record).tag(record.id)
                            .contextMenu {
                                Button(T("Download log")) { download(record) }
                                Button(T("Delete"), role: .destructive) { remove(record) }.disabled(history.open.contains(record.id))
                            }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(minWidth: 270, idealWidth: 320, maxWidth: 420)
            Group {
                if let record = history.records.first(where: { $0.id == selection }) {
                    ConnectionRecordView(history: history, record: record) { download(record) }.id(record.id)
                } else {
                    ContentUnavailableView(T("Choose a connection"), systemImage: "list.bullet.rectangle")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
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

    private func row(_ record: ConnectionRecord) -> some View {
        let state = record.state(open: history.open.contains(record.id))
        return HStack(spacing: 9) {
            Image(systemName: state.symbol).foregroundStyle(state.color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).lineLimit(1)
                Text(verbatim: "\(record.kind.uppercased())  \(record.address)").appFont(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.started, format: .dateTime.year().month().day().hour().minute())
                    Text(T(state.title))
                }
                .appFont(.caption).foregroundStyle(.secondary)
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
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.name).appFont(.title3.weight(.semibold)).lineLimit(1)
                    Text(verbatim: "\(record.kind.uppercased())  \(record.address)").appFont(.callout.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled)
                    if let route = record.route {
                        Label {
                            Text(verbatim: route.isEmpty ? T("Direct connection") : (route + [record.host]).joined(separator: " → "))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        } icon: { Image(systemName: route.isEmpty ? "arrow.right" : "point.topleft.down.to.point.bottomright.curvepath") }
                            .appFont(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("historyRoute")
                    }
                }
                Spacer()
                Label(T(state.title), systemImage: state.symbol).foregroundStyle(state.color)
                Button(T("Download log"), systemImage: "square.and.arrow.down", action: download)
                    .accessibilityIdentifier("downloadHistoryLog")
            }
            Picker(T("Show"), selection: $shows) {
                ForEach(Shows.allCases, id: \.self) { choice in
                    let count = record.events.filter { choice.includes($0.kind) }.count
                    Text(verbatim: choice == .commands || choice == .files ? "\(T(choice.rawValue)) (\(count))" : T(choice.rawValue)).tag(choice)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if shows.includes(.opened) { event(record.started, "Connection started", nil, nil) }
                    ForEach(Array(record.events.enumerated()).filter { shows.includes($0.element.kind) }, id: \.offset) { _, entry in
                        if entry.kind == .command, let command = entry.detail { commandRow(entry.time, command) }
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
