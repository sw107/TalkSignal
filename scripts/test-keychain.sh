#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/keychain-tests/IdentityCacheProbe.app
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>io.github.sw107.TalkSignal.IdentityCacheTest</string><key>CFBundleExecutable</key><string>IdentityCacheProbe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
xcrun swiftc -module-cache-path build/module-cache Sources/Database/IdentityCache.swift Tests/IdentityCacheProbe.swift -o "$APP/Contents/MacOS/IdentityCacheProbe"
codesign --force --sign - --entitlements Resources/TalkSignal.entitlements "$APP"
TASK_CACHE_SERVICE="io.github.sw107.TalkSignal.synthetic-cache-test.$(uuidgen)"
"$APP/Contents/MacOS/IdentityCacheProbe" "$TASK_CACHE_SERVICE" seed
"$APP/Contents/MacOS/IdentityCacheProbe" "$TASK_CACHE_SERVICE" verify
