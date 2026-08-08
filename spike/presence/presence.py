#!/usr/bin/env python3
"""
User-presence detection — the harvest agent's primary control.

E2 showed contention lands in the tail: a 25 GB background load moved median
frame time 3% but p99 82%. That damage only matters while a human is watching.
At 2am it is irrelevant. So the agent should not try to be simultaneously fast
and invisible — it should detect presence and switch modes. Memory ceiling and
QoS are secondary dials applied *within* a mode.

Every signal here is read through IOKit or power management rather than through
AppKit or the window server, because a LaunchDaemon in session 0 has no GUI
session. NSWorkspace and CGEventSource would be richer but are unavailable
there; whether even these survive session 0 is what E1 measures.

Two properties the design turns on:

1. Asymmetric time constants. Yield must be near-instant, because the moment a
   user returns is the moment they would notice. Resume must be slow and
   conservative, because a false "they're gone" costs a model load and an
   immediate preemption. Hysteresis is not a refinement here, it is the point.

2. Idle time alone is wrong. Someone on a video call, watching playback, or
   waiting on a render produces no HID events for many minutes while being
   entirely present. Power assertions catch exactly that case, which is why
   PASSIVE exists as a distinct state rather than collapsing into IDLE.
"""

import argparse
import json
import subprocess
import time

# How often to sample. E4 measured memory release at ~20ms and model reload at
# 1-3s, which makes this interval the dominant term in end-to-end yield latency:
# polling every 2s means up to 2s of work continues after a user touches the
# keyboard, ~100x the cost of the release it triggers. Sampling is cheap (ioreg
# and pmset reads), so poll fast. Tune this, not the release path.
POLL_INTERVAL_ACTIVE = 0.5   # user present or recently present
POLL_INTERVAL_IDLE = 5.0     # confirmed idle; nothing to interrupt quickly

# Seconds of no HID input before the machine stops counting as actively used.
ACTIVE_IDLE_THRESHOLD = 90
# Sustained idle required before promoting to a more permissive state. Long on
# purpose: the cost of resuming too early is a wasted model load.
IDLE_PROMOTE_SECONDS = 300

# Ordered least to most permissive. Promotion needs hysteresis; demotion is
# immediate.
STATES = ["ACTIVE", "PASSIVE", "IDLE", "LOCKED", "ABSENT"]

# What the agent may do in each state.
#
# The GPU/ANE split is the most important column here. E5 measured a saturating
# ANE workload as statistically indistinguishable from no load at all (p95
# -16%, inside a 36% baseline noise floor) while equivalent GPU work cost
# +59-100%. The ANE is separate silicon and an artist's viewport does not touch
# it, so ANE work stays permitted in states where GPU work is forbidden.
#
# mem_frac is NOT a politeness dial and must not be treated as one: E5 saw a
# 4 GB load — a small fraction of a 64 GB machine — degrade viewport p95 by
# 100%. Footprint governs what fits, not how much a user is disturbed.
# Throttling disturbance requires limiting compute rate, which this table does
# not yet express. See e5_ane/FINDINGS.md.
POLICY = {
    "ACTIVE":  {"gpu": False, "ane": False, "qos": None,         "mem_frac": 0.00},
    # ANE stays on through PASSIVE and even ACTIVE-adjacent states on the E5
    # result; GPU does not.
    "PASSIVE": {"gpu": False, "ane": True,  "qos": "background", "mem_frac": 0.15},
    "IDLE":    {"gpu": True,  "ane": True,  "qos": "background", "mem_frac": 0.35},
    "LOCKED":  {"gpu": True,  "ane": True,  "qos": "standard",   "mem_frac": 0.70},
    "ABSENT":  {"gpu": True,  "ane": True,  "qos": "standard",   "mem_frac": 0.85},
}


def _sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True,
                              text=True, timeout=10).stdout
    except Exception:
        return ""


def hid_idle_seconds():
    """Seconds since the last keyboard/mouse/trackpad event.

    Read from IOHIDSystem rather than CGEventSourceSecondsSinceLastEventType so
    it does not need a GUI session. Value is nanoseconds.
    """
    out = _sh("ioreg -c IOHIDSystem 2>/dev/null | grep -m1 HIDIdleTime")
    try:
        return int(out.split("=")[-1].strip()) / 1e9
    except (ValueError, IndexError):
        return None


def screen_locked():
    out = _sh("ioreg -n Root -d1 -a 2>/dev/null | "
              "plutil -extract IOConsoleLocked raw - 2>/dev/null").strip()
    return {"true": True, "false": False}.get(out)


def console_user():
    user = _sh("stat -f%Su /dev/console").strip()
    # loginwindow owns the console when nobody is logged in.
    return None if user in ("", "root", "_windowserver", "loginwindow") else user


def on_ac_power():
    return "AC Power" in _sh("pmset -g batt")


# Background services that hold sleep assertions indefinitely with no human
# involved. Without this list sharingd's permanent "Handoff" assertion pins a
# machine in PASSIVE forever and it never harvests at all.
SYSTEM_ASSERTION_PROCS = {
    "powerd", "sharingd", "backupd", "mds", "mds_stores", "mDNSResponder",
    "softwareupdated", "nsurlsessiond", "cloudd", "bird", "AppleIDAuthAgent",
    "UpdateBrainService", "corespeechd", "photoanalysisd", "AMPDeviceDiscoveryAgent",
}


