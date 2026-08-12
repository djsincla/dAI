"""A small client for the dAI serving gateway.

Standard library only, because the point of these examples is the gateway and
not a dependency list. `urllib` is enough for an HTTP API and it is already on
every machine that can run the agent.

Three things a caller has to get right, and all three are here rather than in
each script:

**The credential.** An API key, minted once by an operator, sent as
`Authorization: Bearer` or `x-api-key`. The gateway accepts both because the
Anthropic clients people already use send the second one.

**The certificate.** The control plane serves TLS from its own authority, so a
client has to be told which CA to trust. Pointing at that file is the correct
thing to do; turning verification off is not, and this module deliberately makes
the second one awkward. A fleet whose whole argument is that the work stays on
your own hardware should not be reached over a connection nobody authenticated.

**503 is not an error.** Every harvest node runs on somebody's desk, and during
working hours that somebody is at it, so GPU work is forbidden and the honest
answer to a request is "no machine can take this right now". The gateway returns
it immediately rather than hanging, and a caller that treats it as a failure has
misunderstood what it bought.
"""

from __future__ import annotations

import json
import os
import ssl
import urllib.error
import urllib.request

DEFAULT_BASE_URL = "https://localhost:8452"

# Where the control plane's installer puts the CA it signs its own certificate
# with. A client on another machine gets this file copied to it; the installer
# prints the path for exactly this reason.
DEFAULT_CA_PATHS = [
    "/var/db/dai-control/certs/srv-ca.crt",
    os.path.expanduser("~/.dai/srv-ca.crt"),
    "/Library/Application Support/dAI/server-ca.crt",
]


class GatewayError(RuntimeError):
    """An error the gateway reported, with its status kept."""

    def __init__(self, status: int, payload, message: str):
        super().__init__(message)
        self.status = status
        self.payload = payload


class NoCapacity(GatewayError):
    """503: no node can take this request right now.

    Its own type because it is the one failure a caller should handle rather
    than log. It means the fleet is doing what it promised - the machines belong
    to the people sitting at them - and the work should be retried later, moved
    to a node that is idle, or run somewhere else.
    """


