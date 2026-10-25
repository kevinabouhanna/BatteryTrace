#!/bin/bash
# Packages an app as build/BatteryTrace.dmg: the app and a link to
# Applications to drag it onto. Plain hdiutil, nothing to install.
#
#   Scripts/make-dmg.sh "path/to/Battery Trace.app"
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${1:?usage: make-dmg.sh path/to/Battery\ Trace.app}
OUT=build/BatteryTrace.dmg
[ -d "$APP" ] || { echo "error: $APP not found; run 'make universal' first" >&2; exit 1; }

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "==> Packaging Battery Trace $VERSION ($(lipo -archs "$APP/Contents/MacOS/Battery Trace"))"
rm -f "$OUT"
hdiutil create -quiet -volname "Battery Trace" -srcfolder "$STAGING" -fs HFS+ -format UDZO "$OUT"
hdiutil verify -quiet "$OUT"
echo "==> Done: $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
