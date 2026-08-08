#!/bin/bash
# E5 - is ANE work less perceptible to an interactive user than GPU work?
#
# Four conditions against the same Blender viewport benchmark:
#
#   baseline    no load
#   gpu-25gb    MLX matmul, 25 GB resident  (matches the earlier E2 run)
#   gpu-4gb     MLX matmul, 4 GB resident   (a 7B-model-sized footprint)
#   ane         verified 100%-ANE Core ML model, saturating
#
# gpu-4gb exists to separate two effects that the 25 GB run conflates. If ANE
# beats gpu-25gb it could simply be because it holds far less memory; comparing
# against a similarly small GPU footprint isolates the compute unit itself.
#
# The MLX and Core ML loads run from different venvs on purpose: coremltools
# has no working BlobWriter on Python 3.14, MLX wheels are built for it.

set -uo pipefail
cd "$(dirname "$0")"

BL=/Applications/Blender.app/Contents/MacOS/Blender
VIEWPORT=../e2_contention/blender_viewport.py
MLX_PY=../.venv/bin/python
COREML_PY=../.venv-coreml/bin/python
FRAMES=${FRAMES:-150}
OUT=${OUT:-results}

mkdir -p "$OUT"
cleanup() { pkill -f "e2_contention/load.py" 2>/dev/null; pkill -f "ane_load.py" 2>/dev/null; }
trap cleanup EXIT

run_viewport() {  # label
    $BL --python "$VIEWPORT" -- --out "$OUT/$1.json" --frames "$FRAMES" --label "$1" \
        > "$OUT/$1.log" 2>&1
}

wait_for_loaded() {  # logfile
    for _ in $(seq 1 90); do
        grep -q '"event": "loaded"' "$1" 2>/dev/null && return 0
        sleep 1
    done
    echo "  WARNING: load never reported resident; result is not trustworthy" >&2
    return 1
}

# Baselines are interleaved between every loaded condition, not measured once
# at the start. Two full runs of this experiment produced baseline p95 of
# 17.79ms and 24.22ms - a 36% swing with no load at all, large enough to
# manufacture or erase an entire effect. A single leading baseline made
# gpu-25gb look 3x gentler than gpu-4gb in one run and identical to it in the
# next. Each condition is therefore compared against the baselines measured
# around it.
REPS=${REPS:-2}

for rep in $(seq 1 "$REPS"); do
    echo "=== rep $rep: baseline-a ==="
    run_viewport "baseline-a.$rep"

    for spec in "gpu-25gb 25" "gpu-4gb 4"; do
        set -- $spec
        echo "=== rep $rep: $1 ==="
        $MLX_PY ../e2_contention/load.py --memory-gb "$2" > "$OUT/$1.$rep.load.log" 2>&1 &
        LOADPID=$!
        wait_for_loaded "$OUT/$1.$rep.load.log"
        run_viewport "$1.$rep"
        kill $LOADPID 2>/dev/null; wait $LOADPID 2>/dev/null
    done

    echo "=== rep $rep: baseline-b ==="
    run_viewport "baseline-b.$rep"

    echo "=== rep $rep: ane ==="
    $COREML_PY ane_load.py > "$OUT/ane.$rep.load.log" 2>&1 &
    LOADPID=$!
    wait_for_loaded "$OUT/ane.$rep.load.log"
    run_viewport "ane.$rep"
    kill $LOADPID 2>/dev/null; wait $LOADPID 2>/dev/null
done

echo
python3 "$(dirname "$0")/analyze.py" "$OUT"
