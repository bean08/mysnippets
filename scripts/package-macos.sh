#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="mysnippets"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
UNIVERSAL_BINARY="$MACOS_DIR/$APP_NAME"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
ARM_BINARY="$ROOT_DIR/.build/arm64-apple-macosx/release/$APP_NAME"
X64_BINARY="$ROOT_DIR/.build/x86_64-apple-macosx/release/$APP_NAME"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
VOL_NAME="$APP_NAME"

mkdir -p "$DIST_DIR"

swift build -c release --arch arm64
swift build -c release --arch x86_64

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

lipo -create "$ARM_BINARY" "$X64_BINARY" -output "$UNIVERSAL_BINARY"
chmod +x "$UNIVERSAL_BINARY"

cat > "$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>mysnippets</string>
  <key>CFBundleExecutable</key>
  <string>mysnippets</string>
  <key>CFBundleIdentifier</key>
  <string>com.local.mysnippets</string>
  <key>CFBundleName</key>
  <string>mysnippets</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR"

rm -f "$DMG_PATH"
hdiutil create -volname "$VOL_NAME" -srcfolder "$APP_DIR" -ov -format UDZO "$DMG_PATH"

echo "Created:"
echo "  $APP_DIR"
echo "  $DMG_PATH"
