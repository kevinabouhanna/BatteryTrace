#!/bin/bash
# Signs Battery Trace with a Developer ID and notarizes it. The Release
# workflow runs this only when the repository has the signing secrets; without
# them, releases stay ad-hoc signed. See docs/RELEASING.md.
#
#   Scripts/sign-and-notarize.sh app "path/to/Battery Trace.app"
#   Scripts/sign-and-notarize.sh dmg build/BatteryTrace.dmg
#
# Environment:
#   SIGN_IDENTITY       "Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
#                       for notarytool; the password is an app-specific one
#   NOTARIZE=0          sign only, e.g. to try the signing locally
#
# Order matters: the app is signed inside out (helpers, then the app), then
# notarized and stapled; the disk image is made from the stapled app, then
# signed, notarized and stapled itself. Stapling changes the file, so nothing
# is packaged before it.
set -euo pipefail
MODE=${1:?usage: sign-and-notarize.sh app|dmg PATH}
TARGET=${2:?usage: sign-and-notarize.sh app|dmg PATH}
: "${SIGN_IDENTITY:?set SIGN_IDENTITY to a Developer ID Application identity}"

notarize() {
  [ "${NOTARIZE:-1}" = 1 ] || { echo "==> NOTARIZE=0: not notarizing $1"; return 0; }
  : "${APPLE_ID:?}" "${APPLE_TEAM_ID:?}" "${APPLE_APP_PASSWORD:?}"
  echo "==> Notarizing $(basename "$1")"
  xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" --wait --timeout 30m
}

case "$MODE" in
  app)
    [ -d "$TARGET" ] || { echo "error: $TARGET not found" >&2; exit 1; }
    # Every executable beside the main one (the privileged helper, when the
    # app carries it) first, so the app's signature seals them. No
    # --entitlements: the Release build's get-task-allow is dropped, which
    # notarization requires, and the app needs no others.
    main=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$TARGET/Contents/Info.plist")
    while IFS= read -r -d '' binary; do
      echo "==> Signing $(basename "$binary")"
      codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$binary"
    done < <(find "$TARGET/Contents/MacOS" -type f -perm +111 ! -name "$main" -print0)
    echo "==> Signing $(basename "$TARGET")"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$TARGET"
    codesign --verify --deep --strict --verbose=2 "$TARGET"

    if [ "${NOTARIZE:-1}" = 1 ]; then
      archive=$(mktemp -d)/app.zip
      ditto -c -k --keepParent "$TARGET" "$archive"
      notarize "$archive"
      rm -f "$archive"
      xcrun stapler staple "$TARGET"
      spctl --assess --type execute --verbose=2 "$TARGET"
    fi
    ;;
  dmg)
    [ -f "$TARGET" ] || { echo "error: $TARGET not found" >&2; exit 1; }
    echo "==> Signing $(basename "$TARGET")"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$TARGET"
    if [ "${NOTARIZE:-1}" = 1 ]; then
      notarize "$TARGET"
      xcrun stapler staple "$TARGET"
      spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET"
    fi
    ;;
  *)
    echo "usage: sign-and-notarize.sh app|dmg PATH" >&2
    exit 2 ;;
esac
