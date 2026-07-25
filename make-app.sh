#!/bin/zsh
# Build a release binary and wrap it in "Dynamic Island.app" (in this directory).
set -e
cd "$(dirname "$0")"

swift build -c release

APP="Dynamic Island.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/Notchbook "$APP/Contents/MacOS/Notchbook"

mkdir -p "$APP/Contents/Resources"

# App icon. Regenerate with:  swift tools-makeicon.swift AppIcon.iconset \
#   && iconutil -c icns AppIcon.iconset -o AppIcon.icns && rm -rf AppIcon.iconset
if [[ -f AppIcon.icns ]]; then
    cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Static file server for the Servers tab, spawned as a detached child by
# LocalStarter. Without it, "static" entries cannot start.
cp Resources/_serve.py "$APP/Contents/Resources/_serve.py"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.sensubeans.notchbook</string>
    <key>CFBundleName</key><string>Dynamic Island</string>
    <key>CFBundleExecutable</key><string>Notchbook</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
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

# Stable identity so TCC permission grants (Accessibility/Automation/camera/
# calendar) survive rebuilds. macOS keys those grants to the bundle's
# designated requirement; an ad-hoc build's requirement is a bare cdhash that
# changes on every rebuild, so every rebuild would look like a new app and lose
# its grants. Signing with the self-signed "Notchbook Signing" cert AND pinning
# the identifier makes the requirement cert-anchored and identity-stable.
# Detect via find-certificate: find-identity misses login-keychain certs here.
IDENTIFIER="com.sensubeans.notchbook"
if security find-certificate -c "Notchbook Signing" >/dev/null 2>&1; then
    codesign --force --sign "Notchbook Signing" --identifier "$IDENTIFIER" "$APP"
    echo "Signed with 'Notchbook Signing'. Designated requirement:"
    codesign -dr - "$APP" 2>&1 | grep '^designated' || true
else
    echo "WARNING: 'Notchbook Signing' cert not found — falling back to ad-hoc."
    echo "         TCC grants will NOT survive rebuilds. Create the cert in"
    echo "         Keychain Access › Certificate Assistant (Code Signing type)."
    codesign --force --sign - --identifier "$IDENTIFIER" "$APP"
fi
echo "Built $PWD/$APP — open it, or move it to /Applications and add to Login Items."
