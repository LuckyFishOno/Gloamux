import Darwin
import Foundation
import Terminal

/// One connection: when it opened and ended, where to, how it went, and what was copied. Never passwords, answers,
/// session keys, or what the terminal showed; a terminal log, when one was written, is only named.
struct ConnectionRecord: Identifiable, Equatable {
    enum State: String { case connecting, connected, failed, closed, lost, unknown }

    struct Event: Equatable {
        enum Kind: String, Codable { case opened, connected, failed, closed, lost, log, downloaded, uploaded, transferFailed, skipped }
        let time: Date
        let kind: Kind
        var detail: String?
        var bytes: UInt64?
    }

    let id: UUID
    let name: String
    /// ssh, sftp, scp, ftp, ftps, telnet, serial, mosh, docker, kubectl, ssm, rdp, or vnc.
    let kind: String
    let host: String
    let port: Int?
    let user: String
    /// `app`, or `cli` for a command.
    let source: String
    let started: Date
    var events: [Event] = []

    var ended: Date? { events.last { [.failed, .closed, .lost].contains($0.kind) }?.time }
    var logPath: String? { events.last { $0.kind == .log }?.detail }
    var transfers: [Event] { events.filter { [.downloaded, .uploaded, .transferFailed, .skipped].contains($0.kind) } }
    var address: String { (user.isEmpty ? "" : user + "@") + host + (port.map { ":\($0)" } ?? "") }

    /// A connection without an end was open when Gloamux or the Mac stopped, unless it is open now.
    func state(open: Bool) -> State {
        for event in events.reversed() {
            switch event.kind {
            case .failed: return .failed
            case .closed: return .closed
            case .lost: return .lost
            case .connected: return open ? .connected : .unknown
            default: continue
            }
        }
        return open ? .connecting : .unknown
    }
}

/// Every connection of a workspace, one line of JSON per event in a file only this user can read. Events are appended, so
/// the app and commands can write at the same time and an unexpected stop loses nothing that was written.
@MainActor final class ConnectionHistory: ObservableObject {
    nonisolated static let enabledKey = "Gloamux.history.enabled"
    static let recordLimit = 2000
    static let maximumAge: TimeInterval = 365 * 24 * 3600
    private static let fileLimit = 64 * 1024 * 1024

    private struct Line: Codable {
        var id: UUID
        var time: Date
        var event: ConnectionRecord.Event.Kind
        var name: String?
        var kind: String?
        var host: String?
        var port: Int?
        var user: String?
        var source: String?
        var detail: String?
        var bytes: UInt64?
    }

    let url: URL
    /// Newest first.
    @Published private(set) var records: [ConnectionRecord] = []
    /// Connections this process has open.
    @Published private(set) var open: Set<UUID> = []
    /// Texts to leave out of an open connection's events: its session key.
    private var hidden: [UUID: String] = [:]
    private var loaded = false

    init(url: URL) { self.url = url }

    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    // MARK: Writing

    /// Starts a record, or returns nil when history is off.
    func begin(name: String, kind: String, host: String, port: Int?, user: String, source: String = "app", secret: String? = nil) -> UUID? {
        guard Self.isEnabled else { return nil }
        let id = UUID()
        if let secret, !secret.isEmpty { hidden[id] = secret }
        open.insert(id)
        let shownUser = secret == user && !user.isEmpty ? SessionKey.concealed(user) : SessionKey.masked(user)
        write(Line(id: id, time: Date(), event: .opened, name: clean(name, id), kind: kind, host: host, port: port,
                   user: shownUser, source: source))
        return id
    }

    func add(_ kind: ConnectionRecord.Event.Kind, to id: UUID?, detail: String? = nil, bytes: UInt64? = nil) {
        guard let id, open.contains(id) else { return }
        write(Line(id: id, time: Date(), event: kind, detail: detail.map { clean($0, id) }, bytes: bytes))
        if [.failed, .closed, .lost].contains(kind) { open.remove(id); hidden[id] = nil }
    }

