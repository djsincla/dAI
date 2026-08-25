# Python examples

Five scripts against the dAI serving gateway, and a RAG index built over
California's Lanterman Act.

Standard library plus numpy. No SDK, no framework, no vector database service.
That is not minimalism for its own sake: the point of these examples is what the
gateway does, and a dependency list is a good way to hide it.

```
dai_gateway.py      the client every script shares
demo_01_models.py   what the fleet can serve, and what a prompt costs
demo_02_chat.py     one completion, in both API shapes
demo_03_fleet.py    which machines exist and who is sitting at them

rag_fetch.py        fetch the statute from the Legislature
rag_index.py        chunk it, embed it, write the store
rag_store.py        the vector store: one SQLite file
rag_embed.py        text to vectors, and why it happens locally
rag_ask.py          ask a question, answer with citations
rag_ask_split.py    the same question, answered by two machines at once

kubectl_fetch.py    build a corpus from kubectl's help and the published docs
kubectl_ask.py      ask kubectl a question, answered on the fleet
```

## Before anything

```bash
export DAI_BASE_URL=https://your-control-plane:8452
export DAI_CA_CERT=/path/to/srv-ca.crt      # the control plane's installer prints this
export DAI_API_KEY=...                       # minted once, below
```

The CA matters. The control plane signs its certificate with its own authority,
so a client has to be told to trust it; the system roots cannot. `DAI_INSECURE=1`
skips verification and exists for a machine you are standing in front of, not for
anything else.

To mint a key, sign in as an operator and ask for one. It is returned once:

```bash
SESSION=$(curl -sk https://your-control-plane:8452/admin/v1/auth/login \
  -H 'content-type: application/json' \
  -d '{"username":"admin","password":"..."}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')

curl -sk https://your-control-plane:8452/admin/v1/auth/keys \
  -H "authorization: Bearer $SESSION" -H 'content-type: application/json' \
  -d '{"label":"python examples"}'
```

`demo_03_fleet.py` needs a key with admin rights. The others do not.

## The three API demos

```bash
python3 demo_01_models.py
python3 demo_02_chat.py "what can this fleet do?"
python3 demo_03_fleet.py
```

Two things they show that a hosted API has no equivalent for.

**Every answer names the machine that produced it.** The response carries a
`dai` block outside the OpenAI schema, with the node and what its owner was
doing. On a fleet assembled from other people's desks that is not diagnostic
detail, it is the product.

**503 is a real answer, not a failure.** Harvest nodes yield to whoever is
sitting at them, so during working hours there may genuinely be no capacity.
The gateway says so immediately rather than hanging, and the client here treats
it as an outcome to handle rather than an error to log.

There is no streaming demo because the gateway does not stream: a completion is
dispatched to a node as one unit. Writing one against `stream: true` would have
produced an example that cannot work.

## The RAG example

```bash
python3 rag_fetch.py        # ~60 requests, cached; a few minutes once
python3 rag_index.py        # seconds
python3 rag_ask.py "who is eligible for regional center services?"
```

### Where the corpus comes from

