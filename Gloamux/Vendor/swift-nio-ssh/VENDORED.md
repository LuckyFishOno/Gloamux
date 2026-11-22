# Vendored swift-nio-ssh

Copied from https://github.com/Wellz26/swift-nio-ssh at 0.3.7 (revision d88989f3d3bb1dfb2a38ce4af598afbf7fc3095c), the
fork Citadel uses. Apache License 2.0, see LICENSE.txt.

Gloamux's changes, so it can forward the SSH agent (OpenSSH `PROTOCOL.agent`) and X11 (RFC 4254 6.3):

- `auth-agent-req@openssh.com` channel request: `SSHChannelRequestEvent.AgentForwardingRequest`.
- `auth-agent@openssh.com` channel open: `SSHChannelType.agentForwarding`.
- `x11-req` channel request: `SSHChannelRequestEvent.X11ForwardingRequest`.
- `x11` channel open: `SSHChannelType.x11(originatorAddress:)`.

Both channel types are carried as `forwardedTCPIP` with a marker listening host and port 0, so packages that switch over
every `SSHChannelType` case, such as Citadel, still compile.

Keyboard-interactive sign-in (RFC 4256), for servers that ask for a password and a verification code:

- `SSH_MSG_USERAUTH_INFO_REQUEST` (60) and `SSH_MSG_USERAUTH_INFO_RESPONSE` (61). Number 60 is read as `PK_OK` when it
  holds a known key type, and as `INFO_REQUEST` otherwise.
- `NIOSSHAvailableUserAuthenticationMethods.keyboardInteractive`, now part of `.all`.
- Client: `NIOSSHUserAuthenticationOffer.keyboardInteractive(username:)` and
  `NIOSSHClientUserAuthenticationDelegate.respondToKeyboardInteractive(_:responsePromise:)`, whose default refuses.
  The offer is a flag on the offer rather than an `Offer` case, so Citadel still compiles.
- Server: `NIOSSHServerUserAuthenticationDelegate.keyboardInteractive(username:responses:stepPromise:)`, whose default
  refuses, answered with `NIOSSHKeyboardInteractiveStep`. Gloamux uses it only in tests.

The example client and server, tests, and the DocC plugin are left out.
