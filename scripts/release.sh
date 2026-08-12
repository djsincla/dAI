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

echo "==> tests"
# Both suites, because a release is both halves. The control plane's suite drops
# and recreates a schema, so it is pointed at its own database rather than
# whatever DATABASE_URL happens to be - the same reason the test helper refuses
# to take it from there.
(cd "$ROOT/control-plane" && TEST_DATABASE_URL="${TEST_DATABASE_URL:-postgres://dai:dai@localhost:5433/dai_test}" npm test >/dev/null) \
  || { echo "control plane tests failed; not building a release" >&2; exit 1; }
(cd "$ROOT/agent" && swift test >/dev/null 2>&1) \
  || { echo "agent tests failed; not building a release" >&2; exit 1; }
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
PREVIOUS="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
SCHEMA_CHANGES="(no previous tag; this is the first release)"
if [[ -n "$PREVIOUS" ]]; then
  SCHEMA_CHANGES="$(git -C "$ROOT" diff --stat "$PREVIOUS" -- control-plane/db/schema.sql || true)"
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