    private func clean(_ text: String, _ id: UUID) -> String {
        var text = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        if let secret = hidden[id] { text = text.replacingOccurrences(of: secret, with: SessionKey.concealed(secret)) }
        return String(SecretRedaction.redact(text).prefix(1000))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    private func write(_ line: Line) {
        guard var data = try? Self.encoder.encode(line) else { return }
        data.append(0x0A)
        // History is best effort: a full disk must not stop a connection.
        try? locked {
            let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(fd) }
            try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        }
        if loaded { apply(line, to: &records, newest: true) }
    }

    /// Holds the file's lock, so a rewrite never drops a line another process appends.
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = Darwin.open(url.path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try body()
    }

    // MARK: Reading

    /// Reads the file again, so connections made by commands appear, and drops what is past the limits.
    func reload() {
        loaded = true
        guard let lines = try? locked({ try readLines() }) else { records = []; return }
        var found: [ConnectionRecord] = []
        var index: [UUID: Int] = [:]
        for line in lines { Self.apply(line, to: &found, index: &index) }
        let oldest = Date().addingTimeInterval(-Self.maximumAge)
        let kept = found.suffix(Self.recordLimit).filter { $0.started > oldest || open.contains($0.id) }
        if kept.count < found.count { try? keep(Set(kept.map(\.id))) }
        records = kept.reversed()
    }

