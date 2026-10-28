#!/bin/bash
# Install the Homebrew, Python and TeX dependencies Manimble's engine needs, without building
# the app. install_manimble.sh runs this when building from source. A prebuilt Manimble.app from a
# GitHub Release doesn't need it: its first-launch setup window installs what is missing
# (apps/macos/install_dependencies.sh).
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

# LaTeX for formulas: BasicTeX (~400 MB with the packages below) rather than the full MacTeX (several GB).
# The packages are what manim's TeX templates use (its Chinese `ctex` template excepted); an existing TeX
# installation that already has them, such as MacTeX, is left alone.
TEX_PACKAGES=(standalone preview babel-english doublestroke dvisvgm everysel fundus-calligra mathastext physics
  ragged2e relsize rsfs setspace tipa wasy wasysym xcolor xkeyval cbfonts-fd jknapltx microtype multitoc prelim2e
  count1to frcursive)
if ! command -v latex >/dev/null 2>&1; then
  brew install --cask basictex
  export PATH="/Library/TeX/texbin:$PATH"
fi
if ! command -v dvisvgm >/dev/null 2>&1 || ! kpsewhich standalone.cls preview.sty english.ldf dsfont.sty >/dev/null 2>&1; then
  echo "Adding the LaTeX packages manim needs (asks for your password: TeX lives in a system folder)."
  # a fresh BasicTeX refuses to install packages until tlmgr has updated itself
  sudo tlmgr update --self
  sudo tlmgr install "${TEX_PACKAGES[@]}"
fi

PY_ENV="$HOME/Library/Application Support/Manimble/python"
mkdir -p "$(dirname "$PY_ENV")"
if [[ ! -x "$PY_ENV/bin/python" ]]; then
  python3.11 -m venv "$PY_ENV"
fi
"$PY_ENV/bin/python" -m pip install --upgrade pip
"$PY_ENV/bin/python" -m pip install -r "$ROOT/engine/requirements.txt"
echo "Python environment ready at $PY_ENV"
