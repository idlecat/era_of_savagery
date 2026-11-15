#!/usr/bin/env bash
# Build the downloadable games: export/EraOfSavagery-windows.zip and
# export/EraOfSavagery-macos.zip (presets in export_presets.cfg).
# Needs Godot 4.7.2 and its export templates installed
# (~/Library/Application Support/Godot/export_templates/4.7.2.stable/).
#   tools/build.sh            # build both
#   tools/build.sh --release v0.2.0   # build, then publish a GitHub release (needs gh)
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"

rm -rf export/windows export/macos
mkdir -p export/windows export/macos

"$GODOT" --headless --path . --export-release "Windows" export/windows/EraOfSavagery.exe
"$GODOT" --headless --path . --export-release "macOS" export/macos/EraOfSavagery.zip

(cd export/windows && rm -f ../EraOfSavagery-windows.zip && zip -q -r ../EraOfSavagery-windows.zip .)
mv export/macos/EraOfSavagery.zip export/EraOfSavagery-macos.zip
ls -lh export/*.zip

if [[ "${1:-}" == "--release" ]]; then
	tag="${2:?usage: tools/build.sh --release vX.Y.Z}"
	gh release create "$tag" export/EraOfSavagery-windows.zip export/EraOfSavagery-macos.zip \
		--title "Era of Savagery $tag" --notes-file tools/release_notes.md
fi
