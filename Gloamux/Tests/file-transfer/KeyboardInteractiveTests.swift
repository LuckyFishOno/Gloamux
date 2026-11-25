import XCTest
import Foundation
import Citadel
@preconcurrency import NIOSSH
import NIOCore
@testable import Ssh
@testable import App

// Keyboard-interactive sign-in (RFC 4256) against an in-process server on 127.0.0.1: a server that asks only
// questions, a key followed by a verification code, refused and cancelled answers, and the timeout while the user types.

/// Asks `rounds` in order, then accepts when every answer matched. `publicKey` accepts any key as a partial success,
/// so the questions are the second step.
private final class QuestionsAuth: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    struct Round { var prompts: [(String, Bool)]; var expected: [String] }
    let rounds: [Round]
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods
    private let lock = NSLock()
    private var step = 0
    private var allRight = true

    /// Password and key sign-ins the server saw.
    var refused: Int { lock.withLock { refusals } }
    private var refusals = 0
    private let keyIsStep: Bool

    init(rounds: [Round], afterKey: Bool = false, also: NIOSSHAvailableUserAuthenticationMethods = []) {
        self.rounds = rounds
        keyIsStep = afterKey
        supportedAuthenticationMethods = afterKey ? [.publicKey, .keyboardInteractive] : also.union(.keyboardInteractive)
    }

    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .publicKey = request.request, keyIsStep {
            responsePromise.succeed(.partialSuccess(remainingMethods: .keyboardInteractive))
        } else {
            lock.withLock { refusals += 1 }
            responsePromise.succeed(.failure)
        }
    }

    func keyboardInteractive(username: String, responses: [String]?, stepPromise: EventLoopPromise<NIOSSHKeyboardInteractiveStep>) {
        lock.lock(); defer { lock.unlock() }
        if responses == nil { step = 0; allRight = true }
        if let responses {
            if responses != rounds[step - 1].expected { allRight = false }
        }
        guard username == "tester", step < rounds.count else {
            stepPromise.succeed(.outcome(allRight && username == "tester" ? .success : .failure))
            return
        }
        let round = rounds[step]
        step += 1
        stepPromise.succeed(.challenge(.init(name: "Example sign-in", instruction: "Answer to continue.",
                                             prompts: round.prompts.map { .init(text: $0.0, echo: $0.1) })))
    }
}

/// The questions the client was asked, and the answers it gives.
private final class Answerer: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [SSHLoginChallenge] = []
    var questions: [SSHLoginChallenge] { lock.withLock { asked } }
    let answers: [String]
    let delay: Duration
    let cancels: Bool
    init(_ answers: [String], delay: Duration = .zero, cancels: Bool = false) { self.answers = answers; self.delay = delay; self.cancels = cancels }

    var handler: SSHLoginAnswerer {
        { [self] challenge in
            lock.withLock { asked.append(challenge) }
            if delay > .zero { try await Task.sleep(for: delay) }
            if cancels { throw CancellationError() }
            return answers
        }
    }
}

