#!/bin/sh
# Writes the Sparkle update feed (appcast.xml) for one Gloamux release to standard output.
#
#   Gloamux/scripts/appcast.sh VERSION BUILD DMG DOWNLOAD_URL NOTES.html
#
# The DMG is signed with the EdDSA key in the login Keychain (account "Gloamux"), whose public half is SUPublicEDKey in
# package-app.sh. Sparkle shows NOTES.html in its update window and installs the DMG only if the signature matches.
# release.sh publish calls this and uploads the result next to the DMG.
set -eu

fail() { printf 'appcast: %s\n' "$*" >&2; exit 1; }
[ $# -eq 5 ] || fail "usage: appcast.sh VERSION BUILD DMG DOWNLOAD_URL NOTES.html"
version=$1 build=$2 dmg=$3 url=$4 notes=$5
[ -f "$dmg" ] || fail "no DMG at $dmg"
[ -f "$notes" ] || fail "no release notes at $notes"
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

sign_update=$(ls /tmp/gloamux-build/artifacts/sparkle/Sparkle/bin/sign_update \
    "$project_dir/.build/artifacts/sparkle/Sparkle/bin/sign_update" 2>/dev/null | head -n 1)
[ -n "$sign_update" ] || fail "Sparkle's sign_update was not found; build Gloamux once (swift build) first"
# Prints: sparkle:edSignature="..." length="..."
enclosure=$("$sign_update" --account Gloamux "$dmg") || fail "could not sign $dmg; is the Gloamux update key in the login Keychain?"
case $enclosure in *'sparkle:edSignature="'*'length="'*) ;; *) fail "unexpected sign_update output: $enclosure" ;; esac
signature=$(printf '%s' "$enclosure" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
"$sign_update" --account Gloamux --verify "$dmg" "$signature" >/dev/null 2>&1 || fail "the DMG signature does not verify"

grep -q ']]>' "$notes" && fail "the release notes may not contain ]]>"
date=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
<title>Gloamux</title>
<link>https://github.com/LuckyFishOno/Gloamux</link>
<language>en</language>
<item>
<title>Gloamux $version (build $build)</title>
<pubDate>$date</pubDate>
<sparkle:version>$build</sparkle:version>
<sparkle:shortVersionString>$version</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
<sparkle:fullReleaseNotesLink>https://github.com/LuckyFishOno/Gloamux/releases</sparkle:fullReleaseNotesLink>
<description><![CDATA[
$(cat "$notes")
]]></description>
<enclosure url="$url" type="application/x-apple-diskimage" $enclosure/>
</item>
</channel>
</rss>
XML
