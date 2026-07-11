#!/bin/zsh
# Builds Progresso.app (release) into the project root and installs it to /Applications.
set -e
cd "$(dirname "$0")"

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
swift build -c release

APP=Progresso.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BIN=$(swift build -c release --show-bin-path)/Progresso
cp "$BIN" "$APP/Contents/MacOS/Progresso"

# App icon: compile the Icon Composer bundle (Progresso.icon) if present.
if [ -d Progresso.icon ]; then
    ICONTMP=$(mktemp -d)
    xcrun actool Progresso.icon --compile "$ICONTMP" \
        --platform macosx --minimum-deployment-target 14.0 \
        --app-icon Progresso \
        --output-partial-info-plist "$ICONTMP/partial.plist" > /dev/null
    cp "$ICONTMP/Assets.car" "$APP/Contents/Resources/" 2>/dev/null || true
    cp "$ICONTMP/Progresso.icns" "$APP/Contents/Resources/" 2>/dev/null || true
    rm -rf "$ICONTMP"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.cj.progresso</string>
    <key>CFBundleName</key><string>Progresso</string>
    <key>CFBundleExecutable</key><string>Progresso</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.3</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>Progresso</string>
    <key>CFBundleIconName</key><string>Progresso</string>
</dict>
</plist>
PLIST

# Keep the installed copy in /Applications current so there's never a stale fork.
# Also retire the pre-rename ClientTracker.app installs.
rm -rf /Applications/ClientTracker.app ./ClientTracker.app
rm -rf /Applications/Progresso.app
ditto "$APP" /Applications/Progresso.app
echo "Installed /Applications/Progresso.app"
echo "Built $PWD/$APP"
