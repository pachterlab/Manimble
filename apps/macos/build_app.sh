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
# Build a universal binary (Apple Silicon + Intel): one SwiftPM build per architecture, joined
# with lipo. (`swift build --arch a --arch b` would hand the build to Xcode's build system, which
# fails on SwiftTerm's build-tool plugin.) MANIMBLE_ARCHS="arm64" or "x86_64" builds one slice.
MANIMBLE_ARCHS="${MANIMBLE_ARCHS:-arm64 x86_64}"
SLICES=()
for arch in $MANIMBLE_ARCHS; do
  SWIFT_ARGS=(-c release --triple "$arch-apple-macosx13.0"
    --skip-update --force-resolved-versions
    --cache-path "$ROOT/.build/swift-cache"
    --config-path "$ROOT/.build/swift-config"
    --security-path "$ROOT/.build/swift-security")
  swift build "${SWIFT_ARGS[@]}"
  SLICES+=("$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)/Manimble")
done
mkdir -p "$ROOT/.build/universal"
lipo -create "${SLICES[@]}" -output "$ROOT/.build/universal/Manimble"
VERSION="$(cat "$ROOT/../../VERSION")"
APP="$ROOT/Manimble.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/universal/Manimble" "$APP/Contents/MacOS/Manimble"
rsync -a --exclude __pycache__ "$ROOT/../../engine/" "$APP/Contents/Resources/engine/"
install -m 755 "$ROOT/install_dependencies.sh" "$APP/Contents/Resources/install_dependencies.sh"
cp assets/Manimble.icns "$APP/Contents/Resources/manimble.icns"
cp assets/ManimbleDocument.icns "$APP/Contents/Resources/manimble-document.icns"
cp assets/biocartoon.png "$APP/Contents/Resources/biocartoon.png"
# the black-and-white logo comes from the biocartoon repository when it is checked out; else the copy in assets/
BIOCARTOON_REPO="${BIOCARTOON_REPO:-$HOME/code/biocartoon}"
if [ -f "$BIOCARTOON_REPO/brand/biocartoon-mono.svg" ]; then
  swift tools/import_biocartoon_logo.swift "$BIOCARTOON_REPO"
fi
cp assets/biocartoon-mono.png "$APP/Contents/Resources/biocartoon-mono.png"

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
<key>CFBundleVersion</key><string>$VERSION</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Manimble uses Keynote to import and export Keynote files.</string>
<key>CFBundleDocumentTypes</key><array>
  <dict><key>CFBundleTypeName</key><string>Manimble Project</string><key>CFBundleTypeRole</key><string>Editor</string>
    <key>CFBundleTypeIconFile</key><string>manimble-document</string>
    <key>LSHandlerRank</key><string>Owner</string><key>LSItemContentTypes</key><array><string>com.manimble.project</string></array></dict>
  <dict><key>CFBundleTypeName</key><string>Deck Folder</string><key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>public.folder</string></array></dict>
</array>
<key>UTExportedTypeDeclarations</key><array>
  <dict><key>UTTypeIdentifier</key><string>com.manimble.project</string><key>UTTypeDescription</key><string>Manimble Project</string>
    <key>UTTypeIconFile</key><string>manimble-document</string>
    <key>UTTypeConformsTo</key><array><string>public.zip-archive</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>manimble</string></array></dict></dict>
</array>
</dict></plist>
PL
# Sign with a stable local identity when one exists (tools/make_signing_identity.sh).
# macOS ties folder-access grants (Desktop, Documents, ...) to the signature;
# an ad-hoc signature changes on every build, so each rebuild would re-prompt.
# A "Developer ID Application" identity (release builds) also gets the hardened runtime, a secure timestamp
# and the entitlements Apple's notarization requires, and a failure stops the build instead of falling back.
SIGN_ID="${MANIMBLE_SIGN_IDENTITY:-Manimble Local Signing}"
if [[ "$SIGN_ID" == "Developer ID Application"* ]]; then
  codesign -s "$SIGN_ID" --force --options runtime --timestamp --entitlements "$ROOT/Manimble.entitlements" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
elif security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
  codesign -s "$SIGN_ID" --force "$APP" >/dev/null 2>&1 || codesign -s - --force "$APP" >/dev/null 2>&1 || true
else
  codesign -s - --force "$APP" >/dev/null 2>&1 || true
fi
echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/Manimble"))"
