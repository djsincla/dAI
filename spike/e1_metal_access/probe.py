#!/usr/bin/env python3
"""
E1 - Can MLX reach the Metal GPU from a launchd context with no user session?

This is the existential gate for the harvest tier. If GPU compute requires an
active GUI session, we can only ever harvest logged-in-but-idle machines, which
is a materially weaker product.

Run the same probe in four contexts and diff the results:
  1. interactive   - normal shell, user logged in at the GUI
  2. agent         - LaunchAgent (runs inside the user's GUI session)
  3. daemon        - LaunchDaemon (session 0, root, no user context)
  4. daemon-locked - LaunchDaemon with the screen locked / user logged out

Writes a JSON result so it can be collected from a daemon that has no stdout.
"""

import json
import os
import pwd
import subprocess
import sys
import time
import traceback

# MLX is lazy: building a graph touches no hardware. Every timing and every
# claim of "the GPU ran this" below depends on an explicit mx.eval().
MATMUL_N = 2048
MATMUL_ITERS = 50


def sh(cmd):
    """Best-effort shell probe; never raise, the context matters more than any one value."""
    try:
        out = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=10
        )
        return out.stdout.strip() or out.stderr.strip() or None
    except Exception as e:
        return f"<error: {e}>"


def process_context():
    """Who and where are we? This is what distinguishes the four run contexts."""
    try:
        login = os.getlogin()
    except OSError:
        login = None  # expected in a daemon: no controlling terminal

    console_user = sh("stat -f%Su /dev/console")
    screen_locked = sh(
        "ioreg -n Root -d1 -a | plutil -extract IOConsoleLocked raw - 2>/dev/null"
    )

    return {
        "uid": os.getuid(),
        "euid": os.geteuid(),
        "user": pwd.getpwuid(os.getuid()).pw_name,
        "os_getlogin": login,
        "pid": os.getpid(),
        "sid": os.getsid(0),
        "console_user": console_user,
        "screen_locked_raw": screen_locked,
        "ssh_session": bool(os.environ.get("SSH_CONNECTION")),
        "has_tty": sys.stdin.isatty(),
        "security_session": sh("launchctl managername"),
        "audit_session": sh("id -a 2>/dev/null | head -c 200"),
    }


def gpu_probe():
    """Force real Metal work and verify the result is numerically correct.

    Correctness matters as much as "it didn't crash": a silent fallback to CPU
    would still produce right answers, so we record the device MLX actually
    used alongside the memory counters, which only move for GPU allocations.
    """
    import mlx.core as mx

    result = {"mlx_version": getattr(mx, "__version__", "unknown")}

    # Ask explicitly for the GPU rather than trusting the default.
    mx.set_default_device(mx.gpu)
    result["default_device"] = str(mx.default_device())

    # device_info moved between mx.metal and top-level across versions.
    for holder, name in ((getattr(mx, "metal", None), "mx.metal"), (mx, "mx")):
        fn = getattr(holder, "device_info", None) if holder else None
        if callable(fn):
            try:
                result["device_info"] = {k: str(v) for k, v in fn().items()}
                result["device_info_source"] = name
                break
            except Exception as e:
                result["device_info_error"] = repr(e)

    a = mx.random.normal((MATMUL_N, MATMUL_N), dtype=mx.float32)
    b = mx.random.normal((MATMUL_N, MATMUL_N), dtype=mx.float32)
    mx.eval(a, b)  # materialize inputs before timing

    t0 = time.perf_counter()
    for _ in range(MATMUL_ITERS):
        c = a @ b
        mx.eval(c)  # without this the loop is free and measures nothing
    elapsed = time.perf_counter() - t0

    # 2*N^3 flops per matmul.
    flops = 2 * (MATMUL_N**3) * MATMUL_ITERS
    result["matmul_n"] = MATMUL_N
    result["matmul_iters"] = MATMUL_ITERS
    result["elapsed_s"] = round(elapsed, 4)
    result["gflops"] = round(flops / elapsed / 1e9, 1)

    # Correctness: compare one row against an independent CPU computation.
    row = 7
    gpu_row = (a[row : row + 1] @ b)[0]
    with mx.stream(mx.cpu):
        cpu_row = (a[row : row + 1] @ b)[0]
    mx.eval(gpu_row, cpu_row)
    max_abs_err = float(mx.max(mx.abs(gpu_row - cpu_row)).item())
    result["max_abs_err_vs_cpu"] = max_abs_err
    result["numerically_correct"] = max_abs_err < 1e-2  # fp32 matmul reassociation

    for label, fn_name in (
        ("active_memory_bytes", "get_active_memory"),
        ("peak_memory_bytes", "get_peak_memory"),
        ("cache_memory_bytes", "get_cache_memory"),
    ):
        for holder in (mx, getattr(mx, "metal", None)):
            fn = getattr(holder, fn_name, None) if holder else None
            if callable(fn):
                try:
                    result[label] = fn()
                except Exception:
                    pass
                break

    # If Metal never allocated, the counters stay at zero even though the
    # matmul "succeeded" on CPU - this is the real fallback detector.
    result["gpu_memory_moved"] = bool(result.get("peak_memory_bytes", 0) > 0)
    return result


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/e1_result.json"
    context_label = os.environ.get("E1_CONTEXT", "unlabeled")

    record = {
        "context_label": context_label,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "process": process_context(),
    }

    # Metal access alone does not make a daemon viable. The agent also has to
    # see whether a human is at the machine, and those signals may not survive
    # session 0 either. Collect them in the same run rather than discovering a
    # second existential problem after E1 "passes".
    try:
        import pathlib
        sys.path.insert(
            0, str(pathlib.Path(__file__).resolve().parent.parent / "presence"))
        import presence
        signals = presence.read_signals()
        record["presence"] = {
            "state": presence.classify(signals),
            "signals": signals,
            # The whole point of the daemon check: a signal that reads None here
            # but works interactively is unavailable in session 0.
            "unavailable_signals": [
                k for k in ("hid_idle_s", "screen_locked", "console_user")
                if signals.get(k) is None
            ],
        }
    except Exception as exc:
        record["presence"] = {"error": repr(exc)}

    try:
        record["gpu"] = gpu_probe()
        record["gpu_reachable"] = bool(
            record["gpu"].get("numerically_correct")
            and record["gpu"].get("gpu_memory_moved")
        )
    except Exception:
        record["gpu_reachable"] = False
        record["error"] = traceback.format_exc()

    # Append mode for the interval-driven daemon run, which needs to accumulate
    # samples across a lock/unlock/logout cycle rather than overwrite each time.
    if out_path.endswith(".jsonl"):
        with open(out_path, "a") as f:
            f.write(json.dumps(record) + "\n")
        os.chmod(out_path, 0o666)  # daemon runs as root; keep it user-readable
    else:
        with open(out_path, "w") as f:
            json.dump(record, f, indent=2)
    print(json.dumps(record, indent=2))
    return 0 if record["gpu_reachable"] else 1


if __name__ == "__main__":
    sys.exit(main())
