# Vendored swift-nio-ssl

Copied from https://github.com/apple/swift-nio-ssl at 2.37.5 (revision 322f3c2a4a21df31c84ca416bf65ee5e9059e440).
Apache License 2.0, see LICENSE.txt and NOTICE.txt.

Gloamux's change adds TLS session resumption for clients, so FTPS data connections can resume the control connection's
session. Servers such as vsftpd with `require_ssl_reuse` refuse data connections that do not.

- `NIOSSLSession.swift` (new): `NIOSSLSession`, which holds an `SSL_SESSION`, and on `NIOSSLHandler`:
  `resumableSession`, `offerSession(_:)`, and `sessionWasReused`.
- `SSLContext.swift`: every context adds `SSL_SESS_CACHE_CLIENT` to its cache mode and a `new_session_cb` that hands each
  resumable client session (the end of a TLS 1.2 handshake, or a TLS 1.3 ticket) to its connection. Clients never use
  BoringSSL's internal cache, and the server cache is unchanged.
- `SSLConnection.swift`: `resumableSession`, `offer(_:)`, and `sessionReused`.
- `NIOSSLHandler.swift`: `connection` is internal instead of private.

Only the `NIOSSL` library and its BoringSSL targets are copied. The example executables, tests, benchmarks, and the
`swift-certificates` test dependency are left out.
