#!/bin/bash
# Bundles the helper into a menu-bar .app (no Dock icon) so macOS can grant it
# Accessibility and register it as a login item. Needs only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product AssistantHelper
BIN="$(swift build -c release --show-bin-path)/AssistantHelper"
APP=.build/AssistantHelper.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AssistantHelper"
# Dependencies' resource bundles (e.g. NIO's privacy manifest) go where Bundle.module looks.
for bundle in "$(dirname "$BIN")"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
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
    <key>NSAppleEventsUsageDescription</key><string>Reads the front tab's URL so web work can match your Projects, and finds open actions in Apple Notes (Excluded folders are never read).</string>
    <key>NSScreenCaptureUsageDescription</key><string>Takes one screenshot of a window it can't place, to guess its Project. Never stored.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>Reads today's events so meetings can match your Projects.</string>
</dict>
</plist>
PLIST
# Ad-hoc signature: enough for a locally built, un-notarized app.
codesign --force --sign - "$APP"
echo "Built $APP — move it to /Applications, open it, then choose Open at Login from its menu."
