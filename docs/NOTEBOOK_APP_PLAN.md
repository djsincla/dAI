# Plan: notebookMLX

A document based macOS app for the retrieval experiments. Drop text, PDF, CSV
and Excel into a notebook; they are extracted, chunked and embedded; ask
questions and get answers with citations you can open.

## What it is, and what that decides

**A notebook is a document the user owns.** A file that can be moved, renamed,
put in iCloud, sent to somebody, and opened without asking a server for
permission. That is the decision everything else follows from, and it is the
opposite of the assumption in `NOTEBOOKS_PLAN.md`, which put notebooks in the
control plane. That document is superseded for notebooks; what survives from it
is the retrieval arithmetic and the honest note about tables.

The consequences are worth stating plainly rather than discovering:

- **The control plane is a service, not the owner.** It answers `/v1/embeddings`
  and `/v1/messages`. It does not know what notebooks exist and does not need to.
- **The app works offline for everything except answering.** Extraction and
  chunking are local. Embedding can be local. Only generation needs the fleet,
  and only when a question is asked.
- **The web UI does not get notebooks.** A browser cannot own a file this way,
  and pretending otherwise would produce two incompatible notions of a notebook.
  The fleet view stays what it is.

## The file format is the contract

A notebook is a **package** (a directory the Finder presents as one file):

    Statutes.dainotebook/
      notebook.json        name, embedding model, chunk settings, created
      index.sqlite         chunks, metadata, vectors: rag_store.py's schema
      originals/           the dropped files, byte for byte
      extracted/           the text each original produced

**`index.sqlite` is deliberately the schema `examples/python/rag_store.py`
already uses**, so `rag_ask.py --index Statutes.dainotebook/index.sqlite` works
with no new code. The format is the shared contract rather than the API, which
is a stronger guarantee: two implementations agreeing on a file cannot drift
the way two implementations agreeing on a protocol can.

### What is precious and what is derived

The package holds two kinds of thing, and treating them the same would be a
mistake:

    precious   originals/      what was dropped in, unrecoverable if lost
               conversation    the interaction, which is the work
    derived    extracted/      rebuildable from originals in seconds
               index.sqlite    rebuildable in minutes

**The sources are the ground; the conversation is the document.** Inputs are
processed once into chunks and vectors, and from then on the file is a thread
of questions and answers about them. That is what is worth keeping, syncing,
and versioning.

The derived half is a cache with a long rebuild time. Naming it as such buys
several things: a corrupt index can be discarded rather than mourned, a
notebook can be shipped without its vectors and rebuilt on arrival, and
changing the embedding model or the chunk size is a rebuild rather than a
migration. It also means the honest answer to "how big is a notebook" is the
size of the originals plus a conversation, which is small.

**Keeping the originals is the point of a document.** The browser plan could not
re-chunk without the file being dropped again, and chunk size is the parameter
most worth sweeping. Here the original is in the package, so re-chunking is a
menu item. It costs disk, and disk is cheap next to an afternoon.

## Inputs, and the split that matters

**Prose: text, markdown, PDF.** Chunk by structure where there is one and by
size where there is not. PDFKit for extraction, which also gives page numbers,
so a citation can open the PDF at the page rather than quoting a fragment.

**Tabular: CSV, Excel.** A different problem, and worth being blunt about:
**retrieval over tables answers lookup well and aggregation wrongly.** "Which
rows mention Auckland" is a retrieval question. "What was the Q3 total" is a
query question, and a vector index will answer it confidently and incorrectly
because the nearest chunk always looks plausible.

So:

- **One row per chunk**, rendered as `Region: Auckland; Units: 42; Date:
  2026-03-01`. That is the shape an embedding model was trained on, and it
  embeds far better than a slab of comma separated values.
- **The header travels with every chunk.** `Auckland, 42, 2026-03-01` is noise
  without column names, and a chunk that has lost them cannot be recovered.
- **The parsed rows are kept in the package**, not only their text. That is what
  makes correct aggregation possible later, by arithmetic rather than by
  retrieval. Storing them costs almost nothing; recovering them from embedded
  text is impossible.
- **The app says so.** A question that looks like aggregation over a table gets
  a stated limitation rather than a confident number. This is the same rule as
  refusing to truncate an over-length input: the failure is invisible in the
  output, so it has to be caught before it becomes output.

`.xlsx` is a zip of XML. `CoreXLSX` (SPM, MIT) reads it without shelling out.
Decisions it forces, named now: multiple sheets become multiple documents; a
formula cell contributes its cached value, not its formula; merged cells repeat
their value across the span; and a sheet with no header row is refused rather
than guessed at, because guessing wrong poisons every chunk from it.

## Embedding: local, fleet, or both

Both, and they agree. `mlx-community/Qwen3-Embedding-0.6B-8bit` runs through
`MLXEmbedders` locally and through `/v1/embeddings` on the fleet, and the fleet
path has been verified against the reference client at 0.9998 cosine with the
ranking reproduced exactly.

- **Local** is the default: no network, no queue, and a laptop embeds a few
  thousand chunks in minutes.
- **Fleet** is for a corpus worth fanning out, and is the only path that scales
  past one machine.
- **The notebook records which model produced its vectors**, and refuses to mix.
  Two models means two spaces; a notebook that quietly contains both returns
  plausible nonsense, which is the failure this whole area keeps producing.

