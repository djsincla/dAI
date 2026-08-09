#!/bin/bash
#
# Build a signed, notarised installer package.
#
# This is the fleet-distribution path. install.sh is fine for a machine you are
# sitting at; anything pushed by MDM has to be a notarised .pkg or Gatekeeper
# will refuse it on every target and the failure is silent enough to waste a
# day.
#
# Three credentials are needed, and they are separate things that get confused:
#
#   Developer ID Application  signs the binary
#   Developer ID Installer    signs the .pkg
#   a notarytool profile      submits to Apple for notarisation
#
# The "Apple Development" certificate that comes with a normal Xcode setup is
# none of these. It signs code for local use only and Apple will not notarise
# anything signed with it, so this script checks up front rather than failing
# after a long build.
#
#   ./build-pkg.sh --version 0.1.0 \
#                  --app-id "Developer ID Application: Example Inc (TEAMID)" \
#                  --installer-id "Developer ID Installer: Example Inc (TEAMID)" \
#                  --notary-profile dai-notary
#
# Create the notary profile once with:
#   xcrun notarytool store-credentials dai-notary \
#     --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
#
set -euo pipefail

VERSION=""; APP_ID=""; INSTALLER_ID=""; NOTARY_PROFILE=""; SKIP_NOTARY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)        VERSION="$2"; shift 2 ;;
    --app-id)         APP_ID="$2"; shift 2 ;;
    --installer-id)   INSTALLER_ID="$2"; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
    --skip-notary)    SKIP_NOTARY=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$VERSION" ]] || { echo "missing --version" >&2; exit 2; }
[[ -n "$APP_ID" ]] || { echo "missing --app-id" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
STAGING="$HERE/.staging"
OUT="$HERE/dist"

# Check the identities exist before spending two minutes on a release build.
if ! security find-identity -v -p codesigning | grep -qF "$APP_ID"; then
  echo "no such signing identity: $APP_ID" >&2
  echo "available:" >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi

echo "==> building release"
(cd "$ROOT" && swift build -c release)

echo "==> staging"
rm -rf "$STAGING" && mkdir -p "$STAGING/usr/local/libexec/dai"
cp "$ROOT/.build/release/dai-agent" "$STAGING/usr/local/libexec/dai/"
for bundle in "$ROOT"/.build/release/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$STAGING/usr/local/libexec/dai/"
done
cp "$HERE/com.dai.agent.plist.in" "$HERE/install.sh" "$HERE/uninstall.sh" \
   "$STAGING/usr/local/libexec/dai/"

echo "==> signing binary"
# The hardened runtime is required for notarisation. No entitlements: the
# Secure Enclave key is reached through CryptoKit, which needs none, and that
# was the point of choosing it over the keychain.
codesign --force --timestamp --options runtime \
         --sign "$APP_ID" "$STAGING/usr/local/libexec/dai/dai-agent"
codesign --verify --strict --verbose=2 "$STAGING/usr/local/libexec/dai/dai-agent"

echo "==> building package"
mkdir -p "$OUT"
PKG="$OUT/dai-agent-$VERSION.pkg"
pkgbuild --root "$STAGING" \
         --identifier com.dai.agent \
         --version "$VERSION" \
         --install-location / \
         "$OUT/dai-agent-unsigned.pkg"

if [[ -n "$INSTALLER_ID" ]]; then
  productsign --sign "$INSTALLER_ID" "$OUT/dai-agent-unsigned.pkg" "$PKG"
  rm -f "$OUT/dai-agent-unsigned.pkg"
else
  echo "no --installer-id given; package is unsigned and cannot be notarised" >&2
  mv "$OUT/dai-agent-unsigned.pkg" "$PKG"
  SKIP_NOTARY=1
fi

if [[ $SKIP_NOTARY -eq 1 || -z "$NOTARY_PROFILE" ]]; then
  echo
  echo "Built $PKG (NOT notarised)."
  echo "Gatekeeper will refuse this on any machine other than one where it was built."
  exit 0
fi

echo "==> notarising (this waits on Apple and usually takes a few minutes)"
xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait

# Stapling matters for fleet installs: without it every target has to reach
# Apple to verify, and machines on an isolated network cannot. Which, given the
# whole point of this product is data that never leaves the building, is a
# realistic deployment.
echo "==> stapling"
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"

echo
echo "Built and notarised $PKG"
