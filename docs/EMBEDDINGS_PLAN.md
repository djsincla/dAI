# Plan: making `/v1/embeddings` real

Companion to `EMBEDDINGS.md`, which explains why the endpoint returns 404 today
and should be read first. This is the plan to resolve it, and it revises that
document's dependency order on the strength of something already in the tree.

## What changed

`EMBEDDINGS.md` puts the work in this order, with the route last and smallest:

1. a real embedding model converted to Core ML
2. a tokenizer on the agent
3. `ANERuntime.run` returning a vector rather than `keys`
4. an interactive dispatch kind for embed
5. the route

Steps 1 to 3 were called "the work". They are the work **for the Core ML path**.
There is a second path that skips all three, and it is already vendored:

    agent/vendor/mlx-swift-examples/Libraries/Embedders/
        Bert.swift  NomicBert.swift  Qwen3.swift
        Pooling.swift  Tokenizer.swift  Load.swift  EmbeddingModel.swift

`MLXEmbedders` is a product of the package the agent already depends on, with 15
registered models including `nomic-ai/nomic-embed-text-v1.5`, the BGE family,
and `Qwen3-Embedding-0.6B`. It brings its own tokenizer and its own pooling. The
agent does not list it in `Package.swift`, and that is the only reason it is not
available.

So the honest revision is: **steps 1 to 3 are avoidable, not mandatory.** What
remains is a runtime that wraps an existing library, a dispatch kind, and a
route.

## The decision this forces, which is not a technical one

`PLAN.md` chose the ANE for embeddings deliberately, and the reason is the
premise of the whole product:

> Apple Silicon has unified memory ... Isolation must be policy-enforced, not
> hardware-enforced ... one artist noticing their machine got slow will kill the
> program.

`policy.ts:59` encodes that: `if (p.ane) kinds.push('embed')`, and ANE work is
permitted in every presence state. Embeddings are the one workload that can run
on a machine somebody is actively using, because the Neural Engine is not what
their desktop is contending for. That is a genuine product advantage and it is
worth more than a fast endpoint.

MLX embedding runs on the GPU. It contends with the artist exactly as generation
does, so it has to be presence-gated exactly as generation is.

**Both paths should exist, and the plan should not let the availability of the
easy one quietly cancel the valuable one.**

| | MLX (GPU) | Core ML (ANE) |
|---|---|---|
| effort | a runtime over a vendored library | conversion, tokenizer, runtime |
| presence | preemptible, gated like `generate` | runs while the machine is in use |
| models | 15 registered, including nomic v1.5 | whatever is converted, fixed sequence length |
| serves | `/v1/embeddings` correctly, now | the harvest thesis |

## Recommended sequencing

**Phase 1, MLX.** Make the endpoint real and correct. Embed becomes a GPU work
kind under normal presence gating. This unblocks every client, closes the
api-first gap, and produces vectors that are actually vectors.

**A thing the route taught, worth recording before the dispatch slice.** The
OpenAPI validator runs ahead of every handler, so a path absent from
`openapi/dai.yaml` is answered 404 before any code in the route is reached. The
first run of the route's tests failed that way and one of them passed for the
wrong reason: a test expecting 404 for an unknown model passed while the route
did not exist at all. The spec is not documentation here, it is the router.

**Phase 2, ANE.** Steps 1 to 3 of `EMBEDDINGS.md`, unchanged, as an additional
runtime for the same dispatch kind. The route, the registry and the tests from
phase 1 all still apply, so phase 2 becomes a runtime swap behind a stable
interface rather than a feature.

Phase 2 is where the interesting claim lives: embedding a corpus on machines
whose owners are using them. Phase 1 is what makes phase 2 testable, because it
gives a correct implementation to compare against. A hashed tensor cannot be
told from a good vector by looking at it, which is the argument `EMBEDDINGS.md`
makes for the 404, and it applies just as strongly to validating the ANE path.

## Design

### The route

`POST /v1/embeddings`, OpenAI shape, in `routes/serving.ts` beside the
completions handlers.

    request   {model, input: string | string[], encoding_format?: "float"}
    response  {object, model, data: [{object, index, embedding}], usage}

Rejections worth being specific about, because each is a failure a caller
otherwise discovers as bad retrieval rather than as an error:

- a model whose `kind` is not `embed`, refused rather than silently generated
- an input longer than the model's sequence length, refused with the limit and
  the measured length, never silently truncated
- an empty input array, refused rather than answered with `[]`
- a batch over a configured ceiling, refused with the ceiling

Truncation is the important one. Silently embedding the first 256 tokens of a
2,000 token passage produces a vector of the right shape, in the right range,
cosine-comparable, and wrong. That is the same class of defect the 404 exists to
prevent, and it is the defect that cost a quarter of every chunk in the VCF
example before it was measured.

### Dispatch

`embed` already exists as a `WorkKind` (`policy.ts:10`) and as a leased batch
kind. `/v1/embeddings` is synchronous, so it needs the reverse channel that
`/v1/messages` uses, with `embed` as a dispatch kind, exactly as
`EMBEDDINGS.md` step 4 says.

