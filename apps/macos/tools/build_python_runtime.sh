#!/bin/bash
# Build the self-contained Python runtime the app downloads on first launch (install_dependencies.sh):
# a relocatable python-build-standalone CPython with engine/requirements.txt installed into it.
#
#   apps/macos/tools/build_python_runtime.sh [out_dir]   ->  out_dir/Manimble-python-<arch>.tar.gz
#
# It builds for the machine's own architecture (CI runs it once on an Apple Silicon and once on an Intel
# runner). pycairo has no macOS wheels on PyPI, so it is compiled against conda-forge's cairo and the cairo
# dylibs are then copied into the package (delocate). conda-forge rather than Homebrew: Homebrew's bottles
# target the build machine's macOS (26 on CI's Apple Silicon runner), conda-forge's target macOS 11 or older.
set -euo pipefail
cd "$(dirname "$0")/../../.."
ROOT="$PWD"
OUT="${1:-$ROOT/apps/macos/.build/runtime}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

PBS_TAG=20261021
PY_VERSION=3.11.17
MICROMAMBA_VERSION=2.9.0-0
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) TRIPLE=aarch64-apple-darwin; CONDA_PLATFORM=osx-arm64 ;;
  x86_64) TRIPLE=x86_64-apple-darwin; CONDA_PLATFORM=osx-64 ;;
  *) echo "unsupported architecture $ARCH" >&2; exit 1 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -fsSL -o "$WORK/python.tar.gz" \
  "https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_TAG/cpython-$PY_VERSION+$PBS_TAG-$TRIPLE-install_only_stripped.tar.gz"
tar -xzf "$WORK/python.tar.gz" -C "$WORK"   # -> $WORK/python
PY="$WORK/python/bin/python3"
ln -sf python3 "$WORK/python/bin/python"

# cairo and pkg-config from conda-forge, in a throwaway environment; zlib, freetype and expat are the
# packages that carry the .pc files cairo's pkg-config dependencies need (libzlib etc. are runtime-only)
curl -fsSL -o "$WORK/micromamba" \
  "https://github.com/mamba-org/micromamba-releases/releases/download/$MICROMAMBA_VERSION/micromamba-$CONDA_PLATFORM"
chmod +x "$WORK/micromamba"
CF="$WORK/cf"
MAMBA_ROOT_PREFIX="$WORK/mamba" "$WORK/micromamba" create -q -y -p "$CF" -c conda-forge --override-channels \
  cairo zlib freetype expat pkg-config

"$PY" -m pip install --disable-pip-version-check --no-warn-script-location -q --upgrade pip
REQ="$ROOT/engine/requirements.txt"
PIP=("$PY" -m pip --disable-pip-version-check -q)
# The runtime has to run on macOS 13 (LSMinimumSystemVersion), but pip picks the wheels built for the newest
# macOS the build machine runs (numpy, scipy and av publish macOS 14 ones). So the requirements are installed
# in three passes:
#  1. wheels for everything: pycairo built against the conda-forge cairo (never a Homebrew one, nor a wheel
#     cached from such a build) for macOS 13, its rpath letting delocate find the @rpath-linked cairo libraries;
#     pure-Python packages that publish only sources (srt) built into wheels
#  2. the set to install, from those wheels and PyPI's, restricted to wheels that run on macOS 13 (this picks
#     older wheels, or an older release such as av 15, where the newest ones need a newer macOS)
#  3. the install itself, from that set only
PKG_CONFIG="$CF/bin/pkg-config" PKG_CONFIG_PATH="$CF/lib/pkgconfig" PKG_CONFIG_LIBDIR="$CF/lib/pkgconfig" \
  LDFLAGS="-Wl,-rpath,$CF/lib" MACOSX_DEPLOYMENT_TARGET=13.0 PIP_NO_CACHE_DIR=1 \
  "${PIP[@]}" wheel -w "$WORK/built" -r "$REQ"
"${PIP[@]}" download --only-binary=:all: --platform "macosx_13_0_$ARCH" --python-version 3.11 --implementation cp \
  --find-links "$WORK/built" -d "$WORK/wheels" -r "$REQ"
"${PIP[@]}" install --no-warn-script-location --no-index --find-links "$WORK/wheels" -r "$REQ"
rm -rf "$WORK/built" "$WORK/wheels"

# Copy conda-forge's cairo (and what it links) next to pycairo's extension.
"$PY" -m pip install --disable-pip-version-check -q --target "$WORK/delocate" delocate
SITE="$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
PYTHONPATH="$WORK/delocate" "$PY" -m delocate.cmd.delocate_path -L .dylibs "$SITE/cairo"
rm -rf "$WORK/delocate"
# install_name_tool invalidates signatures, and Apple Silicon refuses to load unsigned code
find "$WORK/python" \( -name '*.so' -o -name '*.dylib' \) -newer "$WORK/python.tar.gz" -exec codesign -f -s - {} \; 2>/dev/null

# Nothing may still point into Homebrew or the conda-forge environment (or anywhere else outside the runtime and the OS).
BAD="$(find "$WORK/python" \( -name '*.so' -o -name '*.dylib' \) | while read -r f; do
  otool -L "$f" | tail -n +2 | grep -v -F "$(otool -D "$f" | tail -n +2)" | sed "s|^|$f: |"; done \
  | grep -E -e ':\s+/(opt/homebrew|usr/local)/' -e ":\s+$CF/" || true)"
[[ -z "$BAD" ]] || { echo "runtime still links outside itself:" >&2; echo "$BAD" >&2; exit 1; }
# The app supports macOS 13 (LSMinimumSystemVersion), so every binary in the runtime must too
# (minos of LC_BUILD_VERSION, or version of the older LC_VERSION_MIN_MACOSX)
NEWER="$(find "$WORK/python" \( -name '*.so' -o -name '*.dylib' \) | while read -r f; do
  v="$(otool -l "$f" | awk '/LC_VERSION_MIN_MACOSX/{m=1} m && /version/{print $2; exit} /minos/{print $2; exit}')"
  [[ "${v%%.*}" -le 13 ]] || echo "${f#"$WORK/python/"} needs macOS $v"; done)"
[[ -z "$NEWER" ]] || { echo "runtime binaries need a newer macOS than 13:" >&2; echo "$NEWER" >&2; exit 1; }

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
