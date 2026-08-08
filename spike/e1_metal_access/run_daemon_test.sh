#!/bin/bash
# E1 daemon test — the existential gate for the harvest tier.
#
# Installs the probe as a LaunchDaemon (system domain, session 0, root, no user
# context) firing every 20s, so a single load captures samples across an
# unlock -> lock -> logout cycle.
#
#   sudo ./run_daemon_test.sh install     # start sampling
#   ./run_daemon_test.sh collect          # summarize (no sudo)
#   sudo ./run_daemon_test.sh uninstall   # remove daemon + artifacts
#
# Between install and collect: lock the screen (Ctrl-Cmd-Q) for ~1 min, unlock,
# then optionally log out fully for ~1 min and log back in. Each 20s tick
# records the lock state alongside the GPU result.

set -uo pipefail

LABEL="com.dai.e1probe.daemon"
PLIST_SRC="$(cd "$(dirname "$0")" && pwd)/${LABEL}.plist"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"
RESULTS="/tmp/dai_e1_daemon.jsonl"

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "error: '$1' needs root — run: sudo $0 $1" >&2
        exit 1
    fi
}

case "${1:-}" in
install)
    require_root install
    rm -f "$RESULTS" /tmp/dai_e1_daemon.out.log /tmp/dai_e1_daemon.err.log
    # LaunchDaemons must be root-owned and not group/world writable or launchd
    # refuses to load them.
    install -o root -g wheel -m 644 "$PLIST_SRC" "$PLIST_DST"
    launchctl bootout system/"$LABEL" 2>/dev/null
    launchctl bootstrap system "$PLIST_DST" || { echo "bootstrap failed" >&2; exit 1; }
    echo "Daemon loaded, sampling every 20s -> $RESULTS"
    echo
    echo "Now, in order:"
    echo "  1. Wait ~30s (captures: daemon, screen unlocked)"
    echo "  2. Lock the screen with Ctrl-Cmd-Q, wait ~60s, unlock"
    echo "  3. Optional: log out fully, wait ~60s, log back in"
    echo "  4. Run: $0 collect"
    ;;

collect)
    if [[ ! -s "$RESULTS" ]]; then
        echo "No results at $RESULTS — is the daemon loaded?" >&2
        echo "launchctl print system/$LABEL | head -20" >&2
        launchctl print system/"$LABEL" 2>&1 | grep -E "state|last exit" >&2
        exit 1
    fi
    python3 - "$RESULTS" <<'PY'
import json, sys
from collections import Counter

rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(f"{len(rows)} samples from the daemon context\n")

hdr = f"{'time':<9} {'session':<9} {'uid':<5} {'console':<10} {'locked':<7} {'GPU':<5} {'gflops':>8}"
print(hdr); print("-" * len(hdr))
for r in rows:
    p, g = r["process"], r.get("gpu", {})
    print(f"{r['timestamp'][11:19]:<9} {str(p['security_session']):<9} {p['uid']:<5} "
          f"{str(p['console_user']):<10} {str(p['screen_locked_raw']):<7} "
          f"{('YES' if r['gpu_reachable'] else 'NO'):<5} {str(g.get('gflops','-')):>8}")

print()
by_lock = {}
for r in rows:
    by_lock.setdefault(str(r["process"]["screen_locked_raw"]), []).append(r["gpu_reachable"])
for lock, oks in sorted(by_lock.items()):
    print(f"  screen_locked={lock:<6} -> GPU reachable in {sum(oks)}/{len(oks)} samples")

failures = [r for r in rows if not r["gpu_reachable"]]
if failures:
    print(f"\n!!! {len(failures)} FAILURE(S). First traceback:\n")
    print(failures[0].get("error", "<no traceback captured>")[:2000])
    print("\nVERDICT: E1 FAILS in at least one daemon state. The harvest tier")
    print("cannot rely on a system daemon; fall back to a LaunchAgent and")
    print("accept logged-in-but-idle machines only.")
else:
    print("\nVERDICT: E1 PASSES. Metal is reachable from a LaunchDaemon in every")
    print("sampled state. The node agent can ship as a system daemon.")
PY
    ;;

uninstall)
    require_root uninstall
    launchctl bootout system/"$LABEL" 2>/dev/null
    rm -f "$PLIST_DST" "$RESULTS" /tmp/dai_e1_daemon.out.log /tmp/dai_e1_daemon.err.log
    echo "Daemon removed and artifacts cleaned up."
    ;;

*)
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
