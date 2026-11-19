#!/bin/bash
# Builds build/TaskFerry.app from the Swift package and signs it.
#
# With an "Apple Development" certificate in your keychain the app gets a stable identity,
# so macOS remembers its Reminders permission and Keychain item across rebuilds.
# Without one it is signed ad hoc and macOS asks again after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product TaskFerry

APP="build/TaskFerry.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/TaskFerry" "$APP/Contents/MacOS/TaskFerry"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="$(security find-identity -v -p codesigning | grep 'Apple Development' | head -1 | awk '{print $2}' || true)"
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "No Apple Development certificate found; using an ad-hoc signature."
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP"
