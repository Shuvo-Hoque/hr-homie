#!/bin/bash
# Build the app from the Swift package, plus a disk image to share. Needs only the Xcode Command Line Tools.
# usage: scripts/build-app.sh [--open]
#   -> build/<Name>.app            (name from Info.plist CFBundleName)
#   -> build/<Name>-<version>.dmg  (drag-to-Applications disk image, for colleagues)
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" Info.plist)
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
EXE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" Info.plist)

ARCHS=(--arch arm64)
# universal binary (Apple silicon + Intel) when the toolchain can do it
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then ARCHS=(--arch arm64 --arch x86_64); fi
swift build -c release "${ARCHS[@]}"
BIN=$(swift build -c release "${ARCHS[@]}" --show-bin-path)/DeskBuddy

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXE"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/ "$APP/Contents/Resources/"
# ad-hoc signature: runs here as is; on colleagues' Macs macOS asks once (see docs/INSTALL.md). A Developer ID
# certificate + notarisation would remove that prompt.
codesign --force --deep --sign - "$APP"

# disk image: the app and an Applications shortcut to drag it onto
DMG="build/${NAME// /-}-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

echo "built: $APP  ($(lipo -archs "$APP/Contents/MacOS/$EXE"))"
echo "share: $DMG  ($(du -h "$DMG" | cut -f1))"
[[ "${1:-}" == "--open" ]] && open "$APP"
exit 0
