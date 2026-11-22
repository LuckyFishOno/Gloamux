import AppIntents
import Foundation

/// A saved session as Shortcuts and Siri see it.
public struct IntentSession: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let detail: String
    public init(id: UUID, name: String, detail: String) { self.id = id; self.name = name; self.detail = detail }
}

/// How the intents reach the running workspace. The app sets the closures once its workspace has loaded; until
/// then, sessions are read from the saved catalog and actions wait briefly for the workspace.
@MainActor public enum IntentBridge {
    public static var open: ((UUID) -> Bool)?
    public static var newLocalTerminal: (() -> Void)?
    public static var sessions: (() -> [IntentSession])?

    /// Saved sessions from `sessions.json` in the default workspace folder, for when the app has not loaded it.
    nonisolated static func storedSessions() -> [IntentSession] {
        struct Node: Decodable {
            struct Connection: Decodable { let host: String; let port: Int; let username: String }
            struct Container: Decodable { let tool: String; let target: String }
            let id: UUID; let name: String; let connection: Connection?; let container: Container?
        }
        struct Document: Decodable { let nodes: [Node] }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gloamux/sessions.json")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4_194_305), data.count <= 4_194_304,
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        return document.nodes.compactMap { node in
            if let connection = node.connection {
                return IntentSession(id: node.id, name: node.name, detail: "\(connection.username)@\(connection.host)")
            }
            if let container = node.container { return IntentSession(id: node.id, name: node.name, detail: container.target) }
            return nil
        }
    }

    static func current() -> [IntentSession] { sessions?() ?? storedSessions() }

    /// Waits up to five seconds for the app to finish opening its workspace.
    static func ready<T>(_ value: () -> T?) async -> T? {
        for _ in 0..<50 {
            if let found = value() { return found }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return value()
    }
}

public struct SessionEntity: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Saved Session"
    public static let defaultQuery = SessionQuery()
    public let id: UUID
    public let name: String
    public let detail: String
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    }
    init(_ session: IntentSession) { id = session.id; name = session.name; detail = session.detail }
}

public struct SessionQuery: EntityStringQuery {
    public init() {}
    public func entities(for identifiers: [UUID]) async throws -> [SessionEntity] {
        let sessions = await IntentBridge.current()
        return identifiers.compactMap { id in sessions.first { $0.id == id }.map(SessionEntity.init) }
    }
    public func entities(matching string: String) async throws -> [SessionEntity] {
        await IntentBridge.current().filter { $0.name.localizedStandardContains(string) || $0.detail.localizedStandardContains(string) }
            .map(SessionEntity.init)
    }
    public func suggestedEntities() async throws -> [SessionEntity] {
        await IntentBridge.current().prefix(50).map(SessionEntity.init)
    }
}

public struct OpenSessionIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Saved Session"
    public static let description = IntentDescription("Opens a saved SSH or container session in a new Gloamux tab.")
    public static let openAppWhenRun = true
    @Parameter(title: "Session") public var session: SessionEntity
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Open \(\.$session)") }

    @MainActor public func perform() async throws -> some IntentResult {
        guard let open = await IntentBridge.ready({ IntentBridge.open }), open(session.id) else {
            throw IntentFailure.sessionMissing
        }
        return .result()
    }
}

public struct NewLocalTerminalIntent: AppIntent {
    public static let title: LocalizedStringResource = "New Local Terminal"
    public static let description = IntentDescription("Opens a terminal on this Mac in a new Gloamux tab.")
    public static let openAppWhenRun = true
    public init() {}

    @MainActor public func perform() async throws -> some IntentResult {
        guard let start = await IntentBridge.ready({ IntentBridge.newLocalTerminal }) else { throw IntentFailure.notReady }
        start()
        return .result()
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case sessionMissing, notReady
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .sessionMissing: return "That saved session no longer exists."
        case .notReady: return "Gloamux could not open its workspace."
        }
    }
}

public struct GloamuxShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenSessionIntent(), phrases: ["Open \(\.$session) in \(.applicationName)",
                                                           "Connect to \(\.$session) with \(.applicationName)"],
                    shortTitle: "Open Session", systemImageName: "server.rack")
        AppShortcut(intent: NewLocalTerminalIntent(), phrases: ["New \(.applicationName) terminal"],
                    shortTitle: "New Terminal", systemImageName: "terminal")
    }
}
