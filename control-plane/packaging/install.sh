#!/bin/bash
#
# Install the dAI control plane as a system daemon.
#
# Run as root. Everything it needs beyond Postgres it either brings or makes:
# the Node runtime is in the package, the TLS material is generated if absent,
# the database is created if missing, and the schema is applied every time so
# an upgrade is an install.
#
#   sudo ./install.sh --db postgres://dai:dai@localhost:5432/dai
#
# or, for an install nobody is standing at, the same settings from a file:
#
#   sudo ./install.sh --config "/Library/Application Support/dAI/control.json"
#
# Moving a control plane that already has a fleet - off a working tree, or onto
# a replacement machine - has to bring the certificate authority those machines
# trust. Every node certificate traces to it, and a new one locks all of them
# out at once:
#
#   sudo ./install.sh --adopt-certs /path/to/control-plane/certs --db ...
#
# The installer refuses to mint an authority when the database it was given
# already holds enrolled machines, rather than succeeding and taking the fleet
# down.
#
# Postgres is the one prerequisite. Bundling a database server is a much larger
# commitment than bundling an interpreter - it owns data, it needs its own
# upgrade story, and every platform already has a good way to install one - so
# this checks for it and says so rather than pretending.
set -euo pipefail

BINARY_DIR=/usr/local/libexec/dai-control
STATE_DIR=/var/db/dai-control
LOG_DIR=/var/log/dai-control
PLIST=/Library/LaunchDaemons/com.dai.control.plist
CONFIG_DIR="/Library/Application Support/dAI"
LABEL=com.dai.control

DB=""; PORT="8452"; SVC_USER="_daictl"; CONFIG=""; ADOPT=""
AGENT_CIDRS=""; ADMIN_CIDRS=""; MONITOR_CIDRS=""; HOSTNAME_FOR_CERT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)      DB="$2"; shift 2 ;;
    --port)    PORT="$2"; shift 2 ;;
    --user)    SVC_USER="$2"; shift 2 ;;
    --config)  CONFIG="$2"; shift 2 ;;
    # Which addresses may reach each surface. Left empty they mean "anywhere",
    # which is the right default for the surfaces that also want a credential
    # and the wrong one for monitoring, which has none.
    --agent-cidrs)   AGENT_CIDRS="$2"; shift 2 ;;
    --admin-cidrs)   ADMIN_CIDRS="$2"; shift 2 ;;
    --monitor-cidrs) MONITOR_CIDRS="$2"; shift 2 ;;
    # The name agents will use to reach this machine, which has to be in the
    # certificate or every one of them refuses the connection.
    --hostname) HOSTNAME_FOR_CERT="$2"; shift 2 ;;
    # Bring an existing certificate authority rather than minting one. The path
    # out of a working-tree deployment, and the answer when this machine is
    # replacing a control plane that lived somewhere else.
    --adopt-certs) ADOPT="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# Settings from a file, read with plutil because it is part of macOS. Flags win,
# so somebody standing at the machine is correcting the file rather than being
# overruled by it.
if [[ -n "$CONFIG" ]]; then
  [[ -f "$CONFIG" ]] || { echo "no configuration at $CONFIG" >&2; exit 1; }
  cfg() { plutil -extract "$1" raw -o - "$CONFIG" 2>/dev/null || true; }
  DB="${DB:-$(cfg databaseUrl)}"
  CFG_PORT="$(cfg port)"
  if [[ -n "$CFG_PORT" ]]; then PORT="${PORT:-$CFG_PORT}"; fi
  if [[ -z "$AGENT_CIDRS" ]];   then AGENT_CIDRS="$(cfg agentCidrs)"; fi
  if [[ -z "$ADMIN_CIDRS" ]];   then ADMIN_CIDRS="$(cfg adminCidrs)"; fi
  if [[ -z "$MONITOR_CIDRS" ]]; then MONITOR_CIDRS="$(cfg monitorCidrs)"; fi
  if [[ -z "$HOSTNAME_FOR_CERT" ]]; then HOSTNAME_FOR_CERT="$(cfg hostname)"; fi
  # Readable from the file too, because the install that most needs it is the
  # one nobody is standing at: an MDM replacing a control plane cannot be handed
  # a flag, and without this its only options are to mint an authority its fleet
  # does not trust or to refuse and wait for somebody.
  if [[ -z "$ADOPT" ]]; then ADOPT="$(cfg adoptCerts)"; fi
