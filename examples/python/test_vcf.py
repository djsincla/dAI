"""Tests for the VCF documentation corpus and its retrieval.

    python3.11 -m pytest examples/python/test_vcf.py -v

Three of these are regressions for bugs that shipped a corpus which looked
entirely healthy. That is the point of writing them down: none of the three
raised an error, changed an exit code, or printed a warning. The corpus built,
the index built, and every question returned six confident passages.

    a section cut to nothing      70 sections silently absent from the corpus
    a span with no child entries  citations naming a page 390 pages away
    a chunk longer than the model quarter of every chunk never embedded

The first group needs no data and runs anywhere. The rest need the corpus and
the index, and skip rather than fail when they are absent, because a fresh
clone has neither:

    python3.11 vcf_fetch.py
    python3.11 rag_index.py --backend st --max-chars 600 --overlap 100 \\
                            --corpus corpus/vcf91.jsonl --index corpus/vcf91.db
"""

from __future__ import annotations

import json
import os

import pytest

import vcf_fetch

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus", "vcf91.jsonl")
INDEX = os.path.join(HERE, "corpus", "vcf91.db")

# The model the index is built with reads 256 word pieces and silently drops
# the rest. Measured with the real tokeniser rather than a characters per token
# rule of thumb, because this corpus is full of URLs, version strings and
# identifiers, which tokenise far worse than prose.
MODEL_TOKEN_BUDGET = 256

# Some overflow is tolerated. Chunks overlap, so text past the limit still
# reaches the index through the neighbouring chunk; what is lost is that one
# vector's account of its own tail. At 600 characters this measured 5.8%, and
# at 1,400 it was 15.4% with a worst case of 632 tokens unread.
MAX_OVERFLOWING = 0.10

needs_corpus = pytest.mark.skipif(
    not os.path.exists(CORPUS), reason="corpus not built; run vcf_fetch.py")
needs_index = pytest.mark.skipif(
    not os.path.exists(INDEX), reason="index not built; run rag_index.py")


@pytest.fixture(scope="module")
def records():
    with open(CORPUS, encoding="utf-8") as fh:
        return [json.loads(line) for line in fh]


def page_of(record: dict) -> int:
    return int(record["url"].split("#page=")[1])


class TestSectionBoundaries:
    """The bug that lost 70 sections, in the shape that caused it."""

    def test_a_boundary_that_leaves_nothing_is_rejected(self):
        # A landing page lists its children before any prose, so the first
        # occurrence of the next title is a link and not the heading. Cutting
        # there left "Upgrade Sequence to 9.1" and nothing else.
        span = "Upgrade Sequence to 9.1\nWhat's New\nBill of Materials\n" + "x" * 900
        at = vcf_fetch.next_heading(span, "What's New", len("Upgrade Sequence to 9.1"))
        assert at < 0 or at >= vcf_fetch.MIN_KEEP

    def test_a_real_boundary_is_still_honoured(self):
        span = "Section One\n" + "prose " * 100 + "\nSection Two\nmore prose"
        at = vcf_fetch.next_heading(span, "Section Two", len("Section One"))
        assert at > vcf_fetch.MIN_KEEP
        assert span[:at].startswith("Section One")
        assert "Section Two" not in span[:at]

    def test_a_missing_next_title_does_not_cut(self):
        span = "Section One\n" + "prose " * 100
        assert vcf_fetch.next_heading(span, "Nowhere", 0) < 0


class TestPageAttribution:
    """The bug that pointed citations at a page up to 390 pages away."""

    def test_a_short_span_keeps_its_page(self):
        parts = vcf_fetch.split_pages("a page of prose", 500)
        assert [p["page"] for p in parts] == [500]

    def test_an_oversized_span_advances_the_page(self):
        pages = ["z" * 4000 for _ in range(10)]
        parts = vcf_fetch.split_pages("\f".join(pages), 100)
        assert len(parts) > 1
        assert parts[0]["page"] == 100
        # Strictly increasing, and never past the pages actually in the span.
        numbers = [p["page"] for p in parts]
        assert numbers == sorted(numbers)
        assert len(set(numbers)) == len(numbers)
        assert max(numbers) <= 100 + len(pages)

    def test_form_feeds_do_not_survive(self):
        parts = vcf_fetch.split_pages("one\ftwo\fthree", 1)
        assert all("\f" not in p["text"] for p in parts)


class TestContentsParsing:
    def test_depth_comes_from_indentation_clusters(self):
        # Observed clusters in this document: 0, 3, 8-11, 13-18. The buckets sit
        # between the clusters because the generator positions by point size.
        assert vcf_fetch.depth_of(0) == 0
        assert vcf_fetch.depth_of(3) == 1
        assert vcf_fetch.depth_of(9) == 2
        assert vcf_fetch.depth_of(15) == 3

    def test_dot_leaders_are_parsed(self):
        toc = "Release Notes.......79\n   Upgrade Sequence to 9.1......79\n"
        entries = vcf_fetch.parse_toc(toc, 79)
        assert [e["title"] for e in entries] == [
            "Release Notes", "Upgrade Sequence to 9.1"]
        assert entries[0]["depth"] < entries[1]["depth"]

    def test_contents_entries_pointing_into_the_contents_are_dropped(self):
        assert vcf_fetch.parse_toc("Contents.......2\n", 79) == []

    def test_running_furniture_is_stripped(self):
        page = "VMware Cloud Foundation 9.1\n\nReal prose here.\n\nVMware by Broadcom\n\n4821\n"
        cleaned = vcf_fetch.clean(page)
        assert cleaned == "Real prose here."