    private func readLines() throws -> [Line] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        // A file past the limit keeps its newest part; the first, cut line does not decode and is dropped.
        try handle.seek(toOffset: size > UInt64(Self.fileLimit) ? size - UInt64(Self.fileLimit) : 0)
        let data = try handle.readToEnd() ?? Data()
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(Line.self, from: Data($0)) }
    }

    private func apply(_ line: Line, to records: inout [ConnectionRecord], newest: Bool) {
        if line.event == .opened {
            if let record = Self.record(line) { records.insert(record, at: 0) }
        } else if let index = records.firstIndex(where: { $0.id == line.id }) {
            records[index].events.append(.init(time: line.time, kind: line.event, detail: line.detail, bytes: line.bytes))
        }
    }

    private static func apply(_ line: Line, to records: inout [ConnectionRecord], index: inout [UUID: Int]) {
        if line.event == .opened {
            guard index[line.id] == nil, let record = record(line) else { return }
            index[line.id] = records.count
            records.append(record)
        } else if let position = index[line.id] {
            records[position].events.append(.init(time: line.time, kind: line.event, detail: line.detail, bytes: line.bytes))
        }
    }

    private static func record(_ line: Line) -> ConnectionRecord? {
        guard let kind = line.kind, let host = line.host else { return nil }
        return ConnectionRecord(id: line.id, name: line.name ?? host, kind: kind, host: host, port: line.port, user: line.user ?? "",
                                source: line.source ?? "app", started: line.time)
    }

    // MARK: Removing

    /// Removes records; a connection that is open now stays.
    func remove(_ ids: Set<UUID>) throws {
        try rewrite { !ids.contains($0.id) || open.contains($0.id) }
        records.removeAll { ids.contains($0.id) && !open.contains($0.id) }
    }

    func clear() throws {
        try rewrite { open.contains($0.id) }
        records.removeAll { !open.contains($0.id) }
    }

    private func keep(_ ids: Set<UUID>) throws { try rewrite { ids.contains($0.id) } }

    private func rewrite(_ keeps: (Line) -> Bool) throws {
        try locked {
            var data = Data()
            for line in try readLines() where keeps(line) {
                data.append(try Self.encoder.encode(line)); data.append(0x0A)
            }
            try writePrivate(data, to: url)
        }
    }

    // MARK: Exporting

    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    func json(_ record: ConnectionRecord, events: Bool = false) -> [String: Any] {
        var object: [String: Any] = ["id": record.id.uuidString, "name": record.name, "protocol": record.kind, "host": record.host,
                                     "user": record.user, "source": record.source, "started": Self.stamp(record.started),
                                     "state": record.state(open: open.contains(record.id)).rawValue, "transfers": record.transfers.count]
        if let port = record.port { object["port"] = port }
        if let ended = record.ended { object["ended"] = Self.stamp(ended) }
        if let log = record.logPath { object["log"] = log }
        if events {
            object["events"] = record.events.map { event in
                var entry: [String: Any] = ["time": Self.stamp(event.time), "event": event.kind.rawValue]
                if let detail = event.detail { entry["detail"] = detail }
                if let bytes = event.bytes { entry["bytes"] = bytes }
                return entry
            }
        }
        return object
    }

    /// One row per connection, for a spreadsheet.
    func csv(_ records: [ConnectionRecord]) -> String {
        func field(_ text: String) -> String {
            // A cell that starts like a formula is written as text, since names and errors come from servers.
            let safe = text.first.map { "=+-@\t\r".contains($0) } == true ? "'" + text : text
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var out = "started,ended,state,name,protocol,host,port,user,source,transfers,detail\n"
        for record in records {
            let reason = record.events.last { $0.kind == .failed }?.detail ?? ""
            out += [Self.stamp(record.started), record.ended.map(Self.stamp) ?? "", record.state(open: open.contains(record.id)).rawValue,
                    record.name, record.kind, record.host, record.port.map(String.init) ?? "", record.user, record.source,
                    String(record.transfers.count), reason].map(field).joined(separator: ",") + "\n"
        }
        return out
    }

    /// One connection as text: what happened, then its terminal log when there is one.
    func report(_ record: ConnectionRecord) -> String {
        var out = "Gloamux connection record\n\nName: \(record.name)\nAddress: \(record.address)\nProtocol: \(record.kind)\n"
        out += "State: \(record.state(open: open.contains(record.id)).rawValue)\nOpened from: \(record.source)\n\n"
        out += "\(Self.stamp(record.started))  opened\n"
        for event in record.events {
            out += "\(Self.stamp(event.time))  \(event.kind.rawValue)" + (event.detail.map { "  " + $0 } ?? "")
                + (event.bytes.map { "  (\($0) bytes)" } ?? "") + "\n"
        }
        if let text = logText(record) { out += "\nTerminal log\n\n" + text }
        return out
    }

    /// The terminal log of a record, at most its last `limit` bytes. Only a file inside the workspace's log folder is read.
    func logText(_ record: ConnectionRecord, limit: Int = 8 * 1024 * 1024) -> String? {
        guard let file = logURL(record), let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(limit) ? size - UInt64(limit) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func logURL(_ record: ConnectionRecord) -> URL? {
        guard let path = record.logPath else { return nil }
        let folder = url.deletingLastPathComponent().appendingPathComponent("logs", isDirectory: true).resolvingSymlinksInPath().path
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard file.path.hasPrefix(folder + "/"), FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }
}

extension SessionKey {
    /// A known key, shortened whatever it looks like.
    static func concealed(_ key: String) -> String { key.count >= 12 ? key.prefix(4) + "••••" : "••••" }
}

// MARK: - Recording a tab's connections

extension WorkspaceModel {
    /// Starts the record of a connection this tab is opening. `key` is a session key, which is left out of the record.
    func beginHistory(_ tab: SessionTab, kind: String? = nil, user: String? = nil, key: String? = nil) {
        // Trying again without disconnecting first ends the earlier attempt.
        endHistory(tab, .closed)
        let name = UIStrings.text(tab.title, language: UIStrings.language)
        if let container = tab.container {
            tab.historyID = history.begin(name: name, kind: container.tool.rawValue, host: container.target,
                                          port: container.tool.opensDesktop || container.tool == .telnet ? container.effectivePort : nil, user: "")
            return
        }
        let scheme = kind ?? (tab.ftpSecurity.map { $0 == .none ? "ftp" : "ftps" }
                              ?? (tab.showsFiles ? (tab.fileProtocol?.rawValue ?? "sftp") : "ssh"))
        tab.historyID = history.begin(name: name, kind: scheme, host: tab.host, port: Int(tab.port),
                                      user: key ?? user ?? tab.username, secret: key)
    }

    func noteHistory(_ tab: SessionTab, _ event: ConnectionRecord.Event.Kind, detail: String? = nil, bytes: UInt64? = nil) {
        history.add(event, to: tab.historyID, detail: detail, bytes: bytes)
    }

    func endHistory(_ tab: SessionTab, _ event: ConnectionRecord.Event.Kind, detail: String? = nil) {
        history.add(event, to: tab.historyID, detail: detail)
        tab.historyID = nil
    }
}
