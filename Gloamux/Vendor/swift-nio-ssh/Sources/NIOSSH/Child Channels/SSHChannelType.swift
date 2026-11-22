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

/// `SSHChannelType` represents the type of a single SSH channel.
///
/// SSH Channels are always one of a number of types. The most common type is "session", which
/// encompasses remote execution of a program, whether that be a single binary, a shell, a subsystem,
/// or something else.
///
/// Other major types include X11 channels (not supported by swift-nio-ssh), direct TCP/IP (for
/// forwarding a connection from the SSH client to the SSH server) and forwarded TCP/IP (for forwarding
/// a connection from a socket the server was listening on on behalf the client).
///
/// Some channel types have associated metadata. That metadata can be retrieved from SSH channels using
/// channel options.
public enum SSHChannelType: Equatable, NIOSSHSendable {
    /// A "session" is remote execution of a program.
    case session

    /// "Direct TCP/IP" is a request from the client to the server to open an outbound connection.
    case directTCPIP(DirectTCPIP)

    /// "Forwarded TCP/IP" is a connection that was accepted from a listening socket and is being forwarded to the client.
    case forwardedTCPIP(ForwardedTCPIP)
}

extension SSHChannelType {
    /// A connection to the client's SSH agent, opened by a server the client asked to forward its agent to
    /// (`auth-agent@openssh.com`). Added by Gloamux. It is carried as `forwardedTCPIP` with this listening host, so
    /// code that switches over every channel type keeps compiling.
    public static let agentForwardingHost = "auth-agent@openssh.com"

    public static var agentForwarding: SSHChannelType {
        .forwardedTCPIP(.init(listeningHost: agentForwardingHost, listeningPort: 0,
                              originatorAddress: try! SocketAddress(ipAddress: "127.0.0.1", port: 0)))
    }

    public var isAgentForwarding: Bool {
        if case .forwardedTCPIP(let info) = self { return info.listeningHost == Self.agentForwardingHost && info.listeningPort == 0 }
        return false
    }

    /// An X11 connection the server forwards to the client (`x11`). Added by Gloamux, carried as `forwardedTCPIP` with
    /// this listening host; the originator is the X client's address on the server.
    public static let x11Host = "x11"

    public static func x11(originatorAddress: SocketAddress) -> SSHChannelType {
        .forwardedTCPIP(.init(listeningHost: x11Host, listeningPort: 0, originatorAddress: originatorAddress))
    }

    public var isX11: Bool {
        if case .forwardedTCPIP(let info) = self { return info.listeningHost == Self.x11Host && info.listeningPort == 0 }
        return false
    }
}

public extension SSHChannelType {
    struct DirectTCPIP: Equatable, NIOSSHSendable {
        /// The target host for the forwarded TCP connection.
        public var targetHost: String

        /// The target port for the forwarded TCP connection.
        public var targetPort: Int {
            get {
                Int(self._targetPort)
            }
            set {
                self._targetPort = UInt16(newValue)
            }
        }

        /// The address of the initiating peer.
        public var originatorAddress: SocketAddress

        fileprivate private(set) var _targetPort: UInt16

        public init(targetHost: String, targetPort: Int, originatorAddress: SocketAddress) {
            self.targetHost = targetHost
            self._targetPort = UInt16(targetPort)
            self.originatorAddress = originatorAddress
        }

        internal init(targetHost: String, targetPort: UInt16, originatorAddress: SocketAddress) {
            self.targetHost = targetHost
            self._targetPort = targetPort
            self.originatorAddress = originatorAddress
        }
    }
}

public extension SSHChannelType {
    struct ForwardedTCPIP: Equatable, NIOSSHSendable {
        /// The host the remote peer connected to. This should be identical to the one that was requested.
        public var listeningHost: String

        /// The port on which the proxy is listening, and to which the remote peer connected.
        public var listeningPort: Int {
            get {
                Int(self._listeningPort)
            }
            set {
                self._listeningPort = UInt16(newValue)
            }
        }

        /// The address of the remote peer.
        public var originatorAddress: SocketAddress

        fileprivate private(set) var _listeningPort: UInt16

        public init(listeningHost: String, listeningPort: Int, originatorAddress: SocketAddress) {
            self.originatorAddress = originatorAddress
            self.listeningHost = listeningHost
            self._listeningPort = UInt16(listeningPort)
        }

        internal init(listeningHost: String, listeningPort: UInt16, originatorAddress: SocketAddress) {
            self.originatorAddress = originatorAddress
            self.listeningHost = listeningHost
            self._listeningPort = listeningPort
        }
    }
}

extension SSHChannelType {
    internal init(_ message: SSHMessage.ChannelOpenMessage) {
        switch message.type {
        case .session:
            self = .session
        case .directTCPIP(let message):
            self = .directTCPIP(.init(targetHost: message.hostToConnectTo, targetPort: message.portToConnectTo, originatorAddress: message.originatorAddress))
        case .forwardedTCPIP(let message):
            self = .forwardedTCPIP(.init(listeningHost: message.hostListening, listeningPort: message.portListening, originatorAddress: message.originatorAddress))
        case .agentForwarding:
            self = .agentForwarding
        case .x11(let address, let port):
            let originator = (try? SocketAddress(ipAddress: address, port: Int(min(port, 65535))))
                ?? (try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
            self = .x11(originatorAddress: originator)
        }
    }
}

extension SSHMessage.ChannelOpenMessage.ChannelType {
    internal init(_ type: SSHChannelType) {
        switch type {
        case .session:
            self = .session
        case .directTCPIP(let data):
            self = .directTCPIP(.init(hostToConnectTo: data.targetHost, portToConnectTo: data._targetPort, originatorAddress: data.originatorAddress))
        case .forwardedTCPIP(let data) where type.isAgentForwarding:
            _ = data
            self = .agentForwarding
        case .forwardedTCPIP(let data) where type.isX11:
            self = .x11(originatorAddress: data.originatorAddress.ipAddress ?? "127.0.0.1", originatorPort: UInt32(data.originatorAddress.port ?? 0))
        case .forwardedTCPIP(let data):
            self = .forwardedTCPIP(.init(hostListening: data.listeningHost, portListening: data._listeningPort, originatorAddress: data.originatorAddress))
        }
    }
}