fi

[[ $EUID -eq 0 ]] || { echo "must run as root: sudo $0 ..." >&2; exit 1; }
[[ -n "$DB" ]] || { echo "missing --db (a postgres:// URL)" >&2; exit 2; }
[[ -n "$HOSTNAME_FOR_CERT" ]] || HOSTNAME_FOR_CERT="$(scutil --get LocalHostName 2>/dev/null || hostname)"

HERE="$(cd "$(dirname "$0")" && pwd)"
[[ -x "$HERE/node" ]] || { echo "no bundled runtime at $HERE/node" >&2; exit 1; }
[[ -f "$HERE/dist/server.js" ]] || { echo "no build at $HERE/dist/server.js" >&2; exit 1; }

# ---------------------------------------------------------------- service user
#
# Created here rather than documented as a prerequisite. A prerequisite people
# skip becomes "just run it as root", and then nobody revisits it - which
# matters more than usual for a process that holds the private key of the
# authority signing every node's identity.
if [[ "$SVC_USER" != "root" ]] && ! id "$SVC_USER" >/dev/null 2>&1; then
  echo "==> creating service account $SVC_USER"
  NEXT_UID=440
  while dscl . -list /Users UniqueID | awk '{print $2}' | grep -qx "$NEXT_UID"; do
    NEXT_UID=$((NEXT_UID + 1))
  done
  dscl . -create "/Users/$SVC_USER"
  dscl . -create "/Users/$SVC_USER" UserShell /usr/bin/false
  dscl . -create "/Users/$SVC_USER" RealName "dAI control plane"
  dscl . -create "/Users/$SVC_USER" UniqueID "$NEXT_UID"
  dscl . -create "/Users/$SVC_USER" PrimaryGroupID 20
  dscl . -create "/Users/$SVC_USER" NFSHomeDirectory /var/empty
  dscl . -create "/Users/$SVC_USER" Password '*'
fi

# ------------------------------------------------------------------ directories
for d in "$STATE_DIR" "$STATE_DIR/certs" "$STATE_DIR/node-ca" "$STATE_DIR/models" \
         "$STATE_DIR/scenes" "$STATE_DIR/blobs" "$STATE_DIR/outputs" "$LOG_DIR"; do
  mkdir -p "$d"
done
# The CA directory holds a private key and is readable by nobody else. The rest
# is content the service owns.
chown -R "$SVC_USER":wheel "$STATE_DIR" "$LOG_DIR"
chmod 700 "$STATE_DIR/node-ca" "$STATE_DIR/certs"

