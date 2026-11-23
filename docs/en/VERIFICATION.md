# Gloamux verification record

[English](VERIFICATION.md) · [繁體中文](../zh-TW/VERIFICATION.md) · [Back to README](../../README.md)

Rebuilt and verified on November 24, 2026 with the architecture changes on top of `b1e4638` that ship in Gloamux 1.2 (build 3). The tested package is `build/Gloamux.app`.

## Functional and regression checks

| Check | Result |
|---|---|
| Full Swift suite | 469 cases, 461 passed, 8 skipped, 0 failed |
| Rust remote desktop engine | 18 passed |
| Packaged app | Deep strict signature verification passed, feature-contract self-test 9/9 |
| CLI help entry points | 22 groups passed |
| Packaged batch verification scripts | 81/81 passed, including the quit-recording case rerun with the corrected test identifier |
| Localization files | All five Localizable.strings catalogs passed plutil validation |

Swift coverage includes parsing and imports, host trust, credentials, proxies and jumps, loopback MFA, terminal behavior, splits and locks, SFTP/SCP/FTP/FTPS, forwarding, and the new architecture regressions. The eight skips are three external SSH checks and five installed Xshell sample checks.

The 81 packaged checks cover safe overwrites, lock refusal, damaged-store protection, recording save failures, concurrent CLI requests, shared connection services, help and completion, exit codes, stdin passphrases, relative paths, and recording saves at the size limit and on quit. Checks use throwaway workspaces and the loopback SSH tests use keys generated for the run.

The user reported successful manual checks on the packaged test build for Zhuyin/Pinyin composition and Return, composition while another split pane continuously prints output, mouse selection, and input reaching the focused pane. This manual result is recorded in the local project status.

## Full stress test

The run used Apple silicon, 10 cores, and macOS 27.2.1. All 14 phases passed in full mode (14/14).

| Phase | Result |
|---|---|
| CLI catalog (offline) | Passed |
| Config export and import | Passed |
| Test SSH server | Passed |
| SFTP large file | Passed |
| SCP large file | Passed |
| Folder transfer (recursive) | Passed |
| SSH connection churn | Passed |
| Terminal benchmark | Passed |
| App launch | Passed |
| CLI catalog (app running) | Passed |
| Tabs and terminal output | Passed |
| Port forwarding | Passed |
| MCP agents | Passed |
| App idle after load | Passed |

| Measurement | Result |
|---|---|
| Large files | 512 MB round trips over each of SFTP and SCP |
| Folder tree | 2,000 files uploaded, downloaded, and removed |
| Parallel SSH | 40 connections, 0 failures |
| Terminal load | 20 local and 10 SSH tabs, each printing 1,000,000 lines |
| Aggregate output | About 660,949 lines/s |
| App memory | 711 MB peak, about 153 MB after closing the loaded tabs |
| Forwarding | 200 connections, 256 MB round trip |
| MCP | 5 tools, 300 calls, about 4 ms p95, command proposal remained awaiting review |

These are measurements from this Mac and run. Transfer endpoints are loopback and resource sampling is once per second.

## Architecture status and remaining checks

All ten findings have corresponding implementation and tests, covering upload commits, target-workspace locks, stale results, storage failures, concurrent requests, bounded processes, shared connection services, background saves, isolated terminal updates, and the command catalog.

Offline management commands still create a full WorkspaceModel and CLI handlers still parse string operands. These remain follow-up refactors. Real VNC/Screen Sharing, PAM one-time-code sign-in, XQuartz rendering and input, broader Vim/tmux compatibility, update installation, and Intel builds also need verification. Feature-contract self-checks and other checks establish the coverage described in this record.

## Test harness correction

The quit-recording script initially hard-coded the older test app identifier. Its first rerun closed the previous test instance and failed the new instance's quit and save checks. After correcting the temporary script to this run's isolated identifier, all 6 checks passed. This required a test-script correction. Both the initial and corrected logs are retained in the local evidence.

## Reproduction and source

```sh
swift test --package-path Gloamux
cargo test --offline --locked --manifest-path Gloamux/RDP/Cargo.toml
Gloamux/scripts/package-app.sh
codesign --verify --deep --strict build/Gloamux.app
python3 Gloamux/scripts/stress-test.py --out /tmp/gloamux-stress-verification
```

Source digest SHA-256 is `7632fcf66a6a1b75b5cb4191dc4092d308109d132e70bb5a99700a1f1617f984`. It covers Sources, Tests, RDP/src, Package.swift, Package.resolved, Cargo.toml, and Cargo.lock, sorted by path and hashed as path, NUL, file bytes, NUL. Raw local evidence is in `analysis/verification-20261124/`, excluded by Git.
