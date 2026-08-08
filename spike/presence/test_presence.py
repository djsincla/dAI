"""
Regression suite for the presence policy core.

Every test here corresponds to a bug that actually shipped into the spike and
had to be found by running the system. The policy core is three pure functions
over a signal dictionary, so all of them reproduce from recorded data with no
hardware involved — which is exactly why that purity is worth protecting.

The spike's failure mode was consistent: six separate measurements were wrong in
the *flattering* direction. These tests are written to fail closed.

    ../.venv-harvest/bin/python -m pytest test_presence.py -q
"""

import pytest

import presence


def signals(**overrides):
    """A quiet, idle, plugged-in machine. Override one field per test so each
    case states exactly what it is about."""
    base = {
        "timestamp": 1_000_000.0,
        "hid_idle_s": 600.0,
        "screen_locked": False,
        "console_user": "dwayne",
        "on_ac_power": True,
        "display_assertions": [],
        "busy_assertions": [],
        "thermal_ok": True,
    }
    base.update(overrides)
    return base


def policy_for(**overrides):
    sig = signals(**overrides)
    return presence.effective_policy(presence.classify(sig), sig)


# --------------------------------------------------------------------------
# Classification
# --------------------------------------------------------------------------

def test_recent_input_is_active():
    assert presence.classify(signals(hid_idle_s=5.0)) == "ACTIVE"


def test_locked_screen_beats_idle_time():
    assert presence.classify(signals(screen_locked=True, hid_idle_s=1.0)) == "LOCKED"


def test_no_console_user_is_absent():
    assert presence.classify(signals(console_user=None)) == "ABSENT"


def test_unreadable_idle_signal_fails_closed_to_active():
    """A missing signal must never be read as 'nobody is here'.

    Guessing ABSENT degrades a machine someone is using, which is the one-strike
    failure. Guessing ACTIVE only costs throughput.
    """
    assert presence.classify(signals(hid_idle_s=None)) == "ACTIVE"


# --------------------------------------------------------------------------
# Sleep assertions: the bug that shipped twice
# --------------------------------------------------------------------------

def test_display_assertion_means_a_human_is_watching():
    """A video call or playback holds PreventUserIdleDisplaySleep and emits no
    HID events. Without PASSIVE the agent would resume work mid-call."""
    sig = signals(display_assertions=["zoom.us: Zoom Meeting"])
    assert presence.classify(sig) == "PASSIVE"


def test_system_sleep_assertions_do_not_imply_presence():
    """PreventUserIdleSystemSleep means only 'do not sleep'.

    Regression for the sharingd/Handoff bug: treating these as presence pinned
    the machine in PASSIVE permanently and it never harvested.
    """
    sig = signals(busy_assertions=["sharingd: Handoff", "coreaudiod: ..."])
    assert presence.classify(sig) == "IDLE"


def test_system_sleep_assertions_do_not_block_work():
    """Regression for the second occurrence of the same bug, one layer down.

    A single `caffeinate` assertion was gating GPU work off entirely. Safari,
    coreaudiod, downloads and caffeinate hold these more or less permanently, so
    gating on them blocks harvesting on any normally-used machine.
    """
    locked = policy_for(screen_locked=True,
                        busy_assertions=["caffeinate: caffeinate command-line tool"])
    assert locked["gpu"] is True
    assert locked["duty_max"] == 1.0
    assert locked["blocked_by"] == []


@pytest.mark.parametrize("proc", ["powerd", "sharingd", "coreaudiod", "backupd"])
def test_permanent_system_daemons_are_filtered(proc):
    """These hold sleep assertions continuously with no human involved. powerd
    in particular asserts whenever the display is on, so counting it would make
    every unlocked machine look permanently busy."""
    assert proc in presence.SYSTEM_ASSERTION_PROCS


# --------------------------------------------------------------------------
# Policy: what may run where
# --------------------------------------------------------------------------

@pytest.mark.parametrize("state", ["ACTIVE", "PASSIVE", "IDLE"])
def test_gpu_is_forbidden_whenever_a_user_is_logged_in(state):
    """E2 measured every GPU setting as perceptible, including the gentlest
    (background QoS at 25% duty, +46% of viewport p95)."""
    p = presence.effective_policy(state, signals())
    assert p["gpu"] is False
    assert p["duty_max"] == 0.0


@pytest.mark.parametrize("state", presence.STATES)
def test_ane_is_permitted_in_every_state(state):
    """E5 measured ANE work as indistinguishable from no load. It is the only
    thing a logged-in machine may do, across three of five states."""
    assert presence.effective_policy(state, signals())["ane"] is True


