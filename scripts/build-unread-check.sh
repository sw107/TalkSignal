#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SQLCIPHER_PREFIX="$(/opt/homebrew/bin/brew --prefix sqlcipher)"
TASK_MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
APP=build/TalkSignalUnreadCheck.app
mkdir -p build/module-cache build/unread-cmodule "$APP/Contents/MacOS" "$APP/Contents/Resources"
TASK_SOURCE_DIR="$(pwd)/Diagnostics/Unread"
xcrun clang -O3 -c "$TASK_SOURCE_DIR/IdentityScan.c" -o build/IdentityScan.o
cat > build/unread-cmodule/module.modulemap <<EOF
module CSQLCipher [system] {
  header "$SQLCIPHER_PREFIX/include/sqlcipher/sqlite3.h"
  link "sqlcipher"
  export *
}
module IdentityScan {
  header "$TASK_SOURCE_DIR/IdentityScan.h"
  export *
}
EOF
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path build/module-cache \
  -target "$(uname -m)-apple-macos$TASK_MACOS_MAJOR.0" -I build/unread-cmodule -L "$SQLCIPHER_PREFIX/lib" \
  Diagnostics/Unread/*.swift build/IdentityScan.o -lsqlcipher -o "$APP/Contents/MacOS/TalkSignalUnreadCheck"
python3 - "${1:-}" "${2:-$(pwd)/build/unread-check-result.json}" "$TASK_MACOS_MAJOR.0" <<'PY'
import json, plistlib, sys
from pathlib import Path
bundle = Path('build/TalkSignalUnreadCheck.app/Contents')
info = {'CFBundleExecutable':'TalkSignalUnreadCheck', 'CFBundleIdentifier':'io.github.sw107.TalkSignalUnreadCheck',
        'CFBundleName':'TalkSignalUnreadCheck', 'CFBundleDisplayName':'TalkSignal Unread Check',
        'CFBundlePackageType':'APPL', 'CFBundleShortVersionString':'0.1.0', 'CFBundleVersion':'1',
        'LSMinimumSystemVersion':sys.argv[3],'NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication'}
(bundle/'Info.plist').write_bytes(plistlib.dumps(info))
(bundle/'Resources/Config.json').write_text(json.dumps({'target':sys.argv[1],'reportPath':sys.argv[2]},ensure_ascii=False))
PY
codesign --force --sign - --identifier io.github.sw107.TalkSignalUnreadCheck "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/TalkSignalUnreadCheck" --self-test
printf '%s\n' "Built: $(pwd)/$APP"
