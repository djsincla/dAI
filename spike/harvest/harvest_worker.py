#!/usr/bin/env python3
"""
Harvest worker — pulls work, runs it, and gets out of the way when someone sits
down.

This is the intersection nothing had tested. E3 measured a fleet with nobody at
the keyboards; E2 and E5 measured contention with no scheduler. The harvest tier
is both at once, and the interesting behaviour only appears when they run
together.

Every constant here traces to a measurement:

  E1  ProcessType/QoS is the politeness control and costs ~2.4x throughput, so
      it is switched dynamically rather than pinned. Metal caps itself at ~81%
      of unified memory, so ceilings are fractions of that, not of installed RAM.
  E2  No GPU setting is imperceptible while a user is present — even background
      QoS at 25% duty costs 46% of viewport p95. GPU work therefore waits for
      LOCKED or ABSENT, and duty cycling is a real second lever.
  E4  Model load is 1-3s and release is ~20ms, so preemption is cheap and the
      agent should yield eagerly. Yield latency is dominated by how often
      presence is sampled, not by releasing memory.
  E5  ANE work is indistinguishable from no load, making it the only daytime
      option. It stays permitted in states where GPU work is forbidden.

The yield point is *between items*, not between work units. A unit is a batch;
checking presence only at unit boundaries would mean up to a full unit of
continued work after someone returns. Checking between items bounds that to one
item, and completed items are reported rather than discarded — a preemption
costs at most the item in flight.
"""

import argparse
import ctypes
import json
import platform
import subprocess
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent.parent / "presence"))
import presence  # noqa: E402

MAX_TOKENS = 24

# setpriority(2) with Darwin extensions — the same mechanism `taskpolicy -b`
# uses, callable on self so QoS can follow presence state at runtime rather than
# being fixed at launch by a plist.
PRIO_DARWIN_PROCESS = 4
PRIO_DARWIN_BG = 0x1000
_libc = ctypes.CDLL("libc.dylib", use_errno=True)


def set_background_qos(enabled):
    """Enter or leave Darwin background priority. Returns True on success."""
    rc = _libc.setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG if enabled else 0)
    return rc == 0


def machine_label():
    try:
        out = subprocess.run(["system_profiler", "SPHardwareDataType"],
                             capture_output=True, text=True, timeout=20).stdout
        chip = next((l.split(":", 1)[1].strip() for l in out.splitlines()
                     if "Chip:" in l), "unknown")
        mem = next((l.split(":", 1)[1].strip() for l in out.splitlines()
                    if "Memory:" in l), "?")
        return f"{chip} / {mem}"
    except Exception:
        return platform.machine()


class Runtime:
    """Owns the model. Load and unload are cheap (E4: 1-3s load, ~20ms release),
    so holding a model through a yield is not worth the memory it occupies."""

    def __init__(self, model_name):
        self.model_name = model_name
        self.model = None
        self.tokenizer = None
        self.sampler = None

    @property
    def loaded(self):
        return self.model is not None

    def load(self):
        if self.loaded:
            return 0.0
        from mlx_lm import load
        from mlx_lm.sample_utils import make_sampler
        t0 = time.perf_counter()
        self.model, self.tokenizer = load(self.model_name, lazy=False)
        self.sampler = make_sampler(temp=0.0)
        return time.perf_counter() - t0

    def unload(self):
        if not self.loaded:
            return 0.0
        import gc
        import mlx.core as mx
        t0 = time.perf_counter()
        self.model = self.tokenizer = self.sampler = None
        gc.collect()
        mx.clear_cache()
        return time.perf_counter() - t0

    def run(self, prompt_text):
        from mlx_lm import generate
        messages = [{"role": "user", "content": prompt_text}]
        prompt = self.tokenizer.apply_chat_template(messages, add_generation_prompt=True)
        return generate(self.model, self.tokenizer, prompt,
                        max_tokens=MAX_TOKENS, sampler=self.sampler, verbose=False)


