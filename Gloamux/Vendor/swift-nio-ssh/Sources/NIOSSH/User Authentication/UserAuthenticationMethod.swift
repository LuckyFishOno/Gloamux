//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore

/// The user authentication modes available at this point in time.
///
/// Note: SSH certificate authentication is supported through the publicKey method,
/// not as a separate authentication method. When using certificates, the publicKey
/// method is used with a certified key.
public struct NIOSSHAvailableUserAuthenticationMethods: OptionSet {
    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let publicKey: NIOSSHAvailableUserAuthenticationMethods = .init(rawValue: 1 << 0)
    public static let password: NIOSSHAvailableUserAuthenticationMethods = .init(rawValue: 1 << 1)
    public static let hostBased: NIOSSHAvailableUserAuthenticationMethods = .init(rawValue: 1 << 2)
    /// RFC 4256 keyboard-interactive sign-in: questions chosen by the server, such as a password and a one-time code.
    public static let keyboardInteractive: NIOSSHAvailableUserAuthenticationMethods = .init(rawValue: 1 << 3)

    public static let all: NIOSSHAvailableUserAuthenticationMethods = [.publicKey, .password, .hostBased, .keyboardInteractive]
}

extension NIOSSHAvailableUserAuthenticationMethods {
    internal init(_ message: SSHMessage.UserAuthFailureMessage) {
        self = .init()

        for message in message.authentications {
            switch message {
            case "publickey":
                self.insert(.publicKey)
            case "password":
                self.insert(.password)
            case "hostbased":
                self.insert(.hostBased)
            case "keyboard-interactive":
                self.insert(.keyboardInteractive)
            default:
                // This is an unknown method, which we ignore.
                break
            }
        }
    }

    internal var strings: [Substring] {
        guard self != .init() else {
            return []
        }

        // We need an array.
        var methods = [Substring]()
        methods.reserveCapacity(4)

        if self.contains(.password) {
            methods.append("password")
        }
        if self.contains(.publicKey) {
            methods.append("publickey")
        }
        if self.contains(.hostBased) {
            methods.append("hostbased")
        }
        if self.contains(.keyboardInteractive) {
            methods.append("keyboard-interactive")
        }

        return methods
    }
}

extension NIOSSHAvailableUserAuthenticationMethods: Hashable {}

/// A specific request for user authentication. This type is the one observed from the server side. The
/// associated client side type is `NIOSSHUserAuthenticationOffer`.
public struct NIOSSHUserAuthenticationRequest {
    public var username: String

    public var request: Request

    public init(username: String, serviceName: String, request: Request) {
        self.username = username
        self.request = request
    }
}

public extension NIOSSHUserAuthenticationRequest {
    enum Request {
        case publicKey(PublicKey)
        case password(Password)
        case hostBased(HostBased)
        case none
    }
}

public extension NIOSSHUserAuthenticationRequest.Request {
    struct PublicKey {
        public var publicKey: NIOSSHPublicKey
        
        /// If the public key is a certificate, this contains the parsed certificate information.
        /// This includes critical options, extensions, and other certificate metadata.
        /// Certificate authentication in SSH uses the publicKey authentication method with
        /// a certified key, not a separate authentication method.
        public var certifiedKey: NIOSSHCertifiedPublicKey?

        public init(publicKey: NIOSSHPublicKey) {
            self.publicKey = publicKey
            self.certifiedKey = NIOSSHCertifiedPublicKey(publicKey)
        }
        
        public init(publicKey: NIOSSHPublicKey, certifiedKey: NIOSSHCertifiedPublicKey?) {
            self.publicKey = publicKey
            self.certifiedKey = certifiedKey
        }
    }

    struct Password {
        public var password: String

        public init(password: String) {
            self.password = password
        }
    }

    struct HostBased {
        init() {
            fatalError("HostBased authentication is currently unimplemented")
        }
    }
}

extension NIOSSHUserAuthenticationRequest: Hashable {}

extension NIOSSHUserAuthenticationRequest.Request: Hashable {}

extension NIOSSHUserAuthenticationRequest.Request.PublicKey: Hashable {}

extension NIOSSHUserAuthenticationRequest.Request.Password: Hashable {}

extension NIOSSHUserAuthenticationRequest.Request.HostBased: Hashable {}

/// A specific offer of user authentication. This type is the one used on the client side. The
/// associated server side type is `NIOSSHUserAuthenticationRequest`.
public struct NIOSSHUserAuthenticationOffer {
    public var username: String

    public var offer: Offer

    /// True for an RFC 4256 keyboard-interactive offer, whose questions go to the delegate's
    /// `respondToKeyboardInteractive(_:responsePromise:)`. `offer` is then `.none` and ignored. This is a flag rather than
    /// an `Offer` case so code that switches over every case, such as Citadel, still compiles.
    public var isKeyboardInteractive: Bool = false

    public init(username: String, serviceName: String, offer: Offer) {
        self.username = username
        self.offer = offer
    }

