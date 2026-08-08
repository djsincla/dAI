#!/usr/bin/env python3
"""
Harvest worker - pulls work, runs it, and gets out of the way when someone sits
down.

This is the intersection nothing had tested. E3 measured a fleet with nobody at
the keyboards; E2 and E5 measured contention with no scheduler. The harvest tier
is both at once, and the interesting behaviour only appears when they run
together.

Every constant here traces to a measurement:

  E1  ProcessType/QoS is the politeness control and costs ~2.4x throughput, so
      it is switched dynamically rather than pinned. Metal caps itself at ~81%
      of unified memory, so ceilings are fractions of that, not of installed RAM.
  E2  No GPU setting is imperceptible while a user is present - even background
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
item, and completed items are reported rather than discarded - a preemption
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
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
import presence  # noqa: E402
from ane_runtime import ANERuntime, ANEPlacementError  # noqa: E402

MAX_TOKENS = 24

# setpriority(2) with Darwin extensions - the same mechanism `taskpolicy -b`
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
    def __init__(self, coordinator, name, model_name, ane_model=None, verbose=True,
                 promote_after=presence.IDLE_PROMOTE_SECONDS):
        self.coordinator = coordinator.rstrip("/")
        self.name = name
        self.machine = machine_label()
        # Two runtimes, chosen by what policy permits rather than by what work
        # exists. GPU work is forbidden in three of five presence states, so
        # without the ANE path a logged-in machine contributes nothing at all.
        self.runtime = Runtime(model_name)
        self.ane = ANERuntime(ane_model) if ane_model else None
        self.monitor = presence.PresenceMonitor(promote_after=promote_after)
        self.verbose = verbose
        self.qos_background = None
        self._reading = None
        self._reading_at = 0.0
        self.stats = {"items": 0, "units": 0, "yields": 0, "items_lost": 0,
                      "loads": 0, "load_s": 0.0, "work_s": 0.0, "idle_s": 0.0}

    def presence(self, max_age=None):
        """Presence reading, cached briefly.

        read_signals() costs ~116ms (six subprocess calls: ioreg, pmset x3,
        stat). An ANE item costs ~27ms, so polling per item spent 81% of the
        worker's time asking whether the user was back - the check cost 4x the
        work it was guarding.

        Caching for POLL_INTERVAL_ACTIVE costs nothing in responsiveness,
        because that interval is already the designed yield latency (E4: the
        sampling interval dominates end-to-end yield, not the ~20ms release).
        """
        max_age = presence.POLL_INTERVAL_ACTIVE if max_age is None else max_age
        now = time.monotonic()
        if self._reading is None or (now - self._reading_at) >= max_age:
            self._reading = self.monitor.update()
            self._reading_at = now
        return self._reading

    def log(self, msg):
        if self.verbose:
            print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)

    def apply_qos(self, policy, kind=None):
        """Set process QoS for the work about to run.

        GPU work follows the policy. ANE work never does: E5 measured it as
        indistinguishable from no load, so there is nothing to be polite about,
        while background QoS costs ~26x on bursty items. Running ANE work under
        background priority pays a large throughput tax to buy politeness that
        is already free - and ANE work is all a logged-in machine may do, so the
        tax lands on the majority of presence states.
        """
        want_bg = policy["qos"] == "background" and kind != "embed"
        if want_bg != self.qos_background:
            if set_background_qos(want_bg):
                self.qos_background = want_bg
                self.log(f"  QoS -> {'background' if want_bg else 'standard'}")

    def available_kinds(self, policy):
        """Work kinds this worker may run *right now*.

        Advertised to the coordinator so it hands out only servable work,
        instead of the worker fetching a unit it must immediately return.
        """
        kinds = []
        if policy["gpu"] and policy["duty_max"] > 0:
            kinds.append("generate")
        # E5: ANE work is indistinguishable from no load, so it stays permitted
        # wherever the policy allows it - including states where a user is
        # present and GPU work is not.
        if policy["ane"] and self.ane is not None:
            kinds.append("embed")
        return kinds

    def runtime_for(self, kind):
        return self.ane if kind == "embed" else self.runtime

    def unload_all(self, except_runtime=None):
        freed = 0.0
        for rt in (self.runtime, self.ane):
            if rt is not None and rt is not except_runtime and rt.loaded:
                freed += rt.unload()
        return freed

    def poll_interval(self, state):
        # E4: yield latency is dominated by sampling frequency, not by releasing
        # memory. Sample fast when a user could plausibly be about to return.
        return (presence.POLL_INTERVAL_IDLE if state in ("LOCKED", "ABSENT")
                else presence.POLL_INTERVAL_ACTIVE)

    def fetch(self, kinds):
        try:
            url = (f"{self.coordinator}/work?worker={self.name}"
                   f"&kinds={','.join(kinds)}")
            with urllib.request.urlopen(url, timeout=60) as r:
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

    def process(self, unit, kind):
        """Run a unit, re-checking presence between every item.

        Between-item is the right granularity: a unit is a batch, so checking
        only at unit boundaries would let up to a whole batch run on after
        someone returns. Per-item bounds the intrusion to one item (~1s) while
        keeping the presence check itself negligible.
        """
        items = unit["items"]
        runtime = self.runtime_for(kind)
        self.apply_qos(self.presence()["policy"], kind)
        t0 = time.perf_counter()
        done = 0

        for index, item in enumerate(items):
            reading = self.presence()
            policy = reading["policy"]
            self.apply_qos(policy, kind)

            # Re-check that *this* kind is still permitted, not merely that some
            # work is: a machine moving from LOCKED to ACTIVE keeps ANE work
            # legal while revoking GPU work mid-unit.
            if kind not in self.available_kinds(policy):
                unfinished = items[index:]
                self.stats["yields"] += 1
                self.stats["items_lost"] += 0  # nothing in flight was discarded
                self.log(f"  YIELD -> {reading['state']} "
                         f"({', '.join(policy['blocked_by']) or 'user present'}); "
                         f"{done} done, {len(unfinished)} returned")
                return done, unfinished, time.perf_counter() - t0

            item_t0 = time.perf_counter()
            runtime.run(item) if kind == "embed" else runtime.run(item["prompt"])
            item_s = time.perf_counter() - item_t0
            done += 1

            # E2: duty cycle is a real, monotonic lever independent of QoS.
            # Sleeping proportionally yields the GPU back in gaps. ANE work is
            # exempt - E5 measured it as invisible, so throttling it would cost
            # throughput to buy politeness that is already free.
            duty = 1.0 if kind == "embed" else policy["duty_max"]
            if 0 < duty < 1.0:
                time.sleep(item_s * (1.0 / duty - 1.0))

        return done, [], time.perf_counter() - t0

    def run(self):
        self.log(f"harvest worker {self.name} ({self.machine})")
        self.log(f"coordinator {self.coordinator}")
        if self.ane is not None:
            try:
                load_s = self.ane.load()
                pl = self.ane.placement
                self.log(f"  ANE model loaded in {load_s:.2f}s "
                         f"({pl['ane_share']:.0%} of {pl['total_ops']} ops on ANE)")
            except ANEPlacementError as exc:
                # Refuse rather than silently disturbing the user from the CPU.
                self.log(f"  ANE model REJECTED: {exc}")
                self.ane = None
            except Exception as exc:
                self.log(f"  ANE model failed to load: {exc!r}")
                self.ane = None

        while True:
            reading = self.presence()
            state, policy = reading["state"], reading["policy"]
            kinds = self.available_kinds(policy)

            if not kinds:
                freed = self.unload_all()
                if freed:
                    self.log(f"  standing down in {state}; released in {freed*1000:.0f}ms")
                wait = self.poll_interval(state)
                self.stats["idle_s"] += wait
                time.sleep(wait)
                continue

            # Release the GPU model as soon as GPU work stops being permitted,
            # even though ANE work continues. E4 puts reload at 1-3s, so holding
            # it against a possible return is not worth the resident memory.
            if "generate" not in kinds and self.runtime.loaded:
                freed = self.runtime.unload()
                self.log(f"  GPU work not permitted in {state}; "
                         f"released model in {freed*1000:.0f}ms")

            work = self.fetch(kinds)
            if work is None:
                continue
            if work.get("wait") or work.get("idle"):
                time.sleep(3)
                continue
            if work.get("done"):
                break

            kind = work.get("kind", "generate")
            if kind == "generate" and not self.runtime.loaded:
                load_s = self.runtime.load()
                self.stats["loads"] += 1
                self.stats["load_s"] += load_s
                self.log(f"  loaded GPU model in {load_s:.2f}s (state={state})")

            done, unfinished, seconds = self.process(work, kind)
            self.stats["items"] += done
            self.stats.setdefault(f"items_{kind}", 0)
            self.stats[f"items_{kind}"] += done
            self.stats["units"] += 1
            self.stats["work_s"] += seconds
            self.report(work["unit_id"], done, unfinished, seconds)

            if not unfinished:
                rate = done / seconds if seconds else 0
                self.log(f"  {kind}: {done} items in {seconds:.2f}s ({rate:.2f}/s) "
                         f"state={state}")

        self.unload_all()
        self.log("done: " + json.dumps(self.stats))
        return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--coordinator", required=True)
    ap.add_argument("--model", default="mlx-community/Qwen2.5-1.5B-Instruct-4bit",
                    help="MLX model for GPU 'generate' work")
    ap.add_argument("--ane-model",
                    help="Core ML .mlpackage for ANE 'embed' work. Without it "
                         "the worker can only run in LOCKED and ABSENT.")
    ap.add_argument("--name", default=platform.node().split(".")[0])
    ap.add_argument("--promote-after", type=float,
                    default=presence.IDLE_PROMOTE_SECONDS,
                    help="seconds a more-permissive state must hold before the "
                         "worker adopts it. Production default is deliberately "
                         "long (E4: a false 'they are gone' costs a model load "
                         "and an instant preemption); lower it only for tests.")
    args = ap.parse_args()
    return HarvestWorker(args.coordinator, args.name, args.model,
                         ane_model=args.ane_model,
                         promote_after=args.promote_after).run()


if __name__ == "__main__":
    raise SystemExit(main())
