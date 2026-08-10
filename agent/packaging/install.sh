#!/bin/bash
#
# Install the dAI agent as a system daemon.
#
# Enrollment is part of installation because the two cannot be separated: the
# daemon has nothing to authenticate with until an admin has approved the node,
# and a daemon that starts without an identity would sit in a reconnect loop
# looking like a network fault.
#
# Run as root. The key is generated in the Secure Enclave during this script and
# never leaves it, so the identity this creates belongs to this machine and
# cannot be copied to another.
#
#   sudo ./install.sh --url https://control-plane:8452 \
#                     --token JOIN_TOKEN \
#                     --ca server-ca.crt \
#                     --model mlx-community/Llama-3.2-3B-Instruct-4bit
#
set -euo pipefail

BINARY_DIR=/usr/local/libexec/dai
IDENTITY_DIR=/var/db/dai/identity
STATE_DIR=/var/db/dai
LOG_DIR=/var/log/dai
MODEL_DIR=/var/db/dai/models
PLIST=/Library/LaunchDaemons/com.dai.agent.plist
MENUBAR_APP=/Applications/dAI.app
MENUBAR_PLIST=/Library/LaunchAgents/com.dai.menubar.plist
LABEL=com.dai.agent

URL=""; TOKEN=""; CA=""; MODEL=""; ANE="-"; WAIT=600; SVC_USER="_dai"; PROMOTE=300; GPU_MODEL_CACHE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)   URL="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --ca)    CA="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --ane)   ANE="$2"; shift 2 ;;
    --wait)  WAIT="$2"; shift 2 ;;
    --user)  SVC_USER="$2"; shift 2 ;;
    # Seconds of sustained absence before GPU work is allowed to start. Long by
    # design; short only for testing, since waiting 5 minutes to see anything
    # happen makes the behaviour impossible to check by hand.
    --promote) PROMOTE="$2"; shift 2 ;;
    --gpu-model-cache) GPU_MODEL_CACHE="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "must run as root: sudo $0 ..." >&2; exit 1; }
