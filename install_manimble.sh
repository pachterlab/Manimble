#!/bin/bash
# Install Manimble's Python and rendering dependencies, then build the app.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required to install Manimble's macOS dependencies." >&2
  echo "Install Homebrew, then run this script again." >&2
  exit 1
fi

BREW_PREFIX="$(brew --prefix)"
export PATH="$BREW_PREFIX/bin:/usr/local/bin:/Library/TeX/texbin:$PATH"

if ! command -v python3.11 >/dev/null 2>&1; then
  brew install python@3.11
  export PATH="$(brew --prefix python@3.11)/bin:$PATH"
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  brew install ffmpeg
fi

if ! command -v latex >/dev/null 2>&1 || ! command -v dvisvgm >/dev/null 2>&1; then
  brew install --cask mactex-no-gui
  export PATH="/Library/TeX/texbin:$PATH"
fi

PY_ENV="$HOME/Library/Application Support/Manimble/python"
mkdir -p "$(dirname "$PY_ENV")"
if [[ ! -x "$PY_ENV/bin/python" ]]; then
  python3.11 -m venv "$PY_ENV"
fi
"$PY_ENV/bin/python" -m pip install --upgrade pip
"$PY_ENV/bin/python" -m pip install -r "$ROOT/engine/requirements.txt"

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
