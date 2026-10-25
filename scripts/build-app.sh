#!/usr/bin/env bash
# Builds build/Fan Control.app (release, ad-hoc signed) with fanctl inside it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Fan Control.app"
swift build -c release --product FanControl
swift build -c release --product fanctl
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/FanControl" "$APP/Contents/MacOS/FanControl"
cp "$BIN/fanctl" "$APP/Contents/Resources/fanctl"

if [ ! -f build/AppIcon.icns ]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Fan Control</string>
  <key>CFBundleDisplayName</key><string>Fan Control</string>
  <key>CFBundleIdentifier</key><string>com.xocode.fancontrol</string>
  <key>CFBundleExecutable</key><string>FanControl</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/Resources/fanctl"
codesign --force --sign - "$APP"
echo "built $APP"
