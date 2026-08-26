#!/usr/bin/env python3
"""Ask the VMware Cloud Foundation 9.1 documentation a question.

    python3 vcf_ask.py "how do I add a host to a workload domain?"
    python3 vcf_ask.py --retrieve-only "what is the upgrade sequence to 9.1?"
    python3 vcf_ask.py --k 10 --show-sources "vSAN ESA disk claim requirements"

The same shape as rag_ask.py and kubectl_ask.py, over a corpus with a property
neither of those has: **the whole source is one 8,894 page PDF on this disk.**
That changes what the example demonstrates.

    question -> vectors, here          no network, no third party
             -> nearest sections       from a file on this disk
             -> a prompt with the text with section title and page number
             -> the fleet              somebody's idle Mac, named in the output
             -> an answer that cites a page you can open

Retrieval is semantic, not lexical, and for this corpus that is a requirement
rather than a preference. bm25 stores one dense row per chunk across the whole
vocabulary: at 985 chunks that is 23 MB and at 18,304 chunks it is gigabytes.
The index is built with --backend st for that reason, and the same reason means
you cannot fall back to bm25 here without rechunking coarsely first.

Every retrieved passage carries the page it came from, so an answer can be
checked against the PDF rather than believed. That matters more here than in
the kubectl example: a wrong kubectl flag fails immediately at the terminal,
whereas a wrong claim about a supported upgrade path fails on a Saturday, three
hours into a maintenance window.

Build the index first:

    python3 vcf_fetch.py
    python3 rag_index.py --backend st --corpus corpus/vcf91.jsonl \\
                         --index corpus/vcf91.db

This summarises documentation. It does not know your environment, your licence
entitlements, or your Bill of Materials, and it cannot see whether the sentence
it found applies to your version.
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
INDEX = os.path.join(HERE, "corpus", "vcf91.db")

# The voice rules exist because the first version of this prompt was all
# prohibitions, and a model told only what it may not do answers by paraphrasing
# the source. That produces a passage of documentation with the question's words
# in it, which the reader could have found themselves.
#
# The accuracy rules outrank them, and are stated after them so they are the
# last thing read. The version rule is the one specific to this corpus: the same
# PDF documents 9.1 and every 9.1.0.x patch, plus Known Issues that describe
# behaviour that is real and broken, and a sentence lifted from a Known Issue
# and presented as how the product works is the failure this corpus invites.
SYSTEM = """You answer questions about VMware Cloud Foundation 9.1 using the documentation provided below.

You are not a search result. The reader can already search the PDF. What they
cannot get from it is a straight answer to the question they asked, so give
them that first and keep it short.

Shape the answer like this:
- The answer itself, first, in two or three sentences. Not a restatement of the
  question and not a summary of what the documentation covers.
- Then only what is needed to act on it: the sequence, the prerequisite, or the
  constraint that decides whether this applies.
- Then the one thing that catches people out, when the documentation shows one.
  A prerequisite that is easy to miss, an order that cannot be reversed, a
  default that surprises. One, not a list.

If you find yourself copying sentences out of the text above, you are quoting
rather than answering. Say it in your own words and cite where it came from.

Two kinds of statement, kept visibly apart:
- Facts about the product come from the documentation above, and name the
  section they came from, like (Deployment > VCF Installer).
- Judgement about what suits a situation is yours, and reads like judgement:
  "usually", "unless", "I would". Never dress judgement as documented fact.

Rules on accuracy, which outrank every rule on voice above:
- Facts must come from the provided documentation. If it does not answer the
  question, say so plainly and name the section you would expect to cover it.
  An invented procedure is worse than no answer here, because it will be
  discovered halfway through a maintenance window and not at the keyboard.
- Do not invent product names, menu paths, API endpoints, or version numbers.
  A plausible menu path that does not exist costs somebody an afternoon.
- Version matters and this document covers several. Say which release a claim
  applies to when the text does. Do not generalise a statement about a patch
  release, such as 9.1.0.0200, into a statement about 9.1.
- Passages from Known Issues or Resolved Issues describe defects, not intended
  behaviour. Never present one as how the product works. If the answer rests on
  a Known Issue, say so in those words.
- Say plainly when an operation is disruptive or irreversible - decommissioning
  a domain, removing a host, an upgrade that cannot be rolled back - and say
  what is lost, not merely that care is needed.

Documentation:
"""


def render(chunks: list[dict]) -> str:
    return "\n\n".join(
        f"[{c['citation']} - {c['chapter_name']} - page {page_of(c)}]\n{c['text']}"
        for c in chunks)


def page_of(chunk: dict) -> str:
    url = chunk.get("url", "")
    return url.split("#page=")[-1] if "#page=" in url else "?"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("question", nargs="*", help="what to ask")
    parser.add_argument("--k", type=int, default=8,
                        help="passages to retrieve (higher than the other "
                             "examples: this corpus is broad and one section "
                             "rarely answers a question on its own)")
    parser.add_argument("--per-section", type=int, default=2,
                        help="most chunks taken from any one section")
    parser.add_argument("--index", default=INDEX)
    parser.add_argument("--model", default=None)
    parser.add_argument("--max-tokens", type=int, default=800)
    parser.add_argument("--retrieve-only", action="store_true",
                        help="show what was retrieved and stop")
    parser.add_argument("--show-sources", action="store_true",
                        help="print the retrieved text, not just the citations")
    args = parser.parse_args()

    question = " ".join(args.question).strip()
    if not question:
        print('Ask something:  python3 vcf_ask.py "how do I add a host to a workload domain?"')
        return 2
    if not os.path.exists(args.index):
        print(f"No index at {args.index}.\n"
              "  python3 vcf_fetch.py\n"
              "  python3 rag_index.py --backend st --corpus corpus/vcf91.jsonl \\\n"
              "                       --index corpus/vcf91.db")
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
        print("Nothing retrieved; the index looks empty. Build it with vcf_fetch.py then rag_index.py")
        return 1

    print(f"question  {question}")
    print(f"retrieved {len(chunks)} of {args.k} requested, by {model.name}\n")
    for chunk in chunks:
        part = f" part {chunk['part'] + 1}/{chunk['parts']}" if chunk["parts"] > 1 else ""
        print(f"  {chunk['score']:.3f}  {chunk['citation']}{part}")
        print(f"         {chunk['chapter_name']}")
        print(f"         page {page_of(chunk)}")
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
        total = gateway.count_tokens(name, messages, system=prompt)
        print(f"prompt    {total} tokens ({len(prompt)} chars of documentation)")
    except GatewayError:
        pass  # a count is a convenience; not having it should not stop the answer

    completion = gateway.messages(name, messages, max_tokens=args.max_tokens,
                                  system=prompt)
    answer = text_of(completion).strip()

    print("\n--- answer ---------------------------------------------------\n")
    print(answer)
    print("\n--- sources --------------------------------------------------")
    for citation in dict.fromkeys(c["citation"] for c in chunks):
        chunk = next(c for c in chunks if c["citation"] == citation)
        print(f"  page {page_of(chunk):>5}  {citation}")
    print("  open the PDF at those pages to check any of it:")
    print("  vcf91/vmware-cloud-foundation-9-1.pdf")

    quoted = quotecheck.report(quotecheck.check(answer, [c["text"] for c in chunks]))
    if quoted:
        print()
        print(quoted)

    print("\n--- where this answer came from -------------------------------")
    print(provenance(gateway, completion))
    print("\nThis summarises documentation. It does not know your environment,\n"
          "your licences, or your Bill of Materials. Check the pages above\n"
          "before acting on anything disruptive.")
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
