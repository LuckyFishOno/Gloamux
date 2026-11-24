# Releasing Gloamux

[English](RELEASING.md) · [繁體中文](../zh-TW/RELEASING.md) · [Back to README](../../README.md)

Functional and stress results for the November 24, 2026 working tree are in the [verification record](VERIFICATION.md).

This is the standard way to update the documentation, push `main`, build the DMG, and publish a GitHub release. It is written so that a person or a coding agent can follow it from start to finish. `Gloamux/scripts/release.sh` does the building, checking, and publishing; the steps around it are yours.

## Version numbers

| Release | Tag | App version (`CFBundleShortVersionString`) | Build (`CFBundleVersion`) |
|---|---|---|---|
| Gloamux 1.0 (build 1) | `v1.0` | `1.0` | `1` |
| Gloamux 1.1 (build 2) | `v1.1` | `1.1` | `2` |
| Gloamux 1.2 (build 3) | `v1.2` | `1.2` | `3` |
| Gloamux 1.2.1 (build 4) | `v1.2.1` | `1.2.1` | `4` |
| Gloamux 1.2.2 (build 5) | `v1.2.2` | `1.2.2` | `5` |
| **Next normal-release example: Gloamux 1.3 (build 6)** | `v1.3` | `1.3` | `6` |

- The version is what users see. Raise the second number for a normal release (1.1, 1.2) and the first for a major one (2.0). Use a third number only for a fix-only release of a published version (1.1.1).
- The build number goes up by one for every published release, whatever the version, and is never reused. A tag is never reused either, so a replacement for a broken DMG is a fix version with the next build number, for example 1.3.1 (build 7).
- The release title is always `Gloamux VERSION (build BUILD)` and the tag is always `vVERSION`.
- Local builds carry the same numbers as the latest release. They are the defaults in `Gloamux/scripts/package-app.sh` (`version=${GLOAMUX_VERSION:-1.2.2}` and `build_number=${GLOAMUX_BUILD:-5}` today), and the release commit raises them to the new release. `release.sh` refuses to build until they match.

## Before you start

- An Apple silicon Mac with macOS 14 or later, Xcode, and Rust 1.94 or later.
- The GitHub CLI signed in with access to `LuckyFishOno/Gloamux`: `gh auth status`.
- Push access to `main`. If `git push origin main` asks for HTTPS credentials, push over SSH instead: `git push git@github.com:LuckyFishOno/Gloamux.git main`.
- The update signing key in the login Keychain. Check with `Gloamux/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account Gloamux -p` (after one `swift build --package-path Gloamux`); it must print the `update_key` in `package-app.sh`. Only the owner has this key. On another Mac, import the owner's backup with `generate_keys --account Gloamux -f BACKUP_FILE`, and delete the backup file afterwards.

### The update signing key

