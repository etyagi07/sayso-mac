#!/usr/bin/env bash
# Build Sayso.app from the Swift package.
#   ./build.sh            -> app/build/Sayso.app, running this checkout's engine
#   DIST=1 APP=build/dist/Sayso.app ./build.sh
#                         -> the panel alone; package.sh adds the engine
# Run it:
#   open build/Sayso.app                      (live: real orders)
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=${APP:-build/Sayso.app}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SaysoFace "$APP/Contents/MacOS/Sayso"

# The icon is drawn by the app itself (Snapshot.swift, AppIconView).
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
.build/release/SaysoFace --icon build/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# A development build runs this checkout's engine (sayso/.venv). A packaged
# build has no such key and runs the engine bundled into it.
BUILD="$(git -C .. rev-parse --short HEAD 2>/dev/null || echo dev)$([ -n "$(git -C .. status --porcelain 2>/dev/null)" ] && echo + || true)"
PROJECT_KEY=""
if [ "${DIST:-}" != "1" ]; then
  PROJECT_KEY="<key>SaysoProject</key><string>$(cd .. && pwd)</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>             <string>Sayso</string>
  <key>CFBundleDisplayName</key>      <string>Sayso</string>
  <key>CFBundleIdentifier</key>       <string>com.ekanshtyagi.sayso</string>
  <key>CFBundleExecutable</key>       <string>Sayso</string>
  <key>CFBundleIconFile</key>         <string>AppIcon</string>
  <key>CFBundlePackageType</key>      <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key>          <string>$BUILD</string>
  <key>LSMinimumSystemVersion</key>   <string>14.0</string>
  <!-- no dock icon, no menu bar: the floating panel is the whole app -->
  <key>LSUIElement</key>              <true/>
  <!-- the engine records the push-to-talk utterance; audio never leaves the Mac -->
  <key>NSMicrophoneUsageDescription</key>
  <string>Sayso listens only after you press push-to-talk, and speech is recognised on this Mac.</string>
  $PROJECT_KEY
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
