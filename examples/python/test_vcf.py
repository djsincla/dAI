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
    python3.11 rag_index.py --backend mlx --max-chars 20000 --overlap 0 \\
                            --corpus corpus/vcf91.jsonl --index corpus/vcf91.db
"""

from __future__ import annotations

import json
import os

import pytest

import vcf_fetch

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus", "vcf91.jsonl")

# Overridable so the same suite can be pointed at an index built with a
# different backend, which is the only way to tell whether changing the
# embedding model helped or merely moved the failures around:
#
#   VCF_INDEX=corpus/vcf91-mlx.db python3.11 -m pytest test_vcf.py -v
INDEX = os.environ.get("VCF_INDEX") or os.path.join(HERE, "corpus", "vcf91.db")

# Some overflow is tolerated. Chunks overlap, so text past the limit still
# reaches the index through the neighbouring chunk; what is lost is that one
# vector's account of its own tail. Under all-MiniLM's 256 tokens this measured
# 15.4% at 1,400 characters and 5.8% at 600. Under the 8192 token MLX backend
# with whole sections it is 0%, which is the point of the larger context and
# the reason the tolerance is kept rather than tightened to zero: the number
# describes the model in use, not this corpus.
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


class TestLexicalTerms:
    """What the literal matcher is given, which is not the whole question."""

    def test_question_words_are_dropped(self):
        from rag_store import lexical_terms
        assert lexical_terms("what is SDDC Manager?") == ["sddc", "manager"]

    def test_an_identifier_survives_intact(self):
        from rag_store import lexical_terms
        assert "vcf-vsan-esa-rcmd-cfg-0" in lexical_terms("VCF-VSAN-ESA-RCMD-CFG-0")

    def test_a_question_of_nothing_but_stopwords_matches_nothing(self):
        # Better than matching everything, which is what an unfiltered OR of
        # these terms would do.
        from rag_store import lexical_terms
        assert lexical_terms("what is it for?") == []


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
        """The budget comes from the model the index records, not a constant.

        Hardcoding 256 would pass an all-MiniLM index and fail an 8192 token
        one for a reason that is not a defect. What is being asserted is the
        relationship - chunks fit the model that will read them - and that
        holds whichever model built the index.
        """
        # The silent truncation, measured across the index rather than at one
        # question. A chunk over the budget is embedded from its opening tokens
        # and scored as though that were the whole of it. Nothing reports it:
        # the tokeniser warns to stderr during indexing and the index builds.
        import random
        import sqlite3

        import rag_embed

        from rag_store import Store

        store = Store(INDEX)
        backend = store.get_meta("backend", "bm25")
        state = store.get_meta("backend_state", {})
        store.close()
        if backend == "bm25":
            pytest.skip("bm25 reads whole chunks; there is no budget to exceed")

        model = rag_embed.restore(backend, state)
        if backend == rag_embed.MlxEmbeddings.name:
            tokenizer = model._tokenizer._tokenizer
            budget = state.get("max_length", 8192)
        else:
            tokenizer = model._model.tokenizer
            budget = model._model.max_seq_length

        rows = [r[0] for r in sqlite3.connect(INDEX).execute("select text from chunks")]
        random.seed(7)
        sample = random.sample(rows, min(500, len(rows)))
        over = sum(1 for t in sample
                   if len(tokenizer.encode(t)) > budget)
        assert over / len(sample) < MAX_OVERFLOWING, (
            f"{over}/{len(sample)} chunks exceed {budget} tokens for {backend}; "
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

    def test_a_version_number_no_longer_pulls_only_release_notes(self, search):
        # This used to assert the failure. Under all-MiniLM a question
        # containing "VCF 9.1" scored against pages that are mostly version
        # strings, and the upgrade material did not appear until k=12. Whole
        # sections embedded by nomic carry enough surrounding context that the
        # version token stops dominating, so the assertion is inverted and now
        # protects the improvement.
        found = [c["citation"] for c in search("what is the upgrade sequence to VCF 9.1?", k=8)]
        assert any("Upgrad" in c for c in found), found

    def test_hybrid_recovers_an_exact_identifier_dense_misses(self):
        """The case hybrid retrieval exists for, and the only one it wins here.

        A design decision id is a rare exact string. The embedding model has no
        useful notion of where "VCF-VSAN-ESA-RCMD-CFG-0" belongs in its space,
        so dense retrieval returns whatever design blueprint is nearest and
        misses the vSAN material entirely. A literal matcher finds it in one
        lookup, which is exactly the failure mode the two halves have in
        opposite directions.
        """
        import rag_embed
        from rag_store import Store

        store = Store(INDEX)
        model = rag_embed.restore(store.get_meta("backend"),
                                  store.get_meta("backend_state"))
        store.ensure_lexical()
        q = "VCF-VSAN-ESA-RCMD-CFG-0"
        qv = model.encode_query([q])[0]
        dense = [c["citation"] for c in store.search(qv, k=6)]
        hybrid = [c["citation"] for c in store.search_hybrid(qv, q, k=6)]
        store.close()

        assert not any("vsan" in c.lower() for c in dense), dense
        assert any("vsan" in c.lower() for c in hybrid), hybrid

    def test_hybrid_does_not_cost_a_prose_question(self, search):
        """The regression that a heavier lexical weight causes.

        At lexical_weight 0.5 and above this question loses "Requirements for
        vSAN", which dense retrieval finds on its own: the literal matcher hits
        hundreds of sections containing these very ordinary words and displaces
        the right one. The default weight of 0.25 is what keeps both this and
        the identifier case above, and this test is what stops the weight being
        raised without noticing the cost.
        """
        import rag_embed
        from rag_store import Store

        store = Store(INDEX)
        model = rag_embed.restore(store.get_meta("backend"),
                                  store.get_meta("backend_state"))
        store.ensure_lexical()
        q = "what are the requirements for vSAN ESA?"
        qv = model.encode_query([q])[0]
        hybrid = [c["citation"] for c in store.search_hybrid(qv, q, k=6)]
        heavy = [c["citation"] for c in
                 store.search_hybrid(qv, q, k=6, lexical_weight=1.0)]
        store.close()

        assert any("Requirements for vSAN" in c for c in hybrid), hybrid
        # Stated as an observation rather than a requirement: if a future model
        # makes this pass at full weight, the default is worth revisiting.
        assert not any("Requirements for vSAN" in c for c in heavy), heavy

    def test_the_lexical_index_is_actually_populated(self):
        """The bug that made hybrid retrieval silently identical to dense.

        On an external content FTS5 index, COUNT(*) reads the content table, so
        an index that has never been built still answers with the full row
        count. Guarding the rebuild on that meant it never ran, every literal
        search returned nothing, and fusion quietly degraded to dense retrieval
        with extra steps and no error anywhere.
        """
        from rag_store import Store

        store = Store(INDEX)
        store.ensure_lexical()
        hits = store.search_lexical("workload domain", k=5)
        store.close()
        assert len(hits) > 0

    def test_the_vocabulary_gap_is_closed(self, search):
        # The section is called "Expand a VCF Domain" and the question says
        # "add a host". all-MiniLM never bridged that; nomic over whole
        # sections does, because the section body says what expanding a domain
        # involves even though its title does not. This was written as an
        # assertion that the gap persisted, and inverting it is the clearest
        # record that changing the embedding model is what closed it.
        found = [c["citation"] for c in search("how do I add a host to a workload domain?")]
        assert any("Expand a VCF Domain" in c for c in found), found
