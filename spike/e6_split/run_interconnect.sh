#!/bin/bash
# Measure one interconnect end to end. Re-runnable against any link.
#
#   ./run_interconnect.sh <label> <local-ip> <remote-ip>
#
#   ./run_interconnect.sh gbe         10.0.0.2      10.0.0.1
#   ./run_interconnect.sh thunderbolt 169.254.10.1  169.254.10.2
#   ./run_interconnect.sh wifi        192.168.4.24  192.168.4.26
#
# Produces, per link: RTT, all-reduce latency at three payload sizes, the
# comm-only token ceiling, and the end-to-end sharded generation rate. The last
# one is what matters — the ceiling proved 2.7x optimistic against real
# generation on gigabit, because a tight all-reduce loop pays neither
# synchronisation nor per-op overhead.
#
# Ports start at 9100 deliberately: macOS AirPlay Receiver owns 5000, which is
# MLX's ring default, and the collision hangs with no error message.

set -uo pipefail

LABEL="${1:?usage: $0 <label> <local-ip> <remote-ip>}"
LOCAL_IP="${2:?missing local ip}"
REMOTE_IP="${3:?missing remote ip}"

REMOTE_HOST="${REMOTE_HOST:-orca.local}"
REMOTE_PY="${REMOTE_PY:-\$HOME/.dai-e3/.venv313/bin/python}"
LOCAL_PY="${LOCAL_PY:-/Users/dwayne/Developer/dAI/spike/.venv/bin/python}"
WORKDIR="$HOME/e6"
OUT="$(cd "$(dirname "$0")" && pwd)/results_${LABEL}.json"

cleanup() {
    ssh "$REMOTE_HOST" 'pkill -f allreduce_bench 2>/dev/null; pkill -f sharded_generate 2>/dev/null; true' 2>/dev/null
    pkill -f allreduce_bench 2>/dev/null; pkill -f sharded_generate 2>/dev/null
}
trap cleanup EXIT
cleanup

echo "=== $LABEL: $LOCAL_IP <-> $REMOTE_IP ==="

RTT=$(ping -c 10 -t 10 "$REMOTE_IP" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
echo "RTT avg: ${RTT:-unknown} ms"

MEDIA=$(for i in $(ifconfig -l); do
    ifconfig "$i" 2>/dev/null | grep -q "inet $LOCAL_IP " && ifconfig "$i" | grep -o 'media: .*' | head -1
done)
echo "local link: ${MEDIA:-unknown}"

# Rank 0 is local, rank 1 remote. Endpoint list per rank, one entry each.
HOSTFILE="$WORKDIR/hosts_${LABEL}.json"
mkdir -p "$WORKDIR"
printf '[["%s:9100"], ["%s:9101"]]\n' "$LOCAL_IP" "$REMOTE_IP" > "$HOSTFILE"
scp -q "$HOSTFILE" "$REMOTE_HOST:$WORKDIR/" || { echo "scp hostfile failed" >&2; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"
cp "$SRC/allreduce_bench.py" "$SRC/sharded_generate.py" "$WORKDIR/"
scp -q "$SRC/allreduce_bench.py" "$SRC/sharded_generate.py" "$REMOTE_HOST:$WORKDIR/"

run_pair() {  # script, extra-args
    local script="$1"; shift
    # Rank 1 first so it is listening when rank 0 dials in.
    ssh "$REMOTE_HOST" "cd $WORKDIR && MLX_HOSTFILE=hosts_${LABEL}.json MLX_RANK=1 \
        nohup $REMOTE_PY $script $* > /tmp/e6_${LABEL}_r1.log 2>&1 &" >/dev/null
    sleep 3
    ( cd "$WORKDIR" && MLX_HOSTFILE="hosts_${LABEL}.json" MLX_RANK=0 \
        "$LOCAL_PY" "$script" $* 2>&1 ) | grep -E "E6_RESULT|E6_GEN_RESULT" | tail -1
}

echo "--- all-reduce latency ---"
AR=$(run_pair allreduce_bench.py)
echo "${AR:-(failed)}"

echo "--- sharded generation ---"
SH=$(run_pair sharded_generate.py --mode shard --reps 3)
echo "${SH:-(failed)}"

echo "--- single-node baseline ---"
SG=$( cd "$WORKDIR" && "$LOCAL_PY" sharded_generate.py --mode single --reps 3 2>&1 \
      | grep -E "E6_GEN_RESULT" | tail -1 )
echo "${SG:-(failed)}"

python3 - "$OUT" "$LABEL" "${RTT:-0}" "${MEDIA:-unknown}" <<PY
import json, sys
out, label, rtt, media = sys.argv[1:5]
def parse(s, tag):
    return json.loads(s.split(tag, 1)[1]) if s and tag in s else None
rec = {
    "label": label, "rtt_ms": float(rtt or 0), "media": media,
    "allreduce": parse('''$AR''', "E6_RESULT "),
    "sharded": parse('''$SH''', "E6_GEN_RESULT "),
    "single": parse('''$SG''', "E6_GEN_RESULT "),
}
with open(out, "w") as f:
    json.dump(rec, f, indent=2)

a, sh, si = rec["allreduce"], rec["sharded"], rec["single"]
print()
print(f"{'link':<14}{'RTT ms':>8}{'allreduce ms':>14}{'ceiling':>10}{'actual':>9}{'single':>9}{'shard/single':>14}")
ar = a["allreduce"]["1 token  (generation)"]["latency_ms"] if a else None
ceil = a["comm_only_token_ceiling_tok_s"] if a else None
act = sh["median_steady_tok_s"] if sh else None
one = si["median_steady_tok_s"] if si else None
ratio = f"{100*act/one:.0f}%" if act and one else "-"
print(f"{label:<14}{rec['rtt_ms']:>8.2f}{(ar if ar else 0):>14.3f}"
      f"{(ceil if ceil else 0):>10.2f}{(act if act else 0):>9.2f}{(one if one else 0):>9.2f}{ratio:>14}")
print(f"\nWrote {out}")
PY