Two properties make embed easier to schedule than generate, and both should be
used rather than merely noted:

- **No KV cache and no session.** Nothing is warm, nothing is held, so any node
  with the model can take any request. `PromptCache` and the whole share
  negotiation are irrelevant here.
- **Preemption costs a retry, not a conversation.** A dropped embed request is
  re-runnable with no user-visible loss, which makes it the ideal harvest
  workload even on the GPU path.

### The model registry

`import.ts:102` already classifies `embed|bge|e5|gte|minilm` as `kind: 'embed'`.
Line 162 then forces `runtime: 'coreml'` for anything so classified. That is the
line encoding the assumption this plan revises, and it becomes a real choice:
`coreml` when an `.mlpackage` was staged, `mlx` when MLX weights were.

The classifier pattern needs `nomic|gte|qwen3-embedding|modernbert` added, and
`Qwen3-Embedding-0.6B` is a case worth checking by hand, since a name containing
`qwen3` currently reads as a generation model.

Embedding models are staged like any other model, under the constraint already
set: **only models on the machine's disk**. An embedding model is 100 to 600 MB
against 18 GB for a 30B, so staging is cheap, and there is a real argument for
staging one on every node by default rather than pinning it to a pool.

### The agent

A new `EmbedRuntime.swift` in `Sources/DaiWorker/`, beside `MLXRuntime.swift`
and `RenderRuntime.swift`, wrapping `MLXEmbedders.loadModelContainer` and its
`perform` closure. It needs to own three decisions the library leaves open:

- **Pooling strategy** comes from the model's own `PoolingConfiguration`, not a
  default chosen here. Mean against CLS pooling changes every vector.
- **Normalisation** is applied, and stated in the response, because the caller
  scores with a dot product and an unnormalised vector turns that into something
  that is not cosine and quietly favours longer passages.
- **The prefix convention.** Nomic and E5 models are trained with a prefix
  declaring what the text is for: `search_query:` against `search_document:`.
  A query embedded as a document lands somewhere measurably different, 0.80
  cosine rather than 1.0 for one string put through both. Since the API cannot
  guess, the request carries the intent.

  This said the server should apply the prefix the model's config declares, and
  **that was wrong**, found while building the runtime. Sentence-transformers
  records prefixes in `config_sentence_transformers.json` under `prompts`, and
  the MLX conversion of nomic's ModernBERT embedder ships `"prompts": {}` while
  still being a model that requires them: the conversion dropped them. A server
  trusting that config would apply no prefix to a model that needs one, with no
  error and nothing visible in the vector.

  So the convention is carried in the agent, keyed by model family, with the
  literals matched to `examples/python/rag_embed.py`. An index built by one and
  queried through the other is only comparable while both agree, which makes
  those two strings a compatibility surface rather than an implementation
  detail. The registry is the better long term home, since an operator staging
  a model knows what it wants; the agent default is what stops a staged model
  being silently wrong in the meantime.

That last point deserves a field. OpenAI's schema has nowhere to put it, so
`input_type: "query" | "document"` is a documented extension, defaulting to
`document`, and ignored by models that declare no prefixes.

### The catalogue bug, first and separately

`EMBEDDINGS.md` closes on it and it should be fixed before any of the above:
`/v1/models` and `/api/v0/models` advertise `ane:embed` as `type: "embeddings"`,
which invites the request that 404s. Either the endpoint exists or the model is
not listed. This is a small change and it is the only part of this plan that
makes things better on its own.

## Files

    control-plane/src/routes/serving.ts     the route, beside completions   DONE
    control-plane/openapi/dai.yaml          the schema                      DONE
    control-plane/src/lib/candidates.ts     embed as an interactive dispatch kind
    control-plane/src/lib/policy.ts         embed permitted for mlx runtime, presence gated
    control-plane/src/lib/import.ts         runtime by staged artifact, not by kind
    control-plane/test/api.test.ts          route behaviour and every refusal
    agent/Package.swift                     the MLXEmbedders product      DONE
    agent/Sources/DaiWorker/EmbedRuntime.swift      new                   DONE
    agent/Sources/DaiWorker/Worker.swift    dispatch embed to it
    agent/Tests/DaiAgentTests/EmbedRuntimeTests.swift   new               DONE

Progress: the agent half of phase 1 is in, 380 agent tests passing, plus a
`dai-agent verify-embed` command that checks agreement with the Python client.

Two findings from building it changed the model choice, and they are worth
recording because both were invisible until something was actually run.

**The two implementations support almost disjoint architectures.** Swift
MLXEmbedders registers bert, roberta, xlm-roberta, distilbert, nomic_bert and
qwen3. Python mlx-embeddings 0.1.0 has bert, modernbert and qwen3. So the
ModernBERT model the VCF index was built with cannot be loaded by the agent at
all, and nomic-embed-text-v1.5, which the agent can load, has no MLX conversion
and declares only 2,048 trained positions. `qwen3` is the only architecture both
sides support that also has room for a whole section, at 32,768. Both sides now
use `mlx-community/Qwen3-Embedding-0.6B-8bit`.

