#!/bin/bash
#
# Build a release: both packages, their checksums, and a note saying what an
# upgrade needs.
#
#   ./scripts/release.sh 0.1.0 \
#       --app-id "Developer ID Application: Example Inc (TEAMID)" \
#       --installer-id "Developer ID Installer: Example Inc (TEAMID)" \
#       --notary-profile dai-notary
#
#   ./scripts/release.sh 0.1.0 --unsigned    # to check the build, nothing else
#
# The tests run first and a failure stops the build. That is the whole reason
# this script exists rather than a line in a README: the two packages are built
# by separate scripts in separate directories, and a release where one of them
# was built from a tree that did not pass is a release nobody can reason about.
set -euo pipefail

VERSION="${1:-}"; shift || true
[[ -n "$VERSION" ]] || { echo "usage: $0 <version> [signing options]" >&2; exit 2; }

SIGNING=("$@")
UNSIGNED=0
for arg in "$@"; do [[ "$arg" == "--unsigned" ]] && UNSIGNED=1; done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist/$VERSION"

LOGS="$(mktemp -d)"

# Run a suite with its output kept and a clock on it.
#
# Both of those are here because of the same afternoon. The output used to go to
# /dev/null, so when a suite wedged there was nothing to look at - and it did
# wedge, for one hour and fifty-four minutes, on a Foundation deadlock that a
# stack sample found in a minute and a silent build could never have shown. A
# test run that stops making progress is a failure, not a slow pass, and a
# release script has to be able to tell the difference.
#
# TIMEOUT is generous: the agent suite takes 45 seconds and the control plane's
# about 90. Anything past ten minutes is not slow, it is stuck.
TIMEOUT="${DAI_TEST_TIMEOUT:-600}"
run_suite() {
  local name="$1" dir="$2"; shift 2
  local log="$LOGS/$name.log"
  ( cd "$dir" && "$@" >"$log" 2>&1 ) &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null && [[ $waited -lt $TIMEOUT ]]; do
    sleep 5; waited=$((waited + 5))
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "$name tests stopped making progress after ${waited}s; not building a release" >&2
    echo "  log: $log" >&2
    echo "  last lines:" >&2
    tail -15 "$log" >&2
    # A sample, while the process is still there to sample. This is the artifact
    # that identifies a hang, and it is gone the moment the process is killed.
    local host
    host="$(pgrep -f 'swiftpm-testing-helper|vitest' | head -1 || true)"
    if [[ -n "$host" ]]; then
      sample "$host" 5 -mayDie -f "$LOGS/$name-hang.sample" >/dev/null 2>&1 || true
      echo "  stack sample: $LOGS/$name-hang.sample" >&2
    fi
    kill "$pid" 2>/dev/null || true
    pkill -f swiftpm-testing-helper 2>/dev/null || true
    exit 1
  fi
  wait "$pid" || {
    echo "$name tests failed; not building a release" >&2
    tail -30 "$log" >&2
    exit 1
  }
}

echo "==> tests"
# Both suites, because a release is both halves. The control plane's suite drops
# and recreates a schema, so it is pointed at its own database rather than
# whatever DATABASE_URL happens to be - the same reason the test helper refuses
# to take it from there.
run_suite "control plane" "$ROOT/control-plane" \
  env TEST_DATABASE_URL="${TEST_DATABASE_URL:-postgres://dai:dai@localhost:5433/dai_test}" npm test
run_suite "agent" "$ROOT/agent" swift test
echo "    both suites green"

echo "==> agent package"
(cd "$ROOT/agent/packaging" && ./build-pkg.sh --version "$VERSION" "${SIGNING[@]}" >/dev/null)

echo "==> control plane package"
(cd "$ROOT/control-plane/packaging" && ./build-control-pkg.sh --version "$VERSION" "${SIGNING[@]}" >/dev/null)

rm -rf "$OUT" && mkdir -p "$OUT"
cp "$ROOT"/agent/packaging/dist/dai-agent-"$VERSION"*.pkg "$OUT/"
cp "$ROOT"/control-plane/packaging/dist/dai-control-"$VERSION"*.pkg "$OUT/"

