# Gloamux data protection inventory

[English](DATA-PROTECTION.md) · [繁體中文](../zh-TW/DATA-PROTECTION.md) · [Back to README](../../README.md)

The [verification record](VERIFICATION.md) includes the November 25, 2026 local serial/terminal checks and the November 24 full application stress baseline.

Reviewed on November 21, 2026, against the 0.10.0 working tree, and rechecked against the 1.1 (build 2) source, including in-app updates, on November 23, 2026, and against the 1.2 (build 3) and 1.3 (build 6) changes on November 24, 2026. The 1.3 jump host list stores only session IDs in `sessions.json`; secrets typed for each jump host stay in memory and are cleared when the connection starts, and the route check reads `$SSH_CONNECTION` from each server only when asked. This inventory lists the data Gloamux stores or handles and its current protection. It also covers planned features from the [roadmap](ROADMAP.md) and [feature backlog](FEATURE-BACKLOG.md).

The 1.3.2 (build 8) serial-discovery change was checked against this inventory. Discovery reads local device paths and IOKit USB ancestry; it neither opens a serial port nor makes a network request. Device paths are held in memory and enter `sessions.json` only when a connection is saved, under the catalog's existing protection. A USB device path can contain the adapter's identifier.

The 1.4 (build 9) changes were checked against this inventory on November 25, 2026. They add `connection-history.jsonl` and session keys held in memory; both are listed below. 1.4.1 (build 10) adds no stored data. 1.4.2 (build 11) adds commands, routes, port forwarding, and file changes to `connection-history.jsonl`, and 1.4.3 (build 12) adds how each `ssh` run in a terminal went; they are listed below.

## Protection classes

These are protection targets. The current-storage table records what the implementation provides and the gaps still open in 1.4.3 (build 12).

| Class | Meaning | Required protection |
|---|---|---|
| **S1 · Secret** | Grants access to systems or other secrets. | Encrypted at rest with authenticated encryption and a key that never leaves Gloamux in plaintext. Never written to logs, recordings, macros, crash reports, exports, sync, the CLI, or MCP. Kept in memory only while needed and cleared on lock. |
| **S2 · Sensitive content** | Can reveal secrets or private infrastructure, but does not authenticate by itself. | Encrypted at rest by default or by a clear user setting. Secret redaction before it leaves the app. Explicit user action before it is shared. |
| **I · Integrity critical** | Tampering would weaken security, for example by redirecting a connection or approving a host. | Tamper detection with a key held by Gloamux. Refuse or flag modified data. |
| **L · Low** | Preferences with no security impact. | Private file permissions. |

## Current storage

Gloamux stores working files in `~/Library/Application Support/Gloamux`. The directory is `0700` and files are written with `writePrivate` as `0600`. The language preference is in `UserDefaults`.

