import AppKit
import Foundation

/// Gloamux was called Termac, and MShell before that. These names keep data saved under them readable: the first launch
/// under the new name moves the newest old data folder and settings over, and exports with the old extensions still
/// import.
public enum LegacyName {
    /// An earlier name's data folder and settings domain, newest first.
    public struct Install: Sendable {
        public let folder: String
        public let bundleID: String
    }

    public static let installs = [Install(folder: "Termac", bundleID: "local.termac.desktop"),
                           Install(folder: "MShell", bundleID: "local.mshell.desktop")]
    static let configExtensions = ["termacconfig", "mshellconfig"]
    static let configFormats = ["termac/config@1", "mshell/config@1"]
    static let sessionsExtensions = ["termacsessions", "mshellsessions"]
    static let sessionsFormats = ["termac-sessions", "mshell-sessions"]

    /// Moves the newest earlier data folder to Gloamux's when Gloamux has none yet, and copies the newest earlier settings
    /// when Gloamux has none of its own. Nothing is moved while an earlier app is still running, since it may be writing to that
    /// folder; the next launch tries again. The old settings domains are left in place.
    public static func migrate(support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                               newFolder: String = "Gloamux", newBundleID: String = "local.gloamux.desktop",
                               earlier: [(folder: String, bundleID: String)] = installs.map { ($0.folder, $0.bundleID) },
                               defaults: UserDefaults = .standard,
                               oldAppRunning: () -> Bool = {
                                   installs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty }
                               }) {
        guard !oldAppRunning() else { return }
        let files = FileManager.default
        let new = support.appendingPathComponent(newFolder, isDirectory: true)
        if !files.fileExists(atPath: new.path),
           let old = earlier.lazy.map({ support.appendingPathComponent($0.folder, isDirectory: true) }).first(where: { files.fileExists(atPath: $0.path) }) {
            try? files.moveItem(at: old, to: new)
        }
        // macOS writes window frames and similar `NS` keys on its own, so only Gloamux's own settings count.
        let current = defaults.persistentDomain(forName: newBundleID) ?? [:]
        if !current.keys.contains(where: { !$0.hasPrefix("NS") }),
           let settings = earlier.lazy.compactMap({ defaults.persistentDomain(forName: $0.bundleID) }).first(where: { !$0.isEmpty }) {
            defaults.setPersistentDomain(current.merging(settings) { kept, _ in kept }, forName: newBundleID)
        }
    }
}
