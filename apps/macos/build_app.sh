#!/bin/bash
# Build Manimble.app (native Swift + Metal) next to this script.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
# Prefer the complete Xcode toolchain when installed. The standalone Command
# Line Tools can lag behind the SDK shipped with macOS, which makes SwiftPM
# fail while compiling the package manifest.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Keep SwiftPM and Clang caches with the checkout so builds also work when the
# user's home cache directories are unavailable (for example, in restricted
# environments).
mkdir -p "$ROOT/.build/swift-cache" "$ROOT/.build/swift-config" \
  "$ROOT/.build/swift-security" "$ROOT/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
swift build -c release \
  --skip-update --force-resolved-versions \
  --cache-path "$ROOT/.build/swift-cache" \
  --config-path "$ROOT/.build/swift-config" \
  --security-path "$ROOT/.build/swift-security"
APP="$ROOT/Manimble.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Manimble "$APP/Contents/MacOS/Manimble"
rsync -a --exclude __pycache__ "$ROOT/../../engine/" "$APP/Contents/Resources/engine/"
cp assets/Manimble.icns "$APP/Contents/Resources/manimble.icns"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Manimble</string>
<key>CFBundleDisplayName</key><string>Manimble</string>
<key>CFBundleIdentifier</key><string>com.manimble.Manimble</string>
<key>CFBundleExecutable</key><string>Manimble</string>
<key>CFBundleIconFile</key><string>manimble</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>0.2.0</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Manimble uses Keynote to import and export Keynote files.</string>
</dict></plist>
PL
codesign -s - --force "$APP" >/dev/null 2>&1 || true
echo "built $APP"
