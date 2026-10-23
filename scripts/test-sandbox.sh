#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test -x build/staging/TalkSignal.app/Contents/MacOS/TalkSignal
python3 - <<'PY'
import plistlib, subprocess
from pathlib import Path
expected = plistlib.loads(Path('Resources/TalkSignal.entitlements').read_bytes())
actual = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', ':-', 'build/staging/TalkSignal.app'], stderr=subprocess.DEVNULL))
assert actual == expected == {
    'com.apple.security.app-sandbox': True,
    'com.apple.security.files.user-selected.read-only': True,
    'com.apple.security.files.bookmarks.app-scope': True,
}, 'Unexpected production entitlement'
PY
APP=build/privacy-tests/SandboxProbe.app
mkdir -p "$APP/Contents/MacOS" build/privacy-tests/fixture
printf 'synthetic fixture, no personal data\n' > build/privacy-tests/fixture/value.txt
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>io.github.sw107.TalkSignal.SandboxTest</string><key>CFBundleExecutable</key><string>SandboxProbe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
xcrun swiftc -swift-version 5 -module-cache-path build/module-cache Tests/SandboxProbe.swift -o "$APP/Contents/MacOS/SandboxProbe"
codesign --force --sign - --entitlements Resources/TalkSignal.entitlements "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/SandboxProbe" "$(pwd)/build/privacy-tests/fixture/value.txt"
if nm -u build/staging/TalkSignal.app/Contents/MacOS/TalkSignal | rg 'AXUIElement|AXIsProcessTrusted|CGEventPost|CGEventCreateKeyboard|task_for_pid|mach_vm_read|vm_read|ptrace'; then
  echo 'FAIL: forbidden UI automation or process memory symbol'; exit 1
fi
echo 'PASS: production entitlements deny synthetic unselected-file access and direct networking; main binary has no checked automation/process-memory symbols'