# Written the long way because macOS ships bash 3.2, where ${var,,} and
# associative arrays are both syntax errors rather than features.
[[ -n "$URL" ]]   || { echo "missing --url" >&2; exit 2; }
[[ -n "$TOKEN" ]] || { echo "missing --token" >&2; exit 2; }
[[ -n "$CA" ]]    || { echo "missing --ca" >&2; exit 2; }
[[ -n "$MODEL" ]] || { echo "missing --model" >&2; exit 2; }
[[ -f "$CA" ]] || { echo "server CA not found: $CA" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# The xcodebuild product, not the SwiftPM one. SwiftPM's command line cannot
# compile MLX's Metal shaders, which is documented upstream, so a binary built
# with `swift build` aborts from C++ the first time it touches the GPU. It looks
# exactly like a missing Metal toolchain and is not.
BUILD="$HERE/../.xcbuild/Build/Products/Release"
[[ -x "$BUILD/dai-agent" ]] || {
  echo "no build found at $BUILD" >&2
  echo "run: xcodebuild build -scheme dai-agent -destination 'platform=OS X' \\" >&2
  echo "       -configuration Release -derivedDataPath .xcbuild \\" >&2
  echo "       ENABLE_CODE_COVERAGE=NO CLANG_ENABLE_CODE_COVERAGE=NO \\" >&2
  echo "       SWIFT_ENABLE_CODE_COVERAGE=NO" >&2
  exit 1
}

# The daemon runs as this account, not as root. Creating it here rather than
# documenting it as a prerequisite, because a prerequisite people skip becomes
# "just run it as root" and then nobody revisits it.
if [[ "$SVC_USER" != "root" ]] && ! id "$SVC_USER" >/dev/null 2>&1; then
  echo "==> creating service account $SVC_USER"
  # Pick a free uid in the system range. Below 500 keeps it out of the login
  # window and the user list.
  NEXT_UID=400
  while dscl . -list /Users UniqueID | awk '{print $2}' | grep -qx "$NEXT_UID"; do
    NEXT_UID=$((NEXT_UID + 1))
  done
  dscl . -create "/Users/$SVC_USER"
  dscl . -create "/Users/$SVC_USER" UserShell /usr/bin/false
  dscl . -create "/Users/$SVC_USER" RealName "dAI harvest agent"
  dscl . -create "/Users/$SVC_USER" UniqueID "$NEXT_UID"
  dscl . -create "/Users/$SVC_USER" PrimaryGroupID 20
  dscl . -create "/Users/$SVC_USER" NFSHomeDirectory /var/empty
  # No password, and explicitly no login: this account exists to own a process.
  dscl . -create "/Users/$SVC_USER" Password '*'
  dscl . -delete "/Users/$SVC_USER" AuthenticationAuthority 2>/dev/null || true
fi

echo "==> installing to $BINARY_DIR"
install -d -m 755 "$BINARY_DIR"
install -m 755 "$BUILD/dai-agent" "$BINARY_DIR/dai-agent"
# The resource bundles are looked up next to the executable, so they travel with
# it or the process dies on first use rather than at launch.
for bundle in "$BUILD"/*.bundle; do
  [[ -e "$bundle" ]] || continue
  rm -rf "$BINARY_DIR/$(basename "$bundle")"
  cp -R "$bundle" "$BINARY_DIR/"
done

install -d -m 700 "$STATE_DIR" "$IDENTITY_DIR"
install -d -m 755 "$LOG_DIR"

# /Users/Shared is sticky, so the service account cannot replace a status file
# somebody else created - and one left by a hand-run agent silently froze the
# menu bar at whatever it last said. Removed here so the daemon owns it.
rm -f /Users/Shared/.dai-status.json
install -m 600 "$CA" "$IDENTITY_DIR/server-ca.crt"

# Models are copied into the daemon's own state rather than referenced where
# they happen to sit. A path under someone's home is unreadable to the service
# account, and worse, may be on a FileVault volume that is not mounted at boot -
# so the daemon would work when installed and fail after a restart, which is the
# hardest kind of failure to attribute.
install -d -m 755 "$MODEL_DIR"
# The GPU model is staged too, rather than fetched by the daemon.
#
# Two reasons, and the second is the real one. The service account reports
# itself offline when it tries to reach the hub, so the fetch fails outright.
# But even where it works, a fleet whose selling point is that data never leaves
# the building should not have every node pulling weights from the internet on
# first use: models belong in the control plane's catalogue, distributed
# deliberately and verified by hash. This is the interim form of that.
# Note the layout: swift-transformers stores models as <base>/<org>/<repo>,
# not the models--org--repo form the Python hub client uses. Copying the Python
# cache here produces a directory that looks right and is never found.
if [[ -n "$GPU_MODEL_CACHE" && -d "$GPU_MODEL_CACHE" ]]; then
  echo "==> staging GPU model cache from $GPU_MODEL_CACHE"
  cp -R "$GPU_MODEL_CACHE"/. "$MODEL_DIR/"
fi

if [[ "$ANE" != "-" && -e "$ANE" ]]; then
  rm -rf "$MODEL_DIR/$(basename "$ANE")"
  cp -R "$ANE" "$MODEL_DIR/"
  ANE="$MODEL_DIR/$(basename "$ANE")"
  echo "==> ANE model staged at $ANE"
fi

# The identity belongs to the account that will use it. The Enclave blob is
# sealed to the machine rather than to a user, so ownership here is only about
# who can read the file, but a daemon that cannot read its own certificate fails
# in a way that looks like a certificate problem.
if [[ "$SVC_USER" != "root" ]]; then
  chown -R "$SVC_USER" "$STATE_DIR" "$LOG_DIR"
fi

echo "==> enrolling"
# Enrollment is resumable: re-running picks up the pending node rather than
# creating a second one and stranding the first in the approval queue.
# Enrolled as the service account, so the key is generated by the process that
# will sign with it rather than handed over afterwards.
RUN_AS=(env "DAI_IDENTITY_DIR=$IDENTITY_DIR")
[[ "$SVC_USER" != "root" ]] && RUN_AS=(sudo -u "$SVC_USER" "${RUN_AS[@]}")
if ! "${RUN_AS[@]}" "$BINARY_DIR/dai-agent" \
      enroll "$URL" "$TOKEN" "$IDENTITY_DIR/server-ca.crt" "$WAIT"; then
  echo "enrollment did not complete. Approve the node, then re-run this script." >&2
  exit 1
fi

if [[ ! -f "$IDENTITY_DIR/node.crt" ]]; then
  echo
  echo "Node is enrolled but not yet approved."
  echo "Approve it in the fleet UI, then re-run this script to finish."
  exit 1
fi

echo "==> installing daemon"
sed -e "s|@BINARY@|$BINARY_DIR/dai-agent|g" \
    -e "s|@URL@|$URL|g" \
    -e "s|@MODEL@|$MODEL|g" \
    -e "s|@ANE@|$ANE|g" \
    -e "s|@IDENTITY_DIR@|$IDENTITY_DIR|g" \
    -e "s|@STATE_DIR@|$STATE_DIR|g" \
    -e "s|@LOG_DIR@|$LOG_DIR|g" \
    -e "s|@USER@|$SVC_USER|g" \
    -e "s|@MODEL_DIR@|$STATE_DIR|g" \
    -e "s|@PROMOTE@|$PROMOTE|g" \
    "$HERE/com.dai.agent.plist.in" > "$PLIST"
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

# bootout first so re-running upgrades in place rather than failing on an
# already-loaded label.
launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

# The menu bar app, if it was built. Not fatal if absent: the daemon works
# without it. But a machine running this with no way for its owner to see or
# stop it is the arrangement the whole programme depends on not being, so the
# absence is called out rather than passed over.
if [[ -d "$BUILD/dAI.app" ]]; then
  echo "==> installing the menu bar app"
  rm -rf "$MENUBAR_APP"
  cp -R "$BUILD/dAI.app" "$MENUBAR_APP"
  sed -e "s|@APP@|$MENUBAR_APP|g" "$HERE/com.dai.menubar.plist.in" > "$MENUBAR_PLIST"
  chown root:wheel "$MENUBAR_PLIST"; chmod 644 "$MENUBAR_PLIST"
  # Loaded into the console user's session rather than system, since a
  # LaunchAgent belongs to a login session and there may not be one yet.
  CONSOLE_UID=$(stat -f%u /dev/console)
  if [[ "$CONSOLE_UID" != "0" ]]; then
    launchctl bootout "gui/$CONSOLE_UID/com.dai.menubar" 2>/dev/null || true
    launchctl bootstrap "gui/$CONSOLE_UID" "$MENUBAR_PLIST" 2>/dev/null || true
  fi
else
  echo "WARNING: no menu bar app was built, so this machine's owner has no" >&2
  echo "         visible way to see or stop what runs on it." >&2
fi

echo
echo "Installed. Runs as a system daemon under $SVC_USER, and survives logout."
echo "  logs:     tail -f $LOG_DIR/agent.log"
echo "  status:   sudo launchctl print system/$LABEL | head -20"
echo "  stop:     sudo launchctl bootout system/$LABEL"