@needs_corpus
class TestTheBuiltCorpus:
    def test_the_section_that_used_to_vanish_is_present(self, records):
        assert any("Upgrade Sequence" in r["section"] for r in records)

    def test_every_citation_is_inside_the_document(self, records):
        assert max(page_of(r) for r in records) <= 8894

    def test_pages_never_go_backwards(self, records):
        pages = [page_of(r) for r in records]
        assert pages == sorted(pages)

    def test_no_section_is_large_enough_to_lose_its_page(self, records):
        # An oversized span is what made a citation meaningless in the first
        # place, so the ceiling itself is the assertion.
        assert max(len(r["text"]) for r in records) <= vcf_fetch.MAX_SPAN

    def test_records_carry_a_breadcrumb_and_prose(self, records):
        assert all(r["chapter_name"] for r in records)
        assert all(len(r["text"]) >= 40 for r in records)

    def test_running_furniture_is_essentially_gone(self, records):
        # Not zero: a handful of pages set the footer differently and are not
        # worth a special case. This asserts the sweep worked, not that it was
        # perfect.
        left = sum(1 for r in records if "VMware by Broadcom" in r["text"])
        assert left < len(records) * 0.01


@needs_index
class TestRetrieval:
    """What the index actually returns, which is the only thing worth claiming.

    Each case names a section that must appear in the top k. These passed on
    this hardware; a model or chunk size change can break them, which is what
    they are for.
    """

    @pytest.fixture(scope="class")
    def search(self):
        import rag_embed
        from rag_store import Store

        store = Store(INDEX)
        state = store.get_meta("backend_state", {})
        model = rag_embed.restore(store.get_meta("backend", "bm25"), state)

        def run(question: str, k: int = 6):
            query = model.encode_query([question])[0]
            return store.search(query, k=k, per_section=2)
        yield run
        store.close()

    def test_most_chunks_fit_what_the_model_reads(self):
        # The silent truncation, measured across the index rather than at one
        # question. A chunk over the budget is embedded from its opening tokens
        # and scored as though that were the whole of it. Nothing reports it:
        # the tokeniser warns to stderr during indexing and the index builds.
        import random
        import sqlite3

        import rag_embed

        tokenizer = rag_embed.SentenceTransformer()._model.tokenizer
        rows = [r[0] for r in sqlite3.connect(INDEX).execute("select text from chunks")]
        random.seed(7)
        sample = random.sample(rows, min(500, len(rows)))
        over = sum(1 for t in sample
                   if len(tokenizer.encode(t, add_special_tokens=True)) > MODEL_TOKEN_BUDGET)
        assert over / len(sample) < MAX_OVERFLOWING, (
            f"{over}/{len(sample)} chunks exceed {MODEL_TOKEN_BUDGET} tokens; "
            "rebuild the index with a smaller --max-chars")

    @pytest.mark.parametrize("question,expected", [
        ("how do I decommission a workload domain?", "Delete a Workload Domain"),
        ("what are the requirements for vSAN ESA?", "Requirements for vSAN"),
        ("expand a VCF domain by adding a host", "Expand a VCF Domain"),
        ("how do I upgrade VMware Cloud Foundation to 9.1?", "Upgrade Sequence to 9.1"),
    ])
    def test_the_right_section_is_retrieved(self, search, question, expected):
        found = [c["citation"] for c in search(question)]
        assert any(expected in c for c in found), \
            f"{expected!r} missing from {found}"

    def test_every_result_carries_a_checkable_page(self, search):
        for chunk in search("how do I delete a vSphere cluster?"):
            assert "#page=" in chunk["url"]
            assert 1 <= int(chunk["url"].split("#page=")[1]) <= 8894

    def test_a_version_number_pulls_the_release_notes(self, search):
        # The other documented weakness, and the more surprising one. This PDF
        # carries release notes for 9.1 and for every 9.1.0.x patch, so a
        # question containing "VCF 9.1" scores against pages that are mostly
        # version strings. The upgrade guide does not appear until k=12, while
        # the same question without the version number retrieves it first.
        # Ask about the operation, not the release.
        found = [c["citation"] for c in search("what is the upgrade sequence to VCF 9.1?", k=8)]
        assert not any("Upgrade Sequence" in c for c in found)
        assert any(c.startswith("9.1.0.") or "Release Notes" in c for c in found)

    def test_the_known_vocabulary_gap_is_still_the_gap(self, search):
        # Documented rather than fixed: the section is called "Expand a VCF
        # Domain" and the embedding model does not bridge it from "add a host".
        # If this ever fails, the retrieval got better and the docs should say
        # so instead of warning about it.
        found = [c["citation"] for c in search("how do I add a host to a workload domain?")]
        assert not any("Expand a VCF Domain" in c for c in found)
