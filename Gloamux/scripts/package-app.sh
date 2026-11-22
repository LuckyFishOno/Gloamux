#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_path=${1:-/tmp/gloamux-build}
output_dir=${2:-"$project_dir/../build"}
cd "$project_dir"
command -v cargo >/dev/null 2>&1 || { printf 'Rust and Cargo are required to build the remote desktop engine.\n' >&2; exit 1; }
rdp_target="$build_path/gloamux-desktop-engine"
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --release --locked --manifest-path RDP/Cargo.toml --target-dir "$rdp_target"
# Release builds draw and parse terminal output several times faster than debug builds.
swift build -c release --build-path "$build_path" --product GloamuxApp
bin_dir=$(swift build -c release --build-path "$build_path" --show-bin-path)
app="$output_dir/Gloamux.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin"
mkdir -p "$app/Contents/Helpers"
mkdir -p "$app/Contents/Resources/RemoteDesktopLicenses"
cp "$bin_dir/GloamuxApp" "$app/Contents/MacOS/Gloamux"
cp "$rdp_target/release/gloamux-rdp" "$app/Contents/Helpers/gloamux-rdp"
cp RDP/licenses/*.txt "$app/Contents/Resources/RemoteDesktopLicenses/"
codesign --force --sign - "$app/Contents/Helpers/gloamux-rdp"
ln -sf ../../MacOS/Gloamux "$app/Contents/Resources/bin/gloamux"
ln -sf ../../MacOS/Gloamux "$app/Contents/Resources/bin/gloam"
for resource in "$bin_dir"/*.bundle; do
    [ -d "$resource" ] || continue
    ditto "$resource" "$app/Contents/Resources/$(basename "$resource")"
done
# Shortcuts and Siri find the app's actions in Metadata.appintents. SwiftPM compiles the intents with constant
# values but does not run Xcode's metadata step, so run it here; without it the app still works, minus Shortcuts.
intents_consts=$(find "$build_path" -name 'ShellIntents*.swiftconstvalues' -path '*Release*' 2>/dev/null | head -n 1)
if [ -n "$intents_consts" ] && xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then
    lists=$(mktemp -d)
    printf '%s\n' "$project_dir/Sources/intents/ShellIntents.swift" > "$lists/sources"
    printf '%s\n' "$intents_consts" > "$lists/consts"
    rm -rf "$app/Contents/Resources/Metadata.appintents"
    xcrun appintentsmetadataprocessor --output "$app/Contents/Resources" \
        --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" \
        --module-name ShellIntents --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
        --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
        --platform-family macOS --deployment-target 14.0 --target-triple "$(uname -m)-apple-macos14.0" \
        --source-file-list "$lists/sources" --swift-const-vals-list "$lists/consts" --quiet-warnings >/dev/null 2>&1 \
        || printf 'warning: App Intents metadata was not generated; Shortcuts will not list Gloamux actions.\n' >&2
    rm -rf "$lists"
else
    printf 'warning: no App Intents constant values found; Shortcuts will not list Gloamux actions.\n' >&2
fi
# Empty language folders tell macOS which languages the app has, so its own menus (About, Hide, Quit) and
# System Settings' per-app language list match the interface text in the resource bundle.
for language in en zh-Hant; do mkdir -p "$app/Contents/Resources/$language.lproj"; done
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.gloamux.desktop</string>
<key>CFBundleName</key><string>Gloamux</string>
<key>CFBundleDisplayName</key><string>Gloamux</string>
<key>CFBundleExecutable</key><string>Gloamux</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hant</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.13.0</string>
<key>CFBundleVersion</key><string>19</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>local.gloamux.desktop</string>
<key>CFBundleURLSchemes</key><array><string>gloamux</string></array>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$app"
printf 'Built local application: %s\n' "$app"
