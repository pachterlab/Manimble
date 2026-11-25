#!/bin/sh
# Set Manimble's version everywhere it is written: VERSION, the engine's __version__, and the agent plugin manifests
# (.claude-plugin/plugin.json, .codex-plugin/plugin.json). The release workflow refuses a tag where they disagree.
#
#   ./set_version.sh 0.4.9      set the version
#   ./set_version.sh            write VERSION's version into the others
set -eu
cd "$(dirname "$0")"

v="${1:-$(cat VERSION)}"
echo "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$' || { echo "not a version: $v" >&2; exit 1; }

printf '%s\n' "$v" > VERSION
sed -i.bak "s/^__version__ = \".*\"$/__version__ = \"$v\"/" engine/manimble/__init__.py
for f in .claude-plugin/plugin.json .codex-plugin/plugin.json; do
    sed -i.bak "s/^  \"version\": \".*\",$/  \"version\": \"$v\",/" "$f"
done
rm -f engine/manimble/__init__.py.bak .claude-plugin/plugin.json.bak .codex-plugin/plugin.json.bak

grep -q "^__version__ = \"$v\"$" engine/manimble/__init__.py
for f in .claude-plugin/plugin.json .codex-plugin/plugin.json; do
    grep -q "^  \"version\": \"$v\",$" "$f" || { echo "could not set the version in $f" >&2; exit 1; }
done
echo "version $v"
