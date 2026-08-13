#!/bin/bash
#
# Change which model this machine serves.
#
#   sudo ./scripts/set-served-model.sh --model mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit
#   sudo ./scripts/set-served-model.sh --show
#   sudo ./scripts/set-served-model.sh --revert
#
# The model a node serves is a positional argument in its launchd plist, fixed
# when the agent was installed. Which models a node *holds* is managed by the
# fleet - assign one to a pool and the weights distribute themselves - but which
# one it *loads* is a string on each machine. So you can push seventeen
# gigabytes of weights to fifty Macs centrally and then have no way to make any
# of them serve it, which is the gap this script papers over until the control
# plane can say "serve this" the way it can already say "hold this".
#
# It edits with plutil rather than sed. The plist is XML, the model sits at a
# fixed index in an array, and a text substitution that matches the wrong string
# leaves a daemon that will not start.
set -euo pipefail

PLIST=/Library/LaunchDaemons/com.dai.agent.plist
LABEL=com.dai.agent
MODEL_INDEX=3          # dai-agent work <url> <model> <ane-model>
MODEL=""; SHOW=0; REVERT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)  MODEL="$2"; shift 2 ;;
    --show)   SHOW=1; shift ;;
    --revert) REVERT=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -f "$PLIST" ]] || { echo "no agent daemon at $PLIST" >&2; exit 1; }

current() { plutil -extract "ProgramArguments.$MODEL_INDEX" raw -o - "$PLIST"; }

if [[ $SHOW -eq 1 ]]; then
  echo "serving: $(current)"
  exit 0
fi

[[ $EUID -eq 0 ]] || { echo "must run as root: sudo $0 ..." >&2; exit 1; }

if [[ $REVERT -eq 1 ]]; then
  BACKUP=/var/db/dai/com.dai.agent.plist.before-model-change
  [[ -f "$BACKUP" ]] || { echo "no backup at $BACKUP" >&2; exit 1; }
  cp "$BACKUP" "$PLIST"
  echo "reverted to: $(current)"
else
  [[ -n "$MODEL" ]] || { echo "missing --model (or --show / --revert)" >&2; exit 2; }

  # The weights have to be here already. Without this the daemon restarts,
  # fails to load, and the machine looks like it has broken rather than like it
  # was asked for something it does not have.
  STORE="/var/db/dai/models/$MODEL"
  ALT="/var/db/dai/$MODEL"
  if [[ ! -d "$STORE" && ! -d "$ALT" ]]; then
    echo "this machine does not hold $MODEL" >&2
    echo "  looked in $STORE and $ALT" >&2
    echo "  assign it to a pool this node is in and wait for the transfer" >&2
    exit 1
  fi

  echo "was:  $(current)"
  # Not beside the plist. /Library/LaunchDaemons is a directory launchd scans,
  # and leaving anything there that is not a job somebody meant to install is
  # how a machine ends up with a daemon nobody can account for.
  mkdir -p /var/db/dai
  cp "$PLIST" /var/db/dai/com.dai.agent.plist.before-model-change
  plutil -replace "ProgramArguments.$MODEL_INDEX" -string "$MODEL" "$PLIST"
  echo "now:  $(current)"
fi

echo "==> reloading $LABEL"
launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
launchctl enable "system/$LABEL"

echo
echo "Loading a model takes a moment. Watch it:"
echo "  tail -f /var/log/dai/agent.log"
echo
echo "If it does not come back:"
echo "  sudo $0 --revert"
