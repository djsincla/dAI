#!/usr/bin/env python3
"""
Control plane client for the harvest agent.

Speaks the contract at control-plane/openapi/dai.yaml. The agent is the second
implementation of that schema and the control plane is the first, which is the
point of writing the schema before either: a mismatch shows up here rather than
in production.

Two properties this client is careful about.

**The local policy is a floor, not a suggestion.** The control plane serves a
policy table and the agent fetches it, but the agent also carries its own from
`presence.py` and applies whichever is more restrictive. A control plane that is
compromised, misconfigured, or simply newer than the agent must not be able to
talk a machine into running GPU work while someone is using it. The agent
already re-derives presence locally; this makes the permission side symmetric.

**Unreachable is not permission.** Every failure path leaves the agent doing
less work, never more. If policy cannot be fetched the local table applies
unchanged; if the control plane is down the agent stands down rather than
falling back to some default that happens to be permissive.
"""

import json
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "presence"))
import presence  # noqa: E402


class ControlPlaneError(RuntimeError):
    pass


class NotEnrolled(ControlPlaneError):
    """The node has no certificate yet, or has one that is not approved."""


class ControlPlane:
    def __init__(self, base_url, client_cert=None, client_key=None, ca_cert=None,
                 dev_fingerprint=None, timeout=60):
        self.base = base_url.rstrip("/")
        self.timeout = timeout
        # Development escape hatch mirroring the server's
        # DAI_TRUST_FINGERPRINT_HEADER. Never use where a certificate is
        # possible: a header as node identity is not authentication.
        self.dev_fingerprint = dev_fingerprint

        self.ssl_context = None
        if self.base.startswith("https"):
            # Pin the CA rather than trusting the system store. A node that
            # verifies nothing accepts work from anything that can reach it on
            # the network, and a work unit tells a node what to execute.
            self.ssl_context = ssl.create_default_context(cafile=ca_cert)
            if client_cert and client_key:
                self.ssl_context.load_cert_chain(client_cert, client_key)

    def _request(self, method, path, body=None, expect=(200, 202, 204)):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(f"{self.base}{path}", data=data, method=method)
        req.add_header("content-type", "application/json")
        if self.dev_fingerprint:
            req.add_header("x-node-fingerprint", self.dev_fingerprint)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout,
                                        context=self.ssl_context) as resp:
                if resp.status not in expect:
                    raise ControlPlaneError(f"{method} {path} returned {resp.status}")
                raw = resp.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")[:300]
            if exc.code in (401, 403):
                raise NotEnrolled(f"{exc.code}: {detail}") from exc
            raise ControlPlaneError(f"{method} {path} -> {exc.code}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise ControlPlaneError(f"{method} {path} unreachable: {exc.reason}") from exc

    # -- enrollment ---------------------------------------------------------

    def enroll(self, join_token, hostname, chip, memory_gb, metal_working_set_gb,
               os_version, csr_pem):
        """Request enrollment.

        Returns the pending node record. A join token grants nothing on its own:
        the node waits in `pending` until an admin approves it, so this is the
        start of the flow rather than the end.
        """
        return self._request("POST", "/agent/v1/enroll", {
            "joinToken": join_token,
            "hostname": hostname,
            "chip": chip,
            "memoryGb": memory_gb,
            "metalWorkingSetGb": metal_working_set_gb,
            "osVersion": os_version,
            "csrPem": csr_pem,
        }, expect=(202,))

    # -- policy -------------------------------------------------------------

    def fetch_policy(self):
        """Server policy table, keyed by presence state, in the agent's shape."""
        served = self._request("GET", "/agent/v1/policy")
        return {
            state: {
                "gpu": bool(p["gpu"]),
                "ane": bool(p["ane"]),
                "qos": p["qos"],
                "duty_max": float(p["dutyMax"]),
                "mem_frac": float(p["memFrac"]),
            }
            for state, p in (served or {}).items()
        }

    # -- work ---------------------------------------------------------------

    def heartbeat(self, presence_state, on_ac_power=None, thermal_ok=None,
                  capability_samples=None, resident_models=None):
        body = {"presenceState": presence_state}
        if resident_models is not None:
            # Sent every time, replacing rather than merging: a model released
            # on a yield is no longer resident, and routing to a node that has
            # to reload it defeats the point of tracking residency at all.
            body["residentModels"] = resident_models
        if on_ac_power is not None:
            body["onAcPower"] = on_ac_power
        if thermal_ok is not None:
            body["thermalOk"] = thermal_ok
        if capability_samples:
            # Throughput observed from completed work, per workload class. The
            # scheduler needs a profile rather than a scalar: the same two
            # machines differed 7.5% on a 1.5B model and 26.3% on a 7B.
            body["capabilitySamples"] = [
                {"workloadClass": k, "itemsPerSecond": v}
                for k, v in capability_samples.items()
            ]
        self._request("POST", "/agent/v1/heartbeat", body, expect=(204,))

    def lease_work(self, kinds):
        if not kinds:
            return {"reason": "none-of-these-kinds"}
        return self._request("GET", f"/agent/v1/work?kinds={','.join(kinds)}")

    def poll_dispatch(self, timeout=40):
        """Hold the reverse channel open, waiting for an interactive request.

        Returns None on a 204, which is a normal timeout rather than an error:
        the connection is closed and reopened so a node notices a control plane
        restart instead of waiting on a socket nobody is listening to.
        """
        req = urllib.request.Request(f"{self.base}/agent/v1/dispatch", method="GET")
        if self.dev_fingerprint:
            req.add_header("x-node-fingerprint", self.dev_fingerprint)
        try:
            with urllib.request.urlopen(req, timeout=timeout,
                                        context=self.ssl_context) as resp:
                if resp.status == 204:
                    return None
                raw = resp.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                raise NotEnrolled(str(exc.code)) from exc
            raise ControlPlaneError(f"dispatch poll -> {exc.code}") from exc
        except urllib.error.URLError as exc:
            raise ControlPlaneError(f"dispatch poll unreachable: {exc.reason}") from exc

    def report_dispatch(self, dispatch_id, result=None, error=None):
        body = {"result": result} if error is None else {"error": error}
        return self._request("POST", f"/agent/v1/dispatch/{dispatch_id}/result", body,
                             expect=(200, 409))

    def report(self, unit_id, completed, unfinished, seconds, failed=False):
        return self._request("POST", f"/agent/v1/work/{unit_id}/result", {
            "completed": completed,
            "unfinished": unfinished,
            "seconds": round(seconds, 3),
            "failed": failed,
        })


def merge_policy(local, served):
    """Combine the agent's policy with the server's, taking the stricter of each.

    Not a preference for one side. The server knows fleet-wide intent and may be
    newer; the agent knows the machine and is the thing that will actually
    disturb its owner. Taking the intersection means neither a stale agent nor a
    compromised control plane can widen what runs on someone's Mac, and the
    failure mode of disagreement is less work rather than more.
    """
    if not served:
        return local
    merged = {}
    for state, lp in local.items():
        sp = served.get(state)
        if not sp:
            merged[state] = lp
            continue
        merged[state] = {
            **lp,
            "gpu": lp["gpu"] and sp["gpu"],
            "ane": lp["ane"] and sp["ane"],
            # background is the more restrictive of the two QoS levels.
            "qos": "background" if "background" in (lp["qos"], sp["qos"]) else "standard",
            "duty_max": min(lp["duty_max"], sp["duty_max"]),
            "mem_frac": min(lp["mem_frac"], sp["mem_frac"]),
        }
    return merged


def apply_policy(policy):
    """Install a merged policy as the presence module's table for this process."""
    for state, p in policy.items():
        if state in presence.POLICY:
            presence.POLICY[state] = p
