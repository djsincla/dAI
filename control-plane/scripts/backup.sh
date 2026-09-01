#!/bin/bash
#
# Everything the fleet cannot rebuild by itself, in one archive.
#
# Three things are irreplaceable and two of them are small:
#
#   The CA private key. Every node certificate traces to it. Lose it and every
#   machine has to enrol again, and enrolment needs the Secure Enclave, which
#   will not generate a key over ssh. So re-enrolling a fleet means walking to
#   each machine in person. It is 1.7KB.
#
#   The database. Node identities, which machines were approved and by whom,
#   pool membership, the model catalogue with its hashes, and the audit trail.
#   Small, and none of it can be derived from anything else.
#
#   The server configuration, which currently lives in whichever shell started
#   the process. That is how a restart once turned into archaeology.
#
# Model weights are deliberately excluded. They are large, they are the one
# thing that can be fetched again, and the catalogue records a hash for every
# file so a re-import can be verified rather than trusted.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$HERE/backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DB_URL="${DATABASE_URL:-postgres://dai:dai@localhost:5433/dai}"

# One way to reach the database, whichever one was asked for.
#
# The manifest used to be built by a hardcoded `docker exec ... -d dai` while
# the dump came from DATABASE_URL. Backing up anything other than the default
# produced an archive whose manifest described a different fleet, and the
# manifest is what a restore is checked against.
DB_NAME="$(printf '%s' "$DB_URL" | sed -E 's|.*/([^/?]+).*|\1|')"

dai_psql() {
  if command -v psql >/dev/null 2>&1; then
    psql -q -t -A "$DB_URL" "$@"
  else
    docker exec -i control-plane-postgres-1 psql -q -t -A -U dai -d "$DB_NAME" "$@"
  fi
}

echo "==> database"
# --clean --if-exists so a restore replaces rather than merges. Merging two
# fleets would leave duplicate node rows with the same certificate fingerprint,
# and the scheduler would dispatch to a machine that no longer exists.
if command -v pg_dump >/dev/null 2>&1; then
  pg_dump --clean --if-exists --no-owner --no-privileges "$DB_URL" > "$WORK/dai.sql"
else
  # No local client, so borrow the one inside the container.
  docker exec -i control-plane-postgres-1 \
    pg_dump --clean --if-exists --no-owner --no-privileges -U dai "$DB_NAME" > "$WORK/dai.sql"
fi
echo "    $(wc -l < "$WORK/dai.sql") lines"

echo "==> certificate authority"
# Where the authority lives. Overridable because the scripts were otherwise
# only runnable on a machine that already had one, which meant nothing could
# test them: CI reported "MISSING: certs/srv-ca.key" and was right to.
CERT_DIR="${DAI_CERT_DIR:-$HERE/certs}"
mkdir -p "$WORK/certs"
# The keys are the point of this whole script, so their absence is an error
# rather than a warning. A backup that quietly skipped them would be worse than
# no backup, because somebody would believe it.
for f in ca.crt ca.key srv-ca.crt srv-ca.key server.crt server.key; do
  if [[ -f "$CERT_DIR/$f" ]]; then
    cp "$CERT_DIR/$f" "$WORK/certs/$f"
  elif [[ "$f" == *.key ]]; then
    echo "    MISSING: certs/$f" >&2
    exit 1
  fi
done
chmod -R go-rwx "$WORK/certs"
echo "    $(ls "$WORK/certs" | wc -l | tr -d ' ') files"

echo "==> configuration"
# What the server needs to start, recorded because it currently exists only in
# the environment of whoever launched it.
cat > "$WORK/config.env" <<CONF
# Settings this control plane was running with when the backup was taken.
# Secrets are named but not captured: fill them in on restore.
DATABASE_URL=${DATABASE_URL:-<unset, defaulted to postgres://dai:dai@localhost:5433/dai>}
PORT=${PORT:-8443}
DAI_MODEL_REPO=${DAI_MODEL_REPO:-<unset, defaulted to ./models>}
DAI_REQUEST_TIMEOUT_MS=${DAI_REQUEST_TIMEOUT_MS:-<unset>}
DAI_AGENT_CIDRS=${DAI_AGENT_CIDRS:-<unset, any address accepted>}
DAI_ADMIN_CIDRS=${DAI_ADMIN_CIDRS:-<unset, any address accepted>}
DAI_IMPORT_PATHS=${DAI_IMPORT_PATHS:-<unset, defaults to the usual caches>}
CONF

echo "==> manifest"
# What was in the fleet at the time, so a restore can be checked against what
# it should have produced rather than merely completing without error.
{
  echo "taken_at=$STAMP"
  echo "host=$(hostname)"
  for t in nodes pools models model_files audit_log activity_log agent_builds; do
    n=$(dai_psql -c "select count(*) from $t" 2>/dev/null || echo "?")
    echo "$t=$n"
  done
} > "$WORK/manifest.txt"

mkdir -p "$OUT_DIR"
ARCHIVE="$OUT_DIR/dai-backup-$STAMP.tar.gz"
tar -czf "$ARCHIVE" -C "$WORK" .
chmod 600 "$ARCHIVE"

echo
echo "wrote $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
echo
echo "This archive contains the CA private key in the clear. It is the one file"
echo "that lets somebody issue a certificate this fleet will trust, so it wants"
echo "to be somewhere with fewer readers than the machine it came from."
