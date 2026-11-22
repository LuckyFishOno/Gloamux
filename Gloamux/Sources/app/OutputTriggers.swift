import AppKit
import Foundation
import SwiftUI

/// A rule that watches terminal output: when a line matches, Gloamux notifies, plays a sound, or marks the tab.
struct OutputTrigger: Codable, Equatable, Identifiable, Sendable {
    enum Action: String, Codable, CaseIterable, Sendable {
        case notify, sound, mark
        var title: String {
            switch self {
            case .notify: return "Show a notification"
            case .sound: return "Play a sound"
            case .mark: return "Mark the tab"
            }
        }
    }

    var id = UUID()
    var name: String
    var pattern: String
    var regex = false
    var caseSensitive = false
    var action = Action.notify
    var enabled = true

    /// Patterns longer than this are refused, and lines are matched up to this length.
    static let maximumPattern = 512
    static let maximumLine = 4096

    func validate() throws {
        guard !pattern.isEmpty, pattern.count <= Self.maximumPattern else {
            throw WorkspaceError.invalid("Enter a pattern of up to 512 characters.")
        }
        if regex { _ = try compiled() }
    }

    func compiled() throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: regex ? pattern : NSRegularExpression.escapedPattern(for: pattern),
                                           options: caseSensitive ? [] : [.caseInsensitive])
        } catch { throw WorkspaceError.invalid("This regular expression is not valid.") }
    }
}

/// The saved triggers, in `<storage>/triggers.json`.
@MainActor final class OutputTriggerStore: ObservableObject {
    let url: URL
    @Published private(set) var triggers: [OutputTrigger] = []
    /// At most this many rules, so matching stays cheap on fast output.
    static let limit = 32

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([OutputTrigger].self, from: data) {
            triggers = Array(saved.prefix(Self.limit))
        }
    }

    func save(_ trigger: OutputTrigger) throws {
        try trigger.validate()
        var updated = triggers
        if let index = updated.firstIndex(where: { $0.id == trigger.id }) { updated[index] = trigger }
        else {
            guard updated.count < Self.limit else { throw WorkspaceError.invalid("You can keep up to 32 triggers.") }
            updated.append(trigger)
        }
        try write(updated)
    }

    func remove(_ id: UUID) throws { try write(triggers.filter { $0.id != id }) }

    private func write(_ updated: [OutputTrigger]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivate(encoder.encode(updated), to: url)
        triggers = updated
    }
}

/// Matches one terminal's output against the triggers, a whole line at a time. Each rule fires at most once every
/// ten seconds per terminal, so a flood of matching lines makes one notification.
struct OutputTriggerMatcher {
    private var stripper = EscapeStripper()
    private var line: [UInt8] = []
    private var lastFired: [UUID: Date] = [:]
    static let quietPeriod: TimeInterval = 10

    /// Takes decoded UTF-8 output and returns the rules that matched a finished line, with that line.
    mutating func feed(_ bytes: [UInt8], triggers: [(OutputTrigger, NSRegularExpression)], now: Date = Date()) -> [(OutputTrigger, String)] {
        guard !triggers.isEmpty else { line.removeAll(); return [] }
        var fired: [(OutputTrigger, String)] = []
        for byte in stripper.strip(bytes) {
            if byte == 0x0A {
                fired += match(String(decoding: line, as: UTF8.self), triggers: triggers, now: now)
                line.removeAll(keepingCapacity: true)
            } else if line.count < OutputTrigger.maximumLine {
                line.append(byte)
            }
        }
        return fired
    }

    private mutating func match(_ text: String, triggers: [(OutputTrigger, NSRegularExpression)], now: Date) -> [(OutputTrigger, String)] {
        guard !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var fired: [(OutputTrigger, String)] = []
        for (trigger, expression) in triggers where expression.firstMatch(in: text, range: range) != nil {
            if let last = lastFired[trigger.id], now.timeIntervalSince(last) < Self.quietPeriod { continue }
            lastFired[trigger.id] = now
            fired.append((trigger, text.trimmingCharacters(in: .whitespaces)))
        }
        return fired
    }
}

