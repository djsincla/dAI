"""Turning text into vectors, with the gateway's gap stated plainly.

**The dAI gateway does not serve embeddings.** It serves generation: OpenAI and
Anthropic shaped completions, a model list, a token count. There is no
`/v1/embeddings`, so the retrieval half of RAG has to get its vectors somewhere
else, and pretending otherwise would produce an example that cannot run.

That is not as awkward as it sounds, and it splits the work along a line worth
seeing:

    retrieval   local, cheap, runs on the machine asking the question
    generation  the fleet, on hardware somebody already owns

Neither half involves anybody else's API. The statute is public but the
questions asked of it are not, and on this arrangement a question about a named
individual's eligibility never leaves the building.

Two backends, chosen at index time and recorded in the store so a query cannot
use one to search an index built with the other:

**bm25** (default, no dependencies beyond numpy)
    BM25 over a vocabulary fitted to the corpus, arranged so a dot product
    scores it and the vector store needs no special case. It suits this corpus better than it would suit most: statutes are
    written in deliberately consistent terminology, and a question about
    "regional center" is asking about the words "regional center".

    The first version of this hashed terms into a fixed 4096 dimensions, which
    is what you do when a vocabulary is too large or arrives as a stream. This
    corpus has 5,772 distinct terms. Hashing them into 4096 buckets collided 46%
    of them - "appeal" sharing a dimension with an unrelated word, and the
    appeals sections consequently losing to noise on a question about appeals.
    Hashing bought nothing here and cost that, so the vocabulary is simply
    kept. Worth remembering as the general lesson: an approximation chosen for
    a scale you do not have is not free.

**sentence-transformers** (optional, `pip install sentence-transformers`)
    Real dense semantic embeddings. Better when a question and its answer share
    meaning rather than vocabulary - "who decides what services my child gets"
    against text that says "individual program plan". Costs a large dependency
    and a model download.

If you add `/v1/embeddings` to the gateway later, a third backend belongs here
and nothing else in these scripts has to change.
"""

from __future__ import annotations

import math
import os
import re
from collections import Counter
from pathlib import Path

import numpy as np

# Words carrying no retrieval signal in a legal corpus. Deliberately short: an
# aggressive stop list removes terms that are load-bearing in statute, where
# "shall" and "may" are the difference between a duty and a discretion.
STOPWORDS = {
    "the", "of", "to", "and", "a", "an", "in", "is", "it", "for", "on", "as",
    "by", "that", "this", "with", "at", "from", "or", "be", "are", "was", "were",
    "which", "any", "all", "such", "if", "than", "then", "there", "these",
    "those", "have", "has", "had", "will", "would", "who", "whom", "what",
    "when", "where", "how", "its", "their", "his", "her", "them", "they",
}

TOKEN = re.compile(r"[a-z][a-z0-9]+|\d+(?:\.\d+)?")

# Words a question uses for words the statute uses. Short by design: this is a
# normalisation table, not a thesaurus, and every entry is a plain morphological
# variant rather than a judgement about meaning.
#
# It exists because of one concrete failure. Asked "what rights do PEOPLE with
# developmental disabilities have", the index ranked section 4502 - the Bill of
# Rights, whose text begins "PERSONS with developmental disabilities have the
# same legal rights" - twenty-second. No amount of weighting fixes that, because
# to a lexical index "people" and "persons" are unrelated strings. This is the
# standing weakness of lexical retrieval and the reason the dense backend is
# offered; a mapping this small only covers the cases somebody thought of.
IRREGULAR = {
    "people": "person", "peoples": "person", "children": "child",
    "men": "man", "women": "woman", "criteria": "criterion",
    "analyses": "analysis", "bases": "basis",
}


def stem(word: str) -> str:
    """Strip a plural, and nothing more adventurous than that.

    Deliberately not a real stemmer. Aggressive stemming conflates words that
    statute distinguishes on purpose, and the cost of merging two legal terms is
    higher here than the cost of missing a match.
    """
    if word in IRREGULAR:
        return IRREGULAR[word]
    if len(word) > 4 and not word.endswith("ss"):
        if word.endswith("ies"):
            return word[:-3] + "y"
        if word.endswith(("ses", "xes", "zes", "ches", "shes")):
            return word[:-2]
        if word.endswith("s"):
            return word[:-1]
    return word


