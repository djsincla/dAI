#!/usr/bin/env bash
#
# Check a built package by taking it apart, not by trusting the build that made
# it.
#
# Every packaging fault this project has hit was invisible to the build and to
# the unit tests, and arrived on a machine somebody was standing at:
#
#   - a signed node that could not execute compiled code, so the installer
#     reached "applying the schema", trapped, and reported that Postgres was
#     unreachable while Postgres was running perfectly well;
#   - an .app that pkgbuild marked relocatable, which the installer then wrote
#     into a build directory it found through Spotlight - leaving the daemon
#     without its status app and a root-owned bundle where the next build
#     expected to write;
#   - a release that swept an unsigned package in by glob;
#   - dist/ shipping every design comment in plaintext.
#
# None of those are things a test of the source can see. They are properties of
# the artifact, so this reads the artifact. It runs at the end of every build,
# which is the last moment the answer is still cheap.
set -euo pipefail

PKG="${1:?usage: verify-pkg.sh <path to .pkg>}"
[[ -f "$PKG" ]] || { echo "no such package: $PKG" >&2; exit 2; }
# Absolute, because everything below runs from a temporary directory and a
# relative path resolves against the wrong place there.
PKG="$(cd "$(dirname "$PKG")" && pwd)/$(basename "$PKG")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

fail() { echo "  FAIL  $1" >&2; FAILED=1; }
pass() { echo "  ok    $1"; }

(cd "$WORK" && xar -xf "$PKG")
# Not "payload": the archive already contains a file called Payload, and macOS
# filesystems are case-insensitive by default, so the two collide.
PAYLOAD_DIR="$WORK/extracted"
mkdir -p "$PAYLOAD_DIR"
(cd "$PAYLOAD_DIR" && gunzip -dc "$WORK/Payload" | cpio -i --quiet)

D="$PAYLOAD_DIR/usr/local/libexec/dai-control"
echo "verifying $(basename "$PKG")"

# ---------------------------------------------------------------- the runtime
#
# The check that matters most, and the one codesign cannot make: codesign
# confirms a signature is well formed and says nothing about whether the
# entitlements let the program run.
if [[ -x "$D/node" ]]; then
  if "$D/node" -e 'new Function("return 1+1")()' >/dev/null 2>&1; then
    pass "node executes compiled code"
  else
    fail "node cannot execute compiled code - it will trap on the first real program"
  fi
  # Loading a module tree is a different path from -e, and it is the one the
  # installer takes.
  set +e
  "$D/node" "$D/dist/preflight.js" >/dev/null 2>&1
  code=$?
  set -e
  # 2 is preflight refusing for want of --ca, which means it loaded and ran.
  # 133 is SIGTRAP, which is the failure this whole script exists for.
  if [[ $code -eq 2 ]]; then
    pass "node loads a real module tree"
  else
    fail "node cannot load dist/preflight.js (exit $code)"
  fi
else
  fail "no node runtime in the payload"
fi

# ------------------------------------------------------------------- bundles
#
# pkgbuild marks a nested .app relocatable by default: the installer asks
# Spotlight where the bundle id already lives and writes there instead of the
# payload path, reporting success either way.
if grep -q "<relocate>" "$WORK/PackageInfo" 2>/dev/null; then
  fail "a bundle is relocatable - the installer will place it wherever Spotlight says"
else
  pass "bundles install where the payload says"
fi

if [[ -d "$D/dAI Control.app" ]]; then
  pass "the status app is in the payload"
else
  fail "the status app is missing from the payload"
fi

# --------------------------------------------------------------- what ships
if [[ -f "$D/VERSION" ]]; then
  pass "VERSION present ($(tr -d '[:space:]' < "$D/VERSION"))"
else
  fail "no VERSION file - the control plane cannot say what it is"
fi

if grep -rqs '/\*\*' "$D/dist"; then
  fail "dist/ still carries comments"
else
  pass "dist/ carries no comments"
fi

if [[ -n "$(find "$D/dist" -name '*.map' -print -quit 2>/dev/null)" ]]; then
  fail "source maps shipped inside the package - they undo the minification"
else
  pass "no source maps in the payload"
fi

for needed in openapi/dai.yaml db/schema.sql ui/index.html install.sh uninstall.sh; do
  [[ -e "$D/$needed" ]] && pass "$needed" || fail "$needed is missing"
done

echo
if [[ $FAILED -eq 0 ]]; then
  echo "$(basename "$PKG") is sound"
else
  echo "$(basename "$PKG") is NOT installable - see the failures above" >&2
  exit 1
fi
