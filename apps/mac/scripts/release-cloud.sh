#!/bin/bash
# Builds Screens and signs it with Hope Church's Developer ID through Xcode's
# cloud signing, for a Mac where Xcode is signed in to the team (an Admin
# is enough) but no Developer ID certificate is in the Keychain. Packages a
# DMG and, with --publish, makes it a GitHub release. Not notarized: the
# app's updater checks the Developer ID signature, and its downloads aren't
# quarantined, so Gatekeeper doesn't stop them.
#
#   apps/mac/scripts/release-cloud.sh            # build, sign, DMG
#   apps/mac/scripts/release-cloud.sh --publish  # and the GitHub release
#
# Needs xcodegen, gh (signed in) and the ProPresenter types
# (generate-propresenter-proto.sh, run with bash). RELEASE_WORK sets where
# it builds (default $TMPDIR/screens-release-cloud).
set -euo pipefail
MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${SCREENS_REPO:-cowens-cmyk/screens}"
TEAM="${DEVELOPER_TEAM:-TCAQTA64TB}"
WORK="${RELEASE_WORK:-${TMPDIR:-/tmp}/screens-release-cloud}"
PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1
VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "$MAC_DIR/project.yml")"
BUILD_NUMBER="$(git -C "$MAC_DIR" rev-list --count HEAD)"
COMMIT="$(git -C "$MAC_DIR" rev-parse --short=10 HEAD)"
echo "==> Screens $VERSION (build $BUILD_NUMBER, $COMMIT)"
if [ $PUBLISH = 1 ] && gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "v$VERSION is already released: bump MARKETING_VERSION in apps/mac/project.yml" >&2
  exit 1
fi
if [ ! -d "$MAC_DIR/Packages/ProImport/Sources/ProImport/Generated" ]; then
  echo "ProPresenter import types missing: run apps/mac/scripts/generate-propresenter-proto.sh" >&2
  exit 1
fi
rm -rf "$WORK" && mkdir -p "$WORK"
rm -rf ~/Library/Caches/org.swift.swiftpm/manifests
xcodegen generate --spec "$MAC_DIR/project.yml" --project "$MAC_DIR" | tail -1
echo "==> Archiving"
xcodebuild -project "$MAC_DIR/MxUSlides.xcodeproj" -scheme MxUSlides -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$WORK/dd" -archivePath "$WORK/Screens.xcarchive" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CURRENT_PROJECT_VERSION="$BUILD_NUMBER" MXU_GIT_COMMIT="$COMMIT" \
  archive > "$WORK/archive.log" 2>&1 || { tail -20 "$WORK/archive.log"; exit 1; }
ARCHIVED="$WORK/Screens.xcarchive/Products/Applications/Screens.app"
# The export keeps each binary's entitlements and hardened runtime from its
# signature, so they're put on here as the Developer ID build needs them.
for HELPER in "$ARCHIVED"/Contents/XPCServices/*.xpc; do
  codesign --force --options runtime --entitlements "$MAC_DIR/Signing/Helper.entitlements" --sign - "$HELPER"
done
codesign --force --options runtime --entitlements "$MAC_DIR/Signing/MxUSlides.entitlements" --sign - "$ARCHIVED"
cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$TEAM</string>
<key>destination</key><string>export</string>
</dict></plist>
PLIST
echo "==> Signing with Developer ID (cloud)"
xcodebuild -exportArchive -archivePath "$WORK/Screens.xcarchive" -exportPath "$WORK/export" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" -allowProvisioningUpdates > "$WORK/export.log" 2>&1 \
  || { tail -20 "$WORK/export.log"; exit 1; }
APP="$WORK/export/Screens.app"
codesign --verify --strict --deep "$APP"
# What the updater checks (AppUpdater.teamIdentifier).
codesign -v -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" "$APP"
echo "==> Building the DMG"
DMG="$WORK/Screens-$VERSION.dmg"
mkdir -p "$WORK/stage"
ditto "$APP" "$WORK/stage/Screens.app"
ln -s /Applications "$WORK/stage/Applications"
hdiutil create -volname "Screens" -srcfolder "$WORK/stage" -ov -format UDZO "$DMG" >/dev/null
mkdir -p "$MAC_DIR/build/dist"
cp "$DMG" "$MAC_DIR/build/dist/"
echo "==> $DMG"
if [ $PUBLISH = 1 ]; then
  PREVIOUS="$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null || true)"
  NOTES="$WORK/notes.md"
  if [ -n "$PREVIOUS" ]; then git -C "$MAC_DIR" log "$PREVIOUS..HEAD" --format="- %s" > "$NOTES"; else echo "Screens $VERSION" > "$NOTES"; fi
  gh release create "v$VERSION" "$DMG" --repo "$REPO" --target "$(git -C "$MAC_DIR" rev-parse HEAD)" \
    --title "Screens $VERSION" --notes-file "$NOTES"
fi
