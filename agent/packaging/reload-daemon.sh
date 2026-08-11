#!/bin/bash
#
# Reload a launchd job, waiting for the old one to actually be gone.
#
# `launchctl bootout` is asynchronous. It returns as soon as the job has been
# asked to stop, not when it has stopped, and this daemon holds a long-poll
# connection to the control plane so it can take seconds to exit. Bootstrapping
# into a label that still exists fails with `5: Input/output error`, which says
# nothing about what happened and is easy to read as a broken plist.
#
# That failure left a machine with no daemon at all: bootout had succeeded, so
# the working agent was gone, and the install aborted after every other step had
# already reported success. A re-install has to be safe to run on a machine
# that is currently working, or nobody can safely upgrade a fleet.
#
# Usage: reload-daemon.sh <domain> <label> <plist> [timeout-seconds]
#   domain is a launchd domain target: `system`, or `gui/501` for a user agent.
set -euo pipefail

DOMAIN="$1"; LABEL="$2"; PLIST="$3"; TIMEOUT="${4:-60}"
TARGET="$DOMAIN/$LABEL"

launchctl bootout "$TARGET" 2>/dev/null || true

waited=0
while launchctl print "$TARGET" >/dev/null 2>&1; do
  if [ "$waited" -ge "$TIMEOUT" ]; then
    echo "$LABEL did not unload after ${TIMEOUT}s; not replacing it" >&2
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done

launchctl bootstrap "$DOMAIN" "$PLIST"

# Bootstrap can accept a plist and still leave nothing running. Checking here
# means the installer reports what is true rather than what it attempted.
if ! launchctl print "$TARGET" >/dev/null 2>&1; then
  echo "$LABEL was accepted by launchd but is not loaded" >&2
  exit 1
fi
