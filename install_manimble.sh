#!/bin/bash
# Install Manimble's Python and rendering dependencies, then build the app.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

"$ROOT/setup_python_env.sh"

"$ROOT/apps/macos/tools/make_signing_identity.sh"
"$ROOT/apps/macos/build_app.sh"
APP_DEST="$HOME/Applications/Manimble.app"
mkdir -p "$HOME/Applications"
rm -rf "$APP_DEST"
ditto "$ROOT/apps/macos/Manimble.app" "$APP_DEST"
# The source checkout may be inside Dropbox, whose package attributes confuse
# Launch Services when it tries to start the app from there.
xattr -cr "$APP_DEST"
codesign --force --deep --sign - "$APP_DEST" >/dev/null
echo "Manimble is installed at $APP_DEST"
mkdir -p "$HOME/.local/bin"
install -m 755 "$ROOT/manimbler" "$HOME/.local/bin/manimbler"
echo "manimbler is installed at $HOME/.local/bin/manimbler"
