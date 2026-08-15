#!/usr/bin/env python3
"""Ask the Lanterman Act a question, answered by a model split across machines.

    python3 rag_ask_split.py "who is eligible for regional center services?"
    python3 rag_ask_split.py --port 8461 --k 8 "how is an IPP developed?"
    python3 rag_ask_split.py --explain "appeal a denial of services"

Same retrieval as `rag_ask.py`, and one difference that is the whole point of
this script: it talks to a **group's own socket** rather than the shared serving
port, and it asks for a model that runs across more than one machine.

    question -> vectors, here              no network, no third party
             -> nearest sections           from a file on this disk
             -> a prompt with the text     citations included
             -> https://host:8461/v1       the split-cluster group's socket
             -> two machines               24 layers each, one hidden state per
                                           token over the link between them
             -> an answer with citations

Why a separate port rather than a parameter: a group's socket is the whole of
its addressing. Nothing in the request names a group, so nothing in the request
can name the wrong one, and the URL is a thing you can firewall, monitor and
hand to a team. Point this at 8460 and the same question is answered by one
machine from the harvest group; point it at 8461 and it is answered by two.

What splitting buys is capacity, not speed. With one request in flight the two
machines run in sequence rather than in parallel, so a 72B costs about 14% of
its throughput and halves what each machine has to hold. The reason to do it is
that the model would not fit at all otherwise.

This is a demonstration, not legal advice. It quotes statute and points at the
Legislature's own copy of each section so an answer can be checked rather than
trusted, which is the only responsible way to point a language model at law.
"""

from __future__ import annotations

import argparse
import os
import sys
import time

import rag_embed
import quotecheck
from dai_gateway import Gateway, GatewayError, provenance, text_of, who_answered
from rag_ask import SYSTEM, render
from rag_store import Store

HERE = os.path.dirname(os.path.abspath(__file__))
INDEX = os.path.join(HERE, "corpus", "lanterman.db")

# The group's socket, allocated when the group was created. Not a default that
# will be right on another fleet - the control plane prints it when the group is
# made, and the console shows it on the group's card.
DEFAULT_PORT = 8461


def base_for(port: int) -> str:
    """The gateway URL for a group's socket, keeping whatever host is configured."""
    configured = (os.environ.get("DAI_BASE_URL") or "https://localhost:8452").rstrip("/")
    scheme, _, rest = configured.partition("://")
    host = rest.split("/")[0].split(":")[0]
    return f"{scheme or 'https'}://{host}:{port}"


