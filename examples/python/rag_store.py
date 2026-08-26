"""The vector store: one SQLite file holding chunks, metadata and vectors.

SQLite rather than a vector database service, for the same reason the rest of
this stack is what it is. A dependency that runs as a server is a thing to
deploy, secure and keep alive, and at this size it buys nothing: a few thousand
chunks compared by cosine is one matrix multiply, and numpy does it in
milliseconds. The whole index is a single file you can copy, diff or delete.

Brute force search is honest at this scale and stops being so somewhere in the
high hundreds of thousands of chunks. At that point the shape here is the shape
you would keep - chunks, metadata, vectors, a query vector - with an index in
front of the last step.
"""

from __future__ import annotations

import json
import re
import sqlite3

import numpy as np

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS chunks (
    id        INTEGER PRIMARY KEY,
    citation  TEXT NOT NULL,
    section   TEXT NOT NULL,
    division  TEXT,
    chapter   TEXT,
    chapter_name TEXT,
    url       TEXT NOT NULL,
    part      INTEGER NOT NULL DEFAULT 0,
    parts     INTEGER NOT NULL DEFAULT 1,
    text      TEXT NOT NULL,
    vector    BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS chunks_section ON chunks(section);
"""

# The lexical half of hybrid retrieval, kept out of SCHEMA because it is built
# on demand rather than at every open.
#
# `content='chunks'` makes this an external content index: FTS5 stores the
# inverted index and reads the text from the chunks table, so nothing is
# duplicated. That is also what makes it retrofittable. An index built before
# this existed already holds the text, so the lexical side can be added to it in
# seconds without re-embedding anything, which matters when embedding the corpus
# took fifteen minutes.
#
# This is the storage that made a dense BM25 backend impossible here. Fitting
# BM25 the way rag_embed does it stores one dense row per chunk across the whole
# vocabulary, which for this corpus is gigabytes. An inverted index stores each
# term once with the list of chunks containing it, which is what a lexical index
# is supposed to be.
LEXICAL_SCHEMA = """
CREATE VIRTUAL TABLE IF NOT EXISTS lexical
    USING fts5(text, content='chunks', content_rowid='id', tokenize='porter unicode61');
"""

# FTS5 reads its query as an expression language, where a bare question mark,
# quote or the word NEAR is syntax rather than text. A natural question is not
# that, so terms are extracted and quoted individually and joined with OR.
FTS_TERM = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")

# Question words carry no lexical signal and do enormous damage here, because
# the terms are joined with OR: every chunk containing "what" or "is" enters the
# candidate set, and BM25 then ranks a corpus-wide match list rather than the
# handful of chunks that mention what was actually asked about.
#
# Measured on this corpus before the filter existed: "what is SDDC Manager?"
# fused to three patch release notes, displacing "SDDC Manager Detailed Design"
# and "OpenAPI for SDDC Manager" that dense retrieval had found on its own.
# Hybrid retrieval was making the answer worse, which is the outcome worth
# guarding against, since adding a second retriever feels like it can only help.
STOPWORDS = {
    "a", "all", "an", "and", "any", "are", "as", "at", "be", "by", "can", "do",
    "does", "for", "from", "had", "has", "have", "her", "his", "how", "i", "if",
    "in", "is", "it", "its", "me", "my", "of", "on", "or", "our", "should",
    "such", "than", "that", "the", "their", "them", "then", "there", "these",
    "they", "this", "those", "to", "was", "were", "what", "when", "where",
    "which", "who", "whom", "will", "with", "would", "you", "your",
}


def lexical_terms(question: str) -> list[str]:
    """The words worth matching literally, which is not most of them."""
    return [t for t in FTS_TERM.findall(question.lower())
            if t not in STOPWORDS and len(t) > 1]


class Store:
    def __init__(self, path: str):
        self.path = path
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)

    # ------------------------------------------------------------- writing

    def reset(self) -> None:
        self.db.execute("DELETE FROM chunks")
        self.db.execute("DELETE FROM meta")
        # Including the flag that says the inverted index matches the chunks,
        # which it no longer does.
        self.db.execute("DROP TABLE IF EXISTS lexical")
        self.db.commit()

    def set_meta(self, key: str, value) -> None:
        self.db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)",
                        (key, json.dumps(value)))
        self.db.commit()

    def add(self, rows: list[dict], vectors: np.ndarray) -> None:
        self.db.executemany(
            "INSERT INTO chunks(citation, section, division, chapter, chapter_name, url, part, parts, text, vector)"
            " VALUES (:citation, :section, :division, :chapter, :chapter_name, :url, :part, :parts, :text, :vector)",
            [{**row, "vector": vectors[i].astype(np.float32).tobytes()}
             for i, row in enumerate(rows)])
        self.db.commit()

    # ------------------------------------------------------------- reading

    def get_meta(self, key: str, default=None):
        row = self.db.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return json.loads(row["value"]) if row else default

    def count(self) -> int:
        return self.db.execute("SELECT COUNT(*) AS n FROM chunks").fetchone()["n"]

    def matrix(self) -> tuple[np.ndarray, list[sqlite3.Row]]:
        """Every vector as one array, with the rows in the same order."""
        rows = self.db.execute(
            "SELECT id, citation, section, division, chapter, chapter_name, url, part, parts, text, vector"
            " FROM chunks ORDER BY id").fetchall()
        if not rows:
            return np.zeros((0, 0), dtype=np.float32), []
        vectors = np.vstack([np.frombuffer(r["vector"], dtype=np.float32) for r in rows])
        return vectors, rows

    def search(self, query: np.ndarray, k: int = 6,
               per_section: int = 2) -> list[dict]:
        """The k nearest chunks, with a cap on how many come from one section.

        The cap matters. The longest section in this corpus is thirty thousand
        characters and becomes twenty-odd chunks, all of them about the same
        subject; without a limit a single verbose section wins every slot and
        the answer is grounded in one place when it should be grounded in
        several. Retrieval quality here is mostly this rule, not the metric.
        """
        vectors, rows = self.matrix()
        if len(rows) == 0:
            return []

        scores = vectors @ query.astype(np.float32)
        seen: dict[str, int] = {}
        out: list[dict] = []
        for index in np.argsort(-scores):
            row = rows[int(index)]
            section = row["section"]
            if seen.get(section, 0) >= per_section:
                continue
            seen[section] = seen.get(section, 0) + 1
            out.append({**dict(row), "score": float(scores[index])})
            out[-1].pop("vector", None)
            if len(out) >= k:
                break
        return out

    # ------------------------------------------------------------- lexical

    def ensure_lexical(self) -> int:
        """Build the inverted index if it is absent or empty. Returns its size.

        Cheap and idempotent: the text is already in the chunks table, so this
        is FTS5 reading what is there rather than anything being recomputed.
        """
        self.db.executescript(LEXICAL_SCHEMA)

        # Recorded in meta rather than measured from the table. `SELECT
        # COUNT(*) FROM lexical` reads the *content* table on an external
        # content index, so it answers 4,323 for an index that has never been
        # populated, and the rebuild it was guarding never ran. Every lexical
        # search then returned nothing, quietly, and hybrid retrieval silently
        # degraded to dense retrieval with extra steps.
        if not self.get_meta("lexical_built", False) and self.count() > 0:
            self.db.execute("INSERT INTO lexical(lexical) VALUES('rebuild')")
            self.db.commit()
            self.set_meta("lexical_built", True)
        return self.count()

    def search_lexical(self, question: str, k: int = 30) -> list[sqlite3.Row]:
        """Chunks matching the question's words, best first.

        FTS5's bm25() returns a negative number where more negative is a better
        match, so ordering is ascending and the sign is left alone. It is not
        turned into a similarity: the whole point of fusing by rank is that
        these scores never have to be made comparable to a cosine.
        """
        terms = lexical_terms(question)
        if not terms:
            return []
        match = " OR ".join(f'"{t}"' for t in terms)
        return self.db.execute(
            "SELECT c.*, bm25(lexical) AS lex FROM lexical"
            " JOIN chunks c ON c.id = lexical.rowid"
            " WHERE lexical MATCH ? ORDER BY lex LIMIT ?", (match, k)).fetchall()

    def search_hybrid(self, query: np.ndarray, question: str, k: int = 6,
                      per_section: int = 2, depth: int = 40,
                      rrf_k: int = 60, lexical_weight: float = 0.25) -> list[dict]:
        """Dense and lexical results fused by reciprocal rank.

        Fused on rank, not on score. A cosine sits in [-1, 1] and a BM25 score
        is unbounded and corpus-dependent, so any attempt to add them needs a
        normalisation that is arbitrary and that shifts whenever the corpus
        changes. Reciprocal rank fusion never looks at either score: a chunk
        scores 1/(rrf_k + rank) in each list it appears in, and the sum ranks
        it. A chunk both halves like beats one that either half loves, which is
        the behaviour worth having, since the two halves fail in different ways.

        rrf_k = 60 is the value from the paper this comes from, and it is a
        flattener: it keeps rank 1 from dominating rank 3 so completely that
        appearing in both lists cannot outweigh it.

        **lexical_weight is 0.25 and not 1.0, which was measured rather than
        chosen.** Fusing the two halves equally made retrieval worse on this
        corpus, and it is worth understanding why before copying this elsewhere.
        These are 8,894 pages of product documentation in which the same terms
        recur everywhere, so a lexical match on "workload domain" hits hundreds
        of sections and BM25 then favours short ones dense in those words, which
        are usually not the ones that answer the question. Across nine questions
        with a known right answer:

            weight 0.0 (dense only)   8/9
            weight 0.25               9/9
            weight 0.5                8/9
            weight 1.0                8/9

        The two questions that move explain the shape. "VCF-VSAN-ESA-RCMD-CFG-0"
        is an exact identifier that dense retrieval misses entirely and any
        lexical weight recovers. "what are the requirements for vSAN ESA?" is
        prose that dense gets right and a weight of 0.5 or more loses, because
        lexical noise displaces it. A small weight buys the first without paying
        the second.

        Nine questions is a thin sample and the numbers should not be read as
        precise. The mechanism is the part worth trusting: lexical retrieval is
        good at rare exact strings and bad at common vocabulary, so it should be
        able to rescue a result the dense half missed without being able to
        outvote it.
        """
        vectors, rows = self.matrix()
        if len(rows) == 0:
            return []

        scores = vectors @ query.astype(np.float32)
        dense = [int(i) for i in np.argsort(-scores)[:depth]]
        by_id = {int(rows[i]["id"]): rows[i] for i in dense}

        fused: dict[int, float] = {}
        origin: dict[int, list[str]] = {}
        for rank, index in enumerate(dense):
            rid = int(rows[index]["id"])
            fused[rid] = fused.get(rid, 0.0) + 1.0 / (rrf_k + rank + 1)
            origin.setdefault(rid, []).append("dense")

        for rank, row in enumerate(self.search_lexical(question, depth)):
            rid = int(row["id"])
            by_id.setdefault(rid, row)
            fused[rid] = fused.get(rid, 0.0) + lexical_weight / (rrf_k + rank + 1)
            origin.setdefault(rid, []).append("lexical")

        dense_score = {int(rows[i]["id"]): float(scores[i]) for i in dense}
        seen: dict[str, int] = {}
        out: list[dict] = []
        for rid in sorted(fused, key=lambda r: -fused[r]):
            row = by_id[rid]
            section = row["section"]
            if seen.get(section, 0) >= per_section:
                continue
            seen[section] = seen.get(section, 0) + 1
            out.append({**dict(row), "score": dense_score.get(rid, 0.0),
                        "fused": fused[rid], "found_by": "+".join(origin[rid])})
            out[-1].pop("vector", None)
            if len(out) >= k:
                break
        return out

    def close(self) -> None:
        self.db.close()