The Department of Developmental Services publishes a page of
[Lanterman Act and related laws](https://www.dds.ca.gov/transparency/laws-regulations/lanterman-act-and-related-laws/).
That page is a portal, not the law: it names three divisions of the Welfare and
Institutions Code and points at the Legislature's own site for the text.
`rag_fetch.py` reads the portal to discover which divisions those are, then
fetches each chapter whole from leginfo - about sixty requests rather than
several hundred, which is the polite way round and also the fast one.

That yields **569 sections, about 1.07 million characters**, chunked to 1,408
pieces. Everything is cached under `corpus/`, so only the first run touches the
network.

### The split that matters

**The gateway does not serve embeddings.** There is no `/v1/embeddings`; it
serves generation, a model list and a token count. So the work divides:

```
retrieval    local, on the machine asking     numpy, a 35MB SQLite file
generation   the fleet                        somebody's idle Mac
```

Neither half involves anybody else's API. The statute is public, but the
questions asked of it are not, and on this arrangement a question about a named
individual's eligibility never leaves the building. If `/v1/embeddings` is added
later, it belongs as a third backend in `rag_embed.py` and nothing else changes.

### What the retrieval is, and what it cost to get right

Default is BM25 over a vocabulary fitted to the corpus, arranged so that a dot
product scores it - so the store stays a matrix and a sort, with no special
index. Three things were wrong before it worked, and each is worth more than the
code that fixed it:

**Hashing bought nothing and cost accuracy.** The first version hashed terms
into 4,096 dimensions, which is what you do when a vocabulary is too large to
keep. This corpus has 5,772 distinct terms; hashing collided 46% of them. An
approximation chosen for a scale you do not have is not free.

**Cosine punished the sections that answered best.** Asked what rights people
with developmental disabilities have, TF-IDF cosine ranked short "Definitions"
sections first and put section 4502 - the Bill of Rights itself - **fortieth**.
Cosine normalises length away, so a long section that answers a question fully
loses to a short one that merely mentions the words. BM25 saturates term
frequency and normalises length against the corpus average instead, which is
exactly this problem.

**Chunks had no topical label.** Section text says what the rule is; only the
chapter heading says that chapter 1.3 is the Bill of Rights. A question about
rights could not match the chapter about rights, because the phrase appears only
in the title. Headings are now parsed and prepended to every chunk.

After the three, section 4502's chapter takes the top places on that question.

The remaining weakness is the one lexical retrieval always has: the question said
"people", the statute says "persons". A short table of morphological variants
covers the cases somebody thought of, and `--backend st` (sentence-transformers,
optional) covers the rest by embedding meaning rather than words.

`--retrieve-only` is the right way to judge all of this. If the sections it lists
are not the ones a person would have looked up, no model will rescue the answer:

```bash
python3 rag_ask.py --retrieve-only --show-sources "how do I appeal a denial of services?"
```

## A second corpus: kubectl

The same pipeline over something with no legal weight and a different failure
mode. Statute punishes invention with a citation that does not exist; a manual
punishes it with a flag that fails at the terminal.

```
python3 kubectl_fetch.py        # ~100 requests, cached; a couple of minutes once
python3 rag_index.py --corpus corpus/kubectl.jsonl --index corpus/kubectl.db
python3 kubectl_ask.py "how do I roll back a deployment to the previous revision?"
```

`rag_index.py` is reused unchanged. The store's load-bearing fields are the
citation, the URL and the text, and a command maps onto them as readily as a
section of the Welfare and Institutions Code does.

### Two sources, deliberately not merged

**`kubectl <cmd> --help`, from the binary on the machine that built the corpus.**
Authoritative for the version whose flags will actually work.

**kubernetes.io/docs/reference/kubectl/generated/**, the published reference.
Carries the prose and examples the terminal help trims, and gives an answer
somewhere to point that is not this laptop.

Every entry says which it came from, because "the flag is `--foo`" is a
different claim from your binary than from a page describing another release.
The prompt asks the model to say which it used.

The command tree is walked from kubectl itself rather than hardcoded, so a
plugin or a new subcommand in a later release is picked up without editing
anything. `--local-only` skips the network entirely, which matters if the point
is that nothing leaves the building.

### What it looks like when it works

```
$ python3 kubectl_ask.py "how do I take a node out of service for maintenance?"
...
To take a node out of service for maintenance, use the `kubectl drain` command.
...
> **Warning**: Using `--force` can cause disruption if the pods are critical.

  routed to  rotorua (ACTIVE)
  node time  6.44s
  tokens     1986 in, 80 out
```

The warning is not decoration: the prompt asks for destructive commands to be
named as destructive, because `delete`, `drain` and `taint` all do exactly what
they say and a reader pasting from an answer deserves to be told.

This suggests commands; it does not run them.

### On pointing a language model at law

Every chunk carries its citation inside the text, not only in the metadata, so
the model can cite what it used; the prompt tells it to answer only from the
supplied sections and to say when they do not cover the question; and every
answer prints the sections it drew on with a link to the Legislature's copy.

That is a reading aid for finding the right section quickly. It is not legal
advice, and the statute is the authority.