@pytest.mark.parametrize("state", ["LOCKED", "ABSENT"])
def test_gpu_runs_at_full_duty_and_standard_qos_when_unobserved(state):
    """E1 measured background QoS at ~2.4x on sustained work and the harvest
    worker at ~26x on bursty work. Leaving it pinned to background would waste
    most of the overnight window."""
    p = presence.effective_policy(state, signals())
    assert p["gpu"] is True
    assert p["duty_max"] == 1.0
    assert p["qos"] == "standard"


def test_battery_blocks_all_work():
    """The gate that would have saved orca, which drained its battery running a
    worker with no presence logic at all."""
    p = policy_for(console_user=None, on_ac_power=False)
    assert p["gpu"] is False and p["ane"] is False
    assert p["mem_frac"] == 0.0
    assert "on battery" in p["blocked_by"]


def test_thermal_pressure_blocks_gpu():
    p = policy_for(console_user=None, thermal_ok=False)
    assert p["gpu"] is False
    assert "thermal pressure" in p["blocked_by"]


def test_memory_ceiling_is_never_the_only_throttle():
    """mem_frac is not a politeness dial. E2 measured a 32 GB load disturbing a
    viewport *less* than an 8 GB one at identical duty, so a state that permits
    GPU work must also carry a duty limit."""
    for state in presence.STATES:
        p = presence.effective_policy(state, signals())
        if p["gpu"]:
            assert p["duty_max"] > 0, f"{state} allows GPU with no duty limit"


# --------------------------------------------------------------------------
# Hysteresis: asymmetric by design
# --------------------------------------------------------------------------

def test_demotion_toward_active_is_immediate():
    """A returning user must be respected on the very first sample."""
    monitor = presence.PresenceMonitor(promote_after=300)
    monitor.state = "LOCKED"
    reading = monitor.update(signals(hid_idle_s=1.0, screen_locked=False), now=0)
    assert reading["state"] == "ACTIVE"


def test_promotion_requires_the_condition_to_hold():
    """A false 'they are gone' costs a model load and an immediate preemption
    (E4), so promotion is deliberately slow."""
    monitor = presence.PresenceMonitor(promote_after=300)
    idle = signals(hid_idle_s=600.0)

    monitor.update(signals(hid_idle_s=1.0), now=0)
    assert monitor.state == "ACTIVE"

    # The timer starts at the FIRST sample showing the new condition (t=10),
    # not at the moment the previous state was entered, so the deadline is 310.
    assert monitor.update(idle, now=10)["state"] == "ACTIVE"
    assert monitor.update(idle, now=309)["state"] == "ACTIVE"
    assert monitor.update(idle, now=310)["state"] == "IDLE"


def test_a_brief_return_resets_the_promotion_timer():
    """Otherwise a user tapping the trackpad every few minutes would still see
    the machine promote to a permissive state."""
    monitor = presence.PresenceMonitor(promote_after=300)
    idle = signals(hid_idle_s=600.0)

    monitor.update(signals(hid_idle_s=1.0), now=0)
    monitor.update(idle, now=200)                      # timer would end at 500
    monitor.update(signals(hid_idle_s=1.0), now=250)   # user touches the machine
    assert monitor.state == "ACTIVE"

    # Without the reset this would promote at 500. The timer restarts from the
    # next idle sample (400), so the real deadline is 700.
    assert monitor.update(idle, now=400)["state"] == "ACTIVE"
    assert monitor.update(idle, now=699)["state"] == "ACTIVE"
    assert monitor.update(idle, now=700)["state"] == "IDLE"


@pytest.mark.parametrize("sequence", [
    [1.0, 600.0, 1.0, 600.0, 1.0],
    [600.0, 1.0, 600.0, 600.0, 1.0],
    [1.0, 1.0, 600.0, 1.0, 600.0],
])
def test_never_permits_gpu_while_input_is_recent(sequence):
    """Property: across any signal sequence, a sample with recent input must
    never leave the worker permitted to run GPU work."""
    monitor = presence.PresenceMonitor(promote_after=1)
    for i, idle in enumerate(sequence):
        reading = monitor.update(signals(hid_idle_s=idle), now=i * 10)
        if idle < presence.ACTIVE_IDLE_THRESHOLD:
            assert reading["policy"]["gpu"] is False, (
                f"GPU permitted at idle={idle}s in state {reading['state']}")
