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
(cd "$ROOT" && npm run build >/dev/null)

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
cp "$ROOT/scripts/make-certs.sh" "$PAYLOAD/"
echo "$VERSION" > "$PAYLOAD/VERSION"

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
  codesign --force --timestamp --options runtime --sign "$APP_ID" "$PAYLOAD/node"
  codesign --verify --strict --verbose=2 "$PAYLOAD/node"
fi

echo "==> building package"
mkdir -p "$OUT"
PKG="$OUT/dai-control-$VERSION.pkg"
if [[ $UNSIGNED -eq 1 ]]; then PKG="$OUT/dai-control-$VERSION-unsigned.pkg"; SKIP_NOTARY=1; fi

pkgbuild --root "$STAGING" \
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
  echo
  echo "Built $PKG (NOT notarised)."
  echo "Gatekeeper will refuse this on any machine other than one where it was built."
else
  echo "==> notarising, which takes a few minutes"
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
  # Validated, not assumed. Stapling can report success and leave a package
  # that still needs Apple reachable to verify, which is discovered by whoever
  # installs it on a machine with no network - the exact case notarisation is
  # supposed to solve. The agent's builder has always done this.
  xcrun stapler validate "$PKG"
  echo
  echo "Built and notarised $PKG"
fi
