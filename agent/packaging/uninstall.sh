#!/bin/bash
#
# Remove the dAI agent.
#
# The identity survives by default. Deleting it is not reversible in the way it
# looks: the Enclave key cannot be recovered or recreated, so the node has to be
# enrolled and approved again from scratch. Pass --purge when that is what you
# actually want.
#
#   sudo ./uninstall.sh [--purge]
#
set -euo pipefail

BINARY_DIR=/usr/local/libexec/dai
IDENTITY_DIR=/var/db/dai/identity
STATE_DIR=/var/db/dai
LOG_DIR=/var/log/dai
PLIST=/Library/LaunchDaemons/com.dai.agent.plist
LABEL=com.dai.agent

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

[[ $EUID -eq 0 ]] || { echo "must run as root: sudo $0" >&2; exit 1; }

echo "==> stopping"
# ExitTimeOut in the plist gives the worker its grace period to finish the item
# in flight and report it, so this is not as abrupt as it looks.
launchctl bootout "system/$LABEL" 2>/dev/null || true

rm -f "$PLIST"
rm -rf "$BINARY_DIR"

if [[ $PURGE -eq 1 ]]; then
  echo "==> removing identity (this node will need re-enrolling and re-approving)"
  rm -rf "$STATE_DIR" "$LOG_DIR"
else
  echo "identity kept in $IDENTITY_DIR; re-run install.sh to restart the agent"
  echo "pass --purge to remove it, which means enrolling this node again"
fi

echo "Removed."
