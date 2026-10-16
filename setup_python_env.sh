#!/bin/bash
# Install the Homebrew, Python and TeX dependencies Manimble's engine needs, without building
# the app. install_manimble.sh runs this when building from source; run it on its own after
# downloading a prebuilt Manimble.app from a GitHub Release (https://github.com/pachterlab/Manimble/releases).
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
echo "Python environment ready at $PY_ENV"
