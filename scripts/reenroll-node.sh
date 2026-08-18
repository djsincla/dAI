#!/bin/bash
#
# Give this machine a current identity, and retire the rows it left behind.
#
#   sudo ./scripts/reenroll-node.sh --url https://127.0.0.1:8452 \
#                                   --ca /path/to/srv-ca.crt \
#                                   --token "$(dai-fleet token)"
#
# Join tokens are single use, so this needs a fresh one rather than the one
# the machine first enrolled with. `dai-fleet token` is that one command.
#
# Why this exists rather than a paragraph in a runbook.
#
# A node that re-enrols gets a new row and the old one is marked superseded. If
# the daemon holding the old certificate is still running - which is exactly
# what happens when somebody enrols by hand while the service is up - it keeps
# authenticating, because nothing on the agent surface checks node state. The
# fleet then shows the new row, which is dead, and hides the old one, which is
# the machine you are sitting at. The console says ABSENT about a machine in
# use, and that is the one thing this system is not allowed to get wrong.
#
# So: stop the daemon first, archive the identity rather than delete it, enrol
# once, and only then start anything.
set -euo pipefail

URL=""; CA=""; WAIT=600; LABEL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)   URL="$2"; shift 2 ;;
    --ca)    CA="$2"; shift 2 ;;
    --wait)  WAIT="$2"; shift 2 ;;
    --token) LABEL="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "must run as root: sudo $0 ..." >&2; exit 1; }
[[ -n "$URL" ]] || { echo "missing --url" >&2; exit 2; }

AGENT=/usr/local/libexec/dai/dai-agent
IDENTITY=/var/db/dai/identity
PLIST=/Library/LaunchDaemons/com.dai.agent.plist
LABEL_JOB=com.dai.agent
STAMP="$(date +%Y%m%dT%H%M%S)"

[[ -x "$AGENT" ]] || { echo "no agent at $AGENT" >&2; exit 1; }
[[ -n "$LABEL" ]] || { echo "missing --token (the join token)" >&2; exit 2; }

echo "==> stopping the daemon"
# Before touching the identity, so the running process cannot re-create files
# under it or heartbeat once more on the certificate being retired.
launchctl bootout "system/$LABEL_JOB" 2>/dev/null || true
for _ in $(seq 1 20); do
  pgrep -f "$AGENT work" >/dev/null || break
  sleep 0.5
done
if pgrep -f "$AGENT work" >/dev/null; then
  echo "the agent is still running; not continuing" >&2
  exit 1
fi

echo "==> archiving the old identity"
# Archived, not deleted. If enrolment fails halfway the machine still has the
# credential it had this morning, and putting it back is a mv.
if [[ -d "$IDENTITY" ]]; then
  mv "$IDENTITY" "$IDENTITY.superseded-$STAMP"
  echo "    $IDENTITY.superseded-$STAMP"
fi
mkdir -p "$IDENTITY"

echo "==> enrolling"
echo "    approve this machine in the console; waiting up to ${WAIT}s"
# The CA is copied somewhere the service account can read. A path under a user's
# home directory usually is not, and enrolment then fails on a file that is
# plainly there when root looks for it.
CA_ARG=""
if [[ -n "$CA" ]]; then
  [[ -f "$CA" ]] || { echo "no CA file at $CA" >&2; exit 1; }
  install -m 644 -o _dai "$CA" /var/db/dai/srv-ca.crt
  CA_ARG=/var/db/dai/srv-ca.crt
fi
# Run as the service account so the files land with the ownership the daemon
# needs. Enrolling as root leaves root-owned keys that the daemon cannot read,
# which fails later and looks like a certificate problem.
if sudo -u _dai DAI_IDENTITY_DIR="$IDENTITY" "$AGENT" enroll "$URL" "$LABEL" "$CA_ARG" "$WAIT"; then
  echo "    enrolled"
else
  echo >&2
  echo "enrolment failed. The previous identity is still at" >&2
  echo "  $IDENTITY.superseded-$STAMP" >&2
  echo "and can be restored with:" >&2
  echo "  sudo rm -rf $IDENTITY && sudo mv $IDENTITY.superseded-$STAMP $IDENTITY" >&2
  exit 1
fi

chown -R _dai "$IDENTITY"
chmod 700 "$IDENTITY"

echo "==> starting the daemon"
launchctl bootstrap system "$PLIST"
launchctl enable "system/$LABEL_JOB"

echo
echo "Done. Watch it come back:"
echo "  tail -f /var/log/dai/agent.log"
echo
echo "Approving this node retires the earlier rows for the same hardware by"
echo "itself - that is what approval already does, keyed on machine_id - so the"
echo "fleet view should show one rotorua and one orca once you have approved."
