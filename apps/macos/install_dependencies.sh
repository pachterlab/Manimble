#!/bin/bash
# Installs what Manimble's engine needs, without Homebrew. The app's setup window (Setup.swift) runs it from
# Contents/Resources for whatever its check found missing; it also works on its own.
#
#   install_dependencies.sh check-tex      prints ok, missing, or packages (TeX present, manim's packages not)
#   install_dependencies.sh python         the prebuilt Python runtime with manim (tools/build_python_runtime.sh,
#                                          attached to each GitHub Release) -> ~/Library/Application Support/Manimble/python
#   install_dependencies.sh tex            TinyTeX plus the LaTeX packages manim uses -> ~/Library/TinyTeX
#   install_dependencies.sh tex-packages   just the packages, into the TeX installation already on this Mac
#
# Everything lands in the user's Library, so no administrator password is needed, except to add packages to a
# system-wide TeX (MacTeX/BasicTeX), where macOS asks for one. Lines starting "@@ " are steps for the setup window.
set -euo pipefail

REPO=pachterlab/Manimble
SUPPORT="$HOME/Library/Application Support/Manimble"
TINYTEX="$HOME/Library/TinyTeX"
VERSION="${MANIMBLE_VERSION:-}"
if [[ -z "$VERSION" ]]; then
  HERE="$(cd "$(dirname "$0")" && pwd)"
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HERE/../Info.plist" 2>/dev/null \
    || cat "$HERE/../../VERSION" 2>/dev/null || true)"
fi
# where TeX installations put their binaries (the app starts this script without a login shell's PATH)
export PATH="$TINYTEX/bin/universal-darwin:/Library/TeX/texbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

# What manim's TeX templates use (its Chinese `ctex` template excepted).
TEX_PACKAGES=(latex-bin dvisvgm standalone preview babel-english doublestroke everysel fundus-calligra mathastext
  physics ragged2e relsize rsfs setspace tipa wasy wasysym xcolor xkeyval cbfonts-fd jknapltx microtype multitoc
  prelim2e count1to frcursive amsfonts amsmath)

step() { echo "@@ $*"; }

# Long steps run as children the shell waits on, so the setup window's Cancel (SIGTERM) can stop them:
# bash defers a trap until a foreground command ends, but `wait` returns at once.
trap 'pkill -P $$ 2>/dev/null; exit 143' TERM
run() { "$@" & wait $!; }

arch() { [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == 1 ]] && echo arm64 || echo x86_64; }

# download URL DEST: curl's progress bar ends each update with "NN.N%", which the setup window reads
download() { run curl -fL --retry 3 --progress-bar -o "$2" "$1"; }

check_tex() {
  if ! command -v latex >/dev/null 2>&1; then echo missing; return; fi
  if command -v dvisvgm >/dev/null 2>&1 \
     && kpsewhich standalone.cls preview.sty english.ldf dsfont.sty relsize.sty >/dev/null 2>&1; then
    echo ok
  else
    echo packages
  fi
}

install_python() {
  local a tmp url
  a="$(arch)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  step "Downloading Python and Manim"
  # the runtime built for this version, else the newest one (a build from source between releases);
  # MANIMBLE_RUNTIME_URL points elsewhere, e.g. file:///path/to/Manimble-python-arm64.tar.gz from build_python_runtime.sh
  for url in ${MANIMBLE_RUNTIME_URL:+"$MANIMBLE_RUNTIME_URL"} ${VERSION:+"https://github.com/$REPO/releases/download/v$VERSION/Manimble-python-$a.tar.gz"} \
             "https://github.com/$REPO/releases/latest/download/Manimble-python-$a.tar.gz"; do
    if download "$url" "$tmp/python.tar.gz"; then break; fi
    rm -f "$tmp/python.tar.gz"
  done
  [[ -f "$tmp/python.tar.gz" ]] || { echo "Could not download the Python runtime" >&2; exit 1; }
  step "Unpacking Python"
  run tar -xzf "$tmp/python.tar.gz" -C "$tmp"
  step "Checking Python"
  "$tmp/python/bin/python3" -c "import manim, PIL" || { echo "The downloaded Python runtime does not work" >&2; exit 1; }
  mkdir -p "$SUPPORT"
  # an earlier environment that no longer works (the app only installs when it found none) is set aside, not deleted
  if [[ -e "$SUPPORT/python" ]]; then
    rm -rf "$SUPPORT/python.previous"
    mv "$SUPPORT/python" "$SUPPORT/python.previous"
  fi
  mv "$tmp/python" "$SUPPORT/python"
  echo "Python installed at $SUPPORT/python"
}

install_tex() {
  if [[ ! -x "$TINYTEX/bin/universal-darwin/tlmgr" ]]; then
    local tmp tag
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    # the newest TinyTeX: tlmgr only installs packages while its TeX Live year matches CTAN's
    tag="$(curl -fsSI https://github.com/rstudio/tinytex-releases/releases/latest \
      | tr -d '\r' | sed -n 's|^[Ll]ocation: .*/tag/\(.*\)$|\1|p')"
    [[ -n "$tag" ]] || { echo "Could not find the latest TinyTeX release" >&2; exit 1; }
    step "Downloading LaTeX (TinyTeX $tag)"
    download "https://github.com/rstudio/tinytex-releases/releases/download/$tag/TinyTeX-1-darwin-$tag.tar.xz" "$tmp/tinytex.tar.xz"
    step "Unpacking LaTeX"
    run tar -xJf "$tmp/tinytex.tar.xz" -C "$tmp"
    mkdir -p "$(dirname "$TINYTEX")"
    mv "$tmp/TinyTeX" "$TINYTEX"
    "$TINYTEX/bin/universal-darwin/tlmgr" option repository ctan >/dev/null
  fi
  install_tex_packages
}

install_tex_packages() {
  local tlmgr root
  tlmgr="$(command -v tlmgr)" || { echo "No tlmgr found to add LaTeX packages with" >&2; exit 1; }
  root="$(kpsewhich -var-value TEXMFROOT)"
  step "Adding the LaTeX packages manim uses"
  # tlmgr refuses to install packages once CTAN has a newer tlmgr than itself, so it updates itself first
  if [[ -w "$root/tlpkg" ]]; then
    run "$tlmgr" update --self
    run "$tlmgr" install "${TEX_PACKAGES[@]}"
  else
    # a system TeX (MacTeX, BasicTeX) lives in a folder only an administrator can change: macOS asks for a password
    local cmd="'$tlmgr' update --self && '$tlmgr' install ${TEX_PACKAGES[*]}"
    osascript -e "do shell script \"${cmd//\"/\\\"}\" with administrator privileges" \
      -e 'return ""' || { echo "Adding LaTeX packages was cancelled or failed" >&2; exit 1; }
  fi
  [[ "$(check_tex)" == ok ]] || { echo "LaTeX is still missing packages manim needs" >&2; exit 1; }
  echo "LaTeX ready: $(command -v latex)"
}

case "${1:-}" in
  check-tex) check_tex ;;
  python) install_python ;;
  tex) install_tex ;;
  tex-packages) install_tex_packages ;;
  *) echo "usage: $0 check-tex | python | tex | tex-packages" >&2; exit 2 ;;
esac
