#!/bin/bash
#
# Build a signed, notarised installer package for the control plane.
#
# The same three credentials the agent's builder needs, and they are separate
# things that get confused:
#
#   Developer ID Application  signs the runtime and the scripts
#   Developer ID Installer    signs the .pkg
#   a notarytool profile      submits to Apple for notarisation
#
#   ./build-control-pkg.sh --version 0.1.0 \
#                          --app-id "Developer ID Application: Example Inc (TEAMID)" \
#                          --installer-id "Developer ID Installer: Example Inc (TEAMID)" \
#                          --notary-profile dai-notary
#
# --unsigned builds something that will only run on the machine that built it,
# which is enough to check the installer and nothing else.
set -euo pipefail

VERSION=""; APP_ID=""; INSTALLER_ID=""; NOTARY_PROFILE=""; SKIP_NOTARY=0; UNSIGNED=0
NODE_VERSION="v22.14.0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)        VERSION="$2"; shift 2 ;;
    --app-id)         APP_ID="$2"; shift 2 ;;
    --installer-id)   INSTALLER_ID="$2"; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
    --node)           NODE_VERSION="$2"; shift 2 ;;
    --skip-notary)    SKIP_NOTARY=1; shift ;;
    --unsigned)       UNSIGNED=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$VERSION" ]] || { echo "missing --version" >&2; exit 2; }
# The version has to look like a release, because the one that got through by
# hand was 2026.08.12-5 - a date, which sorts against 0.3.1 as nonsense and told
# an operator nothing about what it was newer than. Leading zeros are rejected
# too, which is what distinguishes a date from a version.
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "not a version: $VERSION (expected MAJOR.MINOR.PATCH, optionally -suffix)" >&2
  exit 2
fi

if [[ $UNSIGNED -eq 0 ]]; then
  [[ -n "$APP_ID" ]] || { echo "missing --app-id (or --unsigned to test locally)" >&2; exit 2; }
  if ! security find-identity -v -p codesigning | grep -qF "$APP_ID"; then
    echo "no such signing identity: $APP_ID" >&2
    security find-identity -v -p codesigning >&2
    exit 1
  fi
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STAGING="$HERE/.staging"
OUT="$HERE/dist"
PAYLOAD="$STAGING/usr/local/libexec/dai-control"

echo "==> building"
# build:packaged, not build: compiled without comments and then minified, because
# this is the tree that goes to somebody else. `npm run build` stays readable for
# development. The maps are archived below and stay here.
(cd "$ROOT" && npm run build:packaged >/dev/null)

echo "==> collecting production dependencies"
rm -rf "$STAGING" && mkdir -p "$PAYLOAD"
cp "$ROOT/package.json" "$ROOT/package-lock.json" "$PAYLOAD/"
# --omit=dev, because the test and build tooling is most of the tree and none of
# it runs in a deployment. It is also the half most likely to contain something
# an auditor would ask about.
(cd "$PAYLOAD" && npm ci --omit=dev --silent >/dev/null)

cp -R "$ROOT/dist" "$PAYLOAD/dist"
# Beside dist/, because every runtime path is relative to the compiled file:
# server.js reads ../openapi and ../ui, lib/db.js reads ../../db. Moving any of
# them means editing code to suit a package, which is the wrong way round.
cp -R "$ROOT/openapi" "$PAYLOAD/openapi"
cp -R "$ROOT/ui" "$PAYLOAD/ui"
cp -R "$ROOT/db" "$PAYLOAD/db"
cp "$HERE/install.sh" "$HERE/uninstall.sh" "$HERE/com.dai.control.plist.in" "$PAYLOAD/"
# Shared with the agent's packaging rather than copied, so a fix to how a daemon
# is reloaded reaches both installers. It is the script that knows bootout is
# asynchronous, which is not obvious and cost a failed install to learn.
cp "$ROOT/../agent/packaging/reload-daemon.sh" "$PAYLOAD/"
# The terms travel with the thing they cover. Apache-2.0 section 4(d) requires a
# redistribution to carry the NOTICE, and this package redistributes a great deal
# more than our own code: `npm ci` above puts nearly two hundred dependencies in
# the payload. Shipping our LICENSE beside theirs is what makes the bundle
# answerable rather than merely assembled.
cp "$ROOT/../LICENSE" "$ROOT/../NOTICE" "$ROOT/../THIRD-PARTY-NOTICES.md" "$PAYLOAD/"
cp "$ROOT/scripts/make-certs.sh" "$PAYLOAD/"
echo "$VERSION" > "$PAYLOAD/VERSION"