class Gateway:
    def __init__(self, base_url: str | None = None, api_key: str | None = None,
                 ca_cert: str | None = None, timeout: float = 300.0,
                 insecure: bool = False):
        self.base_url = (base_url or os.environ.get("DAI_BASE_URL")
                         or DEFAULT_BASE_URL).rstrip("/")
        self.api_key = api_key or os.environ.get("DAI_API_KEY")
        self.timeout = timeout
        self.ca_cert = ca_cert or os.environ.get("DAI_CA_CERT") or self._find_ca()

        if insecure or os.environ.get("DAI_INSECURE") == "1":
            # Available because a first look at a machine you are standing in
            # front of should not require a certificate hunt. It is not a
            # default and it is not silent.
            self._ssl = ssl._create_unverified_context()
            self.verified = False
        else:
            # Passing cafile=None here would not fail - it would quietly fall
            # back to the system roots, which cannot verify a certificate the
            # control plane signed itself. The connection would then fail much
            # later with a TLS error that says nothing about the missing file,
            # so the missing file is reported now instead.
            self._ssl = ssl.create_default_context(cafile=self.ca_cert)
            self.verified = True

    def describe_tls(self) -> str:
        if not self.verified:
            return "NOT VERIFIED (DAI_INSECURE=1)"
        if self.ca_cert:
            return f"verified against {self.ca_cert}"
        return ("no CA found; set DAI_CA_CERT to the control plane's srv-ca.crt "
                "(system roots cannot verify a self-signed control plane)")

    @staticmethod
    def _find_ca() -> str | None:
        for path in DEFAULT_CA_PATHS:
            if os.path.exists(path):
                return path
        return None

    # ---------------------------------------------------------------- plumbing

    def request(self, method: str, path: str, body=None) -> tuple[int, object]:
        """Send one request. Returns the status and the decoded body.

        Errors are not raised here. Several of these endpoints answer with a
        status a caller is meant to read - 503 for no capacity, 404 for a model
        nobody is serving - and a helper that raised on all of them would make
        the interesting cases the hard ones.
        """
        url = f"{self.base_url}{path}"
        data = json.dumps(body).encode() if body is not None else None
        headers = {"accept": "application/json"}
        if data is not None:
            headers["content-type"] = "application/json"
        if self.api_key:
            headers["authorization"] = f"Bearer {self.api_key}"

        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout,
                                        context=self._ssl) as response:
                raw = response.read()
                return response.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                return error.code, json.loads(raw)
            except json.JSONDecodeError:
                return error.code, raw.decode(errors="replace")
        except urllib.error.URLError as error:
            raise self._explain(error) from error

    def _explain(self, error: urllib.error.URLError) -> Exception:
        """Turn the two connection failures people actually hit into advice."""
        reason = str(getattr(error, "reason", error))
        if "CERTIFICATE_VERIFY_FAILED" in reason:
            return GatewayError(0, None,
                f"TLS verification failed against {self.base_url}.\n"
                f"  CA in use: {self.ca_cert or '(none found)'}\n"
                "  The control plane signs its certificate with its own authority.\n"
                "  Copy srv-ca.crt from the control plane and set DAI_CA_CERT to it.\n"
                "  The installer prints its path when it finishes.")
        if "Connection refused" in reason or "connect" in reason.lower():
            return GatewayError(0, None,
                f"Nothing answered at {self.base_url}: {reason}\n"
                "  Check the daemon:  sudo launchctl print system/com.dai.control\n"
                "  Check the log:     /var/log/dai-control/control.log")
        return GatewayError(0, None, f"{self.base_url}: {reason}")

    def _checked(self, status: int, payload, what: str):
        if status == 200:
            return payload
        message = self._message(payload) or f"HTTP {status}"
        if status == 503:
            raise NoCapacity(status, payload,
                f"No node can take this {what} right now: {message}\n"
                "  This is the fleet working as intended. Harvest nodes yield to\n"
                "  whoever is sitting at them, so during working hours there may\n"
                "  genuinely be no capacity. Try again when the desks are empty.")
        if status in (401, 403):
            raise GatewayError(status, payload,
                f"The gateway refused the credential ({status}): {message}\n"
                "  Set DAI_API_KEY to a key minted by an operator:\n"
                "    curl -sk https://<control-plane>:8452/admin/v1/auth/keys \\\n"
                "      -H \"authorization: Bearer $SESSION\" \\\n"
                "      -H 'content-type: application/json' -d '{\"label\":\"examples\"}'")
        raise GatewayError(status, payload, f"{what} failed ({status}): {message}")

    @staticmethod
    def _message(payload) -> str | None:
        if isinstance(payload, dict):
            error = payload.get("error")
            if isinstance(error, dict):
                return error.get("message")
            if isinstance(error, str):
                return error
            if "message" in payload:
                return str(payload["message"])
        return str(payload) if payload else None

    # ------------------------------------------------------------- the surface

    def models(self) -> list[dict]:
        """Models resident somewhere in the fleet, in OpenAI's shape."""
        status, payload = self.request("GET", "/v1/models")
        return self._checked(status, payload, "model list").get("data", [])

    def models_detailed(self) -> list[dict]:
        """The same models in LM Studio's shape, which carries the context window.

        Served so tools written against LM Studio work unchanged. It is also the
        only place a caller can learn how much context a model was loaded with,
        which is what decides how much retrieved text a RAG prompt can carry.
        """
        status, payload = self.request("GET", "/api/v0/models")
        payload = self._checked(status, payload, "model detail")
        return payload.get("data", []) if isinstance(payload, dict) else []

    def count_tokens(self, model: str, messages: list[dict],
                     system=None, tools=None) -> int:
        """What a request would cost, counted by the node's own tokeniser.

        Worth using rather than estimating: the chat template and any tool
        schemas are part of the prompt, and they are often the larger half.
        """
        body = {"model": model, "messages": messages}
        if system is not None:
            body["system"] = system
        if tools is not None:
            body["tools"] = tools
        status, payload = self.request("POST", "/v1/messages/count_tokens", body)
        return self._checked(status, payload, "token count")["input_tokens"]

    def chat(self, model: str, messages: list[dict], max_tokens: int = 512) -> dict:
        """A completion in the OpenAI shape.

        `max_tokens` is a request, not a guarantee. The answering node caps it
        by its own presence policy, because a single completion has no seam to
        stop at and the bound on its length is the bound on how long a returning
        user waits for their machine back.
        """
        status, payload = self.request("POST", "/v1/chat/completions", {
            "model": model, "messages": messages, "max_tokens": max_tokens,
        })
        return self._checked(status, payload, "completion")

    def messages(self, model: str, messages: list[dict], max_tokens: int = 512,
                 system: str | None = None) -> dict:
        """The same completion in the Anthropic shape."""
        body = {"model": model, "messages": messages, "max_tokens": max_tokens}
        if system is not None:
            body["system"] = system
        status, payload = self.request("POST", "/v1/messages", body)
        return self._checked(status, payload, "completion")

    # Admin, for the scripts that show the fleet rather than use it.

    def fleet_summary(self) -> dict:
        status, payload = self.request("GET", "/admin/v1/fleet/summary")
        return self._checked(status, payload, "fleet summary")

    def nodes(self) -> list[dict]:
        status, payload = self.request("GET", "/admin/v1/nodes")
        payload = self._checked(status, payload, "node list")
        return payload if isinstance(payload, list) else payload.get("nodes", [])


