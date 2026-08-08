#!/bin/bash
# End-to-end test of presence-driven yield, using a real signal path.
#
# The worker is not told anything. `caffeinate -d` holds a genuine
# PreventUserIdleDisplaySleep assertion — the same thing a video call or media
# playback holds — which presence.py classifies as PASSIVE, where E2 says GPU
# work is not permitted. So this exercises the production path end to end
# rather than stubbing the presence source.
#
# Timeline:
#   0s    coordinator + worker start
#   ~90s  HID idle passes ACTIVE_IDLE_THRESHOLD, then --promote-after elapses
#         -> worker reaches IDLE and begins working
#   150s  caffeinate -d starts  -> PASSIVE -> worker must yield and unload
#   210s  caffeinate ends       -> IDLE    -> worker must resume
#   270s  stop, report
#
# --promote-after is shortened to 20s here. Production uses 300s because E4
# showed a false "they are gone" costs a model load and an immediate preemption;
# that delay makes the yield path untestable in a short window.
#
# Requires the machine to be genuinely idle: any keypress makes state ACTIVE,
# where GPU work is forbidden anyway and the test proves nothing.

set -uo pipefail
cd "$(dirname "$0")"

PY=../.venv/bin/python
COORD_LOG=/tmp/harvest_coord.log
WORKER_LOG=/tmp/harvest_worker.log
PORT=8722

cleanup() {
    pkill -f "coordinator.py --corpus" 2>/dev/null
    pkill -f harvest_worker.py 2>/dev/null
    pkill -f "caffeinate -d" 2>/dev/null
}
trap cleanup EXIT
cleanup; sleep 1

echo "=== presence state before start ==="
$PY ../presence/presence.py | python3 -c "
import json,sys; d=json.load(sys.stdin)
s=d['signals']
print(f\"  state={d['state']} hid_idle={s['hid_idle_s']}s display_assertions={s['display_assertions']}\")"

$PY ../e3_fleet/coordinator.py --corpus 400 --policy weighted --port $PORT \
    --out /tmp/harvest_coord_result.json > $COORD_LOG 2>&1 &
sleep 3

$PY harvest_worker.py --coordinator "http://127.0.0.1:$PORT" \
    --model mlx-community/Qwen2.5-0.5B-Instruct-4bit --name harvest-test \
    --promote-after 20 > $WORKER_LOG 2>&1 &
echo "worker started; waiting 150s for HID idle to pass 90s and promote to IDLE"
echo "(do not touch the keyboard or trackpad -- any input forces ACTIVE)"
sleep 150

echo
echo "=== asserting display-sleep prevention (real PASSIVE trigger) ==="
caffeinate -d &
CAFF=$!
sleep 60
kill $CAFF 2>/dev/null
echo "=== assertion released; worker should resume ==="
sleep 60

cleanup
sleep 1

echo
echo "=== worker log ==="
cat $WORKER_LOG
echo
echo "=== coordinator: requeue accounting ==="
grep -c "YIELD" $COORD_LOG 2>/dev/null | sed 's/^/  yielded units: /'
tail -3 $COORD_LOG
