//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// Gloamux addition: TLS session resumption for clients. See VENDORED.md.

@_implementationOnly import CNIOBoringSSL

/// A TLS session that a client can offer on a later connection, so the server resumes it instead of running a full
/// handshake. FTPS servers can require this for data connections, to tie them to the signed-in control connection.
public final class NIOSSLSession: @unchecked Sendable {
    /// An `SSL_SESSION *` this object holds one reference to. Sessions are immutable once established.
    let pointer: OpaquePointer

    init(taking pointer: OpaquePointer) { self.pointer = pointer }

    deinit { CNIOBoringSSL_SSL_SESSION_free(self.pointer) }
}

/// Receives each new session of a client connection: at the end of a TLS 1.2 handshake, or with each TLS 1.3 session
/// ticket. Returns 1 when it keeps the reference it is given.
internal func newSessionCallback(_ ssl: OpaquePointer?, _ session: OpaquePointer?) -> CInt {
    guard let ssl, let session, CNIOBoringSSL_SSL_is_server(ssl) == 0,
        CNIOBoringSSL_SSL_SESSION_is_resumable(session) == 1
    else { return 0 }
    SSLConnection.loadConnectionFromSSL(ssl).resumableSession = NIOSSLSession(taking: session)
    return 1
}

extension NIOSSLHandler {
    /// The newest session this client connection can offer on a later connection, or nil before the server sent one.
    /// Read it on the channel's event loop.
    public var resumableSession: NIOSSLSession? { self.connection.resumableSession }

    /// Offers a session from an earlier connection to the same server, to resume it. Call before the handler is added
    /// to the pipeline. A server that does not know the session runs a full handshake instead.
    public func offerSession(_ session: NIOSSLSession) { self.connection.offer(session) }

    /// Whether the handshake resumed an earlier session. Read it on the channel's event loop once the handshake is done.
    public var sessionWasReused: Bool { self.connection.sessionReused }
}