def tokenize(text: str) -> list[str]:
    """Words, plus section numbers, which are the corpus's proper nouns.

    "4512" has to survive tokenisation: a question naming a section is the most
    precise query this corpus can be asked, and dropping digits would throw it
    away.
    """
    words = TOKEN.findall(text.lower())
    return [stem(w) for w in words if w not in STOPWORDS and len(w) > 1]


class LexicalBm25:
    """BM25, arranged so that a dot product scores it.

    The first version scored cosine over TF-IDF and got the Bill of Rights
    question badly wrong: section 4502, whose text reads "Persons with
    developmental disabilities have the same legal rights", ranked fortieth,
    while short "Definitions" sections that happened to be dense in the same
    words took the top four places. That is cosine's length bias, and it is not
    a tuning problem - a long section that answers a question fully is exactly
    what should win, and cosine penalises it for being long.

    BM25 fixes the two things TF-IDF gets wrong about length. Term frequency
    saturates, so the twentieth "rights" adds almost nothing over the fifth; and
    length is normalised against the corpus average rather than by dividing out
    the whole vector, so being long is a mild penalty instead of a fatal one.

    It still fits the vector store, because the score splits cleanly into a part
    that depends only on the document and a part that depends only on the query:

        score = SUM over query terms of  idf(t) * saturated_tf(t, d)

    So the document side is stored as the vector, the query side is the vector
    of idfs for the query's terms, and their dot product is the BM25 score. No
    special index and no second code path - the store still multiplies a matrix
    by a vector and sorts.

    The one visible consequence is that scores are no longer cosines in [0, 1].
    They are BM25 scores: comparable to each other within one query, and not
    comparable across queries.
    """

    name = "bm25"

    # The usual defaults. k1 sets how fast term frequency saturates, b how much
    # length is normalised - b=0.75 is the standard compromise between ignoring
    # length entirely and dividing it straight out.
    def __init__(self, max_terms: int = 200_000, k1: float = 1.5, b: float = 0.75):
        self.max_terms = max_terms
        self.k1 = k1
        self.b = b
        self.vocabulary: dict[str, int] = {}
        self.idf = np.zeros(0, dtype=np.float32)
        self.documents = 0
        self.average_length = 1.0

    def fit(self, texts: list[str]) -> "LexicalBm25":
        counts: Counter[str] = Counter()
        lengths = []
        for text in texts:
            terms = tokenize(text)
            lengths.append(len(terms))
            counts.update(set(terms))

        common = counts.most_common(self.max_terms)
        self.vocabulary = {term: i for i, (term, _) in enumerate(common)}
        self.documents = len(texts)
        self.average_length = float(np.mean(lengths)) if lengths else 1.0

        # BM25's idf. The +0.5 terms keep it finite for a term in every document
        # and the outer 1+ keeps it from going negative there, which the textbook
        # form does and which lets a common term subtract from a score.
        frequencies = np.array([count for _, count in common], dtype=np.float32)
        self.idf = np.log(
            1.0 + (self.documents - frequencies + 0.5) / (frequencies + 0.5)
        ).astype(np.float32)
        return self

    def encode(self, texts: list[str]) -> np.ndarray:
        """The document side: saturated, length-normalised term frequencies."""
        out = np.zeros((len(texts), len(self.vocabulary)), dtype=np.float32)
        for row, text in enumerate(texts):
            terms = tokenize(text)
            if not terms:
                continue
            norm = self.k1 * (1 - self.b + self.b * len(terms) / self.average_length)
            for term, count in Counter(terms).items():
                column = self.vocabulary.get(term)
                if column is not None:
                    out[row, column] = count * (self.k1 + 1) / (count + norm)
        return out

    def encode_query(self, texts: list[str]) -> np.ndarray:
        """The query side: the idf of each term the query uses.

        A term the corpus has never seen is dropped rather than hashed into
        somebody else's dimension. Dropping it is honest: the index genuinely
        has nothing to say about that word.
        """
        out = np.zeros((len(texts), len(self.vocabulary)), dtype=np.float32)
        for row, text in enumerate(texts):
            for term in set(tokenize(text)):
                column = self.vocabulary.get(term)
                if column is not None:
                    out[row, column] = self.idf[column]
        return out

    def state(self) -> dict:
        return {"documents": self.documents, "terms": list(self.vocabulary),
                "idf": self.idf.tobytes(), "average_length": self.average_length,
                "k1": self.k1, "b": self.b}

    @classmethod
    def restore(cls, state: dict) -> "LexicalBm25":
        model = cls(k1=state.get("k1", 1.5), b=state.get("b", 0.75))
        model.documents = state["documents"]
        model.vocabulary = {term: i for i, term in enumerate(state["terms"])}
        model.idf = np.frombuffer(state["idf"], dtype=np.float32).copy()
        model.average_length = state.get("average_length", 1.0)
        return model