def _parse_assertions():
    """Split sleep assertions by what they actually imply.

    These answer two different questions and conflating them is wrong:

      PreventUserIdleDisplaySleep — something insists the *display* stay on.
        Video calls, playback, presentations. Strong evidence a human is
        looking at the screen right now.

      PreventUserIdleSystemSleep — something insists the *machine* keep
        running. Renders and long jobs hold this, but so do a dozen background
        daemons permanently. Evidence the machine is busy, not that anyone is
        present.

    Only the display class implies presence. The system class implies
    contention, which is a separate reason to back off.
    """
    display, system = [], []
    for line in _sh("pmset -g assertions 2>/dev/null").splitlines():
        line = line.strip()
        if not line.startswith("pid "):
            continue
        proc = line.split("(", 1)[-1].split(")", 1)[0] if "(" in line else ""
        if proc in SYSTEM_ASSERTION_PROCS:
            continue
        name = line.split("named:")[-1].strip().strip('"') if "named:" in line else line
        label = f"{proc}: {name}"[:60]
        if "PreventUserIdleDisplaySleep" in line:
            display.append(label)
        elif "PreventUserIdleSystemSleep" in line:
            system.append(label)
    return display, system


def thermal_ok():
    out = _sh("pmset -g therm")
    return not any(w in out for w in ("CPU_Speed_Limit", "warning level 1",
                                      "warning level 2", "warning level 3"))


def read_signals():
    idle = hid_idle_seconds()
    display_a, busy_a = _parse_assertions()
    return {
        "timestamp": time.time(),
        "hid_idle_s": round(idle, 1) if idle is not None else None,
        "screen_locked": screen_locked(),
        "console_user": console_user(),
        "on_ac_power": on_ac_power(),
        "display_assertions": display_a,   # implies a human is watching
        "busy_assertions": busy_a,          # implies the machine is busy
        "thermal_ok": thermal_ok(),
    }


def classify(sig):
    """Map raw signals to a presence state.

    Order matters: the most restrictive interpretation that fits wins. A missing
    signal is treated as "user present", because the failure mode of guessing
    absent is degrading someone's machine, and that ends the program.
    """
    if sig["console_user"] is None:
        return "ABSENT"
    if sig["screen_locked"] is True:
        return "LOCKED"

    idle = sig["hid_idle_s"]
    if idle is None:
        return "ACTIVE"  # cannot tell; assume the worst
    if idle < ACTIVE_IDLE_THRESHOLD:
        return "ACTIVE"
    if sig["display_assertions"]:
        # Something is holding the display awake: a call, playback, a
        # presentation. No keystrokes, but a human is almost certainly looking.
        return "PASSIVE"
    return "IDLE"


def effective_policy(state, sig):
    """Apply hard gates that override the state's policy entirely."""
    policy = dict(POLICY[state])
    reasons = []
    if not sig["on_ac_power"]:
        policy.update(gpu=False, ane=False, mem_frac=0.0)
        reasons.append("on battery")
    if not sig["thermal_ok"]:
        policy.update(gpu=False, mem_frac=0.0)
        reasons.append("thermal pressure")
    if sig["busy_assertions"]:
        # A render or long job is running even though nobody is typing. Not a
        # presence signal, but competing with it wastes both workloads.
        policy["mem_frac"] = min(policy["mem_frac"], 0.15)
        policy["gpu"] = False
        reasons.append(f"machine busy ({len(sig['busy_assertions'])} assertion/s)")
    policy["blocked_by"] = reasons
    return policy


class PresenceMonitor:
    """Applies hysteresis so the agent does not flap between states.

    Demotion (toward ACTIVE) is immediate — a returning user must be respected
    on the very first sample. Promotion (toward ABSENT) requires the condition
    to hold for IDLE_PROMOTE_SECONDS, so a momentary lull does not trigger an
    expensive model load that is about to be thrown away.
    """

    def __init__(self, promote_after=IDLE_PROMOTE_SECONDS):
        self.promote_after = promote_after
        self.state = "ACTIVE"
        self._candidate = None
        self._candidate_since = None

    def update(self, sig=None, now=None):
        sig = sig or read_signals()
        now = now if now is not None else sig["timestamp"]
        observed = classify(sig)

        if STATES.index(observed) <= STATES.index(self.state):
            # More restrictive (or unchanged): apply immediately.
            self.state = observed
            self._candidate = None
        else:
            if observed != self._candidate:
                self._candidate = observed
                self._candidate_since = now
            elif now - self._candidate_since >= self.promote_after:
                self.state = observed
                self._candidate = None

        return {
            "state": self.state,
            "observed": observed,
            "pending": self._candidate,
            "pending_for_s": (round(now - self._candidate_since, 1)
                              if self._candidate else None),
            "policy": effective_policy(self.state, sig),
            "signals": sig,
        }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--watch", action="store_true", help="poll continuously")
    ap.add_argument("--interval", type=float, default=POLL_INTERVAL_ACTIVE)
    ap.add_argument("--json", action="store_true", help="one-shot JSON")
    args = ap.parse_args()

    monitor = PresenceMonitor()

    if args.json:
        print(json.dumps(monitor.update(), indent=2))
        return 0

    if not args.watch:
        sig = read_signals()
        print(json.dumps({"state": classify(sig), "signals": sig}, indent=2))
        return 0

    print(f"{'state':<9} {'observed':<9} {'idle':>7} {'lock':>6} {'ac':>4} "
          f"{'gpu':>4} {'qos':>11} {'mem':>5}  assertions")
    print("-" * 82)
    while True:
        r = monitor.update()
        s, p = r["signals"], r["policy"]
        print(f"{r['state']:<9} {r['observed']:<9} "
              f"{(s['hid_idle_s'] if s['hid_idle_s'] is not None else -1):>7.1f} "
              f"{str(s['screen_locked']):>6} {str(s['on_ac_power']):>4} "
              f"{str(p['gpu']):>4} {str(p['qos']):>11} {p['mem_frac']:>5.2f}  "
              f"{','.join(s['display_assertions'] + s['busy_assertions'])[:34]}",
              flush=True)
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