extension WorkspaceModel {
    /// The enabled triggers, compiled once per change.
    var compiledTriggers: [(OutputTrigger, NSRegularExpression)] {
        if let cached = triggerCache, cached.source == triggers.triggers { return cached.compiled }
        let compiled = triggers.triggers.filter(\.enabled).compactMap { trigger in (try? trigger.compiled()).map { (trigger, $0) } }
        triggerCache = (triggers.triggers, compiled)
        return compiled
    }

    func runTriggers(_ tab: SessionTab, bytes: [UInt8]) {
        let compiled = compiledTriggers
        guard !compiled.isEmpty || tab.triggerMatcher != nil else { return }
        var matcher = tab.triggerMatcher ?? OutputTriggerMatcher()
        let fired = matcher.feed(bytes, triggers: compiled)
        tab.triggerMatcher = compiled.isEmpty ? nil : matcher
        for (trigger, line) in fired {
            switch trigger.action {
            case .notify:
                CommandNotifier.shared.model = self
                CommandNotifier.shared.notify(title: trigger.name.isEmpty ? trigger.pattern : trigger.name,
                                              body: String(line.prefix(200)) + " · " + UIStrings.text(tab.title, language: language), tab: tab.id)
            case .sound:
                NSSound(named: "Glass")?.play()
            case .mark:
                if selection != tab.id { tab.attention = true }
            }
        }
    }
}

/// Settings › Triggers: the rules, with switches to turn each one off, and a form to add or edit one.
struct OutputTriggerSettings: View {
    @ObservedObject var store: OutputTriggerStore
    @State private var draft = OutputTrigger(name: "", pattern: "")
    @State private var editing = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                if store.triggers.isEmpty {
                    Text(T("No triggers yet")).foregroundStyle(.secondary)
                }
                ForEach(store.triggers) { trigger in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { trigger.enabled }, set: { on in
                            var changed = trigger; changed.enabled = on; perform { try store.save(changed) }
                        })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trigger.name.isEmpty ? trigger.pattern : trigger.name)
                            Text((trigger.regex ? "/\(trigger.pattern)/" : "“\(trigger.pattern)”") + " · " + T(trigger.action.title))
                                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(T("Edit")) { draft = trigger; editing = true }.buttonStyle(.borderless)
                        Button { perform { try store.remove(trigger.id) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel(T("Remove trigger"))
                    }
                }
                Button(T("Add trigger")) { draft = OutputTrigger(name: "", pattern: ""); editing = true }
                    .disabled(store.triggers.count >= OutputTriggerStore.limit)
            } header: {
                HStack(spacing: 6) {
                    Text(T("Output triggers"))
                    InfoButton(T("When a line of output in any terminal matches, Gloamux shows a notification, plays a sound, or marks the tab. Each rule fires at most once every 10 seconds per terminal. Triggers never type anything."))
                }
            }
            if let error { Text(T(error)).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $editing) { editor }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(T(store.triggers.contains { $0.id == draft.id } ? "Edit trigger" : "Add trigger")).font(.headline)
            Form {
                TextField(T("Name"), text: $draft.name, prompt: Text(T("Optional")))
                TextField(T("Pattern"), text: $draft.pattern).font(.body.monospaced())
                Toggle(T("Regular expression"), isOn: $draft.regex)
                Toggle(T("Match case"), isOn: $draft.caseSensitive)
                Picker(T("Action"), selection: $draft.action) {
                    ForEach(OutputTrigger.Action.allCases, id: \.self) { Text(T($0.title)).tag($0) }
                }
            }
            if let error { Text(T(error)).foregroundStyle(.red).font(.callout) }
            HStack {
                Button(T("Cancel")) { editing = false; error = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(T("Save")) { perform { try store.save(draft); editing = false } }.keyboardShortcut(.defaultAction)
                    .disabled(draft.pattern.isEmpty)
            }
        }
        .padding(20).frame(width: 440)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
}