# ------------------------------------------------------------------- helpers


def text_of(completion: dict) -> str:
    """The assistant's words, from either response shape."""
    if "choices" in completion:
        return completion["choices"][0]["message"]["content"]
    parts = completion.get("content", [])
    return "".join(p.get("text", "") for p in parts if isinstance(p, dict))


def who_answered(completion: dict) -> str:
    """Which machine did the work, and what its owner was doing.

    Outside the OpenAI schema on purpose. On a fleet assembled from other
    people's desks, "which desk" is not diagnostic detail - it is the product.
    """
    extra = completion.get("dai") or {}
    node = extra.get("node")
    if not node:
        # Deliberately not "unknown node", which reads like a minor gap. Only
        # the control plane's router can fill this block in, so its absence
        # means the answer's origin is unverified - and on a machine that is
        # both control plane and node, unverified is exactly the case worth
        # noticing.
        return "PROVENANCE MISSING (control plane did not say which node answered)"
    presence = extra.get("presenceState")
    return f"{node} ({presence})" if presence else node


def provenance(gateway: "Gateway", completion: dict) -> str:
    """Evidence that this answer came through the gateway, not from here.

    The question this answers is a real one on a single-machine deployment,
    where the control plane, the node and the caller are the same computer and
    a local shortcut would look identical to a fleet round trip.

    Three facts, none of which this script can fabricate:

    - the URL it spoke to, and whether that TLS certificate verified against the
      control plane's own authority;
    - the node the control plane's router selected, and that machine's presence
      state, which only the router knows;
    - the prompt and completion token counts, which are produced by the
      answering node's tokeniser rather than counted here.
    """
    extra = completion.get("dai") or {}
    usage = completion.get("usage") or {}
    prompt_tokens = usage.get("prompt_tokens", usage.get("input_tokens"))
    completion_tokens = usage.get("completion_tokens", usage.get("output_tokens"))

    lines = [
        f"  gateway    {gateway.base_url}",
        f"  TLS        {gateway.describe_tls()}",
        f"  routed to  {who_answered(completion)}",
    ]
    if extra.get("seconds") is not None:
        lines.append(f"  node time  {extra['seconds']}s")
    if prompt_tokens is not None:
        lines.append(f"  tokens     {prompt_tokens} in, {completion_tokens} out"
                     " (counted by the answering node)")
    if extra.get("cappedByPolicy"):
        lines.append(f"  capped     to {extra.get('maxTokensApplied')} tokens by that"
                     " machine's presence policy")
    if not extra.get("node"):
        lines.append("  WARNING    this control plane did not return a provenance block;"
                     " update it to confirm which machine answered")
    return "\n".join(lines)


def pick_model(gateway: Gateway, preferred: str | None = None) -> str:
    """Whatever is loaded, preferring what the caller asked for.

    These scripts are meant to run on a fleet whose resident models are not
    known in advance, so none of them hardcode a name.
    """
    available = [m["id"] for m in gateway.models()]
    if not available:
        raise GatewayError(0, None,
            "No model is resident anywhere in the fleet.\n"
            "  Push one from the console, or check that a node is approved and idle.")
    if preferred:
        if preferred in available:
            return preferred
        for name in available:
            if preferred.lower() in name.lower():
                return name
    return available[0]
