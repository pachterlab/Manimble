#!/bin/bash
# Build the self-contained Python runtime the app downloads on first launch (install_dependencies.sh):
# a relocatable python-build-standalone CPython with engine/requirements.txt installed into it.
#
#   apps/macos/tools/build_python_runtime.sh [out_dir]   ->  out_dir/Manimble-python-<arch>.tar.gz
#
# It builds for the machine's own architecture (CI runs it once on an Apple Silicon and once on an Intel
# runner). pycairo has no macOS wheels on PyPI, so it is compiled against Homebrew's cairo and the cairo
# dylibs are then copied into the package (delocate), leaving nothing in the runtime that needs Homebrew.
set -euo pipefail
cd "$(dirname "$0")/../../.."
ROOT="$PWD"
OUT="${1:-$ROOT/apps/macos/.build/runtime}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

PBS_TAG=20261021
PY_VERSION=3.11.17
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) TRIPLE=aarch64-apple-darwin ;;
  x86_64) TRIPLE=x86_64-apple-darwin ;;
  *) echo "unsupported architecture $ARCH" >&2; exit 1 ;;
esac

command -v brew >/dev/null || { echo "Homebrew is needed to build the runtime (for cairo)" >&2; exit 1; }
brew list cairo >/dev/null 2>&1 || brew install cairo
brew list pkg-config >/dev/null 2>&1 || brew list pkgconf >/dev/null 2>&1 || brew install pkg-config

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -fsSL -o "$WORK/python.tar.gz" \
  "https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_TAG/cpython-$PY_VERSION+$PBS_TAG-$TRIPLE-install_only_stripped.tar.gz"
tar -xzf "$WORK/python.tar.gz" -C "$WORK"   # -> $WORK/python
PY="$WORK/python/bin/python3"
ln -sf python3 "$WORK/python/bin/python"

"$PY" -m pip install --disable-pip-version-check --no-warn-script-location -q --upgrade pip
"$PY" -m pip install --disable-pip-version-check --no-warn-script-location -q -r "$ROOT/engine/requirements.txt"

# Copy Homebrew's cairo (and what it links) next to pycairo's extension.
"$PY" -m pip install --disable-pip-version-check -q --target "$WORK/delocate" delocate
SITE="$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
PYTHONPATH="$WORK/delocate" "$PY" -m delocate.cmd.delocate_path -L .dylibs "$SITE/cairo"
rm -rf "$WORK/delocate"
# install_name_tool invalidates signatures, and Apple Silicon refuses to load unsigned code
find "$WORK/python" \( -name '*.so' -o -name '*.dylib' \) -newer "$WORK/python.tar.gz" -exec codesign -f -s - {} \; 2>/dev/null

# Nothing may still point into Homebrew (or anywhere else outside the runtime and the OS).
BAD="$(find "$WORK/python" \( -name '*.so' -o -name '*.dylib' \) | while read -r f; do
  otool -L "$f" | tail -n +2 | grep -v -F "$(otool -D "$f" | tail -n +2)" | sed "s|^|$f: |"; done \
  | grep -E ':\s+/(opt/homebrew|usr/local)/' || true)"
[[ -z "$BAD" ]] || { echo "runtime still links outside itself:" >&2; echo "$BAD" >&2; exit 1; }
# Homebrew bottles target the build machine's macOS; the app supports 13 (LSMinimumSystemVersion)
NEWER="$(for f in "$SITE/cairo/.dylibs/"*.dylib; do
  v="$(otool -l "$f" | awk '/minos/{print $2; exit}')"; [[ "${v%%.*}" -le 13 ]] || echo "$f needs macOS $v"; done)"
[[ -z "$NEWER" ]] || { echo "cairo libraries need a newer macOS than 13:" >&2; echo "$NEWER" >&2; exit 1; }

# pip writes the build machine's absolute path into console-script shebangs (bin/manim, bin/biocartoon, ...).
# Swap them for a shebang that finds the interpreter next to the script, so the runtime works wherever it lands.
for f in "$WORK/python/bin/"*; do
  [[ -f "$f" && ! -L "$f" ]] || continue
  head -c 2 "$f" | grep -q '#!' || continue
  head -1 "$f" | grep -q "$WORK/python/bin/python" || continue
  { printf '#!/bin/sh\n'"'''"'exec'"'"' "$(dirname -- "$0")/python3" "$0" "$@"\n'"' '''"'\n'; tail -n +2 "$f"; } > "$f.tmp"
  chmod 755 "$f.tmp"; mv "$f.tmp" "$f"
done

find "$WORK/python" -name __pycache__ -type d -prune -exec rm -rf {} +
"$PY" -c "import manim, cairo, PIL, pptx, manim_slides, imageio_ffmpeg; print('runtime ok: manim', manim.__version__)"
find "$WORK/python" -name __pycache__ -type d -prune -exec rm -rf {} +
echo "$PY_VERSION+$PBS_TAG $(cat "$ROOT/engine/requirements.txt" | tr '\n' ' ')" > "$WORK/python/MANIMBLE_RUNTIME"
tar -czf "$OUT/Manimble-python-$ARCH.tar.gz" -C "$WORK" python
echo "built $OUT/Manimble-python-$ARCH.tar.gz ($(du -h "$OUT/Manimble-python-$ARCH.tar.gz" | cut -f1))"