# ------------------------------------------------------------- the status app
#
# The menu bar app that says whether the control plane is up. Staged inside the
# payload and copied to /Applications by install.sh, rather than shipped as a
# second package: it is useless without the daemon and versioning it separately
# would mean an operator with two things to keep in step for one machine.
echo "==> building the status app"
STATUS_APP="$("$ROOT/app/build-status-app.sh" "$VERSION" "${APP_ID:--}")"
rm -rf "$PAYLOAD/dAI Control.app"
cp -R "$STATUS_APP" "$PAYLOAD/dAI Control.app"

# The maps for the minified payload. Kept beside the package and NOT inside it:
# a map next to a minified file undoes the minification for anybody who looks.
# Without one, a stack trace from a customer reads `f (server.js:1:8420)` and
# says nothing, so this is the half that has to be kept to make the other half
# survivable. It is gitignored; archive it somewhere that outlives this checkout
# if the build is going to a real user.
mkdir -p "$OUT"
if [[ -d "$ROOT/.maps" ]]; then
  tar -czf "$OUT/dai-control-$VERSION-sourcemaps.tar.gz" -C "$ROOT" .maps
fi

# ------------------------------------------------------------------ the runtime
#
# The official build from nodejs.org, not whatever `node` happens to be on the
# build machine. A homebrew node is a 67KB shim against dylibs under
# /opt/homebrew, so bundling it produces a package that works only where
# homebrew already installed the same versions - which is nowhere a customer is.
#
# The checksum is verified against Apple's... no: against the SHASUMS the same
# server publishes. That is weaker than a signature and stronger than nothing,
# and it is the check that would notice a truncated download or a substituted
# mirror before an interpreter goes into a package this script then signs.
echo "==> fetching node $NODE_VERSION"
TARBALL="node-$NODE_VERSION-darwin-arm64.tar.gz"
CACHE="$HERE/.node-cache"
mkdir -p "$CACHE"
if [[ ! -f "$CACHE/$TARBALL" ]]; then
  curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/$TARBALL" -o "$CACHE/$TARBALL"
fi
curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt" -o "$CACHE/SHASUMS256.txt"
EXPECTED="$(grep " $TARBALL\$" "$CACHE/SHASUMS256.txt" | awk '{print $1}')"
ACTUAL="$(shasum -a 256 "$CACHE/$TARBALL" | awk '{print $1}')"
if [[ -z "$EXPECTED" || "$EXPECTED" != "$ACTUAL" ]]; then
  echo "node $NODE_VERSION does not match its published checksum" >&2
  echo "  expected ${EXPECTED:-<not published>}" >&2
  echo "  got      $ACTUAL" >&2
  rm -f "$CACHE/$TARBALL"
  exit 1
fi
tar -xzf "$CACHE/$TARBALL" -C "$CACHE"
cp "$CACHE/node-$NODE_VERSION-darwin-arm64/bin/node" "$PAYLOAD/node"
chmod 755 "$PAYLOAD/node" "$PAYLOAD/install.sh" "$PAYLOAD/uninstall.sh" "$PAYLOAD/make-certs.sh"

# ------------------------------------------------------------------ signing
if [[ $UNSIGNED -eq 1 ]]; then
  echo "==> NOT signing: this package is for testing the installer and nothing else"
else
  echo "==> signing"
  # The runtime is the only Mach-O in the payload; the rest is scripts and data.
  # --options runtime is required for notarisation.
  # --entitlements, or the hardened runtime forbids the writable-executable
  # memory V8 compiles into and node dies with Trace/BPT trap: 5 - EXC_BREAKPOINT
  # raised from libsystem_pthread, where the JIT write-protect call lives.
  #
  # It fails in the least useful way available. `node --version` works, because
  # printing a constant never reaches the compiler, and so does `node -e` with a
  # small script. The crash arrives when a real module tree loads - so every
  # signed release shipped this, invisibly, until an upgrade ran migrate and the
  # installer reported that Postgres was unreachable while Postgres was running
  # perfectly well three steps away.
  #
  # The entitlements file carries no XML comments, deliberately. AMFI parses it
  # with a stricter reader than plutil and rejects a comment with "syntax error
  # near line 6", naming a line that is a sentence of prose - so the explanation
  # lives here, where it can be read without breaking the thing it explains.
  #
  # allow-jit permits the MAP_JIT allocation; allow-unsigned-executable-memory
  # permits executing pages nobody signed, which is what a just-in-time compiler
  # produces. disable-library-validation is for native addons under
  # node_modules, signed by whoever built them or by nobody.
  codesign --force --timestamp --options runtime \
           --entitlements "$HERE/node.entitlements" \
           --sign "$APP_ID" "$PAYLOAD/node"
  codesign --verify --strict --verbose=2 "$PAYLOAD/node"
  # Verified by running it, not by asking codesign whether it is happy. codesign
  # confirms the signature is well formed and says nothing about whether the
  # entitlements let the program execute - which is the only question that
  # matters and the one nobody was asking.
  if ! "$PAYLOAD/node" -e 'new Function("return 1+1")()' >/dev/null 2>&1; then
    echo "the signed node cannot execute compiled code - check node.entitlements" >&2
    exit 1
  fi