| Data | Location | Class | Current protection | Gap |
|---|---|---|---|---|
| Saved sign-ins (passwords and key passphrases) | `saved-sign-ins.json` | S1 | Each entry is sealed with AES-GCM, with its ID bound as associated data, under a key derived (HKDF-SHA256) from a Secure Enclave P-256 key agreement. The file holds only the enclave's wrapped key handle, usable on this Mac only. No unlock is needed, so a session connects after a restart. A session can require Touch ID or the Mac password before each connection. The saved passwords list opens only after Touch ID or the Mac password, reveals a secret only on request, and clears a copied password from the clipboard after 60 seconds if nothing else was copied. | Any process running as the user can read the file and ask the Secure Enclave to rebuild the key, the same exposure as an unprotected Keychain item. No MAC over the entry list, so entries can be deleted or rolled back. Not cleared on lock. |
| Passwords added to the vault | `password-vault.json` | S1 | PBKDF2-HMAC-SHA256 (210,000 iterations) derives a key from the master password. Each entry is sealed with AES-GCM. | Entry IDs are not bound as associated data, so sealed entries can be swapped between IDs without detection. No automatic lock. PBKDF2 iteration count is below [OWASP's guidance](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html) of 600,000 for PBKDF2-HMAC-SHA256, and PBKDF2 is not memory-hard. |
| Master password and derived key | Memory only | S1 | Manual lock discards the unwrapped key. On a compatible Mac, Gloamux retains a copy sealed with a key derived through Secure Enclave key agreement, gated by the current Touch ID enrollment. The sealed copy lasts for the app process. | No lock after idle, sleep, screen lock, or app deactivation. The optional workspace idle lock (`workspace.lock-after-minutes`, off by default) only covers the terminals until Touch ID or the Mac password; it does not lock the vault or clear remembered passwords. Swift `String` and `SymmetricKey` copies cannot be reliably zeroed. |
| Passwords remembered for the session | `CredentialVault.sessionPasswords` in memory | S1 | A password or key passphrase that signs in is saved to `saved-sign-ins.json` at once, with or without a vault. On a Mac without a Secure Enclave it goes to the vault when it is unlocked, otherwise at the next unlock. Entries read from the locked vault with Touch ID for one connection are held here too. Cleared on vault lock. | Not cleared on idle or sleep. Kept after the tab closes until the vault is locked. |
| Password, key passphrase, and jump host secret fields | `SessionTab` published properties | S1 | Cleared after connect and on disconnect. | Values live in SwiftUI state while typed. Acceptable, but keep them out of view-state restoration and diagnostics. |
| Private key files | User path in `identityPath` | S1 | Gloamux stores only the path. The passphrase is used for a single load. | The decrypted key stays in memory for the session. The existing generator writes an Ed25519 key in `~/.ssh`, with an optional passphrase. A key generated without a passphrase is unencrypted on disk. |
| Secure Enclave SSH identity | `ssh-key-secure-enclave` in the app data folder | S1 | A P-256 signing key stays inside the Secure Enclave and cannot be exported. The file contains only the enclave-sealed representation, usable on this Mac only. Signing needs no Touch ID; keys from 0.10.0 builds still ask once per launch. | A replacement Mac needs a new key and server-side public key enrollment. |
| Session catalog and forwarding rules | `sessions.json` | S2 and I | Plaintext JSON, `0600`. No credentials. Forward listeners are limited to loopback by the app. | Hostnames, usernames, ports, proxies, jump hosts, and key paths form a map of the user's infrastructure. Plaintext is copied into Time Machine and other backups. A modified host, jump entry, or forwarding rule can redirect a connection. |
| Known hosts | `known-hosts.json` | I | Plaintext JSON, `0600`. A changed key blocks the connection. | No tamper detection. Malware running as the user can add a trusted key and enable a man-in-the-middle connection without a prompt. |
| X11 forwarding authorization | Memory for the SSH shell | S1 | Gloamux sends a random substitute cookie to the server and replaces it only after checking a channel's setup. The real cookie goes to the local X server. | A remote program on a trusted forwarding session can use the local X11 display until the shell closes. |
| RDP and VNC endpoints | Session catalog | S2 | The catalog records host, port, optional RDP username, and any approved RDP certificate fingerprint. | Catalog files have no independent tamper detection. |
| RDP and VNC passwords | Memory in Gloamux and its bundled helper, plus `saved-sign-ins.json` or the vault when remembered | S1 | Passed to the helper over a private pipe. RDP verifies the server's certificate before sign-in. With Remember password enabled, a successful password is saved through the same credential store used by SSH. The helper and app also hold connection credentials in memory for the connection and reconnection. | Classic VNC authentication and desktop traffic have no transport encryption. |
| Quick commands | `quick-commands.json` | S2 | Plaintext JSON, `0600`. | Users often paste tokens, passwords, or internal URLs into commands. |
| Terminal scrollback | Memory, 5,000 lines per terminal by default (1,000 to 50,000) | S2 | Not persisted unless a session log or recording is on. | Output can contain secrets. Find, the CLI's `tabs read`, session logs, recordings, and excerpts the user shares with agents read from it. |
| Session logs and recordings | Plaintext log and asciicast files, `0600`, in `0700` folders | S2 | Written only when the user turns logging or recording on. Likely secrets (private key blocks, access tokens, `password=` values) are masked before anything is written. A recording is masked and written in the background after it stops; one that cannot be written stays in memory until **Try again** saves it or the app quits, and quitting asks before dropping it. | Masking is pattern-based and misses secrets it does not recognize. The files are not encrypted and are copied into backups. |
| Connection history | `connection-history.jsonl` | S2 | Plaintext JSON lines, `0600`, appended under a file lock. Holds times, hosts, user names, jump hosts and proxies, results, commands, forwarded ports, and the paths of copied or changed files; no passwords, session keys, or command output other than the reason an `ssh` run in the terminal failed. A command is taken from what the terminal showed, so input that is not echoed is never stored, and known secret patterns are masked; a secret in another form inside a command is stored as shown. A session key is cut to its first four characters. 2,000 records and one year at most. `history.enabled` turns it off and `history.commands` leaves commands out. Not part of the settings backup. | Hosts, commands, and file paths are readable by any process running as the user. No tamper detection. |
| SFTP gateway session keys | `SessionTreeStore.sessionKeys` in memory | S1 | Never written to disk. Dropped when Gloamux quits, the vault locks, or the server refuses the key. | Not cleared on idle or sleep. Swift strings cannot be reliably zeroed. |
| Agent access and activity | `agent-access.json`, `agent-activity.json` | I and S2 | Plaintext JSON, `0600`. Access is off until the user turns it on and allows sessions in Gloamux. | No tamper detection. A process running as the user can allow sessions or remove history entries. |
| Clipboard | System pasteboard | S2 | Gloamux reads it on paste. OSC 52 writes from remote programs are refused unless `terminal.allow-clipboard-writes` is on (off by default). | With clipboard writes on, a remote program can place secrets on the shared pasteboard and Universal Clipboard. Copy-on-select is still planned. |
| SFTP downloads | User-chosen folder plus `.gloamux-<UUID>.partial` | S2 | The partial file is removed on failure. | Partial files use default permissions. Downloaded files are the user's responsibility, but the partial file should be `0600`. |
| Settings backup | User-chosen `.gloamuxconfig` file and its `.sha256` | S1 and S2 | Written `0600`. Carries `password-vault.json` exactly as stored, sealed under the master password; the master password, passwords remembered on this Mac, and the Secure Enclave keys are not included. Restore replaces the vault only when the backup has one, after copying the current vault to `Backups/`. | The rest of the backup is plaintext. Whoever has the file can guess the master password offline at the vault's PBKDF2 cost, so the vault is only as strong as that password. The `.sha256` file detects damage, not deliberate changes. |
| Appearance and layout | `appearance.json`, `layout.json` | L | `0600`. | None. |
| Language | `UserDefaults` | L | System defaults. | None. |
| Update preferences and last check time | `UserDefaults` (`SUEnableAutomaticChecks`, `SULastCheckTime`) | L | System defaults. Sparkle downloads the feed and the DMG from GitHub over HTTPS and installs only a DMG whose EdDSA signature matches `SUPublicEDKey`. The request User-Agent includes the app and Sparkle versions. GitHub receives the request and source IP. System profiling is disabled by default. The feed and release notes use HTTPS. The DMG carries the EdDSA signature. See [Sparkle settings](https://sparkle-project.org/documentation/customization/). | Builds are ad hoc signed, not notarized. The signing key lives in the release maintainer's login Keychain; losing it means users must reinstall by hand. |

### Other findings

- `writePrivate` creates its temporary file as `0600` with `O_EXCL | O_NOFOLLOW` and renames it into place, so no file is ever readable by other users. Folders are created as `0700`, but an existing folder with wider permissions is not corrected. Verify directory permissions on launch.
- The vault salt uses `UInt8.random(in:)`, which uses the system random generator on Apple platforms. Use `SecRandomCopyBytes` or `SymmetricKey(size:)` explicitly so the source of randomness is clear in review.
- The vault file has no version-bound integrity check over the full set of entries. An attacker who can write the file can delete or roll back individual entries.

## Protection work

Key generation, agent forwarding, keyboard-interactive sign-in, alternate protocols, cloud discovery, CLI, MCP, logs, runbooks, backup, and updates already ship. The table records proposed protection requirements and future extensions for these areas. Current behavior and remaining gaps are recorded above.

| Area | Data | Class | Protection target |
|---|---|---|---|
| Key manager, generation, import, and conversion | Private keys and passphrases | S1 | Write only encrypted OpenSSH keys or vault entries. Never write a temporary plaintext key to disk. |
| SSH agent and agent forwarding | Agent socket access | S1 | Forward only per session after explicit approval. Show the active forwarding state. |
| Keyboard-interactive, MFA, and saved login prompts | Answers, OTP seeds | S1 | Store only in the vault. Never store one-time codes. |
| FTP, FTPS, RDP, VNC, Telnet, and gateway credentials | Passwords | S1 | Use the same vault. Warn before sending a password over plain FTP or Telnet. |
| Cloud discovery (AWS, Tailscale) and S3 | Access keys, tokens | S1 | Prefer the provider's own credential source. Store any key in the vault. |
| CLI | Session operations | S1 boundary | The CLI never prints or accepts secrets as arguments. Use the running app or an interactive prompt for secrets. |
| Local MCP server | Approved session access, terminal excerpts | S1 boundary and S2 | Credentials never cross the MCP boundary. Excerpts are chosen by the user and redacted with the recording rules before they are kept or sent, including a secret that wraps or is partly selected. A secret in a form the rules do not know still passes. Through 1.3.1 (build 7), excerpts were not redacted. Permissions are per session and revocable. |
| Session logs and recordings | Terminal output and input | S2 | Encrypt at rest with the workspace key. Redact passwords typed at prompts. Exclude no-echo input. |
| Macros, runbooks, and startup commands | Command text | S2 | Encrypt at rest. Exclude authentication input from recordings. Reference vault entries instead of embedding secrets. |
| Connection history, audit history, and session restoration | Hosts, times, approvals | S2 and I | Encrypt at rest. Sign the audit history so entries cannot be removed silently. |
| iCloud sync | Profiles, folders, commands, appearance | S2 | End-to-end encryption with a key that Apple cannot read. Never sync S1 data or host trust decisions unless the user enables an end-to-end encrypted vault sync. |
| Backup, restore, and team export | Workspace | S2 | Encrypt backups with a user-chosen password. Team exports contain no credentials or host trust. |
| Crash reports and diagnostics | Memory, state | S1 risk | Strip terminal buffers, secrets, and file paths. Ask before sending. |
| Updates | Application code | I | Sparkle with EdDSA signatures is built in starting with Gloamux 1.1. Notarization is still planned. |

## Recommended design

1. **Vault version 2.** Generate a random 256-bit data key. Wrap it with a key derived from the master password and, optionally, with a Keychain item that requires Touch ID. Use Argon2id, or PBKDF2-HMAC-SHA256 with at least 600,000 iterations if a dependency is not acceptable. Bind each entry's ID as AES-GCM associated data. Add a MAC over the entry list and a version counter. Migrate version 1 vaults on the first unlock.
2. **Encrypted workspace store.** Encrypt S2 files with keys derived from the vault data key: the session catalog, quick commands, logs, recordings, runbooks, and history. Keep a plaintext index only when it is needed before unlock, and make it contain no host or user names.
3. **Host trust integrity.** Add an HMAC to `known-hosts.json` with a key stored in the Keychain. Treat a failed check as an untrusted host and prompt again with a clear warning.
4. **Lock policy.** Lock after a configurable idle time, on sleep, on screen lock, and on quit. Clear remembered session passwords on lock.
5. **Memory handling.** Keep secrets in `Data` or byte buffers where possible and overwrite them after use. Do not place secrets in view-state restoration, undo stacks, or diagnostics.
6. **File handling.** Private files are already created as `0600` directly. Verify `0700` on the workspace directory at launch. Create SFTP partial files with `0600`.

## Verification

The checks below describe verification for the proposed protection changes. Vault version 2, encrypted workspace storage, and tamper protection are still open.

- Unit tests: vault version 2 round trip, entry swap and rollback detection, wrong password, migration from version 1, and lock on each trigger.
- Tamper tests for `known-hosts.json` and the session catalog.
- A scan of logs, recordings, crash output, CLI output, and MCP responses for test secrets after each feature that adds a new output path.
- Manual check that workspace files are unreadable without unlocking and that Time Machine copies contain no plaintext S1 or S2 data.

## Decisions needed

- **Decided 2026-11-21: the vault is optional and outranks the per-session check.** Without a vault, a password that signs in is remembered in `saved-sign-ins.json` and connects again without a prompt, also after a restart; a session with **Confirm each connection with Touch ID** (on for new sessions) asks each time. The original plan moved remembered passwords into the vault and deleted `saved-sign-ins.json`. The revised decision below supersedes that storage behavior. While the vault is unlocked, sessions skip the per-connection confirmation.
- **Decided 2026-11-21 (revised): a locked vault brings back the per-session check, and `saved-sign-ins.json` stays.** Creating the vault no longer moves remembered passwords into it. While the vault is locked, a session set to ask on every connection asks (Touch ID or the Mac password), and other sessions connect with the copy on this Mac, so locking the vault does not protect those copies. A password that only the locked vault holds is read with Touch ID for that connection; the vault stays locked.

- ~~Default unlock~~ **Decided 2026-11-20: both.** The master password always works and is required to create the vault and after a restart or a Touch ID failure. The local 0.10.0 build uses a Secure Enclave-protected key in memory for Touch ID during the same app launch. This works with ad hoc signing.
- Minimum master password length. The current policy is 6 to 50 characters.
- Whether the session catalog and quick commands are encrypted by default, which requires unlocking before the session tree appears.
- Whether vault sync through iCloud is offered at all.
