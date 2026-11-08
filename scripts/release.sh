#!/bin/bash
# Builds QuickGif, signs it with Developer ID, notarizes and staples it, zips it,
# and publishes the zip to a GitHub release tagged v<MARKETING_VERSION>.
#
# One-time setup (stores your Apple notarization credentials in the keychain):
#   xcrun notarytool store-credentials QuickGif --apple-id <you@example.com> --team-id UWZAXPV35R
#
# Usage:
#   scripts/release.sh            build, notarize, publish
#   scripts/release.sh --dry-run  build and sign only (no notarization, no upload)
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-QuickGif}"
TEAM="UWZAXPV35R"
DRY_RUN=0; [ "${1:-}" = "--dry-run" ] && DRY_RUN=1

VERSION=$(xcodebuild -project QuickGif.xcodeproj -scheme QuickGif -configuration Release -showBuildSettings 2>/dev/null \
  | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
TAG="v$VERSION"
OUT=build/release
APP="$OUT/QuickGif.app"
ZIP="$OUT/QuickGif.zip"

echo "==> Building QuickGif $VERSION (universal, Developer ID)"
rm -rf "$OUT" build/DerivedData-release
mkdir -p "$OUT"
xcodebuild -project QuickGif.xcodeproj -scheme QuickGif -configuration Release \
  -derivedDataPath build/DerivedData-release -destination 'generic/platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO -quiet build
ditto build/DerivedData-release/Build/Products/Release/QuickGif.app "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E 'Authority=Developer ID Application|flags=.*runtime|Timestamp'
lipo -archs "$APP/Contents/MacOS/QuickGif"

if [ "$DRY_RUN" = 1 ]; then
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "==> Dry run: signed but not notarized: $ZIP"
  exit 0
fi

echo "==> Notarizing (usually 1-5 minutes)"
ditto -c -k --keepParent "$APP" "$OUT/upload.zip"
xcrun notarytool submit "$OUT/upload.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm "$OUT/upload.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Publishing $TAG"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP" --clobber
else
  gh release create "$TAG" "$ZIP" --title "QuickGif $VERSION" \
    --notes "Download **QuickGif.zip**, unzip it and move QuickGif to Applications. Signed and notarized; requires macOS 14 or later."
fi
echo "==> Done: $(gh release view "$TAG" --json url --jq .url)"
