#!/usr/bin/env python3
"""Ask the same question of a split model and a single-machine model.

    python3 ask_both_shapes.py "what is a regional center?"
    python3 ask_both_shapes.py --split-port 8461 --single-port 8460 "..."
    python3 ask_both_shapes.py --list

The point of running both is that **the calling code is identical**. A model
that runs across two machines and a model that runs on one are the same request
to the same API: same path, same body, same response shape. Nothing here sets a
rank, names a peer, or knows a pipeline exists. That is the whole claim of the
split - it is an operator's deployment decision, not something a caller has to
participate in.

What differs is worth measuring, and this prints it:

**Where the work happened.** One machine, or two acting as one. The catalogue
says which, and the provenance block on the answer says which machine took the
request - for a split that is rank 0, the machine holding the output head, which
is the only one that can answer.

**What it costs per token.** A split pays one hidden state across the link per
token. On this fleet that link is a Thunderbolt bridge at ~0.85ms, or wired
ethernet at ~0.48ms; over Wi-Fi at ~70ms a split is unusable, which is why the
agent refuses to advertise an interface nobody named.

**What it buys.** Memory divides. A model too large for any single machine runs
because each holds only its own layers. That is the only reason to accept the
per-token cost, and if the model fits on one machine the split is a slower way
to get the same answer.

Neither shape is better. They answer different questions: "will it fit" and
"how fast".

Requires DAI_API_KEY, and DAI_CA_CERT unless the control plane's authority is
already trusted by this machine. See README.md.
"""

from __future__ import annotations

import argparse
import sys
import time

from dai_gateway import Gateway, GatewayError, NoCapacity, provenance, text_of


def shapes_on(port: int) -> tuple[Gateway | None, list[dict], str | None]:
    """What one socket offers, sorted into split and single.

    Returns the gateway, its models annotated with shape, and a reason if the
    socket could not be reached at all - which is ordinary rather than
    exceptional here, since a group that is stood down stops listening.
    """
    gateway = Gateway(base_url=f"https://localhost:{port}")
    try:
        models = gateway.models()
    except GatewayError as e:
        return None, [], str(e)
    except OSError as e:
        return None, [], f"nothing listening on {port} ({e})"

    out = []
    for m in models:
        # Embedding models answer a different endpoint. Offering one as a chat
        # model produces a confusing failure from the node rather than a clear
        # refusal here.
        if m["id"].startswith("ane:"):
            continue
        # The catalogue is the authority on this, not the name. This fleet ran
        # for a day with a group declaring it served a 14B while its machines
        # actually held a 32B and a 30B, and no repository path would have said
        # so.
        dai = m.get("dai") or {}
        out.append({
            "id": m["id"],
            "machines": dai.get("machines", 1),
            "split": bool(dai.get("split")),
            "shape": dai.get("shape", "runs on one machine"),
            "port": port,
            # From the model, never from the socket it was found on. A cluster
            # group's split model is also offered on a harvest group's socket
            # when they share machines, and labelling by port called it
            # single-machine on one of them - which is the exact confusion the
            # shape field exists to end.
            "label": "split" if dai.get("split") else "single-machine",
        })
    return gateway, out, None


def ask(gateway: Gateway, model: dict, question: str, max_tokens: int) -> dict | None:
    """One question, one model. Identical for both shapes - that is the point.

    Timed here as well as on the node, because the two differ by exactly what
    this script is for: the node reports its own generation time, and the wall
    clock includes admitting a gang and opening the link between machines, which
    a single-machine request never pays.
    """
    print(f"\n{'-' * 68}")
    print(f"{model['label']}  ->  {model['id']}")
    print(f"  {model['shape']}, on port {model['port']}")

    started = time.monotonic()
    try:
        completion = gateway.chat(
            model["id"],
            [{"role": "user", "content": question}],
            max_tokens=max_tokens,
        )
    except NoCapacity as e:
        # Distinguished from a fault: a split needs every machine at once, so a
        # group one machine short refuses rather than queues. That is a fleet
        # state, not a broken request.
        print(f"  no capacity: {e}")
        return None
    except GatewayError as e:
        print(f"  failed: {e}")
        return None
    elapsed = time.monotonic() - started

    print(f"\n{text_of(completion).strip()}\n")
    print(provenance(gateway, completion))
    print(f"  wall clock {elapsed:.1f}s"
          "   (includes admission and, for a split, opening the link)")

    usage = completion.get("usage") or {}
    out_tokens = usage.get("completion_tokens", usage.get("output_tokens")) or 0
    if elapsed > 0 and out_tokens:
        print(f"  {out_tokens / elapsed:.1f} tokens/sec end to end")
    return {"model": model, "elapsed": elapsed, "out": out_tokens,
            "node": (completion.get("dai") or {}).get("node")}


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("question", nargs="*",
                        default=["What is a regional center, in two sentences?"])
    parser.add_argument("--split-port", type=int, default=8461,
                        help="a group serving a model across machines (default 8461)")
    parser.add_argument("--single-port", type=int, default=8460,
                        help="a group serving on one machine (default 8460)")
    parser.add_argument("--max-tokens", type=int, default=200)
    parser.add_argument("--list", action="store_true",
                        help="show what each socket offers and stop")
    args = parser.parse_args()

    question = " ".join(args.question).strip()

    sockets = [args.split_port, args.single_port]
    found: list[tuple[Gateway, dict]] = []

    print("what each socket offers")
    for port in sockets:
        gateway, models, problem = shapes_on(port)
        if problem:
            print(f"  {port:5}  {problem}")
            continue
        if not models:
            # A real state on this fleet: a cluster group suspends the machines
            # a harvest group would use, so the harvest socket listens and has
            # nothing to serve. Empty is not broken.
            print(f"  {port:5}  listening, nothing being served")
            continue
        for m in models:
            mark = "split " if m["split"] else "single"
            print(f"  {port:5}  [{mark}] {m['id']}  ({m['shape']})")
            # The same model is offered on both sockets when a cluster group and
            # a harvest group share machines. Asking it twice compares nothing.
            if any(m["id"] == seen[1]["id"] for seen in found):
                continue
            found.append((gateway, m))

    if args.list:
        return 0

    # Take one of each shape, whichever socket it turned up on. Asking the same
    # model twice would compare nothing.
    split = next((p for p in found if p[1]["split"]), None)
    single = next((p for p in found if not p[1]["split"]), None)

    if not split and not single:
        print("\nNo model is being served. Check that a group is enabled and has"
              "\nmachines: its socket listens either way.")
        return 1

    print(f"\nquestion  {question}")
    results = []
    for pair in (single, split):
        if pair is None:
            continue
        result = ask(pair[0], pair[1], question, args.max_tokens)
        if result:
            results.append(result)

    if len(results) == 2:
        print(f"\n{'=' * 68}\nboth shapes, same call")
        for r in results:
            m = r["model"]
            across = f"{m['machines']} machines" if m["split"] else "1 machine"
            rate = r["out"] / r["elapsed"] if r["elapsed"] else 0
            print(f"  {across:12} {r['elapsed']:6.1f}s  {rate:5.1f} tok/s"
                  f"  answered by {r['node'] or 'unknown'}  {m['id']}")
        print("\nThe request bodies were identical. Only the deployment differed.")
    elif len(results) == 1:
        missing = "split" if not split else "single-machine"
        print(f"\nOnly one shape was available - no {missing} model is being served,"
              "\nso there is nothing to compare against. The call would be the same.")

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
