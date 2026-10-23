#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/prepare-db.sh
# Stage separately: do not overwrite the running app or its authorization during compilation.
APP=build/staging/TalkSignal.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
xcrun swiftc -swift-version 5 -O -module-cache-path build/module-cache \
  -target "$(uname -m)-apple-macos27.0" -I build/unread-cmodule -L "$SQLCIPHER_PREFIX/lib" \
  Sources/Core.swift Sources/ChatReader.swift Sources/Database/*.swift Sources/App.swift build/IdentityScan.o \
  -lsqlcipher -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP/Contents/MacOS/TalkSignal"
CRYPTO_PREFIX="$(/opt/homebrew/bin/brew --prefix openssl@4)"
cp "$SQLCIPHER_PREFIX/lib/libsqlcipher.dylib" "$APP/Contents/Frameworks/"
cp "$CRYPTO_PREFIX/lib/libcrypto.4.dylib" "$APP/Contents/Frameworks/"
chmod u+w "$APP/Contents/Frameworks/"*.dylib
install_name_tool -change "$SQLCIPHER_PREFIX/lib/libsqlcipher.dylib" @rpath/libsqlcipher.dylib "$APP/Contents/MacOS/TalkSignal"
install_name_tool -id @rpath/libsqlcipher.dylib -change "$CRYPTO_PREFIX/lib/libcrypto.4.dylib" @loader_path/libcrypto.4.dylib "$APP/Contents/Frameworks/libsqlcipher.dylib"
install_name_tool -id @rpath/libcrypto.4.dylib "$APP/Contents/Frameworks/libcrypto.4.dylib"
cp Sources/Database/THIRD_PARTY_LICENSE.txt "$APP/Contents/Resources/KakaoCore-LICENSE.txt"
cp "$SQLCIPHER_PREFIX/LICENSE.txt" "$APP/Contents/Resources/SQLCipher-LICENSE.txt"
cp "$SQLCIPHER_PREFIX/LICENSE.md" "$APP/Contents/Resources/SQLCipher-LICENSE.md"
cp "$CRYPTO_PREFIX/LICENSE.txt" "$APP/Contents/Resources/OpenSSL-LICENSE.txt"
cp Resources/Info.plist "$APP/Contents/Info.plist"
for lib in "$APP/Contents/Frameworks/"*.dylib; do codesign --force --sign - "$lib"; done
codesign --force --sign - --entitlements Resources/TalkSignal.entitlements --identifier io.github.sw107.TalkSignal "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "Built (staged): $(pwd)/$APP" "Quit TalkSignal before copying this app to build/TalkSignal.app."