**MLX cannot run under `swift test`.** SwiftPM's command line cannot compile the
Metal shaders, which packaging/build-pkg.sh already says: it uses xcodebuild and
ships mlx-swift_Cmlx.bundle. A plain checkout fails with "Failed to load the
default metallib" before reaching any of this code, and the built debug binary
fails the same way. So the agreement check is a command rather than a test,
following verify-ane, and the guarded tests beside it skip everywhere SwiftPM
builds. A skip there is not evidence of anything; the command's verdict is.

**Verified.** Built with xcodebuild, run against staged weights:

    loaded mlx-community/Qwen3-Embedding-0.6B-8bit in 1.93s
      document  0.9998  Delete a Workload Domain
      document  0.9998  Requirements for Enabling vSAN
      document  1.0001  search and rescue of a lost hiker
      query     1.0001  how do I decommission a workload domain?
    ranking: 0.855 > 0.518 > 0.353
    VERDICT: agrees with the Python client (worst 0.9998).

The ranking matches Python's 0.855 / 0.519 / 0.353, so the two implementations
order the corpus the same way and not merely produce similar numbers. Cosines
slightly over 1.0 are the fixture's six decimal rounding, not a normalisation
fault.

It took two attempts, and the first one is the reason this check exists.
Pooling was wrong: MLXEmbedders reads `1_Pooling/config.json` and falls back to
`Strategy.none` when it is absent, the mlx-community conversions do not ship
that directory, and the library therefore returned unpooled hidden states. The
first run said "6 dimensions against the fixture's 1024", six being the token
count of the input. That was loud only because the shapes disagreed; with no
fixture to disagree with, something downstream takes the first row and gets a
plausible vector that is not the passage's.

So pooling is now chosen in `EmbedRuntime` by model family, like the prefixes,
and applied per row from each row's real token count. Qwen3-Embedding is causal
and its embedding is the last token's state; BERT-family encoders mean over the
sequence, and using one convention on the other model produces a working system
that retrieves badly. Pooling per row also keeps a vector independent of its
batch, since the library's `.last` takes the final position of a padded
sequence.

One delta from upstream: `EmbeddingModelOutput.hiddenStates` and `pooledOutput`
are made public in the vendored library, because pooling correctly requires
them and the library's own pooling cannot be trusted for these conversions.

## Verification

**Provable without the fleet**

- Every refusal above, as `api.test.ts` already shapes refusals.
- Pooling and normalisation as pure functions: a known input gives a known
  vector, and the vector is unit length.
- The prefix is applied when the config declares one and not when it does not,
  and query and document prefixes produce different vectors for one input. This
  is the assertion that catches the silent retrieval degradation.
- A too long input is refused rather than truncated, which is the defect this
  endpoint exists to avoid producing.

**Needs the fleet**

1. **Agreement with a known good implementation.** Embed the same 500 passages
   through the endpoint and through `examples/python` locally, and compare
   cosine similarities pairwise. Small numerical difference is expected;
   disagreement in *ranking* is a bug. Without this the endpoint can be
   confidently wrong, which is the whole argument of `EMBEDDINGS.md`.
2. **Retrieval end to end.** Rebuild the VCF index through the API and run
   `test_vcf.py` against it. The suite already asserts which sections must be
   retrieved, so it doubles as an acceptance test for the endpoint.
3. **Fan out.** The VCF corpus is 4,323 sections and takes about 15 minutes on
   one machine. Across the fleet it should scale close to linearly, since there
   is no shared state. That is the number that justifies the feature.
4. **Presence.** Confirm embed yields when the machine's owner returns, exactly
   as generate does. Phase 2 is the one that should not yield, and the contrast
   is the point.

## Risks

- **A correct looking wrong answer is the whole risk.** Every failure mode here
  produces a vector of the right shape. Truncation, wrong pooling, a missing
  prefix, an unnormalised vector: none of them raise, none of them log, and all
  of them surface as "the model gave a bad answer" a week later. The verification
  above is weighted accordingly, and comparison against a known good
  implementation is not optional.
- **Phase 1 could cancel phase 2 by accident.** A working endpoint removes the
  pressure that would otherwise fund the ANE path, and the ANE path is the one
  carrying the product argument. Worth stating in the phase 1 commit rather than
  discovering in six months.
- **Query-time embedding over the network may be slower than local.** Measured
  Wi-Fi round trip is 168ms against 0.02s for a warm local embed. Remote only
  wins because a cold Python process pays 0.4s to 5s of startup. Batch indexing
  is where the fleet clearly helps; query-time should stay a client choice, which
  also preserves the property that the question never leaves the machine.
- **`input_type` is an extension.** An OpenAI shaped client will not send it, so
  the default has to be the one that degrades least, and the response should say
  which prefix was applied rather than leaving it to be inferred.

## Scope note

Batch indexing is the case that justifies this. Query-time embedding already
works locally and is not the bottleneck. If the work has to be cut, cut
query-time optimisation and keep batch, since 15 minutes on one machine against
a fleet sitting idle is the argument that made the question worth asking.