Gloamux installs an update only if the DMG is signed with the EdDSA private key whose public half is `update_key` in `package-app.sh` (the app's `SUPublicEDKey`). The private key lives in the owner's login Keychain under the account `Gloamux`. Back it up once with `generate_keys --account Gloamux -x BACKUP_FILE` and keep that file in a password manager, never in the repository. If the key is lost, installed copies can no longer update themselves: a new key has to ship in a release that every user installs by hand. Never replace `update_key` for any other reason.

House rules that apply to every step:

- Documentation is in English, and every document in `docs/en` has a Traditional Chinese copy with the same name in `docs/zh-TW` (the READMEs are `README.md` and `README.zh-TW.md`). Change both in the same commit.
- Screenshots and documents never show a real hostname, user name, IP address, or key. Use `--workspace` with a throwaway folder and example hosts such as `server.example.com`.
- Interface text never ends with "…" or "...", in any language.
- Never commit secrets, `.env` files, keys, or anything under `build/`, `web/`, `/analysis/`, or `.agent-memory/`.
- Never force-push `main`, and never delete or replace a published release or tag without the owner's approval.

## 1. Start from an up-to-date main

```sh
git switch main
git pull --ff-only
git status --short          # must print nothing
gh release list -R LuckyFishOno/Gloamux --limit 5
```

The newest release in that list tells you the last build number. The new build is that number plus one.

## 2. Update the documentation

Go through this list for every release, in both languages:

- [ ] `Gloamux/scripts/package-app.sh`: set the defaults to the new release, for example `version=${GLOAMUX_VERSION:-1.3}` and `build_number=${GLOAMUX_BUILD:-6}`. Local builds then show the same version as the release.
- [ ] `README.md` and `README.zh-TW.md`: the line `Current release: **Gloamux VERSION (build BUILD)**.` (`目前版本：**Gloamux VERSION (build BUILD)**。`). `release.sh publish` refuses to run until both name the new release.
- [ ] `docs/*/USER-GUIDE.md`: every user-facing change since the last release, in its chapter and in the menu, shortcut, settings, and command-line references, with names exactly as the app shows them (the Chinese guide uses the app's Traditional Chinese names).
- [ ] `README` feature list and "Why use it" table, if a headline feature was added or removed.
- [ ] `docs/*/ROADMAP.md` and `docs/*/FEATURE-BACKLOG.md`: tick finished items, and move nothing to done that is not in the app.
- [ ] `docs/*/DATA-PROTECTION.md`: any new stored data, secret, or output path, and its "Reviewed on" line.
- [ ] `docs/*/DEVELOPMENT.md`: new architecture, settings keys, or test instructions.
- [ ] `docs/assets/*.png`: retake only when the interface changed visibly, following the screenshot rule above.
- [ ] Check relative links and section anchors in both languages after moving or renaming documents. Compare the documented commands with the packaged CLI help.
- [ ] Update the local `.agent-memory/status.md` checkpoint with the release commit, installed path, checks completed, and remaining verification. Keep this file local. Website maintenance notes live under `web/`, which is also excluded from public commits.

Then check what you are about to commit:

```sh
git diff --stat
git grep -nIi -e "$(id -un)" -e "$(hostname -s)" -- . ':!*.lproj' || echo "no personal names"
```

## 3. Commit

Commit the code and documentation for the release. Use a short imperative subject (under 72 characters) and a body that lists the user-facing changes:

```sh
git add -A
git status --short          # review: nothing secret, nothing generated
git commit -m "Release Gloamux 1.3 (build 6)" -m "- Short list of the user-facing changes"
```

## 4. Build and check the DMG

```sh
Gloamux/scripts/release.sh build 1.3 6
```

The working tree must be clean, because the DMG is built from the committed source. Rebuild after any further source or documentation commit before publishing, so the archive matches the commit named by the release. The script:

1. Refuses to run off `main`, with uncommitted changes, when `package-app.sh` does not carry this version and build, when the tag exists, or when the build number is not above the last published one.
2. Runs the Swift tests and the Rust remote desktop tests. `--skip-tests` skips them; use it only when both suites already passed on this exact commit.
3. Packages `Gloamux.app` with the release version and build number into `build/release/VERSION-BUILD/`.
4. Checks the version, build number, update feed URL, update key, embedded Sparkle framework, signature, arm64 architecture, the 9-feature self-test, and `gloamux --version`. It also stops early if the update signing key is not in the Keychain.
5. Makes `Gloamux.dmg` with the app and an Applications link, mounts it, and checks its contents, link, signature, and checksum.
6. Writes `Gloamux.dmg.sha256` and prints the paths, size, SHA-256, and commit.

The Swift suite skips its remote host and Xshell sample checks unless those inputs are set up; that is expected. Any failure stops the script. Fix the cause in a new commit and run it again.

## 5. Push main

```sh
git push origin main
```

## 6. Write the release notes

Write the notes in English to `build/release/VERSION-BUILD/notes.md` (the `build/` folder is not committed). Do not add the build information section; `release.sh` appends it. Template:

```markdown
**Gloamux 1.3 (build 6)** adds … and fixes ….

## Highlights
- **Feature name.** What it does for the user, in one sentence.

## Fixes
- What was wrong, and what happens now.

## Installation
1. Download and open **Gloamux.dmg**.
2. Quit Gloamux if it is running, then drag **Gloamux.app** onto **Applications** and replace the old copy.
3. Open Gloamux from Applications. Your connections and settings stay as they are.

Already on Gloamux 1.1 or later? Choose **Gloamux › Check for Updates** instead.

Requires macOS 14 or later and an Apple silicon Mac (M1 or newer). The app is ad hoc signed and is not notarized. If macOS shows "Gloamux" Not Opened, use System Settings → Privacy & Security → Open Anyway, as documented in the README.

## Validation
- Swift suite: N tests, N passed and N skipped (remote host and Xshell sample checks that need external inputs), 0 failed.
- Rust remote desktop engine: N tests passed.
- Packaged app self-test passed for all 9 features.
- Apple silicon release build, deep signature verification, and DMG checksum verification passed.
```

Take the test counts from the output of step 4. Describe only what changed for users; do not list internal refactors.

## 7. Publish

```sh
Gloamux/scripts/release.sh publish 1.3 6 build/release/1.3-6/notes.md
```

The script checks again that the tree is clean, that the DMG still matches its checksum, that both READMEs name the release, and that GitHub's `main` is the commit you built. It renders the notes to HTML (through GitHub's Markdown API) and writes `appcast.xml`, the update feed that installed copies read: the version, build number, notes, and the DMG's EdDSA signature (`Gloamux/scripts/appcast.sh`). It then creates the tag and the release `Gloamux 1.3 (build 6)` as the latest release, attaches `Gloamux.dmg` and `appcast.xml`, appends the build information, and checks that the README's download link (`releases/latest/download/Gloamux.dmg`) answers and that `releases/latest/download/appcast.xml` offers the new build. From this moment, Gloamux 1.1 and later offer the update through **Gloamux › Check for Updates** and the daily check.

Gloamux 1.0 has no updater, so its users install a newer release by hand once. The 1.1 notes say so.

## 8. After publishing

- Open the release page and read it once as a user would.
- Confirm that the README's **Download Gloamux** link downloads the new DMG.
- On a Mac with the previous release installed (from 1.1 on), choose **Gloamux › Check for Updates** and confirm that it offers, installs, and reopens the new version. Record whether this check ran. Passing unit tests and feature self-checks alone does not establish update installation.
- Report the release URL, the DMG's SHA-256, and the commit to the owner.

## When something goes wrong

| Problem | What to do |
|---|---|
| `tag vX.Y already exists` | The version was released before. Pick the next version, or ask the owner before touching the existing release. |
| `build N is not above the published build M` | Use build M + 1. |
| `set version=... and build_number=... in Gloamux/scripts/package-app.sh` | Raise the two defaults to the new release, commit, and run again. |
| `README.md does not name ...` | Update the current-release line in both READMEs, commit, push, then rebuild so the DMG matches the commit. |
| `GitHub main is ..., not ...` | Push `main`, or pull if someone else pushed, then rebuild from the new commit. |
| `the DMG changed after it was built` | Run `release.sh build` again. |
| `hdiutil: ... Resource busy` | Eject any mounted Gloamux volume (`hdiutil info`, then `hdiutil detach`) and run again. |
| `the Gloamux update signing key is not in the login Keychain` | Import the owner's backup (see [The update signing key](#the-update-signing-key)), or ask the owner to publish. Never generate a new key for a release. |
| `the Keychain's update key does not match update_key` | The Keychain holds a different key. Import the owner's backup; do not change `update_key`. |
| `the update feed at ... does not offer build N` | GitHub can take a minute to serve a new asset. Wait and open the URL again. If `appcast.xml` is missing from the release, upload `build/release/VERSION-BUILD/appcast.xml` with `gh release upload vVERSION FILE -R LuckyFishOno/Gloamux`. |
| `gh` asks to sign in | Run `gh auth login` and choose GitHub.com. |
| A test fails during `release.sh build` | Run that test alone, for example `swift test --package-path Gloamux --filter SshTests.KeyFormatTests/testPEMAndPKCS8KeysSignIn`. A few tests that start processes or servers can fail when the whole suite runs at once and pass alone; if it passes alone, run `release.sh build` again. If it fails alone, it is a real bug: fix it in a new commit. |
| A published DMG is broken | Do not replace the asset or move the tag. Fix it and publish a fix version with the next build number, for example 1.3.1 (build 7), and say in the notes which build it replaces. |