class HarvestWorker:
    def __init__(self, coordinator, name, model_name, verbose=True,
                 promote_after=presence.IDLE_PROMOTE_SECONDS):
        self.coordinator = coordinator.rstrip("/")
        self.name = name
        self.machine = machine_label()
        self.runtime = Runtime(model_name)
        self.monitor = presence.PresenceMonitor(promote_after=promote_after)
        self.verbose = verbose
        self.qos_background = None
        self.stats = {"items": 0, "units": 0, "yields": 0, "items_lost": 0,
                      "loads": 0, "load_s": 0.0, "work_s": 0.0, "idle_s": 0.0}

    def log(self, msg):
        if self.verbose:
            print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)

    def apply_qos(self, policy):
        """Follow the policy's QoS. E1 measured this at ~2.4x throughput, so
        leaving it pinned to background wastes most of the overnight window."""
        want_bg = policy["qos"] == "background"
        if want_bg != self.qos_background:
            if set_background_qos(want_bg):
                self.qos_background = want_bg
                self.log(f"  QoS -> {'background' if want_bg else 'standard'}")

    def may_work(self, policy):
        """GPU inference is the only thing this worker can do, so a policy that
        forbids GPU means stand down — even though ANE work would be allowed.
        A Core ML path (E5) would be the daytime complement."""
        return policy["gpu"] and policy["duty_max"] > 0

    def poll_interval(self, state):
        # E4: yield latency is dominated by sampling frequency, not by releasing
        # memory. Sample fast when a user could plausibly be about to return.
        return (presence.POLL_INTERVAL_IDLE if state in ("LOCKED", "ABSENT")
                else presence.POLL_INTERVAL_ACTIVE)

    def fetch(self):
        try:
            with urllib.request.urlopen(
                    f"{self.coordinator}/work?worker={self.name}", timeout=60) as r:
                return json.load(r)
        except urllib.error.URLError as exc:
            self.log(f"  coordinator unreachable ({exc}); retry in 3s")
            time.sleep(3)
            return None

    def report(self, unit_id, done, unfinished, seconds):
        """Return completed items and hand back what was not reached.

        Reporting partial progress is what makes preemption cheap. Discarding
        the whole unit would make a yield cost up to a full batch, which is the
        expensive behaviour E4's economics were meant to avoid.
        """
        payload = {"worker": self.name, "machine": self.machine, "unit_id": unit_id,
                   "count": done, "seconds": round(seconds, 3),
                   "unfinished": unfinished}
        req = urllib.request.Request(
            f"{self.coordinator}/result", data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except urllib.error.URLError as exc:
            self.log(f"  failed to report unit {unit_id}: {exc}")
            return None

    def process(self, unit):
        """Run a unit, re-checking presence between every item.

        Between-item is the right granularity: a unit is a batch, so checking
        only at unit boundaries would let up to a whole batch run on after
        someone returns. Per-item bounds the intrusion to one item (~1s) while
        keeping the presence check itself negligible.
        """
        items = unit["items"]
        t0 = time.perf_counter()
        done = 0

        for index, item in enumerate(items):
            reading = self.monitor.update()
            policy = reading["policy"]
            self.apply_qos(policy)

            if not self.may_work(policy):
                unfinished = items[index:]
                self.stats["yields"] += 1
                self.stats["items_lost"] += 0  # nothing in flight was discarded
                self.log(f"  YIELD -> {reading['state']} "
                         f"({', '.join(policy['blocked_by']) or 'user present'}); "
                         f"{done} done, {len(unfinished)} returned")
                return done, unfinished, time.perf_counter() - t0

            item_t0 = time.perf_counter()
            self.runtime.run(item["prompt"])
            item_s = time.perf_counter() - item_t0
            done += 1

            # E2: duty cycle is a real, monotonic lever independent of QoS.
            # Sleeping proportionally yields the GPU back in gaps.
            duty = policy["duty_max"]
            if 0 < duty < 1.0:
                time.sleep(item_s * (1.0 / duty - 1.0))

        return done, [], time.perf_counter() - t0

    def run(self):
        self.log(f"harvest worker {self.name} ({self.machine})")
        self.log(f"coordinator {self.coordinator}")

        while True:
            reading = self.monitor.update()
            state, policy = reading["state"], reading["policy"]
            self.apply_qos(policy)

            if not self.may_work(policy):
                if self.runtime.loaded:
                    freed = self.runtime.unload()
                    self.log(f"  standing down in {state}; released in {freed*1000:.0f}ms")
                wait = self.poll_interval(state)
                self.stats["idle_s"] += wait
                time.sleep(wait)
                continue

            work = self.fetch()
            if work is None:
                continue
            if work.get("wait"):
                time.sleep(3)
                continue
            if work.get("done"):
                break

            if not self.runtime.loaded:
                load_s = self.runtime.load()
                self.stats["loads"] += 1
                self.stats["load_s"] += load_s
                self.log(f"  loaded model in {load_s:.2f}s (state={state})")

            done, unfinished, seconds = self.process(work)
            self.stats["items"] += done
            self.stats["units"] += 1
            self.stats["work_s"] += seconds
            self.report(work["unit_id"], done, unfinished, seconds)

            if not unfinished:
                rate = done / seconds if seconds else 0
                self.log(f"  unit: {done} items in {seconds:.2f}s ({rate:.2f}/s) "
                         f"state={state} duty={policy['duty_max']:.2f}")

        if self.runtime.loaded:
            self.runtime.unload()
        self.log("done: " + json.dumps(self.stats))
        return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--coordinator", required=True)
    ap.add_argument("--model", default="mlx-community/Qwen2.5-1.5B-Instruct-4bit")
    ap.add_argument("--name", default=platform.node().split(".")[0])
    ap.add_argument("--promote-after", type=float,
                    default=presence.IDLE_PROMOTE_SECONDS,
                    help="seconds a more-permissive state must hold before the "
                         "worker adopts it. Production default is deliberately "
                         "long (E4: a false 'they are gone' costs a model load "
                         "and an instant preemption); lower it only for tests.")
    args = ap.parse_args()
    return HarvestWorker(args.coordinator, args.name, args.model,
                         promote_after=args.promote_after).run()


if __name__ == "__main__":
    raise SystemExit(main())
