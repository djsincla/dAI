# Why there is no `/v1/embeddings`

`POST /v1/embeddings` returns 404. The fleet advertises a model called
`ane:embed`, lists it in the LM Studio-shaped catalogue as `type: "embeddings"`,
schedules `embed` work to it, and measures its throughput. None of that produces
an embedding.

## What `ane:embed` really is

From `ANERuntime.swift`, in its own words:

> This model is E5's synthetic load generator, whose input is 1x64x256x256

and

> Text is hashed into the input tensor as a stand-in until a real embedding model
> is converted; swapping that in changes only this method.

So:

- the input is an image-shaped tensor of 4.19 million floats, not a token
  sequence;
- the text of a work item is **hashed** into that tensor, and the model does not
  care what the contents are;
- `run(item:)` returns `keys`, not a vector.

It exists to measure what the Neural Engine can sustain without disturbing
somebody's desktop, which is a real question that E5 answered. It is a load
generator wearing an embedding model's name.

`MLXRuntime` has no embedding path either - the only matches for "embed" in it
are `max_position_embeddings`, which is a context-length field.

## Why the endpoint was not added

Adding a route over the current runtime is about twenty lines and would be worse
than the 404.

A caller cannot tell a meaningless embedding from a good one by looking at it.
Vectors of the right shape, in the right range, cosine-comparable, all present
and correct - and the ranking they produce is noise. A retrieval system built on
them returns confident, wrong answers with no error anywhere, and the failure
surfaces as "the model gave a bad answer" rather than "the index is hashed
garbage". A 404 is a bad developer experience. Silent nonsense is a bug that
costs somebody a week.

The examples in `examples/python` take the other route deliberately: retrieval
runs locally on the machine asking the question, generation runs on the fleet.
That split is honest today and stays useful afterwards, since it keeps the
question - which is the sensitive half - off the network entirely.

## What resolving it actually requires

In dependency order. The route is the last and smallest item.

1. **A real embedding model in Core ML.** `import.ts` already classifies
   anything matching `embed|bge|e5|gte|minilm` as `kind: 'embed'`, `runtime:
   'coreml'`, so the repository's design already expects this. Converting
   something like `bge-small-en-v1.5` to an `.mlpackage` with a fixed sequence
   length is the first real task.
2. **A tokenizer on the agent.** The current runtime takes bytes and hashes
   them. A real model needs its own tokenizer, its vocabulary shipped with the
   weights, and a decision about truncation, because a chunk longer than the
   sequence length has to be split or dropped and silently truncating changes
   what the vector means.
3. **`ANERuntime.run` returns a vector.** Today it returns `keys`. This is the
   part the existing comment promises is small, and it is - once 1 and 2 exist.
4. **An interactive dispatch kind for embed.** `embed` currently exists only as
   leased batch work. `/v1/embeddings` is a synchronous request, so it needs the
   reverse channel that `/v1/messages` uses, with `embed` as a dispatch kind.
5. **The route.** OpenAI shape: `{model, input}` where input is a string or an
   array, returning `{data: [{embedding, index}], usage}`. Routing is the
   existing `selectNode` with `kind: 'embed'`, which already permits ANE work in
   every presence state - so unlike generation, embeddings could run on a machine
   somebody is using, which is the whole reason the ANE path exists.

Step 5 is an afternoon. Steps 1 to 3 are the work, and until they are done the
endpoint should keep returning 404.

## The smaller bug next door

`/v1/models` and `/api/v0/models` list `ane:embed` as an available model of type
`embeddings`, which invites exactly the request that 404s. Whatever happens to
the rest of this, a model with no endpoint to reach it should not appear in a
catalogue as though it had one.
