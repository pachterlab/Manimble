#!/bin/bash
# Package Manimble.app as a drag-to-Applications disk image.
#
#   apps/macos/make_dmg.sh [app] [out.dmg]    (defaults: apps/macos/Manimble.app, apps/macos/.build/Manimble-macOS.dmg)
#
# Python and LaTeX are not inside: on first launch the app's setup window offers to install whichever of them
# the Mac lacks (install_dependencies.sh).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
APP="${1:-$ROOT/Manimble.app}"
OUT="${2:-$ROOT/.build/Manimble-macOS.dmg}"
mkdir -p "$(dirname "$OUT")"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Manimble.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname Manimble -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT"

SIGN_ID="${MANIMBLE_SIGN_IDENTITY:-}"
if [[ "$SIGN_ID" == "Developer ID Application"* ]]; then
  codesign -s "$SIGN_ID" --timestamp "$OUT"
fi
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
