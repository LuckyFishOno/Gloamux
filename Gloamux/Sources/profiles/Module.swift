// The "profiles" feature. contractSha256 pins the declared interface below; the self-test reports
// contract-mismatch when it changes.
// Declared interface:
//   input:
//     Session file path
//   output:
//     Session settings
//   state:
//     Profile folder tree
//   errors:
//     Typed parse errors
import GloamuxShared
import Foundation
import Formats

// Imports Xshell session files (.xsh) and transfer-session files (.xfp), which are INI files. Unknown
// sections and keys are ignored, so a file with a different grouping still imports what it can.

public enum Protocol: String, Sendable, CaseIterable {
    case ssh = "SSH", sftp = "SFTP", telnet = "TELNET", rlogin = "RLOGIN", serial = "SERIAL", local = "LOCAL"
    /// Session files store the protocol as text; an unrecognized value is kept verbatim here as `.other`.
    case other = ""
}

public struct ConnectionSettings: Equatable, Sendable {
    public var host = ""
    public var port: UInt16 = 22
    public var protocolName = ""
    public var userName = ""
    /// SSH authentication method as stored (e.g. "Password", "Public Key"); meaning not verified.
    public var authMethod = ""
    public var proxy = ""
}

public struct TerminalSettings: Equatable, Sendable {
    public var rows = 24
    public var cols = 80
    public var scrollbackSize = 0
    public var encoding = ""
    public var type = ""
    public var keepAlive = false
}

public struct AppearanceSettings: Equatable, Sendable {
    public var colorScheme = ""
    public var fontFace = ""
    public var fontSize = 0
}

/// One parsed session. `sections` keeps every section and key as read so nothing is lost; the typed
/// groups are a convenience view over the well-known keys.
public struct SessionProfile: Equatable, Sendable {
    public var name: String
    public var connection = ConnectionSettings()
    public var terminal = TerminalSettings()
    public var appearance = AppearanceSettings()
    public var sections: [IniSection]
    public var encoding: IniEncoding

    public func value(section: String, _ key: String) -> String? {
        sections.first { $0.name.caseInsensitiveCompare(section) == .orderedSame }?.value(key)
    }

    public init(data: Data, name: String) throws {
        let (text, encoding) = try IniText.decode(data)
        let sections = IniText.parse(text)
        guard !sections.isEmpty else { throw XshellFormatError.missingSection("SessionInfo") }
        self.name = name
        self.sections = sections
        self.encoding = encoding

        func find(_ key: String) -> String? {
            for s in sections { if let v = s.value(key) { return v } }
            return nil
        }
        func int(_ key: String, _ fallback: Int) -> Int { find(key).flatMap { Int($0) } ?? fallback }

        var c = ConnectionSettings()
        c.host = find("Host") ?? ""
        if let p = find("Port").flatMap({ UInt16($0) }) { c.port = p }
        c.protocolName = find("Protocol") ?? ""
        c.userName = find("UserName") ?? ""
        c.authMethod = find("AuthMethod") ?? ""
        c.proxy = find("Proxy") ?? ""
        self.connection = c

        var t = TerminalSettings()
        t.rows = int("Rows", 24)
        t.cols = int("Cols", 80)
        t.scrollbackSize = int("ScrollbackSize", 0)
        t.encoding = find("Encoding") ?? ""
        t.type = find("Terminal") ?? find("TerminalType") ?? ""
        t.keepAlive = int("KeepAlive", 0) == 1
        self.terminal = t

        var a = AppearanceSettings()
        a.colorScheme = find("ColorScheme") ?? ""
        a.fontFace = find("FontFace") ?? find("Font") ?? ""
        a.fontSize = int("FontSize", 0)
        self.appearance = a
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
    }

    /// Resolved protocol, or `.other` when the stored text is not a value we recognize.
    public var resolvedProtocol: Protocol { Protocol(rawValue: connection.protocolName.uppercased()) ?? .other }
}

/// A folder tree of session files, matching Xshell's "Sessions" folder. Mirrors CProfileFolder/CProfileManager by name only.
public struct SessionFolder: Sendable {
    public var path: URL
    public var sessions: [SessionProfile]
    public var subfolders: [SessionFolder]

    /// Loads every `.xsh`/`.xfp` under `root`. Files that do not parse are collected in `failed` rather than thrown.
    public static func load(_ root: URL) throws -> (folder: SessionFolder, failed: [(URL, Error)]) {
        var failed: [(URL, Error)] = []
        func walk(_ dir: URL) -> SessionFolder {
            var sessions: [SessionProfile] = [], subs: [SessionFolder] = []
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { subs.append(walk(url)) }
                else if ["xsh", "xfp"].contains(url.pathExtension.lowercased()) {
                    do { sessions.append(try SessionProfile(contentsOf: url)) } catch { failed.append((url, error)) }
                }
            }
            return SessionFolder(path: dir, sessions: sessions, subfolders: subs)
        }
        return (walk(root), failed)
    }

    public var allSessions: [SessionProfile] { sessions + subfolders.flatMap(\.allSessions) }
}

// Feature entry: payload is JSON {"path": "..."} for one session file, or {"folder": "..."} for a tree.
public enum ProfilesFeature: GloamuxFeature {
    public static let id = "profiles"
    public static let contractSha256 = "15eeb0817f41b3cc959114bad8f89ff5f7b1457987244378de9249f50b942490"
    public static let dependsOn: [String] = ["formats"]

    public static func run(_ request: FeatureRequest, dependencies: FeatureOutputs) throws -> FeatureResponse {
        if request.payload.isEmpty { return FeatureResponse(payload: #"{"ready":true,"extensions":["xsh","xfp"]}"#) }
        guard let obj = try JSONSerialization.jsonObject(with: Data(request.payload.utf8)) as? [String: String] else {
            throw FeatureError.failed(id, "expected JSON {path} or {folder}")
        }
        if let folder = obj["folder"] {
            let (tree, failed) = try SessionFolder.load(URL(fileURLWithPath: folder))
            let out: [String: Any] = ["sessions": tree.allSessions.map(describe), "failed": failed.map { ["path": $0.0.path, "error": "\($0.1)"] }]
            return FeatureResponse(payload: encode(out))
        }
        guard let path = obj["path"] else { throw FeatureError.failed(id, "expected JSON {path} or {folder}") }
        return FeatureResponse(payload: encode(describe(try SessionProfile(contentsOf: URL(fileURLWithPath: path)))))
    }

    static func describe(_ p: SessionProfile) -> [String: Any] {
        ["name": p.name, "protocol": p.resolvedProtocol.rawValue, "host": p.connection.host, "port": Int(p.connection.port),
         "user": p.connection.userName, "encoding": p.terminal.encoding, "rows": p.terminal.rows, "cols": p.terminal.cols,
         "colorScheme": p.appearance.colorScheme, "sections": p.sections.map(\.name)]
    }

    static func encode(_ obj: [String: Any]) -> String {
        (try? String(decoding: JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)) ?? "{}"
    }
}