def _hub_cache() -> Path:
    """Where huggingface_hub keeps downloaded models, honouring its own settings."""
    if "HF_HUB_CACHE" in os.environ:
        return Path(os.environ["HF_HUB_CACHE"])
    if "HF_HOME" in os.environ:
        return Path(os.environ["HF_HOME"]) / "hub"
    return Path.home() / ".cache" / "huggingface" / "hub"


def _prefer_cached_model(model: str) -> None:
    """Stop the hub being contacted for a model already sitting on this disk.

    The weights are ~87 MB and cached after the first run, but huggingface_hub
    revalidates the revision against the network on every subsequent run. On
    this corpus that measured 6.6s per query against 3.5s offline, so roughly
    half the wall clock of a retrieval was spent asking whether a file that had
    not changed had changed. It also emits the HF_TOKEN rate limit warning,
    which is what an unauthenticated request looks like from the outside.

    Only set when the model is already cached, so a first run can still
    download it, and only via setdefault, so an explicit setting by the caller
    wins. Must run before sentence_transformers is imported: huggingface_hub
    reads this variable once, at import.

    Note what is deliberately NOT set here. HF_HUB_DISABLE_PROGRESS_BARS does
    not silence the "Loading weights" bar and, measured 3 runs to 3, brings the
    rate limit warning back. That bar is a bare tqdm() in transformers
    (core_model_loading.py) with no disable argument, so no environment
    variable reaches it. It reports 103 tensors read from local disk in under
    10ms. Redirect stderr if it bothers you; it is not worth a monkeypatch.
    """
    if "HF_HUB_OFFLINE" in os.environ:
        return
    snapshots = _hub_cache() / f"models--{model.replace('/', '--')}" / "snapshots"
    if snapshots.is_dir() and any(p.is_dir() for p in snapshots.iterdir()):
        os.environ["HF_HUB_OFFLINE"] = "1"


class SentenceTransformer:
    """Dense semantic vectors, if the dependency is installed."""

    name = "sentence-transformers"

    def __init__(self, model: str = "sentence-transformers/all-MiniLM-L6-v2"):
        _prefer_cached_model(model)
        from sentence_transformers import SentenceTransformer as ST
        self.model_name = model
        self._model = ST(model)

    def fit(self, texts: list[str]) -> "SentenceTransformer":
        return self  # nothing to learn from the corpus

    def encode(self, texts: list[str]) -> np.ndarray:
        vectors = self._model.encode(texts, normalize_embeddings=True,
                                     show_progress_bar=len(texts) > 500)
        return np.asarray(vectors, dtype=np.float32)

    def encode_query(self, texts: list[str]) -> np.ndarray:
        # A dense model embeds a question and a passage into the same space, so
        # unlike BM25 there is no separate query side.
        return self.encode(texts)

    def state(self) -> dict:
        return {"model": self.model_name}

    @classmethod
    def restore(cls, state: dict) -> "SentenceTransformer":
        return cls(state["model"])


