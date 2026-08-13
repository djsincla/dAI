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

VERSION=""; APP_ID=""; INSTALLER_ID=""; NOTARY_PROFILE=""; SKIP_NOTARY=0; UNSIGNED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)        VERSION="$2"; shift 2 ;;
    --app-id)         APP_ID="$2"; shift 2 ;;
    --installer-id)   INSTALLER_ID="$2"; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
    --skip-notary)    SKIP_NOTARY=1; shift ;;
    # For checking the installer works, on a machine with no Developer ID.
    # Produces something Gatekeeper will refuse, which is why the name says so.
    --unsigned)       UNSIGNED=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$VERSION" ]] || { echo "missing --version" >&2; exit 2; }
if [[ $UNSIGNED -eq 0 ]]; then
  [[ -n "$APP_ID" ]] || { echo "missing --app-id (or --unsigned to test locally)" >&2; exit 2; }
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
STAGING="$HERE/.staging"
OUT="$HERE/dist"

# Check the identities exist before spending two minutes on a release build.
if [[ $UNSIGNED -eq 0 ]] && ! security find-identity -v -p codesigning | grep -qF "$APP_ID"; then
  echo "no such signing identity: $APP_ID" >&2
  echo "available:" >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi

echo "==> building release"
# xcodebuild rather than swift build: SwiftPM's command line cannot compile
# MLX's Metal shaders, so a package built that way ships a binary that aborts on
# the first GPU work unit.
# Coverage off explicitly. The SwiftPM-generated scheme leaves profiling
# instrumentation in a Release build, and the shipped binary then tries to write
# default.profraw next to wherever it is running. As a daemon under a service
# account that is a permission error on every start, for a file nobody wants.
(cd "$ROOT" && xcodebuild build -scheme dai-agent -destination 'platform=OS X' \
   -configuration Release -derivedDataPath .xcbuild \
   ENABLE_CODE_COVERAGE=NO CLANG_ENABLE_CODE_COVERAGE=NO SWIFT_ENABLE_CODE_COVERAGE=NO)

echo "==> staging"
rm -rf "$STAGING" && mkdir -p "$STAGING/usr/local/libexec/dai"
PRODUCTS="$ROOT/.xcbuild/Build/Products/Release"
cp "$PRODUCTS/dai-agent" "$STAGING/usr/local/libexec/dai/"
# Includes mlx-swift_Cmlx.bundle, which carries the Metal shader library. Ship
# the binary without it and GPU work aborts at runtime.
for bundle in "$PRODUCTS"/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$STAGING/usr/local/libexec/dai/"
done
# Everything install.sh reaches for beside itself. It is worth listing rather
# than globbing: the updater template and reload-daemon.sh were added later and
# not added here, so every package built since shipped an install.sh that could
# not finish. install.sh calls reload-daemon.sh unconditionally under `set -e`,
# so the install died partway; and the updater plist is behind an `if [[ -f ]]`,
# so its absence was silent and produced machines that could never self-update.
cp "$HERE/com.dai.agent.plist.in" "$HERE/com.dai.menubar.plist.in" \
   "$HERE/com.dai.updater.plist.in" "$HERE/reload-daemon.sh" \
   "$HERE/install.sh" "$HERE/uninstall.sh" "$STAGING/usr/local/libexec/dai/"
chmod 755 "$STAGING/usr/local/libexec/dai/reload-daemon.sh"

# The package carries its own version, so install.sh can stamp it into the
# daemon's environment without being told. A build that cannot name itself
# reports as "dev" on every machine and the fleet view stops being able to
# answer what is deployed.
echo "$VERSION" > "$STAGING/usr/local/libexec/dai/VERSION"

# The menu bar app ships in the same package. Shipping the daemon without it
# would put work on someone's machine with no way for them to see or stop it,
# which is the one thing this design cannot afford to get wrong.
"$HERE/build-app.sh" "$PRODUCTS"
mkdir -p "$STAGING/Applications"
cp -R "$PRODUCTS/dAI.app" "$STAGING/Applications/"

echo "==> signing binary"
# The hardened runtime is required for notarisation. No entitlements: the
# Secure Enclave key is reached through CryptoKit, which needs none, and that
# was the point of choosing it over the keychain.
if [[ $UNSIGNED -eq 1 ]]; then
  echo "==> NOT signing: this package is for testing the installer and nothing else"
else
codesign --force --timestamp --options runtime \
         --sign "$APP_ID" "$STAGING/usr/local/libexec/dai/dai-agent"
codesign --verify --strict --verbose=2 "$STAGING/usr/local/libexec/dai/dai-agent"
codesign --force --timestamp --options runtime --sign "$APP_ID" "$STAGING/Applications/dAI.app"
codesign --verify --strict --verbose=2 "$STAGING/Applications/dAI.app"
fi

echo "==> building package"
mkdir -p "$OUT"
PKG="$OUT/dai-agent-$VERSION.pkg"
# An unsigned package is named so it cannot be mistaken for one that ships.
if [[ $UNSIGNED -eq 1 ]]; then PKG="$OUT/dai-agent-$VERSION-unsigned.pkg"; SKIP_NOTARY=1; fi
# --scripts is what makes this an installation rather than a file drop. Without
# it the package laid the binary and the app down and stopped: no service
# account, no rendered plists, nothing running. The postinstall calls install.sh,
# so an MDM push and a person at the machine take the same path.
pkgbuild --root "$STAGING" \
         --identifier com.dai.agent \
         --version "$VERSION" \
         --install-location / \
         --scripts "$HERE/scripts" \
         "$OUT/dai-agent-unsigned.pkg"

if [[ $UNSIGNED -eq 1 ]]; then
  mv "$OUT/dai-agent-unsigned.pkg" "$PKG"
elif [[ -n "$INSTALLER_ID" ]]; then
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
