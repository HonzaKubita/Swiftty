#!/bin/bash
# Builds Swiftty.app, signs it with Developer ID, has Apple notarize it, staples
# the ticket, signs the update for Sparkle, writes appcast.xml, and publishes a
# GitHub release with both.
#
# Signing and notarization use the Apple ID signed into Xcode (Settings › Accounts),
# so no passwords are needed here. The Sparkle update key lives in your login
# keychain (created once with .build/artifacts/sparkle/Sparkle/bin/generate_keys).
#
# Usage: scripts/release.sh            # version from ./VERSION
#        PUBLISH=0 scripts/release.sh  # build and notarize, don't publish
#        TEAM_ID=XXXXXXXXXX scripts/release.sh
set -euo pipefail

TEAM_ID="${TEAM_ID:-HKN7A63ZT3}" # Ceska IT Akademie, z.s.
DEV_IDENTITY="${DEV_IDENTITY:-Apple Development: Honza Kubita (V28CV44XKG)}"
REPO="HonzaKubita/Swiftty"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/Swiftty.xcarchive"
APP="$OUT/notarized/Swiftty.app"
DIST="$ROOT/dist"
ZIP="$DIST/Swiftty-$VERSION.zip"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

rm -rf "$OUT"
mkdir -p "$OUT" "$DIST"

echo "› Building Swiftty $VERSION"
"$ROOT/scripts/bundle.sh" release >/dev/null
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$ROOT/build/Swiftty.app/Contents/Info.plist")

echo "› Archiving"
mkdir -p "$ARCHIVE/Products/Applications"
ditto "$ROOT/build/Swiftty.app" "$ARCHIVE/Products/Applications/Swiftty.app"
# Xcode re-signs everything with Developer ID on export; it needs a team-signed,
# hardened-runtime app to start from.
codesign --force --deep --options runtime --timestamp=none --sign "$DEV_IDENTITY" \
    "$ARCHIVE/Products/Applications/Swiftty.app"
cat > "$ARCHIVE/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ApplicationProperties</key>
    <dict>
        <key>ApplicationPath</key><string>Applications/Swiftty.app</string>
        <key>Architectures</key><array><string>arm64</string></array>
        <key>CFBundleIdentifier</key><string>io.github.honzakubita.Swiftty</string>
        <key>CFBundleShortVersionString</key><string>$VERSION</string>
        <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
        <key>SigningIdentity</key><string>$DEV_IDENTITY</string>
        <key>Team</key><string>$TEAM_ID</string>
    </dict>
    <key>ArchiveVersion</key><integer>2</integer>
    <key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
    <key>Name</key><string>Swiftty</string>
    <key>SchemeName</key><string>Swiftty</string>
</dict>
</plist>
EOF

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>destination</key><string>upload</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
EOF

echo "› Signing with Developer ID and sending to Apple for notarization"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/upload" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates

echo "› Waiting for notarization (usually a few minutes)"
for attempt in $(seq 1 40); do
    if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUT/notarized" \
        > "$OUT/notarization.log" 2>&1; then
        break
    fi
    if [ "$attempt" -eq 40 ]; then
        echo "Notarization didn't finish in 20 minutes:" >&2
        cat "$OUT/notarization.log" >&2
        exit 1
    fi
    sleep 30
done

echo "› Verifying"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
codesign --verify --strict --deep "$APP"

echo "› Packaging"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "› Signing the update for Sparkle"
SIGNATURE_ATTRS=$("$SPARKLE_BIN/sign_update" "$ZIP")   # sparkle:edSignature="…" length="…"
URL="https://github.com/$REPO/releases/download/v$VERSION/Swiftty-$VERSION.zip"
cat > "$DIST/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Swiftty</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Swiftty $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE_ATTRS/>
    </item>
  </channel>
</rss>
EOF

echo "› Built $ZIP and $DIST/appcast.xml"
if [ "${PUBLISH:-1}" = "1" ]; then
    NOTES="${NOTES:-Swiftty $VERSION}"
    gh release create "v$VERSION" "$ZIP" "$DIST/appcast.xml" --repo "$REPO" --title "Swiftty $VERSION" --notes "$NOTES"
    echo "› Published https://github.com/$REPO/releases/tag/v$VERSION"
fi
