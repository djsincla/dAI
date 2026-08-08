#!/usr/bin/env python3
"""
E3 coordinator - hands out work units, collects results, reports scaling.

Deliberately a prototype of the Phase 1 scheduler rather than a throwaway
benchmark, because the interesting question is not "do two Macs go faster than
one" (they do) but "does a heterogeneous fleet schedule correctly", which is the
thing that actually breaks at scale.

Pull-based on purpose. Workers poll for units rather than the coordinator
pushing over SSH, which is how the shipping agent must work anyway: harvested
machines come and go, and a scheduler that has to reach *into* them needs
credentials and reachability it will not reliably have.

Two dispatch policies, switchable, so the difference can be measured rather than
asserted:

  round-robin   equal units to every node, ignoring capability
  weighted      unit size proportional to each node's measured throughput

The weighted policy uses throughput observed from completed units, not a spec
sheet. An M2 Max (~400 GB/s, 38 GPU cores) and an M4 Pro (~273 GB/s, 20 newer
cores) invert depending on whether a workload is bandwidth-bound or
compute-bound, so core counts and generation numbers do not predict placement.

    python3 coordinator.py --corpus 400 --policy weighted
"""

import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Work is typed, because a harvest worker's *permitted* work changes with
# presence state. In LOCKED/ABSENT it may run GPU inference; in ACTIVE, PASSIVE
# and IDLE only ANE work is allowed (E2 + the ~26x bursty-QoS penalty). A worker
# therefore advertises which kinds it can currently serve and the coordinator
# hands out only those, instead of the worker fetching work it must immediately
# hand back.
WORK_KINDS = ("generate", "embed")

STATE = {
    "queues": {k: [] for k in WORK_KINDS},
    "in_flight": {},      # unit_id -> (worker_id, dispatched_at)
    "done": [],           # completed unit records
    "workers": {},        # worker_id -> {throughput, units, items, seconds}
    "policy": "weighted",
    "min_workers": 1,
    "seen_workers": set(),
    "started": None,
    "lock": threading.Lock(),
}

# Unit sizing bounds. Too small and per-unit overhead dominates; too large and a
# preemption throws away more work than E4's economics justify.
MIN_BATCH, MAX_BATCH = 2, 32

# Served at /bootstrap.sh so a machine joins with one command. The model is
# pinned so every node runs identical work - a node quietly running a different
# quantisation would make the throughput comparison meaningless.
BOOTSTRAP = """#!/bin/bash
set -euo pipefail
COORD="{url}"
DIR="$HOME/.dai-e3"
mkdir -p "$DIR" && cd "$DIR"
echo "Setting up dAI E3 worker in $DIR"
[ -d .venv ] || python3 -m venv .venv
./.venv/bin/pip install --quiet --upgrade pip
./.venv/bin/pip install --quiet mlx mlx-lm
curl -fsSL "$COORD/worker.py" -o worker.py
echo "Starting worker against $COORD"
exec ./.venv/bin/python worker.py --coordinator "$COORD" "$@"
"""


def queue_len():
    return sum(len(q) for q in STATE["queues"].values())


def make_corpus(n):
    """Synthetic but realistic batch-classification work - Tier 1 use case #3.

    Prompts are varied so no worker gets a systematically easier slice, which
    would corrupt the throughput comparison the whole experiment rests on.
    """
    topics = [
        "a warehouse robotics startup missing its delivery window",
        "a hospital rescheduling elective surgery after a systems outage",
        "a bank reversing duplicate card transactions",
        "an airline rebooking passengers after a runway closure",
        "a utility explaining a billing spike during a cold snap",
        "a retailer recalling a batch of contaminated produce",
        "a university delaying financial aid disbursement",
        "a telecom apologising for a regional network failure",
    ]
    # Half GPU-only generation, half ANE-eligible. A realistic harvest fleet has
    # both, and the split is what makes the policy visible: a logged-in machine
    # should still drain the embed queue while the generate queue waits for it to
    # lock.
    corpus = []
    for i in range(n):
        kind = "generate" if i % 2 == 0 else "embed"
        corpus.append({
            "id": i, "kind": kind,
            "prompt": f"In one sentence, state the primary operational risk in this "
                      f"scenario: {topics[i % len(topics)]} (case {i})."})
    return corpus


