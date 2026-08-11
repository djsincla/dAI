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
UPDATER_PLIST=/Library/LaunchDaemons/com.dai.updater.plist
UPDATER_LABEL=com.dai.updater
PENDING=/var/db/dai/pending-upgrade.json
ROLLBACK=/var/db/dai/dai-agent.rollback

PURGE=0
SVC_USER="_dai"
[[ "${1:-}" == "--purge" ]] && PURGE=1

[[ $EUID -eq 0 ]] || { echo "must run as root: sudo $0" >&2; exit 1; }

echo "==> stopping"
# The updater goes first, and this script waits for it to be gone rather than
# just asking. It runs as root every two minutes, and it exists to put the
# agent binary back: booting it out after deleting the binary leaves a window
# where it wakes up, finds the machine still enrolled and the binary missing,
# and reinstalls the thing being uninstalled.
#
# `launchctl bootout` returns when the job has been asked to stop, not when it
# has stopped, and a pass that is mid-download holds the network for as long as
# the fetch takes. So the wait is the fix; the ordering alone is not enough.
launchctl bootout "system/$UPDATER_LABEL" 2>/dev/null || true
waited=0
while launchctl print "system/$UPDATER_LABEL" >/dev/null 2>&1; do
  if [ "$waited" -ge 60 ]; then
    echo "$UPDATER_LABEL did not unload after 60s; not removing the binary" >&2
    echo "it may be mid-upgrade. Re-run this once it has finished." >&2
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done
rm -f "$UPDATER_PLIST"

# ExitTimeOut in the plist gives the worker its grace period to finish the item
# in flight and report it, so this is not as abrupt as it looks.
launchctl bootout "system/$LABEL" 2>/dev/null || true

rm -f "$PLIST"
rm -rf "$BINARY_DIR"

# An upgrade that was in flight is now an upgrade of a binary that no longer
# exists. These are removed even without --purge, which otherwise keeps
# everything under the state directory: a marker that outlives its binary is
# not a record of anything, and the next install would act on it. The updater
# reads it before it considers anything else, sees a deadline long past and no
# agent reporting in, and restores the rollback copy over the version that was
# just installed - so a machine reinstalled after an interrupted upgrade
# silently comes back on the older build.
rm -f "$PENDING" "$ROLLBACK"

CONSOLE_UID=$(stat -f%u /dev/console)
# `|| true` because the menu bar job is often not loaded: the installer only
# adds it when the app was built, and a headless machine has no console user to
# load it for. Without this, `set -e` takes a failed bootout as a reason to
# stop the entire uninstall - after the agent has been removed and before the
# identity, the logs and the service account are, so --purge would report
# nothing and leave behind exactly what it promised to delete.
[[ "$CONSOLE_UID" != "0" ]] && launchctl bootout "gui/$CONSOLE_UID/com.dai.menubar" 2>/dev/null || true
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
