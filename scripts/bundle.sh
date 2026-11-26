#!/usr/bin/env bash
# Build Swiftty and wrap it in a .app bundle at build/Swiftty.app.
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c "$CONFIG" --product Swiftty
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/Swiftty.app"
VERSION="$(cat "$ROOT/VERSION")"
# Sparkle compares build numbers: one per commit, always increasing.
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Swiftty" "$APP/Contents/MacOS/Swiftty"
cp -R "$BIN/Swiftty_Swiftty.bundle" "$APP/Contents/Resources/"
# Sparkle, for in-app updates.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# App icon: Resources/AppIcon.png (from scripts/make-icon.swift) -> AppIcon.icns.
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Swiftty</string>
  <key>CFBundleDisplayName</key><string>Swiftty</string>
  <key>CFBundleIdentifier</key><string>io.github.honzakubita.Swiftty</string>
  <key>CFBundleExecutable</key><string>Swiftty</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>SUFeedURL</key><string>https://github.com/HonzaKubita/Swiftty/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>aC5iLXvL1aIvQsT6korJy9Y/IPqhU506CcQ4HMbRrzk=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
