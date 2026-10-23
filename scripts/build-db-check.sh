#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache build/TalkSignalDBCheck.app/Contents/MacOS build/TalkSignalDBCheck.app/Contents/Resources
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path build/module-cache \
  -target "$(uname -m)-apple-macos13.0" Diagnostics/NotificationDBCheck.swift -lsqlite3 \
  -o build/TalkSignalDBCheck.app/Contents/MacOS/TalkSignalDBCheck
python3 - "${1:-}" "${2:-$(pwd)/build/dbcheck-result.json}" <<'PY'
import json, plistlib, sys
from pathlib import Path
bundle = Path('build/TalkSignalDBCheck.app/Contents')
info = {'CFBundleExecutable':'TalkSignalDBCheck', 'CFBundleIdentifier':'io.github.sw107.TalkSignalDBCheck',
        'CFBundleName':'TalkSignalDBCheck', 'CFBundleDisplayName':'TalkSignal DB Check',
        'CFBundlePackageType':'APPL', 'CFBundleShortVersionString':'0.1.0', 'CFBundleVersion':'1',
        'LSMinimumSystemVersion':'13.0', 'NSHighResolutionCapable':True, 'NSPrincipalClass':'NSApplication'}
(bundle/'Info.plist').write_bytes(plistlib.dumps(info))
(bundle/'Resources/DiagnosticConfig.json').write_text(json.dumps({'target':sys.argv[1], 'reportPath':sys.argv[2]},ensure_ascii=False))
PY
codesign --force --sign - --identifier io.github.sw107.TalkSignalDBCheck build/TalkSignalDBCheck.app
codesign --verify --deep --strict build/TalkSignalDBCheck.app
printf '%s\n' "Built: $(pwd)/build/TalkSignalDBCheck.app"