final class KeyboardInteractiveTests: XCTestCase {
    private func withServer(_ auth: QuestionsAuth, _ body: (Int) async throws -> Void) async throws {
        var server: SSHServer?
        var port = 0
        for _ in 0..<12 {
            let candidate = Int.random(in: 49152...65500)
            do {
                server = try await SSHServer.host(host: "127.0.0.1", port: candidate, hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())],
                                                  authenticationDelegate: auth)
                port = candidate
                break
            } catch { continue }
        }
        guard let server else { XCTFail("could not bind a loopback port"); return }
        do { try await body(port) } catch { try? await server.close(); throw error }
        try? await server.close()
    }

    private func settings(_ port: Int) -> SSHConnectionSettings { SSHConnectionSettings(host: "127.0.0.1", port: port, username: "tester") }

    func testPasswordAnswersTheFirstQuestionAndTheUserTheCode() async throws {
        let auth = QuestionsAuth(rounds: [.init(prompts: [("Password: ", false)], expected: ["secret"]),
                                          .init(prompts: [("Verification code: ", true)], expected: ["123456"])])
        let answerer = Answerer(["123456"])
        try await withServer(auth) { port in
            let session = try await SSHSession.connect(settings: settings(port), credential: .password("secret"),
                                                       answer: answerer.handler, connectTimeoutSeconds: 5)
            try await session.close()
        }
        // The saved password answered the server's password question; only the code went to the user.
        XCTAssertEqual(answerer.questions, [SSHLoginChallenge(name: "Example sign-in", instruction: "Answer to continue.",
                                                              prompts: [.init(text: "Verification code: ", hidden: false)])])
    }

    func testKeyThenVerificationCode() async throws {
        let auth = QuestionsAuth(rounds: [.init(prompts: [("Code", false), ("PIN", false)], expected: ["42", "0000"])], afterKey: true)
        let answerer = Answerer(["42", "0000"])
        try await withServer(auth) { port in
            let session = try await SSHSession.connect(settings: settings(port), credential: .privateKey(NIOSSHPrivateKey(ed25519Key: .init())),
                                                       answer: answerer.handler, connectTimeoutSeconds: 5)
            try await session.close()
        }
        XCTAssertEqual(answerer.questions.map(\.prompts), [[.init(text: "Code", hidden: true), .init(text: "PIN", hidden: true)]])
    }

    func testWrongAnswersAreRefusedAndCancellingStops() async throws {
        let auth = QuestionsAuth(rounds: [.init(prompts: [("Verification code: ", true)], expected: ["123456"])])
        try await withServer(auth) { port in
            do {
                _ = try await SSHSession.connect(settings: settings(port), credential: .password("secret"),
                                                 answer: Answerer(["999999"]).handler, connectTimeoutSeconds: 5)
                XCTFail("a wrong code signed in")
            } catch SSHError.authenticationFailed {}
            do {
                _ = try await SSHSession.connect(settings: settings(port), credential: .password("secret"),
                                                 answer: Answerer([], cancels: true).handler, connectTimeoutSeconds: 5)
                XCTFail("a cancelled sign-in connected")
            } catch SSHError.signInCancelled {}
            // Without anyone to ask, questions other than the password end the sign-in.
            do {
                _ = try await SSHSession.connect(settings: settings(port), credential: .password("secret"), connectTimeoutSeconds: 5)
                XCTFail("unanswered questions signed in")
            } catch SSHError.authenticationFailed {}
        }
    }

    func testTimeoutWaitsForTheUser() async throws {
        let auth = QuestionsAuth(rounds: [.init(prompts: [("Verification code: ", true)], expected: ["7"])])
        let answerer = Answerer(["7"], delay: .milliseconds(2500))
        try await withServer(auth) { port in
            let session = try await SSHSession.connect(settings: settings(port), credential: .password("secret"),
                                                       answer: answerer.handler, connectTimeoutSeconds: 2)
            try await session.close()
        }
        XCTAssertEqual(answerer.questions.count, 1)
    }

    private static let passwordThenCode: [QuestionsAuth.Round] = [
        .init(prompts: [("Password: ", false)], expected: ["secret"]), .init(prompts: [("Verification code: ", true)], expected: ["123456"])]

    /// A PAM server with a verification code often lists password sign-in too, and refuses it.
    func testQuestionsComeBeforeAPasswordTheServerWouldRefuse() async throws {
        let auth = QuestionsAuth(rounds: Self.passwordThenCode, also: .password)
        let answerer = Answerer(["123456"])
        try await withServer(auth) { port in
            let session = try await SSHSession.connect(settings: settings(port), credential: .password("secret"),
                                                       answer: answerer.handler, connectTimeoutSeconds: 5)
            try await session.close()
        }
        XCTAssertEqual(answerer.questions.count, 1)
        XCTAssertEqual(auth.refused, 0)
    }

    func testQuestionsFollowAKeyTheServerRefuses() async throws {
        let auth = QuestionsAuth(rounds: [.init(prompts: [("Verification code: ", true)], expected: ["123456"])], also: .publicKey)
        let answerer = Answerer(["123456"])
        try await withServer(auth) { port in
            let session = try await SSHSession.connect(settings: settings(port), credential: .privateKey(NIOSSHPrivateKey(ed25519Key: .init())),
                                                       answer: answerer.handler, connectTimeoutSeconds: 5)
            try await session.close()
        }
        XCTAssertEqual(answerer.questions.count, 1)
    }

    /// A wrong password answered to the server's question is not sent again as a password sign-in.
    func testAWrongPasswordIsSentOnce() async throws {
        let auth = QuestionsAuth(rounds: [.init(prompts: [("Password: ", false)], expected: ["other"])], also: .password)
        let answerer = Answerer([])
        try await withServer(auth) { port in
            do {
                _ = try await SSHSession.connect(settings: settings(port), credential: .password("secret"), answer: answerer.handler, connectTimeoutSeconds: 5)
                XCTFail("a wrong password signed in")
            } catch { XCTAssertEqual(error as? SSHError, .authenticationFailed) }
        }
        XCTAssertEqual(auth.refused, 0)
        XCTAssertEqual(answerer.questions, [])
    }

    func testNothingSavedOnlyAnswersQuestions() async throws {
        let auth = QuestionsAuth(rounds: [.init(prompts: [("Code", false)], expected: ["42"])], also: [.password, .publicKey])
        let answerer = Answerer(["42"])
        try await withServer(auth) { port in
            let session = try await SSHSession.connect(settings: settings(port), credential: .interactive, answer: answerer.handler, connectTimeoutSeconds: 5)
            try await session.close()
        }
        XCTAssertEqual(answerer.questions.map(\.prompts), [[.init(text: "Code", hidden: true)]])
        XCTAssertEqual(auth.refused, 0)
    }

    func testPasswordQuestionsAndLabels() {
        XCTAssertFalse(PasswordAuthDelegate.asksForPassword("One-time password: "))
        XCTAssertFalse(PasswordAuthDelegate.asksForPassword("Password + OTP: "))
        XCTAssertTrue(PasswordAuthDelegate.asksForPassword("Password for root@robotpc: "))
        XCTAssertTrue(PasswordAuthDelegate.asksForPassword("Password for tester@host: "))
        XCTAssertTrue(PasswordAuthDelegate.asksForPassword("密碼："))
        XCTAssertFalse(PasswordAuthDelegate.asksForPassword("Verification code: "))
        XCTAssertEqual(LoginChallengeSheet.label("Verification code: "), "Verification code")
        XCTAssertEqual(LoginChallengeSheet.label("驗證碼：\u{7}"), "驗證碼")
        XCTAssertEqual(LoginChallengeSheet.shown("a\u{1b}[31mb\nc", limit: 100), "a[31mb\nc")
    }
}
