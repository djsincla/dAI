#!/bin/bash
#
# Put a fleet back from an archive.
#
# Restoring is the half nobody exercises, so this refuses to be run casually and
# says exactly what it is about to replace. A backup nobody has restored is a
# hope, not a backup, and the round trip is covered by a test that takes a real
# archive, drops the database and brings it back.
#
# Usage: restore.sh <archive.tar.gz> [--yes]
set -euo pipefail

ARCHIVE="${1:-}"
CONFIRM="${2:-}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
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

[[ -f "$ARCHIVE" ]] || { echo "usage: restore.sh <archive.tar.gz> [--yes]" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xzf "$ARCHIVE" -C "$WORK"

echo "This archive holds:"
sed 's/^/    /' "$WORK/manifest.txt"
echo
echo "Restoring will replace the current database and certificate authority."

if [[ "$CONFIRM" != "--yes" ]]; then
  # Replacing a CA is not undoable: every certificate issued by the one being
  # discarded stops being trusted the moment this finishes.
  read -r -p "Type the word restore to continue: " answer
  [[ "$answer" == "restore" ]] || { echo "stopped"; exit 1; }
fi

echo "==> certificate authority"
# Same override as backup.sh, and for the same reason.
CERT_DIR="${DAI_CERT_DIR:-$HERE/certs}"
mkdir -p "$CERT_DIR"
# The existing CA is moved aside rather than overwritten. If this restore turns
# out to be the wrong archive, the fleet that was working five minutes ago is
# still recoverable.
if [[ -f "$CERT_DIR/ca.key" ]]; then
  ASIDE="$CERT_DIR/superseded-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$ASIDE"
  cp "$HERE"/certs/*.key "$HERE"/certs/*.crt "$ASIDE"/ 2>/dev/null || true
  chmod -R go-rwx "$ASIDE"
  echo "    previous CA kept at $ASIDE"
fi
cp "$WORK"/certs/* "$CERT_DIR/"
chmod go-rwx "$HERE"/certs/*.key

echo "==> database"
if command -v psql >/dev/null 2>&1; then
  psql -q "$DB_URL" < "$WORK/dai.sql"
else
  docker exec -i control-plane-postgres-1 psql -q -U dai -d "$DB_NAME" < "$WORK/dai.sql"
fi

echo "==> checking against the manifest"
FAILED=0
while IFS='=' read -r table expected; do
  case "$table" in
    nodes|pools|models|model_files|audit_log|activity_log|agent_builds) ;;
    *) continue ;;
  esac
  [[ "$expected" == "?" ]] && continue
  actual=$(dai_psql -c "select count(*) from $table" 2>/dev/null || echo "?")
  if [[ "$actual" == "$expected" ]]; then
    printf "    %-16s %s\n" "$table" "$actual"
  else
    printf "    %-16s %s (expected %s) MISMATCH\n" "$table" "$actual" "$expected"
    FAILED=1
  fi
done < "$WORK/manifest.txt"

if [[ "$FAILED" != "0" ]]; then
  # Counted rather than assumed, because a restore that ran without error and
  # produced the wrong fleet is the failure worth catching here rather than
  # three days later.
  echo
  echo "Restore finished but the row counts do not match the archive." >&2
  exit 1
fi

echo
echo "Restored. Model weights are not in this archive: re-import them and the"
echo "catalogue's per-file hashes will confirm they are the same bytes."
