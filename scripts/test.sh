#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/prepare-db.sh
xcrun swiftc -swift-version 5 -module-cache-path build/module-cache \
  -target "$(uname -m)-apple-macos27.0" -I build/unread-cmodule -L "$SQLCIPHER_PREFIX/lib" \
  Sources/Core.swift Sources/ChatReader.swift Sources/Database/*.swift \
  Diagnostics/Unread/SelfTests.swift Tests/CoreTests.swift Tests/EnergyTests.swift build/IdentityScan.o -lsqlcipher -o build/core-tests
build/core-tests
