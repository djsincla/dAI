#!/bin/bash
#
# Remove the control plane.
#
# The database is never touched. It holds the fleet - every node's identity, the
# jobs, the audit log - and deleting it because somebody uninstalled a service
# would be the most destructive thing in this repository. Removing it is a
# decision made with a database tool, deliberately, by somebody who means it.
set -euo pipefail

BINARY_DIR=/usr/local/libexec/dai-control
STATE_DIR=/var/db/dai-control
LOG_DIR=/var/log/dai-control
PLIST=/Library/LaunchDaemons/com.dai.control.plist
CONFIG_DIR="/Library/Application Support/dAI"
LABEL=com.dai.control
SVC_USER="_daictl"
PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

[[ $EUID -eq 0 ]] || { echo "must run as root: sudo $0 [--purge]" >&2; exit 1; }

echo "==> stopping $LABEL"
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$BINARY_DIR"

if [[ $PURGE -eq 1 ]]; then
  echo "==> removing state, certificates and the node CA"
  # This is the part worth pausing over. The node CA's private key lives here,
  # and every certificate the fleet holds was signed by it: losing it means
  # every machine has to be enrolled and approved again, even though the
  # database still lists them.
  rm -rf "$STATE_DIR" "$LOG_DIR" "$CONFIG_DIR/control.json"
  if id "$SVC_USER" >/dev/null 2>&1; then
    echo "==> removing service account $SVC_USER"
    sysadminctl -deleteUser "$SVC_USER" 2>/dev/null \
      || dscl . -delete "/Users/$SVC_USER" 2>/dev/null \
      || echo "could not remove $SVC_USER; remove it by hand" >&2
  fi
  echo
  echo "The database was not touched. It still holds the fleet."
else
  echo
  echo "state kept in $STATE_DIR, including the node CA - reinstalling resumes"
  echo "the same fleet. Pass --purge to remove it, which means enrolling every"
  echo "machine again."
fi
