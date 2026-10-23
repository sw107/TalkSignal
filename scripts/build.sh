#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache build/TalkSignal.app/Contents/MacOS build/TalkSignal.app/Contents/Resources
xcrun swiftc -swift-version 5 -O -module-cache-path build/module-cache \
  -target "$(uname -m)-apple-macos13.0" Sources/Core.swift Sources/ChatReader.swift Sources/App.swift \
  -o build/TalkSignal.app/Contents/MacOS/TalkSignal
cp Resources/Info.plist build/TalkSignal.app/Contents/Info.plist
codesign --force --sign - --identifier io.github.sw107.TalkSignal build/TalkSignal.app
codesign --verify --deep --strict build/TalkSignal.app
printf '%s\n' "Built: $(pwd)/build/TalkSignal.app"
