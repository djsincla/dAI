#!/usr/bin/env python3
"""Ask the Lanterman Act a question: retrieve locally, answer on the fleet.

    python3 rag_ask.py "who is eligible for regional center services?"
    python3 rag_ask.py --retrieve-only "appeal a denial of services"
    python3 rag_ask.py --k 8 --show-sources "what is an individual program plan?"

The shape of the thing:

    question -> vectors, here            no network, no third party
             -> nearest sections         from a 25MB file on this disk
             -> a prompt with the text   citations included in the text itself
             -> the fleet                somebody's idle Mac, named in the output
             -> an answer with citations

`--retrieve-only` runs everything except the generation, which makes it the
right way to judge the retrieval. If the sections it lists are not the ones a
person would have looked up, no model is going to rescue the answer, and the fix
is in chunking or the query rather than in the prompt.

This is a demonstration, not legal advice. It quotes statute and points at the
Legislature's own copy of each section so an answer can be checked rather than
trusted, which is the only responsible way to point a language model at law.
"""

from __future__ import annotations

import argparse
import os
import sys

import rag_embed
from dai_gateway import (Gateway, GatewayError, NoCapacity, pick_model, provenance,
                         text_of, who_answered)
from rag_store import Store

HERE = os.path.dirname(os.path.abspath(__file__))
INDEX = os.path.join(HERE, "corpus", "lanterman.db")

# Short, and every line of it load-bearing. The instruction that matters is the
# one about not knowing: a model asked about law will fill a gap with something
# that sounds like law, and a plausible invented subdivision is worse than no
# answer because it cannot be told apart from a real one.
SYSTEM = """You answer questions about California's Lanterman Act using only the sections of the Welfare and Institutions Code provided below.

Rules:
- Use only the provided sections. If they do not answer the question, say so plainly and say what is missing.
- Cite the section for every claim, like (WIC 4512). Cite the section only:
  never a paragraph or part number that is not printed in the text itself.
- Quote the statute's own words for anything turning on a precise term.
- Do not give legal advice or predict how a particular case would be decided.

Sections:
"""


def render(chunks: list[dict]) -> str:
    return "\n\n".join(f"[{c['citation']}]\n{c['text']}" for c in chunks)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("question", nargs="*", help="what to ask")
    parser.add_argument("--k", type=int, default=6, help="sections to retrieve")
    parser.add_argument("--per-section", type=int, default=2,
                        help="most chunks taken from any one section")
    parser.add_argument("--index", default=INDEX)
    parser.add_argument("--model", default=None)
    parser.add_argument("--max-tokens", type=int, default=700)
    parser.add_argument("--retrieve-only", action="store_true",
                        help="show what was retrieved and stop")
    parser.add_argument("--show-sources", action="store_true",
                        help="print the retrieved text, not just the citations")
    args = parser.parse_args()

    question = " ".join(args.question).strip()
    if not question:
        print('Ask something:  python3 rag_ask.py "who is eligible for services?"')
        return 2
    if not os.path.exists(args.index):
        print(f"No index at {args.index}.\n"
              "  python3 rag_fetch.py && python3 rag_index.py")
        return 1

    # ---- retrieve, entirely locally --------------------------------------
    store = Store(args.index)
    state = store.get_meta("backend_state", {})
    if "idf" in state and isinstance(state["idf"], str):
        state["idf"] = bytes.fromhex(state["idf"])
    model = rag_embed.restore(store.get_meta("backend", "bm25"), state)

    query = model.encode_query([question])[0]
    chunks = store.search(query, k=args.k, per_section=args.per_section)
    store.close()

    if not chunks:
        print("Nothing retrieved; the index looks empty. Rebuild it with rag_index.py")
        return 1

    print(f"question  {question}")
    print(f"retrieved {len(chunks)} of {args.k} requested, by {model.name}\n")
    for chunk in chunks:
        part = f" part {chunk['part'] + 1}/{chunk['parts']}" if chunk["parts"] > 1 else ""
        print(f"  {chunk['score']:.3f}  {chunk['citation']}{part}")
        print(f"         {chunk['url']}")
        if args.show_sources:
            body = chunk["text"].split("\n", 1)[-1]
            print(f"         {body[:400]}{'...' if len(body) > 400 else ''}\n")

    if args.retrieve_only:
        print("\n--retrieve-only: this ran entirely on this machine. No request was"
              " made to the gateway and no model was involved.")
        return 0

    # ---- generate, on the fleet ------------------------------------------
    gateway = Gateway()
    try:
        name = pick_model(gateway, args.model)
    except GatewayError as error:
        print(f"\n{error}\n\nRetrieval worked; only the answer needs a model.\n"
              "Run with --retrieve-only to use this without one.")
        return 1

    prompt = SYSTEM + render(chunks)
    messages = [{"role": "user", "content": question}]

    print(f"\nmodel     {name}")
    try:
        # Counted rather than estimated, because the retrieved text is most of
        # the prompt and the node's own tokeniser is the only thing that knows
        # what the chat template adds to it.
        total = gateway.count_tokens(name, messages, system=prompt)
        print(f"prompt    {total} tokens ({len(prompt)} chars of statute)")
    except GatewayError:
        pass  # a count is a convenience; not having it should not stop the answer

    completion = gateway.messages(name, messages, max_tokens=args.max_tokens,
                                  system=prompt)
    answer = text_of(completion).strip()

    print(f"\n--- answer ---------------------------------------------------\n")
    print(answer)
    print(f"\n--- sources --------------------------------------------------")
    for chunk in dict.fromkeys(c["citation"] for c in chunks):
        url = next(c["url"] for c in chunks if c["citation"] == chunk)
        print(f"  {chunk:<16} {url}")
    print(f"\n--- where this answer came from -------------------------------")
    print(provenance(gateway, completion))
    print("\nThe statute is the authority; this is a reading aid, not advice.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except NoCapacity as error:
        print(f"\n{error}")
        sys.exit(0)
    except GatewayError as error:
        print(f"\n{error}")
        sys.exit(1)
