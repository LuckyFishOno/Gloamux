import SwiftUI
import AppKit

/// Text copied from or pasted into terminals, newest first, for Terminal › Paste from history (⇧⌘H), as in iTerm2.
/// It stays in memory and ends when Gloamux quits. Text with a recognized secret, such as a token or a password
/// argument, is never kept.
@MainActor final class PasteHistory: ObservableObject {
    static let shared = PasteHistory()
    static let limit = 20
    @Published private(set) var entries: [String] = []

    func add(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 65_536,
              SecretRedaction.redact(text) == text else { return }
        entries.removeAll { $0 == text }
        entries.insert(text, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    func clear() { entries = [] }
}

/// The list Paste from history shows: click an entry to paste it into the selected terminal.
struct PasteHistoryView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var history = PasteHistory.shared
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    private var shown: [(Int, String)] {
        history.entries.enumerated().filter { filter.isEmpty || $0.element.localizedCaseInsensitiveContains(filter) }.map { ($0.offset, $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(T("Paste history")).appFont(.headline)
                InfoButton(T("Text you copied from or pasted into a terminal since Gloamux opened, newest first. Text with a recognized secret is never kept, and nothing is saved to disk."))
                Spacer()
                TextField(T("Filter"), text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            if shown.isEmpty {
                Text(T(history.entries.isEmpty ? "Nothing copied or pasted yet" : "No matches"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List(shown, id: \.0) { index, text in
                    Button { paste(text) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.body.monospaced()).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(format: T("Paste entry %d"), index + 1))
                }
                .frame(minHeight: 220)
            }
            HStack {
                Button(T("Clear")) { history.clear() }.disabled(history.entries.isEmpty)
                Spacer()
                Button(T("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private func paste(_ text: String) {
        dismiss()
        guard let tab = model.selected else { return }
        do { _ = try WorkspaceCommand.type(text, into: tab, of: model, pressReturn: false) }
        catch { model.error = error.localizedDescription }
    }
}
