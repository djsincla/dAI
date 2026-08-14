#!/usr/bin/env bash
#
# Minify the compiled output in place, for a build that leaves this machine.
#
# `removeComments` takes out the prose. This takes out the rest of what is worth
# reading: local names become single letters, so `suspensionFor(machine, groups)`
# arrives as `f(a,b)` and the shape of the reasoning goes with the names. It is a
# deterrent and not a protection - anybody sufficiently motivated reads it
# anyway. The licence is what actually says no.
#
# Deliberately NOT a bundle. Every runtime path here is relative to the compiled
# file: server.js reads ../openapi and ../ui, lib/db.js reads ../../db. Collapse
# lib/db.js into dist/server.js and ../../db resolves one directory too high, so
# a bundled control plane installs cleanly and then cannot find its schema. Each
# file is minified where it stands and the import graph is left alone.
#
# Source maps come out as a separate archive that must not be distributed. That
# is the trade this step makes: a stack trace from somebody else's machine reads
# as `f (server.js:1:8420)` and is useless on its own. The map is what turns it
# back into a file and a line, so it is kept, and kept private.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$HERE/dist"
MAPS="$HERE/.maps"

[[ -d "$DIST" ]] || { echo "no dist/ - run the build first" >&2; exit 1; }

ESBUILD="$HERE/node_modules/.bin/esbuild"
[[ -x "$ESBUILD" ]] || { echo "esbuild not installed - npm install" >&2; exit 1; }

rm -rf "$MAPS"

# --allow-overwrite, because the input and the output are the same tree. Every
# file is named explicitly rather than through a glob: a shell that does not
# expand ** silently minifies the top level and leaves lib/ readable, which
# looks like it worked.
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(find "$DIST" -name '*.js' -type f)
[[ ${#FILES[@]} -gt 0 ]] || { echo "no .js under dist/" >&2; exit 1; }

"$ESBUILD" "${FILES[@]}" \
  --minify \
  --format=esm \
  --platform=node \
  --target=node22 \
  --outbase="$DIST" \
  --outdir="$DIST" \
  --allow-overwrite \
  --sourcemap=external \
  --log-level=warning

# external rather than linked: esbuild omits the sourceMappingURL comment, so
# the shipped file carries no pointer to a map that is not there.
mkdir -p "$MAPS"
(cd "$DIST" && find . -name '*.js.map' -type f -print0 \
  | while IFS= read -r -d '' m; do
      mkdir -p "$MAPS/$(dirname "$m")"
      mv "$m" "$MAPS/$m"
    done)

echo "minified $(find "$DIST" -name '*.js' -type f | wc -l | tr -d ' ') files; maps in ${MAPS#"$HERE"/}"
