#!/bin/bash
# Builds a signed, notarized build/PowerCap-<version>.dmg ready to attach to a GitHub release.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in the login keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application).
#   2. Notarization credentials saved under the keychain profile "PowerCap":
#      xcrun notarytool store-credentials PowerCap --apple-id <email> --team-id <team id>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTARY_PROFILE="${POWERCAP_NOTARY_PROFILE:-PowerCap}"
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$ROOT/Resources/Info.plist")"
DMG="$ROOT/build/PowerCap-$VERSION.dmg"

IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
if [[ -z "$IDENTITY" ]]; then
    echo "No Developer ID Application certificate found. See the setup notes at the top of this script." >&2
    exit 1
fi

POWERCAP_SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/build.sh"

STAGING="$(mktemp -d)"
ditto "$ROOT/build/PowerCap.app" "$STAGING/PowerCap.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "PowerCap" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" > /dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

echo "$DMG"
