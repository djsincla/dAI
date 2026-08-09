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
SVC_USER="_dai"
[[ "${1:-}" == "--purge" ]] && PURGE=1

[[ $EUID -eq 0 ]] || { echo "must run as root: sudo $0" >&2; exit 1; }

echo "==> stopping"
# ExitTimeOut in the plist gives the worker its grace period to finish the item
# in flight and report it, so this is not as abrupt as it looks.
launchctl bootout "system/$LABEL" 2>/dev/null || true

rm -f "$PLIST"
rm -rf "$BINARY_DIR"

CONSOLE_UID=$(stat -f%u /dev/console)
[[ "$CONSOLE_UID" != "0" ]] && launchctl bootout "gui/$CONSOLE_UID/com.dai.menubar" 2>/dev/null
rm -f /Library/LaunchAgents/com.dai.menubar.plist
rm -rf /Applications/dAI.app
pkill -f 'dAI.app/Contents/MacOS/dai-menubar' 2>/dev/null || true

if [[ $PURGE -eq 1 ]]; then
  echo "==> removing identity (this node will need re-enrolling and re-approving)"
  rm -rf "$STATE_DIR" "$LOG_DIR"
  # The installer creates this account, so uninstalling should take it away
  # again. Leaving service accounts behind after the thing they served is gone
  # is how machines accumulate users nobody can account for.
  if [[ "$SVC_USER" != "root" ]] && id "$SVC_USER" >/dev/null 2>&1; then
    echo "==> removing service account $SVC_USER"
    # sysadminctl rather than `dscl . -delete`, which returns
    # eDSPermissionError (-14120) even as root: deleting a user is a directory
    # operation with its own authorisation, not a file permission.
    sysadminctl -deleteUser "$SVC_USER" 2>/dev/null \
      || dscl . -delete "/Users/$SVC_USER" 2>/dev/null \
      || echo "could not remove $SVC_USER; remove it by hand" >&2
  fi
else
  echo "identity kept in $IDENTITY_DIR; re-run install.sh to restart the agent"
  echo "pass --purge to remove it, which means enrolling this node again"
fi

echo "Removed."
