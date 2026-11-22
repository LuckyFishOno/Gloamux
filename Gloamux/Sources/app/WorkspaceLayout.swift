import Foundation

/// How the workspace window is arranged. The raw values stay stable for saved preferences and the CLI.
public enum WorkspaceLayout: String, CaseIterable, Codable, Identifiable {
    /// Default: a Mac app with a toolbar, flat tabs, and floating panes.
    case native = "macos"
    /// Classic: icon toolbar, address bar, session manager, numbered tabs, compose bar, and status bar.
    case terminal
    /// Workbench: large-button ribbon, a vertical side rail with sessions, SFTP, and macros,
    /// and a remote monitoring bar.
    case transfer

    public var id: String { rawValue }

    /// Accepts the layout names, the stored values, and the names earlier versions used.
    public init?(argument: String) {
        switch argument.lowercased() {
        case "default", "macos", "native", "mac": self = .native
        case "classic", "terminal", "xshell": self = .terminal
        case "workbench", "transfer", "mobaxterm", "moba": self = .transfer
        default: return nil
        }
    }

    /// The name the CLI prints and accepts first.
    public var argument: String {
        switch self {
        case .native: return "default"
        case .terminal: return "classic"
        case .transfer: return "workbench"
        }
    }

    var title: String {
        switch self {
        case .native: return T("Default")
        case .terminal: return T("Classic")
        case .transfer: return T("Workbench")
        }
    }

    var detail: String {
        switch self {
        case .native: return T("Toolbar, flat tabs, and floating panes")
        case .terminal: return T("Session manager, compose bar, and status bar")
        case .transfer: return T("Ribbon, side rail with SFTP, and remote monitoring")
        }
    }

    var symbol: String {
        switch self {
        case .native: return "macwindow"
        case .terminal: return "rectangle.bottomthird.inset.filled"
        case .transfer: return "sidebar.squares.left"
        }
    }

    private static func file(in storage: URL) -> URL {
        storage.appendingPathComponent("layout.json")
    }

    public static func load(from storage: URL) throws -> Self {
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file(in: storage))) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .native }
    }

    public func save(to storage: URL) throws {
        try writePrivate(JSONEncoder().encode(self), to: Self.file(in: storage))
    }
}
