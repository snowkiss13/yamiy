#!/bin/bash
# Builds build/Yamiy.app with nothing but the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Yamiy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/Yamiy" Sources/main.swift \
    -framework AppKit -framework CoreGraphics -framework ServiceManagement -framework IOKit
cp Info.plist "$APP/Contents/Info.plist"
# App icon: build AppIcon.icns from AppIcon.iconset when iconutil is available.
if command -v iconutil >/dev/null 2>&1 && [ -d AppIcon.iconset ]; then
    iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" AppIcon.iconset
fi
# Ad-hoc signature so the bundle is consistently signed on every machine.
codesign --force --deep -s - "$APP" 2>/dev/null || true
echo "Built $APP"
