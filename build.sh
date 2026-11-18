#!/bin/bash
# 编译出 MouseBattery.app（本机 macOS，需 Xcode Command Line Tools）
set -euo pipefail
cd "$(dirname "$0")"

APP="MouseBattery.app"
swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macosx13.0" \
    -framework Cocoa -framework IOKit \
    -o /tmp/MouseBattery.bin MouseBattery.swift

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mv /tmp/MouseBattery.bin "$APP/Contents/MacOS/MouseBattery"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>MouseBattery</string>
    <key>CFBundleDisplayName</key>     <string>鼠标电量</string>
    <key>CFBundleExecutable</key>      <string>MouseBattery</string>
    <key>CFBundleIdentifier</key>      <string>local.mousebattery</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# 本地 ad-hoc 签名，避免每次打开都被 Gatekeeper 追问
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP — 运行: open $APP"