def split_models(gateway: Gateway) -> list[dict]:
    """Models this socket will serve that run across more than one machine.

    The catalogue says so directly. A repository path does not: this fleet ran
    for a day with a group declaring it served a 14B while its two machines ran
    a 32B and a 30B, and nothing in any name would have told you.
    """
    out = []
    for model in gateway.models():
        shape = model.get("dai") or {}
        if shape.get("split"):
            out.append({"id": model["id"], **shape})
    return out


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("question", nargs="*", help="what to ask")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help=f"the group's socket (default {DEFAULT_PORT})")
    parser.add_argument("--model", default=None,
                        help="which split model; the only one offered, by default")
    parser.add_argument("--k", type=int, default=6, help="sections to retrieve")
    parser.add_argument("--per-section", type=int, default=2,
                        help="most chunks taken from any one section")
    parser.add_argument("--index", default=INDEX)
    parser.add_argument("--max-tokens", type=int, default=700)
    parser.add_argument("--explain", action="store_true",
                        help="show what the fleet is doing with this request")
    args = parser.parse_args()

    question = " ".join(args.question).strip()
    if not question:
        print('Ask something:  python3 rag_ask_split.py "who is eligible?"')
        return 2
    if not os.path.exists(args.index):
        print(f"No index at {args.index}.\n"
              "  python3 rag_fetch.py && python3 rag_index.py")
        return 1

    # ---- retrieve, entirely locally --------------------------------------
    #
    # Unchanged from the single-machine script, and worth noticing: splitting a
    # model changes nothing about retrieval. The statute is on this disk and the
    # query never leaves it.
    store = Store(args.index)
    state = store.get_meta("backend_state", {})
    if "idf" in state and isinstance(state["idf"], str):
        state["idf"] = bytes.fromhex(state["idf"])
    embedder = rag_embed.restore(store.get_meta("backend", "bm25"), state)

    query = embedder.encode_query([question])[0]
    chunks = store.search(query, k=args.k, per_section=args.per_section)
    store.close()

    if not chunks:
        print("Nothing retrieved; the index looks empty. Rebuild it with rag_index.py")
        return 1

    print(f"question  {question}")
    print(f"retrieved {len(chunks)} sections by {embedder.name}, on this machine\n")
    for chunk in chunks:
        part = f" part {chunk['part'] + 1}/{chunk['parts']}" if chunk["parts"] > 1 else ""
        print(f"  {chunk['score']:.3f}  {chunk['citation']}{part}")

    # ---- the group's socket ----------------------------------------------
    gateway = Gateway(base_url=base_for(args.port))
    print(f"\ngateway   {gateway.base_url}   (a group's own socket)")

    try:
        offered = split_models(gateway)
    except GatewayError as error:
        print(f"\n{error}")
        return 1

    if args.model:
        name = args.model
        shape = next((m for m in offered if m["id"] == name), None)
        if shape is None:
            # Worth refusing rather than sending: the request would be answered
            # by one machine, which is not what this script is for and not what
            # anybody reading its output would assume happened.
            print(f"\n{name} is not offered as a split model on this socket."
                  f"\nSplit models here: {', '.join(m['id'] for m in offered) or 'none'}")
            return 1
    elif not offered:
        print("\nThis socket is serving no model that runs across machines."
              "\n\nA split runs where an operator has assigned it - the group has to be"
              "\nserving a model whose shape says it needs more than one machine:"
              "\n  PUT /admin/v1/models/{id}/shape       {\"machines\": 2}"
              "\n  PUT /admin/v1/pools/{id}/serving-model {\"modelId\": \"...\", \"confirm\": true}"
              "\n\nThe confirmation is not a formality: those machines stop being"
              "\navailable to their harvest group for as long as the split stands.")
        return 1
    else:
        shape = offered[0]
        name = shape["id"]

    print(f"model     {name}   ({shape['shape']})")

    prompt = SYSTEM + render(chunks)
    messages = [{"role": "user", "content": question}]
    try:
        total = gateway.count_tokens(name, messages, system=prompt)
        print(f"prompt    {total} tokens ({len(prompt)} chars of statute)")
        # Counting is itself a request, and it is answered by one of the very
        # machines the split needs. A group whose model runs across every
        # machine it has holds no spare rank, so for that moment the gang cannot
        # be formed - the counting machine is mid-request rather than parked on
        # the channel. A second is enough for it to come back.
        if shape["machines"] > 1:
            time.sleep(1.0)
    except GatewayError:
        pass  # a count is a convenience; not having it should not stop the answer

    if args.explain:
        print(f"""
what happens next
  the control plane admits {shape['machines']} machines as a gang, all of them or none
  each is told its rank, and which of them listens for the other
  rank 0 takes the last layers and the output head; the rest take earlier ones
  each machine builds the model with only its own layers, so memory divides
  one hidden state crosses the link per token, and rank 0 answers
""")

    # ---- generate, across machines ---------------------------------------
    try:
        completion = gateway.messages(name, messages, max_tokens=args.max_tokens,
                                      system=prompt)
    except GatewayError as error:
        # One handler, because NoCapacity is a GatewayError and the refusals
        # worth naming arrive as both: a gang that cannot form is reported by
        # the router, and a gang that formed and broke is reported by the node
        # that took the request. They read alike to a caller and have different
        # fixes, which is the whole reason for saying which is which.
        detail = str(error)
        payload = error.payload if isinstance(error.payload, dict) else {}
        inner = payload.get("error") if isinstance(payload.get("error"), dict) else {}
        # Two surfaces, two shapes. OpenAI's error carries `code`; Anthropic's
        # has no such field, so the gateway puts the refusal's name in a `dai`
        # block beside the message - the same bargain the model catalogue makes.
        code = inner.get("code") or (inner.get("dai") or {}).get("code")
        print(f"\n{detail}\n")

        # Keyed on the code rather than the wording. The messages are written to
        # be read by a person and change as they are improved; the code is the
        # part the fleet promises.
        if code == "not-offered":
            print("Nobody has assigned this model to a group. A split runs where an"
                  "\noperator put it, not where a request asks for one:"
                  "\n  PUT /admin/v1/pools/{id}/serving-model {\"modelId\": \"...\","
                  " \"confirm\": true}")
        elif code == "gang-short":
            print("The group cannot field the machines this model needs, or they"
                  "\ncannot reach each other. Two things to check, in this order:"
                  "\n  - are all of them connected? a machine that has gone to sleep"
                  "\n    leaves the group short, and a laptop sleeps on lid close"
                  "\n    whatever power assertions are held"
                  "\n  - has each said where its peers should dial it?"
                  "\n    DAI_PIPELINE_INTERFACE=bridge0 in the agent's plist")
        elif code == "gang-not-cluster":
            print("Only cluster-tier machines can hold a rank: a split cannot be"
                  "\npreempted, and harvest membership is the promise that it can be.")
        elif code == "node-unreachable":
            print("The gang formed and then broke. The message above names every rank"
                  "\nand what each said; the one that stayed silent is usually the"
                  "\nmachine that caused it.")
        return 1

    answer = text_of(completion).strip()
    print(f"\n{answer}\n")
    print(f"answered by {who_answered(completion)} - the rank holding the output head;"
          f"\nthe other {shape['machines'] - 1} did their share and returned nothing to read.\n")
    quoted = quotecheck.report(quotecheck.check(answer, [c["text"] for c in chunks]))
    if quoted:
        print()
        print(quoted)

    print(provenance(gateway, completion))
    return 0


if __name__ == "__main__":
    sys.exit(main())
