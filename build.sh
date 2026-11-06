#!/bin/bash
# Build MeetNote.app from the Swift package (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/MeetNote.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/MeetNote" "$APP/Contents/MacOS/MeetNote"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with your Apple Development certificate so macOS remembers the permissions between builds.
# Falls back to an ad-hoc signature (permissions reset on every rebuild) if no certificate exists.
IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk '{print $2}')
if [ -n "$IDENTITY" ]; then
    echo "Signing with certificate $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "No Apple Development certificate found, using ad-hoc signature"
    codesign --force --deep --sign - "$APP"
fi

echo "Built: $(pwd)/$APP"
echo "Run it with:  open \"$(pwd)/$APP\""
