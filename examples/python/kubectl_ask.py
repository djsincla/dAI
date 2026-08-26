#!/usr/bin/env python3
"""Ask kubectl a question: retrieve locally, answer on the fleet.

    python3 kubectl_ask.py "how do I roll back a deployment?"
    python3 kubectl_ask.py --retrieve-only "copy a file out of a pod"
    python3 kubectl_ask.py --k 8 --show-sources "what does kubectl drain do?"

The same shape as rag_ask.py, over a different corpus:

    question -> vectors, here            no network, no third party
             -> nearest command help     from a file on this disk
             -> a prompt with the text   the command name in the text itself
             -> the fleet                somebody's idle Mac, named in the output
             -> an answer with commands

Two sources are in the index and they are not interchangeable. Entries marked
`(help, vX)` are the output of the binary on the machine that built the corpus,
and are authoritative for *that* version's flags. Entries marked
`(kubernetes.io reference)` are the published docs, which describe some release
and carry the prose and examples the terminal help trims. The answer is asked to
say which it used, because "the flag is --foo" is a different claim depending on
where it came from.

`--retrieve-only` runs everything except the generation, which is the right way
to judge the retrieval: if the commands it lists are not the ones you would have
reached for, no model is going to rescue the answer.

Build the index first:

    python3 kubectl_fetch.py
    python3 rag_index.py --corpus corpus/kubectl.jsonl --index corpus/kubectl.db

This suggests commands; it does not run them. Read anything destructive before
you paste it - `delete`, `drain` and `taint` all do exactly what they say.
"""
from __future__ import annotations

import argparse
import os
import sys

import rag_embed
import quotecheck
from dai_gateway import (Gateway, GatewayError, NoCapacity, pick_model, provenance,
                         text_of, who_answered)
from rag_store import Store

HERE = os.path.dirname(os.path.abspath(__file__))
INDEX = os.path.join(HERE, "corpus", "kubectl.db")

# Short, and every line of it load-bearing. The instruction that matters is the
# one about not knowing: a model asked about law will fill a gap with something
# that sounds like law, and a plausible invented subdivision is worse than no
# answer because it cannot be told apart from a real one.
SYSTEM = """You answer questions about kubectl using the command documentation provided below.

You are not a man page. The reader can already run `kubectl --help` and can
already read kubernetes.io. What they cannot get from either is judgement about
which command to reach for, and what goes wrong in practice. Give them that.

Shape the answer like this:
- The command to run, on its own line, first. Not after a paragraph of preamble
  restating the question.
- One or two sentences on what it actually does, in plain words rather than the
  documentation's phrasing. If you find yourself copying a sentence out of the
  text above, you are reciting rather than answering.
- The thing that bites people: a prerequisite, a surprising default, a common
  mistake, or the neighbouring command that is usually the better choice. Pick
  the single most useful one, not all four.

Keep it short. Brevity forces you to choose what matters. An answer that runs
past a screen has started listing options instead of recommending one.

Two kinds of statement, kept visibly apart:
- Facts about commands, flags, defaults and behaviour come from the
  documentation above, and carry the command name like (kubectl rollout undo).
- Judgement about which command suits a situation is yours, and reads like
  judgement: "usually", "I would reach for", "unless". Never dress judgement as
  a documented fact, and never invent a fact to prop up judgement.

Rules on accuracy, which outrank every rule on voice above:
- Facts must come from the provided documentation. If it does not answer the
  question, say so plainly and say which command you would expect to document
  it. A confident answer from an empty retrieval is the worst outcome here.
- Name only commands and flags that appear in the text above.
- Do not invent flags. A flag that sounds right and does not exist is worse than
  no answer, because it fails at the terminal instead of here - and a flag that
  exists in a different release is the same problem wearing a disguise.
- Say which source a claim came from when it matters: the entries marked
  `(help, vX)` are that binary's own output, the ones marked
  `(kubernetes.io reference)` describe the published release.
- Say plainly when a command is destructive or disruptive - deleting resources,
  draining a node, forcing a rollout - rather than leaving the reader to find
  out. Say what is lost, not merely that care is needed.

Documentation:
"""


def render(chunks: list[dict]) -> str:
    return "\n\n".join(
        f"[{c['citation']} - {c['chapter_name']}]\n{c['text']}" for c in chunks)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("question", nargs="*", help="what to ask")
    parser.add_argument("--k", type=int, default=6, help="command pages to retrieve")
    parser.add_argument("--per-section", type=int, default=2,
                        help="most chunks taken from any one command")
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
        print('Ask something:  python3 kubectl_ask.py "how do I roll back a deployment?"')
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
        print("Nothing retrieved; the index looks empty. Build it with kubectl_fetch.py then rag_index.py")
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
        # "No model was involved" was the wording here, and it was wrong on a
        # semantic index: embedding the question loads all-MiniLM-L6-v2, which
        # is 22.7M parameters and about 2.7s of the 3s this takes. The bar that
        # says "Loading weights" is that, not the fleet. What is skipped is the
        # LLM, and on a bm25 index no weights load at all.
        local = "no language model was involved"
        if getattr(model, "name", "") != "bm25":
            local = (f"the only model involved was the local embedding model"
                     f" ({getattr(model, 'model_name', model.name)}), which is"
                     " what prints 'Loading weights'")
        print(f"\n--retrieve-only: this ran entirely on this machine. No request"
              f" was made to the gateway and {local}.")
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
        print(f"prompt    {total} tokens ({len(prompt)} chars of documentation)")
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
    # Checked before the provenance block, because provenance answers "where did
    # this come from" and this answers "is what it says it copied actually
    # copied" - and the second is the one that has been wrong.
    quoted = quotecheck.report(quotecheck.check(answer, [c["text"] for c in chunks]))
    if quoted:
        print()
        print(quoted)

    print(f"\n--- where this answer came from -------------------------------")
    print(provenance(gateway, completion))
    print("\nRead anything destructive before you paste it. This suggests\n"
          "commands; it does not run them.")
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
