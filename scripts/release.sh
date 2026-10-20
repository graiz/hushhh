#!/usr/bin/env bash
# Builds a signed, notarized Hushhh DMG with a drag-to-Applications layout:
#
#   scripts/release.sh            → build/release/Hushhh-<version>.dmg
#
# Needs: Xcode signed in to an Apple Developer account whose team is set in
# Config/Local.xcconfig (DEVELOPMENT_TEAM), and `brew install create-dmg`.
# Xcode creates the Developer ID certificate and submits to Apple's notary
# service with that account, so no separate notarization password is needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' "$ROOT/Config/Local.xcconfig" 2>/dev/null | tr -d ' ')
[ -n "$TEAM" ] || { echo "error: set DEVELOPMENT_TEAM in Config/Local.xcconfig" >&2; exit 1; }
command -v create-dmg >/dev/null || { echo "error: brew install create-dmg" >&2; exit 1; }

cd "$ROOT"
xcodegen generate >/dev/null
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml)
rm -rf "$OUT" && mkdir -p "$OUT"

options() {   # options <destination>
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
  <key>destination</key><string>$1</string>
</dict></plist>
PLIST
}

echo "==> Archiving Hushhh $VERSION"
xcodebuild -project Hushhh.xcodeproj -scheme Hushhh -configuration Release \
  -archivePath "$OUT/Hushhh.xcarchive" -allowProvisioningUpdates archive -quiet

echo "==> Uploading to Apple's notary service"
options upload > "$OUT/ExportOptions.plist"
xcodebuild -exportArchive -archivePath "$OUT/Hushhh.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/upload" -allowProvisioningUpdates -quiet

echo "==> Waiting for notarization"
for attempt in $(seq 1 60); do
  if xcodebuild -exportNotarizedApp -archivePath "$OUT/Hushhh.xcarchive" -exportPath "$OUT/notarized" >"$OUT/notarize.log" 2>&1; then
    break
  fi
  [ "$attempt" = 60 ] && { echo "error: notarization didn't finish; see $OUT/notarize.log" >&2; exit 1; }
  sleep 30
done
APP="$OUT/notarized/Hushhh.app"
xcrun stapler validate "$APP"
spctl -a -t exec "$APP"

echo "==> Building the DMG"
swift "$ROOT/scripts/dmg-background.swift" "$OUT" >/dev/null
tiffutil -cathidpicheck "$OUT/background.png" "$OUT/background@2x.png" -out "$OUT/background.tiff" >/dev/null
mkdir -p "$OUT/dmg-source" && cp -R "$APP" "$OUT/dmg-source/"
# Signing the DMG itself needs a Developer ID certificate in the keychain. Xcode's
# cloud-managed certificate can't be used here; that's fine, because Gatekeeper checks
# the app inside, which is signed, notarized and stapled.
IDENTITY=$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .*($TEAM)\)\".*/\1/p" | head -1)
SIGN_ARGS=()
if [ -n "$IDENTITY" ]; then SIGN_ARGS=(--codesign "$IDENTITY"); else echo "    (no local Developer ID certificate; the DMG is unsigned, the app inside is notarized)"; fi
DMG="$OUT/Hushhh-$VERSION.dmg"
create-dmg \
  --volname "Hushhh" \
  --volicon "$APP/Contents/Resources/AppIcon.icns" \
  --background "$OUT/background.tiff" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --text-size 13 \
  --icon "Hushhh.app" 170 205 \
  --hide-extension "Hushhh.app" \
  --app-drop-link 490 205 \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
  "$DMG" "$OUT/dmg-source" >/dev/null

[ -n "$IDENTITY" ] && codesign --verify --verbose=1 "$DMG"
echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1))"
