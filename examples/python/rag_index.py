#!/usr/bin/env python3
"""Chunk the corpus, embed it, and write the vector store.

Chunking is where retrieval quality is won or lost, and statute makes it easier
than most prose because the drafters have already done it. A section is a unit
of meaning with a name you can cite, so a section is a chunk - and only the long
ones are split, on their own subdivision markers, so a piece never begins
halfway through "(b)".

    python3 rag_index.py                       # numpy only
    python3 rag_index.py --backend st          # dense semantic vectors
    python3 rag_index.py --max-chars 900       # smaller chunks
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

import rag_embed
from rag_store import Store

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus", "sections.jsonl")
INDEX = os.path.join(HERE, "corpus", "lanterman.db")

# Where a long section may be cut: its own subdivisions, in the order the
# drafters nest them. Splitting on these rather than on a character count is the
# difference between a chunk that reads as law and one that starts mid-clause.
BOUNDARY = re.compile(r"(?=\((?:[a-z]|\d{1,2}|[A-Z]|i{1,3}|iv|vi{0,3}|ix|x)\)\s)")


def split(text: str, max_chars: int, overlap: int) -> list[str]:
    """One chunk if it fits, otherwise pieces that end on a subdivision."""
    if len(text) <= max_chars:
        return [text]

    pieces = [p for p in BOUNDARY.split(text) if p.strip()]
    if len(pieces) == 1:
        # No subdivisions to cut on - a long unbroken passage. Fall back to
        # sentences, and only then to a hard cut.
        pieces = re.split(r"(?<=\.)\s+(?=[A-Z])", text)

    chunks, current = [], ""
    for piece in pieces:
        if current and len(current) + len(piece) > max_chars:
            chunks.append(current.strip())
            # Carry the tail forward so a definition split across a boundary is
            # still whole in one of the two chunks.
            current = (current[-overlap:] + " " + piece) if overlap else piece
        else:
            current = f"{current} {piece}".strip() if current else piece
    if current.strip():
        chunks.append(current.strip())

    # A hard cut for anything still oversized, so no chunk can be unbounded.
    out = []
    for chunk in chunks:
        while len(chunk) > max_chars * 2:
            out.append(chunk[:max_chars])
            chunk = chunk[max_chars - overlap:]
        out.append(chunk)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--backend", default="bm25",
                        help="bm25 (default, numpy only) or st (sentence-transformers)")
    parser.add_argument("--max-chars", type=int, default=1400)
    parser.add_argument("--overlap", type=int, default=200)
    parser.add_argument("--corpus", default=CORPUS)
    parser.add_argument("--index", default=INDEX)
    args = parser.parse_args()

    if not os.path.exists(args.corpus):
        print(f"No corpus at {args.corpus}.\n  Run:  python3 rag_fetch.py")
        return 1

    sections = [json.loads(line) for line in open(args.corpus, encoding="utf-8")]
    print(f"corpus    {len(sections)} sections")

    rows = []
    for section in sections:
        # The citation goes inside the chunk text, not only in the metadata.
        # The model sees only what is in the prompt, and a chunk that does not
        # say which section it is cannot be cited correctly no matter how good
        # the retrieval was.
        # The chapter and article titles, prepended to every chunk. They are the
        # corpus's only topical labels: the sections say what the rule is, and
        # only the heading says that chapter 1.3 is the Bill of Rights. Without
        # this, a question about rights cannot match the chapter about rights,
        # because the phrase appears in the title and nowhere in the text.
        where = " - ".join(part for part in (
            section.get("chapter_name", ""), section.get("article_name", "")) if part)

        pieces = split(section["text"], args.max_chars, args.overlap)
        for number, piece in enumerate(pieces):
            heading = f"{section['citation']}"
            if where:
                heading += f" - {where}"
            if len(pieces) > 1:
                heading += f" (part {number + 1} of {len(pieces)})"
            rows.append({
                "citation": section["citation"],
                "section": section["section"],
                "division": section.get("division", ""),
                "chapter": section.get("chapter", ""),
                "chapter_name": section.get("chapter_name", ""),
                "url": section["url"],
                "part": number,
                "parts": len(pieces),
                "text": f"{heading}\n{piece}",
            })

    print(f"chunks    {len(rows)} (max {args.max_chars} chars, {args.overlap} overlap)")
    longest = max(len(r["text"]) for r in rows)
    print(f"          longest {longest} chars, "
          f"{sum(1 for r in rows if r['parts'] > 1)} from split sections")

    model = rag_embed.build(args.backend)
    print(f"backend   {model.name}")
    texts = [r["text"] for r in rows]
    model.fit(texts)
    vectors = model.encode(texts)
    print(f"vectors   {vectors.shape[0]} x {vectors.shape[1]}")

    store = Store(args.index)
    store.reset()
    store.add(rows, vectors)
    store.set_meta("backend", model.name)
    store.set_meta("backend_state", {
        k: (v.hex() if isinstance(v, bytes) else v)
        for k, v in model.state().items()
    })
    store.set_meta("chunks", len(rows))
    store.set_meta("source", "https://www.dds.ca.gov/transparency/laws-regulations/"
                             "lanterman-act-and-related-laws/")
    store.close()

    size = os.path.getsize(args.index) / 1e6
    print(f"\nindex     {args.index} ({size:.1f} MB)")
    print("ask it:   python3 rag_ask.py \"who is eligible for regional center services?\"")
    return 0


if __name__ == "__main__":
    sys.exit(main())
