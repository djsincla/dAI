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
# TIMEOUT is a ceiling on the whole suite, not a measure of progress, and the
# difference matters because this once reported the wrong thing.
#
# The number was written when the control plane's suite took about 90 seconds
# and 600 was seven times generous. It now takes about eleven minutes - it drops
# and recreates a schema, and a dozen files talk to a real Postgres - so the
# guard fell below the suite it was guarding, and a healthy 0.8.1 was refused
# with "stopped making progress". A guard that fails a good release is worse
# than no guard, because it teaches people to remove it.
#
# Measured on this fleet, on a machine also serving models: agent ~45 s, control
# plane 505-660 s across four runs. 1800 is not "slow", it is stuck.
#
# Progress would be the better thing to measure, and it cannot be measured here:
# vitest buffers when its output is redirected to a file, so the log sits at 96
# bytes for the entire run. A stall detector on log growth would fire on every
# healthy release, which is the failure this comment exists to prevent, in the
# other direction.
TIMEOUT="${DAI_TEST_TIMEOUT:-1800}"
run_suite() {
  local name="$1" dir="$2"; shift 2
  local log="$LOGS/$name.log"
  ( cd "$dir" && "$@" >"$log" 2>&1 ) &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null && [[ $waited -lt $TIMEOUT ]]; do
    sleep 5; waited=$((waited + 5))
  done
  if kill -0 "$pid" 2>/dev/null; then
    # What was measured, not what was inferred. This said "stopped making
    # progress" while timing total runtime, so a suite that had merely grown
    # read as one that had wedged - and the two want opposite responses.
    echo "$name tests did not finish within ${waited}s; not building a release" >&2
    echo "  Either they are stuck, or the suite has outgrown DAI_TEST_TIMEOUT." >&2
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

# Kept, not discarded. The build output used to go to /dev/null, which meant a
# release said nothing whatever about notarisation - and a step that is silent
# when it works is a step that is silent when it stops working, discovered by
# whoever tries to install the result.
build_package() {
  local what="$1" dir="$2" script="$3"
  local log="$LOGS/${what// /-}-pkg.log"
  echo "==> $what package"
  if ! (cd "$dir" && "./$script" --version "$VERSION" "${SIGNING[@]}") >"$log" 2>&1; then
    echo "    $what package failed; last of $log:" >&2
    tail -20 "$log" >&2
    exit 1
  fi
  # What Apple was asked and what it said. notarytool prints the submission id
  # and status; the staple is what makes the ticket travel with the file, so a
  # machine can verify it without asking Apple anything.
  if grep -q "^ *id: " "$log"; then
    grep -E "^ *(id|status): " "$log" | sed 's/^ */    notarisation /' | head -4
    grep -q "staple and validate action worked" "$log" \
      && echo "    ticket stapled" \
      || echo "    NOT STAPLED - the package will need Apple reachable to verify" >&2
  else
    echo "    not notarised"
  fi
}

build_package "agent" "$ROOT/agent/packaging" build-pkg.sh
build_package "control plane" "$ROOT/control-plane/packaging" build-control-pkg.sh

# Copied by name rather than by glob. `dai-control-$VERSION*.pkg` also matches
# `dai-control-$VERSION-unsigned.pkg`, so an unsigned build left over from an
# earlier attempt was swept into a signed release - and it did not sit there
# quietly: the install instructions in RELEASE.md came out naming both files on
# two lines, telling a reader to install the one Gatekeeper refuses.
SUFFIX=""; [[ $UNSIGNED -eq 1 ]] && SUFFIX="-unsigned"
AGENT_SRC="$ROOT/agent/packaging/dist/dai-agent-$VERSION$SUFFIX.pkg"
CONTROL_SRC="$ROOT/control-plane/packaging/dist/dai-control-$VERSION$SUFFIX.pkg"
for f in "$AGENT_SRC" "$CONTROL_SRC"; do
  [[ -f "$f" ]] || { echo "the build did not produce $f" >&2; exit 1; }
done

rm -rf "$OUT" && mkdir -p "$OUT"
cp "$AGENT_SRC" "$CONTROL_SRC" "$OUT/"

echo "==> checksums"
(cd "$OUT" && shasum -a 256 ./*.pkg > SHA256SUMS)

# The names as built, not as predicted. An unsigned build carries -unsigned in
# the filename, and a note telling somebody to install a file that is not there
# is worse than no note.
AGENT_PKG="$(basename "$AGENT_SRC")"
CONTROL_PKG="$(basename "$CONTROL_SRC")"

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