    /// Offers keyboard-interactive sign-in.
    public static func keyboardInteractive(username: String) -> NIOSSHUserAuthenticationOffer {
        var offer = NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .none)
        offer.isKeyboardInteractive = true
        return offer
    }
}

/// Questions a server asks during keyboard-interactive sign-in (RFC 4256).
public struct NIOSSHKeyboardInteractiveChallenge: Hashable, Sendable {
    public struct Prompt: Hashable, Sendable {
        public var text: String
        /// False for secrets such as passwords and codes, which should not be shown as they are typed.
        public var echo: Bool

        public init(text: String, echo: Bool) {
            self.text = text
            self.echo = echo
        }
    }

    public var name: String
    public var instruction: String
    /// May be empty: the server then only wants the client to show `name` and `instruction` and answer.
    public var prompts: [Prompt]

    public init(name: String, instruction: String, prompts: [Prompt]) {
        self.name = name
        self.instruction = instruction
        self.prompts = prompts
    }
}

extension NIOSSHKeyboardInteractiveChallenge {
    init(_ message: SSHMessage.UserAuthInfoRequestMessage) {
        self.init(name: message.name, instruction: message.instruction,
                  prompts: message.prompts.map { Prompt(text: $0.text, echo: $0.echo) })
    }
}

extension SSHMessage.UserAuthInfoRequestMessage {
    init(_ challenge: NIOSSHKeyboardInteractiveChallenge) {
        self.init(name: challenge.name, instruction: challenge.instruction, languageTag: "",
                  prompts: challenge.prompts.map { Prompt(text: $0.text, echo: $0.echo) })
    }
}

/// A server's next keyboard-interactive step: more questions, or the result.
public enum NIOSSHKeyboardInteractiveStep {
    case challenge(NIOSSHKeyboardInteractiveChallenge)
    case outcome(NIOSSHUserAuthenticationOutcome)
}

public extension NIOSSHUserAuthenticationOffer {
    enum Offer {
        case privateKey(PrivateKey)
        case password(Password)
        case hostBased(HostBased)
        case none
    }
}

public extension NIOSSHUserAuthenticationOffer.Offer {
    struct PrivateKey {
        public var privateKey: NIOSSHPrivateKey
        public var publicKey: NIOSSHPublicKey

        public init(privateKey: NIOSSHPrivateKey) {
            self.privateKey = privateKey
            self.publicKey = privateKey.publicKey
        }

        /// Creates a private key offer with a certified public key.
        /// Certificate authentication uses the publicKey authentication method.
        public init(privateKey: NIOSSHPrivateKey, certifiedKey: NIOSSHCertifiedPublicKey) {
            self.privateKey = privateKey
            self.publicKey = NIOSSHPublicKey(certifiedKey)
        }
    }

    struct Password {
        public var password: String

        public init(password: String) {
            self.password = password
        }
    }

    struct HostBased {
        init() {
            fatalError("HostBased authentication is currently unimplemented")
        }
    }
}

extension SSHMessage.UserAuthRequestMessage {
    init(request: NIOSSHUserAuthenticationOffer, sessionID: ByteBuffer) throws {
        // We only ever ask for the ssh-connection service.
        self.username = request.username
        self.service = "ssh-connection"

        if request.isKeyboardInteractive {
            self.method = .keyboardInteractive(submethods: "")
            return
        }

        switch request.offer {
        case .privateKey(let privateKeyRequest):
            let dataToSign = UserAuthSignablePayload(
                sessionIdentifier: sessionID,
                userName: self.username,
                serviceName: self.service,
                publicKey: privateKeyRequest.publicKey
            )
            let signature = try privateKeyRequest.privateKey.sign(dataToSign)
            self.method = .publicKey(.known(key: privateKeyRequest.publicKey, signature: signature))
        case .password(let passwordRequest):
            self.method = .password(passwordRequest.password)
        case .hostBased:
            fatalError("Unsupported")
        case .none:
            self.method = .none
        }
    }
}

/// The outcome of a user authentication attempt.
public enum NIOSSHUserAuthenticationOutcome {
    case success
    case partialSuccess(remainingMethods: NIOSSHAvailableUserAuthenticationMethods)
    case failure
}

enum NIOSSHUserAuthenticationResponseMessage {
    case success
    case failure(SSHMessage.UserAuthFailureMessage)
    case publicKeyOK(SSHMessage.UserAuthPKOKMessage)
    case infoRequest(SSHMessage.UserAuthInfoRequestMessage)
}

extension NIOSSHUserAuthenticationResponseMessage {
    init(_ outcome: NIOSSHUserAuthenticationOutcome, supportedMethods: NIOSSHAvailableUserAuthenticationMethods) {
        switch outcome {
        case .success:
            self = .success
        case .partialSuccess(remainingMethods: let remaining):
            let message = SSHMessage.UserAuthFailureMessage(authentications: remaining.strings, partialSuccess: true)
            self = .failure(message)
        case .failure:
            let message = SSHMessage.UserAuthFailureMessage(authentications: supportedMethods.strings, partialSuccess: false)
            self = .failure(message)
        }
    }
}
