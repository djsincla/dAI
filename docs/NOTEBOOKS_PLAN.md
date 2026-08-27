# Plan: notebooks

A NotebookLM shaped surface for the retrieval experiments: make a notebook, drop
documents into it, they are chunked and embedded in the background, then ask
questions of them and get answers with citations.

Everything in `examples/python` becomes a client of this rather than a separate
implementation. That matters more than it sounds: there are currently two RAG
implementations in this repository that must agree about prefixes, pooling and
normalisation or an index built by one cannot be queried by the other, and the
only thing keeping them honest is a fixture and a command. A third would be a
third chance to disagree.

## What already exists

Most of it, which is why this is worth doing here rather than as another script.

    work_units          kind IN ('embed','generate','render'), payload and
                        result as jsonb, leased to nodes, preemptible, retried.
                        Background embedding is this table.
    attachment_blobs    content addressed by sha256, already used to get render
                        job files onto machines. Documents are these.
    jobs                the parent a set of units belongs to, with progress
                        the UI already renders.
    /v1/embeddings      vectors from the fleet, agreeing with the Python client
                        to within 0.0002 cosine.
    the reverse channel dispatch, presence gating, the group sockets.

## What does not

**No pgvector.** The database has `pgcrypto` and nothing else. Vectors are
stored as `bytea` and scored in Node, which is what `rag_store.py` already does
in Python: read the matrix, one dot product per chunk, sort. At 4,323 chunks of
1,024 dimensions that is 17 MB and a few milliseconds. It stops being honest
somewhere past a hundred thousand chunks per notebook, and the shape does not
change when it does: chunks, metadata, vectors, a query vector, with an index in
front of the last step.

Saying that plainly now is cheaper than discovering it later, and it is the same
call `rag_store.py` documents for the same reason.

## Extraction happens in the browser

PDF and HTML are turned into text client side, by `pdf.js` vendored beside
`rapidoc-min.js`, and only text is uploaded.

This was the interesting decision. Extraction on the control plane means poppler
as a system dependency and CPU work on the one machine that has to stay
responsive; extraction on the fleet means a Swift PDF path and a new work kind.
In the browser it costs a vendored library and nothing else, and **drag and drop
of a raw PDF still works**, which is the whole point of the feature.

It also means the browser holds the only copy of the original PDF. The blob we
store is the extracted text, so a notebook cannot re-chunk from the original
later without the file being dropped again. That is a real limitation and the
right trade at this size: the original is on somebody's disk, and storing 182 MB
of PDF to re-extract it is a cost with no reader.

## Schema

    notebooks
      id, name, embedding_model, chunk_chars, overlap, created_by, created_at

    notebook_documents
      id, notebook_id, sha256 -> attachment_blobs, title, media_type,
      chars, state ('pending'|'embedding'|'ready'|'failed'), error,
      enabled boolean default true, added_at

    notebook_chunks
      id, notebook_id, document_id, ordinal, text, tokens,
      vector bytea, tsv tsvector generated
      unique (document_id, ordinal)

    notebook_queries
      id, notebook_id, question, k, hybrid, answer, citations jsonb, asked_at

`enabled` on a document is the per-document toggle: a chunk from a disabled
document is skipped at query time rather than deleted, so turning it back on
costs nothing and re-embedding is never needed to answer "what does this look
like without that source".

`tsv` is a generated tsvector column. Postgres full text search is the lexical
half of hybrid retrieval, standing where FTS5 stands in the Python
implementation, and fused the same way.

## Retrieval

Identical arithmetic to `rag_store.py`, deliberately.

- Dense: dot product of unit length vectors, which is cosine.
- Lexical: `ts_rank` over the generated tsvector, with stop words removed by
  Postgres rather than by the hand written list the Python side needs.
- Hybrid: reciprocal rank fusion, `lexical_weight` default **0.25**, because
  1.0 measured worse on the VCF corpus: 8/9 questions right against 9/9. The
  number is carried across rather than re-derived, and the reasoning is in
  `rag_store.py`.
- `per_section` cap carried across too. Retrieval quality on a long document is
  mostly that rule rather than the metric.

