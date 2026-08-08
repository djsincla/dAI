#!/usr/bin/env python3
"""
Enroll this machine with a control plane.

Separate from the worker because enrollment happens once and needs a human on
the other end: a join token grants nothing by itself, so this prints the node id
and fingerprint and then stops. An admin approves, and only then does the worker
have an identity to run under.
"""

import argparse
import json
import platform
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from control_plane import ControlPlane  # noqa: E402


def hardware():
    out = subprocess.run(["system_profiler", "SPHardwareDataType"],
                         capture_output=True, text=True, timeout=30).stdout
    def field(label, default=""):
        return next((l.split(":", 1)[1].strip() for l in out.splitlines()
                     if l.strip().startswith(label)), default)
    mem = field("Memory:", "0 GB").split()[0]
    return field("Chip:", "unknown"), float(mem)


def metal_working_set_gb():
    """Metal's own cap, which sits near 81% of unified memory. Agent ceilings are
    fractions of this, never of installed RAM, so the control plane needs it."""
    try:
        import mlx.core as mx
        return int(mx.device_info()["max_recommended_working_set_size"]) / (1 << 30)
    except Exception:
        return 0.0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--control-plane", required=True)
    ap.add_argument("--join-token", required=True)
    ap.add_argument("--ca-cert")
    ap.add_argument("--csr", help="path to a CSR for a key generated on-device")
    args = ap.parse_args()

    chip, memory_gb = hardware()
    # A real agent generates this keypair in the Secure Enclave and marks it
    # non-exportable, so a certificate copied off disk is useless without the
    # hardware. This placeholder stands in until issuance is implemented.
    csr = Path(args.csr).read_text() if args.csr else \
        f"-----BEGIN CERTIFICATE REQUEST-----\n{platform.node()}\n"

    cp = ControlPlane(args.control_plane, ca_cert=args.ca_cert)
    out = cp.enroll(args.join_token, platform.node().split(".")[0], chip, memory_gb,
                    round(metal_working_set_gb(), 1), platform.mac_ver()[0], csr)
    print(json.dumps(out, indent=2))
    print("\nPending approval. An admin must approve this node before it "
          "receives work.", file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
