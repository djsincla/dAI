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
PLIST=/Library/LaunchDaemons/com.dai.agent.plist
LABEL=com.dai.agent

URL=""; TOKEN=""; CA=""; MODEL=""; ANE="-"; WAIT=600
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)   URL="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --ca)    CA="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --ane)   ANE="$2"; shift 2 ;;
    --wait)  WAIT="$2"; shift 2 ;;
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
BUILD="$HERE/../.build/release"
[[ -x "$BUILD/dai-agent" ]] || {
  echo "no release build found. Run: swift build -c release" >&2; exit 1
}

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
install -m 600 "$CA" "$IDENTITY_DIR/server-ca.crt"

echo "==> enrolling"
# Enrollment is resumable: re-running picks up the pending node rather than
# creating a second one and stranding the first in the approval queue.
if ! DAI_IDENTITY_DIR="$IDENTITY_DIR" "$BINARY_DIR/dai-agent" \
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
    "$HERE/com.dai.agent.plist.in" > "$PLIST"
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

# bootout first so re-running upgrades in place rather than failing on an
# already-loaded label.
launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

echo
echo "Installed. The agent runs as a system daemon and survives logout."
echo "  logs:     tail -f $LOG_DIR/agent.log"
echo "  status:   sudo launchctl print system/$LABEL | head -20"
echo "  stop:     sudo launchctl bootout system/$LABEL"
