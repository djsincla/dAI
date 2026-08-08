#!/usr/bin/env python3
"""
Enroll this machine with a control plane and collect its certificate.

Separate from the worker because enrollment happens once and needs a human in
the middle: a join token gets a node into a queue, an admin decides whether it
becomes a member. This generates a keypair, submits a CSR, and waits.

The private key never leaves this machine and is never sent anywhere. On a real
agent it is generated in the Secure Enclave and marked non-exportable, so a
certificate copied off disk is useless without the hardware. Here it is a file
with 0600, which is the closest a Python agent can get.
"""

import argparse
import json
import platform
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from control_plane import ControlPlane, ControlPlaneError  # noqa: E402


def hardware():
    out = subprocess.run(["system_profiler", "SPHardwareDataType"],
                         capture_output=True, text=True, timeout=30).stdout

    def field(label, default=""):
        return next((l.split(":", 1)[1].strip() for l in out.splitlines()
                     if l.strip().startswith(label)), default)

    mem = field("Memory:", "0 GB").split()[0]
    return field("Chip:", "unknown"), float(mem)


def metal_working_set_gb():
    """Metal's own cap, near 81% of unified memory. The control plane sizes
    ceilings against this rather than installed RAM."""
    try:
        import mlx.core as mx
        return round(int(mx.device_info()["max_recommended_working_set_size"]) / (1 << 30), 1)
    except Exception:
        return 0.0


def generate_key_and_csr(identity_dir: Path, hostname: str):
    """Create a keypair and CSR on this machine.

    The CN here is ignored by the issuer: the control plane names the
    certificate after the node record, so a machine cannot request an identity
    belonging to another node.
    """
    identity_dir.mkdir(parents=True, exist_ok=True)
    key = identity_dir / "node.key"
    csr = identity_dir / "node.csr"
    if not key.exists():
        subprocess.run(
            ["openssl", "req", "-newkey", "rsa:2048", "-nodes",
             "-keyout", str(key), "-out", str(csr), "-subj", f"/CN={hostname}"],
            check=True, capture_output=True)
        key.chmod(0o600)
    elif not csr.exists():
        subprocess.run(["openssl", "req", "-new", "-key", str(key),
                        "-out", str(csr), "-subj", f"/CN={hostname}"],
                       check=True, capture_output=True)
    return csr.read_text()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--control-plane", required=True)
    ap.add_argument("--join-token", required=True)
    ap.add_argument("--identity-dir", default=str(Path.home() / ".dai" / "identity"))
    ap.add_argument("--ca-cert", help="CA to pin while enrolling, if already known")
    ap.add_argument("--wait", type=float, default=600,
                    help="seconds to wait for an admin to approve; 0 to exit immediately")
    args = ap.parse_args()

    identity = Path(args.identity_dir)
    hostname = platform.node().split(".")[0]
    chip, memory_gb = hardware()
    csr_pem = generate_key_and_csr(identity, hostname)

    cp = ControlPlane(args.control_plane, ca_cert=args.ca_cert)

    if (identity / "node.crt").exists():
        print(f"Already enrolled. Identity in {identity}", file=sys.stderr)
        return 0

    # Resume rather than re-enroll. Running this twice used to create a second
    # pending node and then poll for it, leaving the first one stranded in the
    # approval queue and the certificate uncollected.
    node_file, token_file = identity / "node-id", identity / "enrollment-token"
    if node_file.exists() and token_file.exists():
        node_id, token = node_file.read_text().strip(), token_file.read_text().strip()
        print(f"Resuming enrollment for {node_id}", file=sys.stderr)
    else:
        out = cp.enroll(args.join_token, hostname, chip, memory_gb,
                        metal_working_set_gb(), platform.mac_ver()[0], csr_pem)
        node_id, token = out["nodeId"], out["enrollmentToken"]
        node_file.write_text(node_id)
        # Single use and the only way back in before the node has an identity,
        # so it is stored with the same care as the private key.
        token_file.write_text(token)
        token_file.chmod(0o600)
        print(json.dumps({"nodeId": node_id, "state": out["state"]}, indent=2))

    if args.wait <= 0:
        print("\nPending approval.", file=sys.stderr)
        return 0

    print(f"\nWaiting up to {args.wait:.0f}s for an admin to approve...", file=sys.stderr)
    deadline = time.time() + args.wait
    while time.time() < deadline:
        try:
            issued = cp.collect_certificate(node_id, token)
        except ControlPlaneError as exc:
            print(f"  {exc}", file=sys.stderr)
            return 1
        if issued:
            (identity / "node.crt").write_text(issued["certPem"])
            # The *server* CA, which is what verifies the control plane. The
            # node CA signs agent identities and is not useful here; pinning it
            # by mistake fails every subsequent connection with a certificate
            # error that reads like a network problem.
            server_ca = issued.get("serverCaPem")
            if server_ca:
                (identity / "ca.crt").write_text(server_ca)
            elif args.ca_cert:
                (identity / "ca.crt").write_text(Path(args.ca_cert).read_text())
            (identity / "node.csr").unlink(missing_ok=True)
            (identity / "enrollment-token").unlink(missing_ok=True)
            print(f"\nApproved. Identity written to {identity}", file=sys.stderr)
            print(f"\n  --client-cert {identity}/node.crt \\", file=sys.stderr)
            print(f"  --client-key {identity}/node.key \\", file=sys.stderr)
            print(f"  --ca-cert {identity}/ca.crt", file=sys.stderr)
            return 0
        time.sleep(3)

    print("\nStill pending. Re-run to keep waiting; the enrollment token is "
          "stored and single use.", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