def next_batch_size(worker_id):
    """Capability-matched sizing.

    Round-robin hands every node the same batch, so on a heterogeneous fleet the
    fast node finishes early and idles while the slow node is still working -
    the classic straggler. Weighted sizing scales each batch by the node's own
    measured throughput relative to the fleet mean.
    """
    if STATE["policy"] == "round-robin":
        return 8

    worker = STATE["workers"].get(worker_id, {})
    rate = worker.get("throughput")
    rates = [w["throughput"] for w in STATE["workers"].values() if w.get("throughput")]
    if not rate or len(rates) < 2:
        return 8  # no signal yet: neutral batch until the probe has data
    mean = sum(rates) / len(rates)
    return max(MIN_BATCH, min(MAX_BATCH, round(8 * rate / mean)))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass  # the coordinator prints its own progress; access logs are noise

    def _send(self, payload, code=200):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # Exact-prefix, not startswith("/work"): "/worker.py" also starts with
        # "/work" and was being served a JSON work unit instead of the script.
        if self.path == "/work" or self.path.startswith("/work?"):
            from urllib.parse import parse_qs, urlparse
            query = parse_qs(urlparse(self.path).query)
            worker_id = query.get("worker", ["?"])[0]
            # A worker with no declared kinds is an older client; give it
            # everything rather than starving it.
            kinds = [k for k in query.get("kinds", [",".join(WORK_KINDS)])[0].split(",")
                     if k in WORK_KINDS]
            with STATE["lock"]:
                STATE["seen_workers"].add(worker_id)
                # Hold the start until the whole fleet has checked in. A node
                # that joins late would otherwise find the queue already
                # drained by the faster node, and the run would measure one
                # machine while claiming to measure two.
                if len(STATE["seen_workers"]) < STATE["min_workers"]:
                    waiting = STATE["min_workers"] - len(STATE["seen_workers"])
                    return self._send({"wait": True, "need": waiting})
                if queue_len() == 0:
                    return self._send({"done": True})
                # Serve the longest queue this worker can handle, so a fleet
                # where only some nodes may run GPU work still drains evenly.
                servable = [k for k in kinds if STATE["queues"][k]]
                if not servable:
                    return self._send({"idle": True, "reason": "no work of a "
                                       "kind this worker may currently run"})
                kind = max(servable, key=lambda k: len(STATE["queues"][k]))
                queue = STATE["queues"][kind]
                size = next_batch_size(worker_id)
                batch = [queue.pop(0) for _ in range(min(size, len(queue)))]
                unit_id = f"u{time.time_ns()}"
                STATE["in_flight"][unit_id] = (worker_id, time.perf_counter())
                if STATE["started"] is None:
                    STATE["started"] = time.perf_counter()
            return self._send({"done": False, "unit_id": unit_id,
                               "kind": kind, "items": batch})

        if self.path == "/status":
            with STATE["lock"]:
                return self._send(summary())

        # Serve the worker and its bootstrap from the coordinator itself, so
        # joining a machine is one command with no repo checkout, no
        # credentials, and no manual file copying. This is a crude version of
        # the Phase 1 enrollment flow, and it is the reason the coordinator is
        # HTTP rather than SSH-driven.
        if self.path in ("/worker.py", "/bootstrap.sh"):
            import pathlib
            if self.path == "/worker.py":
                body = (pathlib.Path(__file__).parent / "worker.py").read_bytes()
                ctype = "text/x-python"
            else:
                body = BOOTSTRAP.format(url=self._base_url()).encode()
                ctype = "text/x-shellscript"
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self._send({"error": "not found"}, 404)

    def _base_url(self):
        return f"http://{self.headers.get('Host', 'localhost')}"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        payload = json.loads(self.rfile.read(length) or b"{}")

        if self.path == "/result":
            worker_id = payload["worker"]
            # A harvest worker that yields mid-unit returns what it did not
            # reach. Requeuing at the head keeps those items near the front so a
            # partially-served unit is not stranded behind the whole backlog.
            # Without this a yield would cost the entire batch, which is exactly
            # the expense E4's economics exist to avoid.
            unfinished = payload.get("unfinished") or []
            with STATE["lock"]:
                STATE["in_flight"].pop(payload["unit_id"], None)
                STATE["done"].append(payload)
                if unfinished:
                    for item in reversed(unfinished):
                        STATE["queues"][item.get("kind", "generate")].insert(0, item)
                    STATE["requeued"] = STATE.get("requeued", 0) + len(unfinished)
                w = STATE["workers"].setdefault(
                    worker_id, {"units": 0, "items": 0, "seconds": 0.0,
                                "yields": 0, "machine": payload.get("machine")})
                w["units"] += 1
                w["items"] += payload["count"]
                w["seconds"] += payload["seconds"]
                if unfinished:
                    w["yields"] = w.get("yields", 0) + 1
                # Throughput is observed, never declared. This is the running
                # capability probe the Phase 1 scheduler needs.
                # Only update the capability estimate from units that actually
                # completed work. A yield with zero items done would otherwise
                # register as zero throughput and poison the node's profile.
                if w["items"] > 0 and w["seconds"] > 0:
                    w["throughput"] = w["items"] / w["seconds"]
                remaining = queue_len()
            rate = payload["count"] / payload["seconds"] if payload["seconds"] else 0
            tag = f"  YIELD +{len(unfinished)} requeued" if unfinished else ""
            print(f"  {worker_id:<22} {payload['count']:>3} items in "
                  f"{payload['seconds']:>6.2f}s  ({rate:>5.2f}/s)"
                  f"   {remaining} left{tag}", flush=True)
            return self._send({"ok": True})

        self._send({"error": "not found"}, 404)


