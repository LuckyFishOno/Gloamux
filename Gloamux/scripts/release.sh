#!/bin/sh
# Builds and publishes a Gloamux release. See docs/en/RELEASING.md for the whole checklist.
#
#   Gloamux/scripts/release.sh build VERSION BUILD [--skip-tests]
#   Gloamux/scripts/release.sh publish VERSION BUILD NOTES.md
#
# `build` checks the working tree, runs the tests, packages the app with VERSION and BUILD, makes
# build/release/VERSION-BUILD/Gloamux.dmg (the app and an Applications link), and verifies both.
# `publish` checks that the release commit is on GitHub and that both READMEs name this release, writes the
# Sparkle update feed (appcast.xml, with NOTES.md and the DMG's EdDSA signature), then creates the tag vVERSION
# and the GitHub release "Gloamux VERSION (build BUILD)" with the DMG and the feed. The build information
# (tag, versions, architecture, commit, SHA-256) is appended to NOTES.md automatically.
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
github_repo=LuckyFishOno/Gloamux
feed_url="https://github.com/$github_repo/releases/latest/download/appcast.xml"

fail() { printf 'release: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

[ $# -ge 3 ] || fail "usage: release.sh build VERSION BUILD [--skip-tests] | release.sh publish VERSION BUILD NOTES.md"
command=$1 version=$2 build=$3
shift 3
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || fail "VERSION must look like 1.1 or 1.1.2, not '$version'"
printf '%s' "$build" | grep -Eq '^[0-9]+$' || fail "BUILD must be a whole number, not '$build'"

tag="v$version"
title="Gloamux $version (build $build)"
out_dir="$repo_dir/build/release/$version-$build"
dmg="$out_dir/Gloamux.dmg"
app="$out_dir/Gloamux.app"
cd "$repo_dir"

check_tree() {
    [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "check out main first"
    package=Gloamux/scripts/package-app.sh
    [ "$(sed -n 's/^version=${GLOAMUX_VERSION:-\(.*\)}$/\1/p' "$package")" = "$version" ] &&
        [ "$(sed -n 's/^build_number=${GLOAMUX_BUILD:-\(.*\)}$/\1/p' "$package")" = "$build" ] ||
        fail "set version=\${GLOAMUX_VERSION:-$version} and build_number=\${GLOAMUX_BUILD:-$build} in $package and commit it"
    [ -z "$(git status --porcelain)" ] || { git status --short >&2; fail "commit or stash the changes above first"; }
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then fail "tag $tag already exists"; fi
}

# The EdDSA private key that signs updates must be in this Mac's login Keychain and match SUPublicEDKey.
check_update_key() {
    generate_keys=$(ls /tmp/gloamux-build/artifacts/sparkle/Sparkle/bin/generate_keys \
        Gloamux/.build/artifacts/sparkle/Sparkle/bin/generate_keys 2>/dev/null | head -n 1)
    [ -n "$generate_keys" ] || fail "Sparkle's tools are missing; run 'swift build --package-path Gloamux' once"
    expected=$(sed -n 's/^update_key=//p' Gloamux/scripts/package-app.sh)
    actual=$("$generate_keys" --account Gloamux -p 2>/dev/null) ||
        fail "the Gloamux update signing key is not in the login Keychain; import the backup (docs/en/RELEASING.md)"
    [ "$actual" = "$expected" ] || fail "the Keychain's update key does not match update_key in package-app.sh"
}

check_newer_build() {
    latest=$(gh release list -R "$github_repo" --limit 50 --json name -q '.[].name' 2>/dev/null |
        sed -n 's/.*(build \([0-9][0-9]*\)).*/\1/p' | sort -n | tail -1)
    if [ -n "$latest" ] && [ "$build" -le "$latest" ]; then fail "build $build is not above the published build $latest"; fi
}

case $command in
build)
    skip_tests=no
    [ "${1:-}" = --skip-tests ] && skip_tests=yes
    check_tree
    check_newer_build
    check_update_key

    if [ $skip_tests = no ]; then
        step "Swift tests"
        swift test --package-path Gloamux
        step "Rust remote desktop engine tests"
        (cd Gloamux/RDP && cargo test --release --locked)
    fi

    step "Package Gloamux $version ($build)"
    rm -rf "$out_dir"
    mkdir -p "$out_dir"
    unset GLOAMUX_FEED_URL
    GLOAMUX_VERSION=$version GLOAMUX_BUILD=$build ./Gloamux/scripts/package-app.sh /tmp/gloamux-build "$out_dir"

    step "Verify the app"
    plist="$app/Contents/Info.plist"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" = "$version" ] || fail "app version is not $version"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" = "$build" ] || fail "build number is not $build"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist")" = "$feed_url" ] || fail "the update feed is not $feed_url"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist")" = "$(sed -n 's/^update_key=//p' Gloamux/scripts/package-app.sh)" ] ||
        fail "the app's update key does not match package-app.sh"
    [ -f "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ] || fail "Sparkle.framework is missing"
    codesign --verify --deep --strict "$app"
    for binary in "$app/Contents/MacOS/Gloamux" "$app/Contents/Helpers/gloamux-rdp"; do
        [ "$(lipo -archs "$binary")" = arm64 ] || fail "$binary is not arm64"
    done
    workspace=$(mktemp -d)
    "$app/Contents/MacOS/Gloamux" --self-test --workspace "$workspace" | tee "$out_dir/self-test.txt"
    rm -rf "$workspace"
    grep -q '"implemented":9' "$out_dir/self-test.txt" && grep -q '"total":9' "$out_dir/self-test.txt" || fail "self-test did not pass every feature"
    [ "$("$app/Contents/Resources/bin/gloamux" --version)" = "$version" ] || fail "gloamux --version is not $version"

    step "Make Gloamux.dmg"
    stage="$out_dir/dmg"
    mkdir -p "$stage"
    ditto "$app" "$stage/Gloamux.app"
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname Gloamux -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$dmg" >/dev/null
    rm -rf "$stage"

    step "Verify Gloamux.dmg"
    hdiutil verify "$dmg" >/dev/null
    mount=$(mktemp -d)
    hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$dmg" >/dev/null
    contents=$(ls "$mount" | tr '\n' ' ')
    link=$(readlink "$mount/Applications" || true)
    codesign --verify --deep --strict "$mount/Gloamux.app" || { hdiutil detach "$mount" -quiet; fail "the app in the DMG fails signature verification"; }
    hdiutil detach "$mount" -quiet
    [ "$contents" = "Applications Gloamux.app " ] || fail "unexpected DMG contents: $contents"
    [ "$link" = /Applications ] || fail "the Applications link points at '$link'"

    (cd "$out_dir" && shasum -a 256 Gloamux.dmg > Gloamux.dmg.sha256)
    step "Done"
    printf 'App:     %s\nDMG:     %s (%s)\nSHA-256: %s\nCommit:  %s\n' "$app" "$dmg" "$(du -h "$dmg" | cut -f1 | tr -d ' ')" \
        "$(cut -d' ' -f1 "$out_dir/Gloamux.dmg.sha256")" "$(git rev-parse HEAD)"
    ;;

publish)
    [ $# -ge 1 ] || fail "publish needs the release notes file"
    notes=$1
    [ -s "$notes" ] || fail "release notes '$notes' are missing or empty"
    check_tree
    check_newer_build
    check_update_key
    [ -f "$dmg" ] || fail "no $dmg; run 'release.sh build $version $build' first"
    (cd "$out_dir" && shasum -a 256 -c Gloamux.dmg.sha256 >/dev/null) || fail "the DMG changed after it was built"
    grep -qF "Gloamux $version (build $build)" README.md || fail "README.md does not name Gloamux $version (build $build)"
    grep -qF "Gloamux $version (build $build)" README.zh-TW.md || fail "README.zh-TW.md does not name Gloamux $version (build $build)"

    step "Check that main is on GitHub"
    commit=$(git rev-parse HEAD)
    remote=$(git ls-remote "https://github.com/$github_repo.git" refs/heads/main | cut -f1)
    [ "$remote" = "$commit" ] || fail "GitHub main is ${remote:-unknown}, not $commit; push main first"

    step "Write the update feed"
    notes_html="$out_dir/notes.html"
    gh api markdown -f mode=gfm -f context="$github_repo" -F text=@"$notes" > "$notes_html" ||
        fail "GitHub could not render $notes as HTML"
    appcast="$out_dir/appcast.xml"
    ./Gloamux/scripts/appcast.sh "$version" "$build" "$dmg" \
        "https://github.com/$github_repo/releases/download/$tag/Gloamux.dmg" "$notes_html" > "$appcast"
    xmllint --noout "$appcast" || fail "appcast.xml is not well-formed XML"

    step "Create $tag"
    body=$(mktemp)
    cat "$notes" > "$body"
    cat >> "$body" <<EOF

## Build information
- Tag: $tag
- App version: $version
- Build number: $build
- Architecture: arm64
- Minimum macOS: 14.0
- Commit: $commit
- Gloamux.dmg SHA-256: $(cut -d' ' -f1 "$out_dir/Gloamux.dmg.sha256")
EOF
    gh release create "$tag" "$dmg" "$appcast" -R "$github_repo" --target "$commit" --title "$title" --notes-file "$body" --latest
    rm -f "$body"
    git fetch -q --tags "https://github.com/$github_repo.git" 2>/dev/null || true

    step "Verify the release"
    gh release view "$tag" -R "$github_repo" --json name,tagName,assets \
        -q '"\(.name) · \(.tagName) · " + (.assets | map(.name + " " + (.size | tostring) + " bytes") | join(", "))'
    curl -fsIL "https://github.com/$github_repo/releases/latest/download/Gloamux.dmg" >/dev/null ||
        fail "the latest-download link does not answer"
    curl -fsL "$feed_url" | grep -qF "<sparkle:version>$build</sparkle:version>" ||
        fail "the update feed at $feed_url does not offer build $build"
    printf 'Published %s: https://github.com/%s/releases/tag/%s\n' "$title" "$github_repo" "$tag"
    ;;

*) fail "unknown command '$command'; use build or publish" ;;
esac
