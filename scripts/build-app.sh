#!/bin/bash
# Bundles the helper into a menu-bar .app (no Dock icon) so macOS can grant it
# Accessibility and register it as a login item. Needs only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product AssistantHelper
BIN="$(swift build -c release --show-bin-path)/AssistantHelper"
APP=.build/AssistantHelper.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/AssistantHelper"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.dara.todo-agent.helper</string>
    <key>CFBundleName</key><string>AssistantHelper</string>
    <key>CFBundleExecutable</key><string>AssistantHelper</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# Ad-hoc signature: enough for a locally built, un-notarized app.
codesign --force --sign - "$APP"
echo "Built $APP — move it to /Applications, open it, then choose Open at Login from its menu."