# ------------------------------------------------------------------------- TLS
#
# Generated once, and never regenerated. Replacing the server certificate on an
# established fleet means every agent that pinned the old CA stops connecting,
# which looks exactly like the network going away.
#
# Adopting is the third case, and the one that has no other path: a control
# plane moving from a working tree, or onto a replacement machine, has to bring
# the authority its fleet already trusts. Five files, and a partial copy is
# worse than none - a server certificate without its CA produces a fleet that
# cannot verify anything, discovered one node at a time.
if [[ -n "$ADOPT" ]]; then
  echo "==> adopting the certificate authority from $ADOPT"
  for f in ca.crt ca.key server.crt server.key srv-ca.crt; do
    [[ -f "$ADOPT/$f" ]] || { echo "  $ADOPT is missing $f" >&2; exit 2; }
  done
  cp "$ADOPT/server.crt" "$ADOPT/server.key" "$ADOPT/srv-ca.crt" "$STATE_DIR/certs/"
  [[ -f "$ADOPT/srv-ca.key" ]] && cp "$ADOPT/srv-ca.key" "$STATE_DIR/certs/"
  cp "$ADOPT/ca.crt" "$ADOPT/ca.key" "$STATE_DIR/node-ca/"
  chown -R "$SVC_USER":wheel "$STATE_DIR/certs" "$STATE_DIR/node-ca"
  chmod 600 "$STATE_DIR/certs"/*.key "$STATE_DIR/node-ca"/*.key
elif [[ ! -f "$STATE_DIR/node-ca/ca.crt" ]]; then
  # No authority here. Whether that is a new machine or a disaster depends on
  # something the shell cannot see: whether the database already holds a fleet
  # whose certificates this machine could not honour. Asked before anything is
  # written, because the alternative is an install that succeeds and locks every
  # machine out.
  if ! DATABASE_URL="$DB" "$HERE/node" "$HERE/dist/preflight.js" \
        --ca "$STATE_DIR/node-ca/ca.crt" --state-dir "$STATE_DIR"; then
    echo >&2
    echo "Nothing has been changed." >&2
    exit 3
  fi
  echo "==> generating TLS material for $HOSTNAME_FOR_CERT"
  "$HERE/make-certs.sh" --out "$STATE_DIR/certs" --host "$HOSTNAME_FOR_CERT"
  # make-certs writes both authorities into one directory; the daemon reads the
  # node CA from its own, so it is moved rather than referenced twice.
  cp "$STATE_DIR/certs/ca.crt" "$STATE_DIR/certs/ca.key" "$STATE_DIR/node-ca/" 2>/dev/null || true
  chown -R "$SVC_USER":wheel "$STATE_DIR/certs" "$STATE_DIR/node-ca"
  chmod 600 "$STATE_DIR/certs"/*.key
  [[ -f "$STATE_DIR/node-ca/ca.key" ]] && chmod 600 "$STATE_DIR/node-ca"/*.key
else
  echo "==> keeping the TLS material already here"
fi

# -------------------------------------------------------------------- database
echo "==> applying the schema"
# The migration creates the database if it is absent and is safe to re-run, so
# this same line is what an upgrade does. It fails loudly when Postgres is not
# reachable, which is the one prerequisite this installer cannot supply.
if ! DATABASE_URL="$DB" "$HERE/node" "$HERE/dist/migrate.js"; then
  echo >&2
  echo "the schema could not be applied. Postgres has to be running and reachable" >&2
  echo "at the URL given to --db before the control plane can start." >&2
  exit 1
fi

# ----------------------------------------------------------------------- plist
echo "==> installing $LABEL"
sed -e "s|@BINARY_DIR@|$BINARY_DIR|g" \
    -e "s|@STATE_DIR@|$STATE_DIR|g" \
    -e "s|@LOG_DIR@|$LOG_DIR|g" \
    -e "s|@USER@|$SVC_USER|g" \
    -e "s|@DATABASE_URL@|$DB|g" \
    -e "s|@PORT@|$PORT|g" \
    -e "s|@AGENT_CIDRS@|$AGENT_CIDRS|g" \
    -e "s|@ADMIN_CIDRS@|$ADMIN_CIDRS|g" \
    -e "s|@MONITOR_CIDRS@|$MONITOR_CIDRS|g" \
    "$HERE/com.dai.control.plist.in" > "$PLIST"
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

# bootout first, so re-running upgrades in place rather than failing on a label
# that is already loaded.
launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
launchctl enable "system/$LABEL"

echo
echo "control plane installed."
echo "  console   https://$HOSTNAME_FOR_CERT:$PORT/ui/"
echo "  logs      $LOG_DIR/control.log"
echo "  state     $STATE_DIR"
echo
echo "Sign in as admin / admin. It will make you choose a password before"
echo "anything else works, which is the point of shipping that account."
echo
echo "Agents need the server CA to verify this machine. Give them:"
echo "  $STATE_DIR/certs/srv-ca.crt"