echo "==> checksums"
(cd "$OUT" && shasum -a 256 ./*.pkg > SHA256SUMS)

# The names as built, not as predicted. An unsigned build carries -unsigned in
# the filename, and a note telling somebody to install a file that is not there
# is worse than no note.
AGENT_PKG="$(cd "$OUT" && ls dai-agent-*.pkg)"
CONTROL_PKG="$(cd "$OUT" && ls dai-control-*.pkg)"

# What changed in the schema since the last tag. An upgrade applies the whole
# file, so this is not a list of steps to run - it is the answer to "what is
# about to happen to my database", which is the question somebody asks before
# they let an installer near it.
# The highest tag that is not the one being built. `git describe` would answer
# with this release's own tag once it exists, and then diff the schema against
# itself and report that nothing changed - which is the most confident way to be
# wrong about a database.
PREVIOUS="$(git -C "$ROOT" tag --list --sort=-v:refname \
              | grep -vx "$VERSION" | head -1 || true)"
if [[ -z "$PREVIOUS" ]]; then
  # Not "this is the first release", which this cannot know. A repository with
  # no tags is a repository nobody has tagged, and an empty list of schema
  # changes reads as "nothing will happen to your database" in exactly the
  # place somebody needs the truth.
  SCHEMA_CHANGES="(nothing to compare against: no other release is tagged in this
repository, so the schema changes could not be computed. Tag releases as they are
built - git tag $VERSION - and this section fills itself in.)"
else
  # The statements themselves rather than a diffstat. "schema.sql | 14 +++-" is
  # a fact about a file; the question being asked is what is about to happen to
  # a database that already has data in it.
  #
  # Split on semicolons rather than on lines, because a statement that wraps -
  # and several here do - is a statement whose column name is on the second
  # line. Reading line by line printed `ALTER TABLE nodes ADD COLUMN IF NOT
  # EXISTS` and stopped, which is exactly the word somebody needed.
  #
  # Guarded blocks are trimmed to the statement they guard: `DO $$ BEGIN IF NOT
  # EXISTS (SELECT 1 FROM pg_constraint...) THEN` is how the file makes itself
  # re-runnable and is not news about anybody's database. Table bodies are
  # dropped for the same reason - the name is the fact.
  SCHEMA_CHANGES="$(git -C "$ROOT" diff "$PREVIOUS" -- control-plane/db/schema.sql \
      | grep -E '^\+' | grep -vE '^\+\+\+' | sed 's/^+//' \
      | grep -vE '^[[:space:]]*--' \
      | awk 'BEGIN { RS = ";" }
             { line = $0
               gsub(/[\n\t]+/, " ", line); gsub(/  +/, " ", line)
               sub(/^ +/, "", line); sub(/ +$/, "", line)
               sub(/^DO \$\$.*THEN +/, "", line)
               if (line ~ /^CREATE TABLE/) sub(/ *\(.*/, "", line)
               if (toupper(line) ~ /ALTER TABLE|CREATE TABLE|CREATE INDEX|DROP /)
                 print "  " line ";" }' || true)"
  [[ -n "$SCHEMA_CHANGES" ]] || SCHEMA_CHANGES="(no schema changes since $PREVIOUS)"
fi

cat > "$OUT/RELEASE.md" <<EOF
# dAI $VERSION

Built $(date -u +%Y-%m-%dT%H:%M:%SZ) from $(git -C "$ROOT" rev-parse --short HEAD).

| Package | Installs |
|---|---|
| \`$AGENT_PKG\` | the harvest agent, as a system daemon, on every machine that lends capacity |
| \`$CONTROL_PKG\` | the control plane, as a system daemon, on one machine |

## Installing

The control plane first, because an agent with nothing to enrol against waits.

Postgres is the one prerequisite it cannot supply. Then:

    sudo installer -pkg $CONTROL_PKG -target /
    sudo /usr/local/libexec/dai-control/install.sh \\
        --db postgres://user:pass@localhost:5432/dai \\
        --hostname control.example.com

It prints where the console is and which certificate to give the agents. Sign
in as \`admin\` / \`admin\`; it will make you choose a password before anything
else works.

Then each machine. One package for every site - what differs is a file:

    /Library/Application Support/dAI/config.json
    { "url": "https://control.example.com:8452",
      "joinToken": "...",
      "caPath": "/Library/Application Support/dAI/server-ca.crt" }

    sudo installer -pkg $AGENT_PKG -target /

With that file present the package enrols the machine and starts. Without it
the package installs and deliberately starts nothing, so MDM may deliver the
two payloads in either order.

Approve each machine in the console. Nothing runs on it until you do.

## Upgrading

Install the newer package over the older one. Both installers are re-runnable
and the schema is applied every time, so there is no separate migration step.

Schema changes since ${PREVIOUS:-the beginning}:

\`\`\`
$SCHEMA_CHANGES
\`\`\`

## Removing

    sudo /usr/local/libexec/dai/uninstall.sh              # keeps the identity
    sudo /usr/local/libexec/dai/uninstall.sh --purge      # enrol it again

The control plane's uninstaller never touches the database, with or without
\`--purge\`. Removing that is a decision made deliberately, with a database
tool.
EOF

echo
echo "Release in $OUT"
ls -1 "$OUT"
if [[ $UNSIGNED -eq 1 ]]; then
  echo
  echo "UNSIGNED. Gatekeeper will refuse both packages anywhere but here."
fi