def summary():
    elapsed = (time.perf_counter() - STATE["started"]) if STATE["started"] else 0
    total_items = sum(w["items"] for w in STATE["workers"].values())
    per_node = {
        wid: {
            "machine": w.get("machine"),
            "units": w["units"],
            "items": w["items"],
            "yields": w.get("yields", 0),
            "busy_s": round(w["seconds"], 2),
            "throughput_items_s": round(w["throughput"], 3) if w.get("throughput") else None,
        }
        for wid, w in STATE["workers"].items()
    }
    aggregate = total_items / elapsed if elapsed else 0
    # Sum of solo rates is what a perfect fleet would achieve; the ratio exposes
    # coordination overhead and straggler loss.
    ideal = sum(w["throughput"] for w in STATE["workers"].values() if w.get("throughput"))
    return {
        "policy": STATE["policy"],
        # Distinct from "nodes": a worker appears here the moment it polls,
        # whereas nodes only populates once it posts a first result. Without
        # this a node that has joined but is still loading its model looks
        # identical to one that never connected.
        "workers_seen": sorted(STATE["seen_workers"]),
        "min_workers": STATE["min_workers"],
        "elapsed_s": round(elapsed, 2),
        "items_done": total_items,
        "items_remaining": queue_len(),
        "queues": {k: len(q) for k, q in STATE["queues"].items()},
        "items_requeued": STATE.get("requeued", 0),
        "aggregate_items_s": round(aggregate, 3),
        "sum_of_solo_rates": round(ideal, 3) if ideal else None,
        "scaling_efficiency": round(aggregate / ideal, 3) if ideal else None,
        "nodes": per_node,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", type=int, default=400)
    ap.add_argument("--policy", choices=["weighted", "round-robin"], default="weighted")
    ap.add_argument("--min-workers", type=int, default=1,
                    help="hold dispatch until this many distinct workers appear")
    ap.add_argument("--port", type=int, default=8712)
    ap.add_argument("--out", default="results.json")
    args = ap.parse_args()

    for item in make_corpus(args.corpus):
        STATE["queues"][item["kind"]].append(item)
    STATE["policy"] = args.policy
    STATE["min_workers"] = args.min_workers

    server = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    import socket
    host = socket.gethostbyname(socket.gethostname())
    print(f"Coordinator on http://{host}:{args.port}  policy={args.policy}  "
          f"corpus={args.corpus}\n")
    print(f"Start workers with:\n  python3 worker.py --coordinator http://{host}:{args.port}\n")

    try:
        while True:
            with STATE["lock"]:
                remaining = queue_len() + len(STATE["in_flight"])
            if remaining == 0 and STATE["started"]:
                break
            time.sleep(0.5)
    except KeyboardInterrupt:
        print("\ninterrupted")

    with STATE["lock"]:
        result = summary()
    print("\n" + json.dumps(result, indent=2))
    with open(args.out, "w") as f:
        json.dump(result, f, indent=2)
    print(f"\nWrote {args.out}")


if __name__ == "__main__":
    raise SystemExit(main())
