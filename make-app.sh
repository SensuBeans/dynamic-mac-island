#!/bin/zsh
# Build a release binary and wrap it in "Dynamic Island.app" (in this directory).
set -e
cd "$(dirname "$0")"

swift build -c release

APP="Dynamic Island.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/Notchbook "$APP/Contents/MacOS/Notchbook"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.sensubeans.notchbook</string>
    <key>CFBundleName</key><string>Dynamic Island</string>
    <key>CFBundleExecutable</key><string>Notchbook</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Notchbook controls Music/Spotify playback and system toggles.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>The media tab's sound wave moves with the audio that is actually playing.</string>
    <key>NSCameraUsageDescription</key>
    <string>The Mirror tab shows your webcam so you can check yourself before a call.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>The Calendar tab shows your upcoming events.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>The Calendar tab shows your upcoming events.</string>
</dict>
</plist>
PLIST

# Stable identity so TCC permission grants (camera/calendar/automation)
# survive rebuilds; falls back to ad-hoc if the cert is missing.
if security find-identity -v -p codesigning | grep -q "Notchbook Signing"; then
    codesign --force --sign "Notchbook Signing" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built $PWD/$APP — open it, or move it to /Applications and add to Login Items."