fi

echo "==> building package"
mkdir -p "$OUT"
PKG="$OUT/dai-control-$VERSION.pkg"
if [[ $UNSIGNED -eq 1 ]]; then PKG="$OUT/dai-control-$VERSION-unsigned.pkg"; SKIP_NOTARY=1; fi

# --component-plist, or the .app in the payload is installed somewhere else
# entirely.
#
# pkgbuild treats a nested .app as a relocatable component: it writes a
# <relocate> entry naming the bundle id, and at install time the installer asks
# Spotlight where that id already lives and puts the new copy THERE, ignoring
# the payload path. Having once run the app out of the build directory, the
# installer found it by id and wrote a root-owned bundle back into
# control-plane/app/.build - which then broke the next build with a wall of
# "Permission denied", and left the daemon's own directory without the app that
# was supposed to be beside it.
#
# The failure is silent from the installer's side. It reports success, because
# from its point of view it did exactly what the package asked for.
COMPONENTS="$STAGING/../components.plist"
pkgbuild --analyze --root "$STAGING" "$COMPONENTS" >/dev/null
# Every bundle, not only the one we know about. A component added later would
# otherwise inherit the default and relocate itself somewhere surprising.
/usr/libexec/PlistBuddy -c "Print" "$COMPONENTS" >/dev/null 2>&1 && \
python3 - "$COMPONENTS" <<'RELOC'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    components = plistlib.load(f)
for c in components:
    c['BundleIsRelocatable'] = False
with open(path, 'wb') as f:
    plistlib.dump(components, f)
print(f"  {len(components)} bundle component(s) pinned to their payload path")
RELOC

pkgbuild --root "$STAGING" \
         --component-plist "$COMPONENTS" \
         --identifier com.dai.control \
         --version "$VERSION" \
         --install-location / \
         --scripts "$HERE/scripts" \
         "$OUT/dai-control-unsigned.pkg"

if [[ $UNSIGNED -eq 1 ]]; then
  mv "$OUT/dai-control-unsigned.pkg" "$PKG"
elif [[ -n "$INSTALLER_ID" ]]; then
  productsign --sign "$INSTALLER_ID" "$OUT/dai-control-unsigned.pkg" "$PKG"
  rm -f "$OUT/dai-control-unsigned.pkg"
else
  echo "no --installer-id given; package is unsigned and cannot be notarised" >&2
  mv "$OUT/dai-control-unsigned.pkg" "$PKG"
  SKIP_NOTARY=1
fi

if [[ $SKIP_NOTARY -eq 1 || -z "$NOTARY_PROFILE" ]]; then
  :
else
  echo "==> notarising, which takes a few minutes"
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
  # Validated, not assumed. Stapling can report success and leave a package
  # that still needs Apple reachable to verify, which is discovered by whoever
  # installs it on a machine with no network - the exact case notarisation is
  # supposed to solve. The agent's builder has always done this.
  xcrun stapler validate "$PKG"
  NOTARISED=1
fi

# Taken apart and checked, not trusted - and on both paths, because an unsigned
# build exists to find out whether the build works and is the cheapest place to
# learn that it does not. Every packaging fault here has been invisible to the
# build that produced it and obvious in the artifact a moment later: a node that
# could not execute, an app the installer would write somewhere else entirely,
# comments nobody meant to ship.
echo
"$HERE/verify-pkg.sh" "$PKG"
echo

if [[ ${NOTARISED:-0} -eq 1 ]]; then
  echo "Built and notarised $PKG"
else
  echo "Built $PKG (NOT notarised)."
  echo "Gatekeeper will refuse this on any machine other than one where it was built."
fi
