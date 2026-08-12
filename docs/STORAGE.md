# Where model weights actually live

Findings from 2026-08-12, measured on both machines in the fleet. Nothing was
deleted; this is the analysis that should come before anybody deletes anything.

The short version: one 4-bit 72B model occupies 76 GB across this fleet because
it is stored twice, and the machine that is 99% full is the one running the
control plane, while the machine with 1.4 TB free holds almost nothing.

## The stores

There are four places a model can sit on a machine, and no single component
knows about all four.

| store | what puts it there | who reads it |
|---|---|---|
| `~/.cache/huggingface/hub` | anything that downloads from Hugging Face | whatever downloaded it |
| `~/Library/Caches/models` | the flat-layout cache the control plane scans | `/admin/v1/models/available` |
| `control-plane/models` (`DAI_MODEL_REPO`) | `POST /admin/v1/models/import`, which **copies** | the control plane, serving weights to nodes |
| `/var/db/dai` (`DAI_MODEL_DIR`) | `ModelSync` on each node | the agent, loading a model to serve |

The first two are caches, the second two are the product. Import copies rather
than moves or links, and a node fetches its own copy from the repository rather
than referencing it, so on a machine that is both control plane and node - which
rotorua is - a model is stored **twice by design** and up to four times in
practice.

## Measured, 2026-08-12

**rotorua** (M2 Max, 64 GB, 926 GB disk, **99% full, 11 GB free**)

| store | size |
|---|---|
| `~/.cache/huggingface/hub` | 61 GB |
| `~/.lmstudio/models` | 53 GB |
| `~/Library/Caches/models` | 32 GB |
| `control-plane/models` | 25 GB |
| `/var/db/dai` | not measured (root) |

Within that machine:

| model | HF cache | Library/Caches | repo | copies |
|---|---|---|---|---|
| Qwen2.5-1.5B | 839 M | 839 M | 839 M | 3 |
| Qwen2.5-14B | 7.7 G | - | 7.7 G | 2 |
| Qwen2.5-7B | 4.0 G | 4.0 G | - | 2 |
| Llama-3.2-3B | 1.7 G | 1.7 G | - | 2 |
| Qwen2.5-0.5B | 276 M | 276 M | - | 2 |
| Qwen2.5-72B | 38 G | - | - | 1 |
| DeepSeek-V2-Lite | 8.2 G | - | - | 1 |
| Qwen2.5-Coder-32B | - | 17 G | - | 1 |

About **14.5 GB is pure redundancy**: copies that could go with an identical
copy still present in another store on the same disk.

**orca** (M4 Pro, 48 GB, 1.8 TB disk, **24% full, 1.4 TB free**)

`~/.cache/huggingface/hub` 51 GB, and nothing else. No LM Studio library, no
flat cache. Its `/var/db/dai` was not measured.

## Two things this makes visible

**The same weights are stored on both machines.** Qwen2.5-72B is 38 GB on
rotorua and 38 GB on orca. DeepSeek-V2-Lite, Qwen2.5-7B and Qwen2.5-0.5B are
also on both. That is roughly 50 GB of duplication across a two-machine fleet,
and it grows linearly with machines. It is not wrong - a node must hold weights
locally to load them - but it is only tolerable because the copies are
deliberate. These are not: they are Hugging Face cache entries left behind by
whatever downloaded them, sitting beside the repository copies the fleet
actually manages.

**The pressure is entirely on the wrong machine.** rotorua carries the control
plane, the model repository, its own node store, three caches and Postgres, on
the smaller disk, at 99%. orca carries one cache on a disk with 1.4 TB free. The
fleet has plenty of room; it is all in the wrong place.

## What would actually fix it

Not a cleanup script. A cleanup buys back a few tens of gigabytes once and the
same thing happens again next month.

- **Import should be able to adopt rather than copy.** A model already on the
  disk is copied into the repository and the original stays where it was, so
  importing doubles it. Hardlinking when the source and repository are on one
  volume would make import nearly free; `/admin/v1/models/import` already hashes
  every file, so it knows they are identical.
- **A node that is also the control plane should reference the repository, not
  fetch a copy of it.** `ModelSync` fetches over HTTP because the general case
  is a remote node. When `DAI_MODEL_REPO` is on the same machine, that transfer
  is a 17 GB copy from a directory to another directory.
- **The repository should be able to live somewhere other than the boot disk.**
  It is a path in an environment variable, so this is configuration rather than
  code, but nothing says so and the default puts it beside the source tree.
- **Nothing reports total footprint.** `/admin/v1/models` reports each model's
  size once. No view answers "how much disk is this fleet using, and where",
  which is why this had to be measured by hand on two machines.

## If you are just trying to free space now

In order of safety, on rotorua:

1. Hugging Face cache copies of models that also exist in the repository or the
   flat cache: 14B, 7B, 3B, 1.5B, 0.5B. About **14.5 GB**, and every one of them
   still exists afterwards.
2. Qwen2.5-72B, 38 GB, single copy on this machine - **but also on orca**, so the
   fleet keeps it either way. This was the split-model spike asset.
3. `~/.lmstudio/models` is 53 GB and belongs to LM Studio, not to dAI. Three
   models, none of them registered here.

None of this was done.