## Background embedding

A document added to a notebook creates a job and one `embed` work unit per batch
of chunks. The UI watches unit states, which the jobs view already renders.

Three properties of embedding make this the easy case, and all three are already
in the table: no session or KV cache, so any node holding the model can take any
unit; a preempted unit costs a retry rather than a conversation; and units are
independent, so a notebook embeds across the whole fleet at once.

**This is the workload the harvest tier was designed for**, and the first one
that genuinely fans out. Generation is one machine per request; embedding a
corpus is not.

## API

    POST   /admin/v1/notebooks                    {name, embeddingModel?}
    GET    /admin/v1/notebooks
    GET    /admin/v1/notebooks/:id                notebook, documents, progress
    DELETE /admin/v1/notebooks/:id
    POST   /admin/v1/notebooks/:id/documents      {title, text, mediaType}
    DELETE /admin/v1/notebooks/:id/documents/:docId
    PUT    /admin/v1/notebooks/:id/documents/:docId/enabled   {enabled}
    POST   /admin/v1/notebooks/:id/query          {question, k?, hybrid?, model?}
    GET    /admin/v1/notebooks/:id/queries        saved queries and answers

Api first, so the Python examples can drop their local sqlite entirely and the
UI is one client rather than the only one.

## The UI

A fifth view in the existing sidebar, no build step and no framework, matching
`app.js` conventions: the `el()` helper, the `api()` wrapper, the same toast and
refresh machinery.

- **Notebook list**, with document count and embedding progress.
- **Drop zone** taking PDF, text, markdown and HTML. Extraction and chunk
  preview happen before upload, so a document that extracts badly is visible
  before it is embedded rather than after it answers badly.
- **Document list** with per-document enable toggles and state.
- **Ask**, with retrieval settings visible rather than buried: k, hybrid on or
  off, lexical weight. These are experiment controls and this is a tool for
  experiments.
- **Answer** with citations that open the chunk they came from, and the scores
  that produced the ranking.
- **Compare**, which runs one question at two settings side by side. This is the
  thing the scripts have been used for all day and the reason a UI is worth
  building: the interesting question is never "what is the answer", it is
  "what changed when I changed that".

## Verification

**Provable without the fleet**

- Chunking and the citation arithmetic, as pure functions.
- Reciprocal rank fusion against a known pair of lists, and that a disabled
  document contributes nothing.
- Every refusal: a notebook with no ready documents, a question with no terms, a
  document whose text is empty, a chunk longer than the model reads.
- That a notebook records its embedding model, and a query refuses when the
  notebook's model is not the one that would answer it. Two models means two
  spaces, and mixing them is the failure this whole area keeps producing.

**Needs the fleet**

1. A document embedded through `/v1/embeddings` and queried, giving the same
   ranking as `examples/python` gives for the same corpus.
2. The VCF corpus imported and `test_vcf.py`'s expectations reproduced through
   the API, which is the acceptance test that already exists.
3. Fan out: a notebook embedding across two machines, measured against one.

## Risks

- **Two implementations of retrieval is one too many, and this makes three
  until the Python side is cut over.** The plan is not finished when the UI
  works; it is finished when `rag_store.py` is a client.
- **A notebook silently mixing embedding models** would produce exactly the
  plausible wrong answers this repository keeps finding. The model is recorded
  on the notebook, not on the request, and changing it invalidates the chunks.
- Brute force scoring in Node is fine now and is a cliff later. The number to
  watch is chunks per notebook, and the answer when it arrives is an index, not
  a rewrite.
- Extraction quality is now the browser's problem, and a bad extraction is
  invisible once it is text. The chunk preview before upload is the mitigation
  and it is not a guarantee.

## Order

1. Schema and the API, with the pure functions tested.
2. Embedding through work units, watched in the existing jobs view.
3. The UI: list, drop, documents, ask.
4. Citations, toggles, compare.
5. Cut `examples/python` over to the API and delete its sqlite store.

Step 5 is the one that will be tempting to skip and is the reason to do any of
this in the control plane rather than in another script.