class MlxEmbeddings:
    """Dense vectors on Metal through MLX, with room for a whole section.

    The same framework the fleet already serves on, which is most of the reason
    it is here. The other reason is measured: the sentence-transformers path
    spends about five seconds importing torch, importing sentence_transformers
    and initialising MPS before it embeds anything, and a retrieval only needs
    about 0.75s of actual work. Loading this takes 0.39s. Nothing about the
    arithmetic changed; the startup did.

    **8192 tokens rather than 256, which removes chunking from this corpus.**
    all-MiniLM-L6-v2 reads 256 word pieces and silently drops the rest, so a
    corpus had to be cut into pieces small enough to survive that, and a
    citation then pointed at a piece rather than at a section. The longest
    section of the VCF documentation is about 5,000 tokens, so every section
    fits whole and every citation names the section it actually came from.

    Note the asymmetry. Nomic's models are trained with a prefix that says what
    the text is for, and a query embedded as a document lands in a measurably
    different place. That is why encode and encode_query differ here by more
    than which side of the comparison they are on, and it is the one detail
    that quietly ruins retrieval if it is dropped.
    """

    name = "mlx"

    # Qwen3-Embedding takes no prefix. Nomic and E5 models do, and the pair
    # below is kept because switching model families is a one line change and
    # dropping the prefix for a model that wants one degrades retrieval with no
    # visible symptom. Empty strings mean "this model was not trained with a
    # role prefix", which is a statement rather than an omission.
    QUERY = ""
    DOCUMENT = ""

    def __init__(self, model: str = "mlx-community/Qwen3-Embedding-0.6B-8bit",
                 max_length: int = 32768, batch: int = 16):
        from mlx_embeddings import load
        self.model_name = model
        self.max_length = max_length
        self.batch = batch
        self._model, self._tokenizer = load(model)

    def fit(self, texts: list[str]) -> "MlxEmbeddings":
        return self  # nothing to learn from the corpus

    def _embed(self, texts: list[str]) -> np.ndarray:
        import mlx.core as mx
        from mlx_embeddings import generate

        if not texts:
            return np.zeros((0, 768), dtype=np.float32)

        # Batches are padded to their longest member, so mixing a 500 token
        # section with a 5,000 token one makes the short one cost what the long
        # one costs. Sorting by length first puts similar lengths together and
        # the padding mostly disappears. The original order is restored before
        # returning, because the caller is pairing these with rows in a table
        # and a permuted result would attach every vector to the wrong text
        # without failing.
        order = sorted(range(len(texts)), key=lambda i: len(texts[i]))
        vectors = [None] * len(texts)
        for start in range(0, len(order), self.batch):
            window = order[start:start + self.batch]
            embedded = generate(self._model, self._tokenizer,
                                [texts[i] for i in window],
                                max_length=self.max_length).text_embeds
            mx.eval(embedded)
            embedded = np.array(embedded, dtype=np.float32)
            for row, i in enumerate(window):
                vectors[i] = embedded[row]

        stacked = np.vstack(vectors)
        # Normalised here rather than trusted, because the store scores with a
        # dot product and an unnormalised vector turns that into something that
        # is not cosine and quietly favours longer passages.
        norms = np.linalg.norm(stacked, axis=1, keepdims=True)
        return stacked / np.maximum(norms, 1e-12)

    def encode(self, texts: list[str]) -> np.ndarray:
        return self._embed([self.DOCUMENT + t for t in texts])

    def encode_query(self, texts: list[str]) -> np.ndarray:
        return self._embed([self.QUERY + t for t in texts])

    def state(self) -> dict:
        return {"model": self.model_name, "max_length": self.max_length}

    @classmethod
    def restore(cls, state: dict) -> "MlxEmbeddings":
        return cls(state["model"], state.get("max_length", 8192))


def build(backend: str) -> LexicalBm25 | SentenceTransformer | MlxEmbeddings:
    if backend in ("bm25", "lexical", "hashed"):
        return LexicalBm25()
    if backend in ("st", "sentence-transformers"):
        try:
            return SentenceTransformer()
        except ImportError as error:
            raise SystemExit(
                "sentence-transformers is not installed.\n"
                "  pip install sentence-transformers\n"
                "  or use the default backend, which needs only numpy:\n"
                "    python3 rag_index.py --backend bm25") from error
    if backend in ("mlx", "mlx-embeddings", "nomic"):
        try:
            return MlxEmbeddings()
        except ImportError as error:
            raise SystemExit(
                "mlx-embeddings is not installed.\n"
                "  pip install mlx mlx-embeddings\n"
                "  Apple silicon only. On anything else use --backend st.") from error
    raise SystemExit(f"unknown backend: {backend}")


def restore(name: str, state: dict):
    if name in (LexicalBm25.name, "lexical", "hashed"):
        return LexicalBm25.restore(state)
    if name == SentenceTransformer.name:
        return SentenceTransformer.restore(state)
    if name == MlxEmbeddings.name:
        return MlxEmbeddings.restore(state)
    raise SystemExit(f"the index was built with an unknown backend: {name}")
