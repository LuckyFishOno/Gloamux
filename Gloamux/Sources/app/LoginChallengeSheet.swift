import AppKit
import SwiftUI
import Ssh

/// The server's sign-in questions, such as a password and a verification code (keyboard-interactive sign-in).
/// The server writes the questions, so they are shown as they are, never looked up as interface text.
struct LoginChallengeSheet: View {
    let prompt: LoginChallengePrompt
    let answer: ([String]?) -> Void
    @State private var answers: [String]
    @FocusState private var focused: Int?

    init(prompt: LoginChallengePrompt, answer: @escaping ([String]?) -> Void) {
        self.prompt = prompt
        self.answer = answer
        _answers = State(initialValue: Array(repeating: "", count: prompt.challenge.prompts.count))
    }

    var body: some View {
        let challenge = prompt.challenge
        VStack(alignment: .leading, spacing: 16) {
            if prompt.asksSessionKey { HStack(spacing: 6) {
                Label(T("Session key"), systemImage: "key.horizontal").appFont(.title2.bold())
                InfoButton(T("Paste the key, or the whole sftp command it came in. Gloamux keeps it until you quit and never saves it."))
            } } else { HStack(spacing: 6) {
                Label(T("Sign-in questions"), systemImage: "person.badge.key").appFont(.title2.bold())
                InfoButton(T("The server asks these questions, for example for a password or a verification code. Gloamux sends the answers only to this server and does not save them."))
            }
            }
            Text(prompt.endpoint).appFont(.headline)
            if !challenge.name.isEmpty {
                Text(verbatim: Self.shown(challenge.name, limit: 200)).appFont(.subheadline.bold())
            }
            if !challenge.instruction.isEmpty {
                ScrollView {
                    Text(verbatim: Self.shown(challenge.instruction, limit: 4000))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(challenge.prompts.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 5) {
                    if !prompt.asksSessionKey {
                        Text(verbatim: Self.label(question.text)).appFont(.caption).foregroundStyle(.secondary)
                    }
                    Group {
                        if question.hidden { SecureField("", text: $answers[index]) }
                        else { TextField("", text: $answers[index]) }
                    }
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: index)
                    .accessibilityLabel(Text(verbatim: prompt.asksSessionKey ? T("Session key") : Self.label(question.text)))
                    .accessibilityIdentifier("loginAnswer\(index)")
                    .onSubmit { advance(from: index) }
                }
            }
            DialogActions(cancel: { answer(nil) }, title: T("Connect"), identifier: "answerLoginButton", confirm: { answer(answers) }) {
                if prompt.asksSessionKey {
                    Button(T("Paste"), systemImage: "doc.on.clipboard") {
                        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty { answers = [text] }
                    }
                    .help(T("Paste from the clipboard"))
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { focused = answers.isEmpty ? nil : 0 }
    }

    /// Return moves to the next question, and sends the answers after the last one.
    private func advance(from index: Int) {
        if index + 1 < answers.count { focused = index + 1 } else { answer(answers) }
    }

    /// The server's question without the colon and spaces it usually ends with.
    static func label(_ text: String) -> String {
        var label = shown(text, limit: 200).trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = label.last, last == ":" || last == "：" { label.removeLast() }
        label = label.trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? T("Answer") : label
    }

    /// Server text without control characters other than line breaks and tabs, cut at `limit` characters.
    static func shown(_ text: String, limit: Int) -> String {
        let kept = text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(kept).prefix(limit))
    }
}

extension View {
    /// Shows the server's sign-in questions for `tab` while they wait for an answer. `visible` hides them in a split pane
    /// that is not selected, as the host key check does.
    func loginChallengeSheet(model: WorkspaceModel, tab: SessionTab, visible: Bool = true) -> some View {
        sheet(item: Binding(get: { visible ? tab.loginChallenge : nil }, set: { _ in })) { prompt in
            LoginChallengeSheet(prompt: prompt) { model.answerLogin(tab, answers: $0) }
                // Closed some other way: cancel these questions, but not newer ones the server asked meanwhile.
                .onDisappear { if tab.loginChallenge?.id == prompt.id { model.answerLogin(tab, answers: nil) } }
        }
    }
}
