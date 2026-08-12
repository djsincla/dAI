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

    def close(self) -> None:
        self.db.close()
