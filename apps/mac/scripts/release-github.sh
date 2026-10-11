#!/bin/bash
# Builds Screens, signs it with the Developer ID, packages a DMG and publishes
# it as a GitHub release — installed copies of Screens update themselves from
# the latest release.
#
#   apps/mac/scripts/release-github.sh            # build + DMG only (dry run)
#   apps/mac/scripts/release-github.sh --publish  # also create the GitHub release
#
# Notarizes when a `notarization-profile` exists in the Keychain
# (xcrun notarytool store-credentials notarization-profile …).
set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"
MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${SCREENS_REPO:-cowens-cmyk/screens}"
IDENTITY="${DEVELOPER_ID_IDENTITY:-Developer ID Application: Hope Church JC (TCAQTA64TB)}"
WORK="${TMPDIR:-/tmp}/screens-release"
DERIVED="$WORK/deriveddata"
APP="$DERIVED/Build/Products/Release/Screens.app"
PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1

VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "$MAC_DIR/project.yml")"
BUILD_NUMBER="$(git -C "$MAC_DIR" rev-list --count HEAD)"
echo "==> Screens $VERSION (build $BUILD_NUMBER)"

if [ $PUBLISH = 1 ] && gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "v$VERSION is already released — bump MARKETING_VERSION in apps/mac/project.yml" >&2
  exit 1
fi

# Build outside iCloud-synced folders: Finder metadata breaks codesign.
rm -rf "$WORK" && mkdir -p "$WORK"
xcodegen generate --spec "$MAC_DIR/project.yml" --project "$MAC_DIR" | tail -1
xcodebuild -project "$MAC_DIR/MxUSlides.xcodeproj" -scheme MxUSlides -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build | tail -3

echo "==> Signing with $IDENTITY"
for HELPER in "$APP"/Contents/XPCServices/*.xpc; do
  codesign --force --options runtime --timestamp \
    --entitlements "$MAC_DIR/Signing/Helper.entitlements" --sign "$IDENTITY" "$HELPER"
done
codesign --force --options runtime --timestamp \
  --entitlements "$MAC_DIR/Signing/MxUSlides.entitlements" --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

NOTARIZE=0
if xcrun notarytool history --keychain-profile notarization-profile >/dev/null 2>&1; then
  NOTARIZE=1
  echo "==> Notarizing the app"
  ditto -c -k --keepParent "$APP" "$WORK/app.zip"
  xcrun notarytool submit "$WORK/app.zip" --keychain-profile notarization-profile --wait
  xcrun stapler staple "$APP"
else
  echo "==> No notarization-profile in the Keychain — skipping notarization"
fi

echo "==> Building the DMG"
DMG="$WORK/Screens-$VERSION.dmg"
mkdir -p "$WORK/stage"
ditto "$APP" "$WORK/stage/Screens.app"
ln -s /Applications "$WORK/stage/Applications"
hdiutil create -volname "Screens" -srcfolder "$WORK/stage" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
if [ $NOTARIZE = 1 ]; then
  xcrun notarytool submit "$DMG" --keychain-profile notarization-profile --wait
  xcrun stapler staple "$DMG"
fi
mkdir -p "$MAC_DIR/build/dist"
cp "$DMG" "$MAC_DIR/build/dist/"
echo "DMG: $MAC_DIR/build/dist/Screens-$VERSION.dmg"

if [ $PUBLISH = 1 ]; then
  echo "==> Publishing v$VERSION to $REPO"
  PREVIOUS="$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null || true)"
  RANGE="${PREVIOUS:+$PREVIOUS..}HEAD"
  git -C "$MAC_DIR" fetch -q --tags -c credential.helper= -c 'credential.helper=!gh auth git-credential' origin 2>/dev/null || true
  NOTES="$(git -C "$MAC_DIR" log --pretty='- %s' "$RANGE" 2>/dev/null | head -40)"
  # Push with the gh login so a different Keychain git credential can't get in the way.
  git -C "$MAC_DIR" -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin HEAD:main
  gh release create "v$VERSION" "$MAC_DIR/build/dist/Screens-$VERSION.dmg" \
    --repo "$REPO" --target "$(git -C "$MAC_DIR" rev-parse HEAD)" \
    --title "Screens $VERSION" --notes "$NOTES"
  git -C "$MAC_DIR" fetch -q --tags -c credential.helper= -c 'credential.helper=!gh auth git-credential' origin 2>/dev/null || true
fi
