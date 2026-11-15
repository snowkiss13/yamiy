#!/bin/bash
# Builds build/Yamiy.app with nothing but the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Yamiy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/Yamiy" Sources/main.swift \
    -framework AppKit -framework CoreGraphics -framework ServiceManagement
cp Info.plist "$APP/Contents/Info.plist"
echo "Built $APP"