Switching a notebook's model re-embeds everything, from the originals, which is
possible only because they were kept.

## The interaction is a conversation, not a query box

Claude shaped: a thread of turns, each one retrieving from the notebook and
asking the fleet, with citations attached to the answer. The conversation lives
in the notebook package, so reopening a file reopens the thread.

Two properties of this fleet shape the design, and both are easy to get wrong.

### There is no streaming, by design

`POST /v1/chat/completions` refuses `stream`: *"a completion is dispatched to a
node as one unit so that a yield has a bounded worst case"*. That is preemption
working as intended, not a gap. A harvested machine must be returnable to its
owner within a bounded time, and a half streamed answer has no seam to stop at.

So the UI cannot fake a token stream, and should not try. What it can do:

- Show the retrieval **immediately**, because it is local and takes
  milliseconds. The citations appear while the answer is still being written,
  which is more informative than a blinking cursor and is genuinely true.
- Say which machine is answering and what its presence state is, from the `dai`
  block already in the response.
- Make waiting cancellable, and mean it: the gateway drops a dispatch whose
  caller has gone.

A several second wait with the sources already on screen reads better than a
spinner, and it does not lie about what is happening.

### Prompt layout decides whether the cache works

The fleet keys its prompt cache on **longest common prefix**, and the measured
difference is 34.6s cold against 0.8s warm. That makes message order a
performance decision rather than a stylistic one.

`examples/python` puts the retrieved documents in the system prompt, which is
right for one shot and wrong for a conversation: the retrieved chunks change
every turn, so the prefix changes every turn and every turn pays a cold
prefill.

**Retrieved context goes in the user turn, not the system prompt.**

    system     the instructions, fixed for the life of the notebook
    history    previous turns, append only
    user       this question, with its retrieved chunks

Now the stable prefix grows monotonically and every turn after the first hits
the cache. Putting the chunks first would produce a chat that gets slower and
more expensive exactly as a conversation becomes worth having.

This also means **re-retrieval per turn is affordable**, which matters: a
follow up question is often about something the previous retrieval did not
cover, and reusing the first turn's chunks would answer the wrong question
efficiently.

## Architecture

Modern Swift throughout, and the choices are deliberate rather than defaults:

- **SwiftUI with `@Observable`**, not `ObservableObject`. Observation is finer
  grained and the app has one long list that must not redraw on every chunk.
- **`DocumentGroup`** with a `FileDocument` package type, so the app is a proper
  document app: New, Open Recent, autosave, versions, and iCloud for free.
- **Structured concurrency, and an actor per pipeline.** Extraction, chunking
  and embedding are one `AsyncStream` per document with real back pressure. A
  8,894 page PDF must not load into memory to be chunked.
- **Cancellation that actually propagates.** Closing a notebook mid embed
  cancels the task tree; a cancelled document is left `pending` rather than
  half embedded, because half is indistinguishable from whole once it is
  vectors.
- **A typed API client checked against `openapi/dai.yaml`**, so a control plane
  change that breaks the app breaks the build rather than a Saturday.
- **SQLite through a thin actor**, not SwiftData. The schema is fixed by the
  contract above and SwiftData would own it.

## Accessibility and platform fit

Named here because it is the part that gets deferred and then never done:

- Full keyboard navigation, including the citation list and the drop zone.
- VoiceOver labels on citations that say the source and page, not "button".
- Drag and drop accepting the file promises Finder actually sends, not only
  file URLs, so dragging from Mail or Safari works.
- Dynamic Type respected in the answer and citation views.
- `.fileImporter` as well as drag and drop, since drag is not an accessible
  path for everybody.

## Verification

**Provable in unit tests**

- Chunking: prose by size and structure, tabular by row with the header carried.
- The CSV renderer, including a value containing a delimiter, a quoted newline,
  and a header with duplicate column names.
- `.xlsx`: multiple sheets, a formula cell, merged cells, and a refusal on a
  sheet with no header.
- The notebook refuses to mix embedding models.
- Cancellation leaves a document `pending`, never partially embedded.
- Local and fleet vectors agree, against the same fixture the agent uses.

**Needs a fleet or a corpus**

1. The VCF PDF as a notebook, reproducing `test_vcf.py`'s expectations.
2. A spreadsheet where the right row is retrieved and an aggregate question is
   refused rather than answered.
3. Fleet embedding of a corpus, measured against local.

## Risks

- **Three retrieval implementations now**: Python, the control plane, and this.
  The file format is what keeps them honest, which is why it is the contract
  rather than the API.
- **Tables will be the first thing that disappoints**, because people expect a
  spreadsheet to be queryable. The plan is to be honest early rather than
  clever later.
- **A document based app makes the fleet optional**, and an app that works
  offline is an app nobody runs the fleet for. That is fine for experiments and
  worth noticing before it becomes the product.
- Extraction quality is invisible once text. The chunk preview before embedding
  is the mitigation and is not a guarantee.

## Order

1. The package format and the SQLite store, with `rag_ask.py` opening one.
2. Extraction: text, PDF, CSV, xlsx, with the chunk preview.
3. Local embedding and query, offline end to end.
4. Fleet embedding and generation.
5. Citations, per document toggles, compare two settings side by side.

Step 1 first because it is the contract, and because a notebook that
`rag_ask.py` can read is a notebook whose retrieval can be checked against
everything already built.
