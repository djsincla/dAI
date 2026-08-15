#!/usr/bin/env bash
#
# Build dAI Control.app, the control plane's menu bar status app.
#
# Release, not debug: SwiftPM's debug build tolerates things a Release build
# rejects outright, and the agent's menu bar app learned that the expensive way -
# with a binary that ran on the machine that built it and nowhere else.
#
# Ad-hoc signed by default so it runs locally. build-control-pkg.sh signs it
# properly with the Developer ID when one is given, because Gatekeeper refuses an
# ad-hoc signature on any machine other than the one that built it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-dev}"
SIGN_ID="${2:--}"

swift build -c release --package-path "$HERE" >/dev/null
BIN="$(swift build -c release --package-path "$HERE" --show-bin-path)/dai-control-status"
[[ -x "$BIN" ]] || { echo "no binary at $BIN" >&2; exit 1; }

APP="$HERE/.build/dAI Control.app"
# Quit a running copy first. macOS protects the bundle of a live app, so
# rebuilding while it sits in the menu bar fails with a wall of "Permission
# denied" on files the builder plainly owns - which reads as a permissions
# problem and is not one.
pkill -f "$APP" 2>/dev/null || true

# And say so plainly when the bundle genuinely is not ours. A previous build run
# under sudo leaves a root-owned bundle here, and `rm -rf` then prints one line
# per file - eight lines of "Permission denied" that bury the only sentence that
# matters, which is that one directory has the wrong owner.
if [[ -e "$APP" ]] && ! rm -rf "$APP" 2>/dev/null; then
  echo "cannot replace $APP" >&2
  echo "  it is owned by $(stat -f '%Su' "$APP"), so this build cannot remove it." >&2
  echo "  sudo rm -rf \"$APP\"" >&2
  exit 1
fi
mkdir -p "$APP/Contents/MacOS"
sed "s|@VERSION@|$VERSION|g" "$HERE/bundle/Info.plist" > "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/dai-control-status"

# --timestamp only for a real identity: notarisation requires a secure timestamp
# and rejects a bundle without one, but requesting it for an ad-hoc signature
# means a network round trip on every local build for a signature Apple will
# never be asked about.
TS=(--timestamp); [[ "$SIGN_ID" == "-" ]] && TS=(--timestamp=none)
codesign --force "${TS[@]}" --options runtime --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"
echo "$APP"
