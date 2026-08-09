#!/bin/bash
#
# Assemble the menu bar app bundle.
#
# A menu bar app has to be a bundle: LSUIElement lives in Info.plist, and
# without it the process gets a Dock icon and an app switcher entry, which reads
# as an application someone has to manage rather than a background arrangement
# they can check on. SwiftPM produces a bare executable, so the bundle is built
# around it here.
#
#   ./build-app.sh [output-dir]
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
OUT="${1:-$ROOT/.xcbuild/Build/Products/Release}"
BIN="$OUT/dai-menubar"

[[ -x "$BIN" ]] || { echo "no dai-menubar binary at $BIN" >&2; exit 1; }

APP="$OUT/dAI.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$HERE/app/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/dai-menubar"

# Ad-hoc signed so it runs locally. build-pkg.sh re-signs with Developer ID for
# anything leaving this machine.
codesign --force --sign - "$APP"
echo "built $APP"
