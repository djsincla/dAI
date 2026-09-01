# Third-party notices

dAI is licensed under the Apache License 2.0, © 2026 Dwayne Sinclair — see
[LICENSE](LICENSE) and [NOTICE](NOTICE). It also contains and depends on work by
others, listed here with the notices their licences require.

The vendored subtree described first below is **MIT, not Apache-2.0**. That
boundary is deliberate: it keeps the fork mergeable back into its upstream
project, which is MIT.

---

## mlx-swift-examples (vendored, modified)

**Location in this repository:** `agent/vendor/mlx-swift-examples/`
**Upstream:** https://github.com/ml-explore/mlx-swift-examples
**Licence:** MIT — full text at
[`agent/vendor/mlx-swift-examples/LICENSE`](agent/vendor/mlx-swift-examples/LICENSE)
**Forked from:** commit `9bff95c` (mlx-swift 0.29.1)

> Copyright (c) 2024 ml-explore
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

Individual files in that subtree carry their own copyright lines — including
`Copyright © 2024 Apple Inc.` on parts of `MLXLMCommon` — which are preserved as
found. Contributors are credited upstream in
[`ACKNOWLEDGMENTS.md`](agent/vendor/mlx-swift-examples/ACKNOWLEDGMENTS.md).

### Modifications made for dAI

This is a **modified copy**. It was forked rather than depended on because
splitting a model across machines cannot be done from outside the library: the
layer loop, the weight loader and the quantisation pass all have to agree about
which layers a machine owns, and none of them are extension points. Upstream has
no pipeline parallelism for Qwen, and `mlx-swift` deliberately excludes
distributed support — its `Package.swift` excludes `ring.cpp`, `mpi.cpp` and
`nccl.cpp` and compiles the `no_ring.cpp` stub instead.

Three files differ from upstream. Changes within existing files are marked
`dAI:` in comments.

| File | Change |
|---|---|
| `Libraries/MLXLLM/Pipeline.swift` | **Added by dAI, not present upstream.** `PipelineSplit`, the `PipelineTransport` seam, and `Pipelineable`. |
| `Libraries/MLXLLM/Models/Qwen2.swift` | **Modified by dAI.** Takes the hidden state from the machine holding the earlier layers, and hands its own on. |
| `Libraries/MLXLMCommon/Load.swift` | **Modified by dAI.** `loadWeights(..., keepingLayers:)` drops the layers this machine does not own and renumbers the rest. |

No upstream file has been relicensed, and no copyright notice has been removed.
The transport is a protocol the caller supplies, so the library learns nothing
about certificates, fleets or sockets.

See [`agent/vendor/README.md`](agent/vendor/README.md) for how to work on the
fork as a repository and rebase it onto a newer upstream release.

---

## Dependencies not vendored

These are resolved at build time and are not redistributed in this repository.
Their licences apply to their own source, wherever it is fetched from.

| Project | Licence | Used by |
|---|---|---|
| [mlx-swift](https://github.com/ml-explore/mlx-swift) | MIT, © 2023 ml-explore | the agent's inference runtime |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | Apache-2.0 | tokenisers, Hub model download |
| [express](https://github.com/expressjs/express) | MIT | control plane HTTP |
| [node-postgres](https://github.com/brianc/node-postgres) | MIT | control plane database access |
| [@peculiar/x509](https://github.com/PeculiarVentures/x509) | MIT | node certificate issuance |
| [express-openapi-validator](https://github.com/cdimascio/express-openapi-validator) | MIT | request validation against the OpenAPI spec |
| [reflect-metadata](https://github.com/rbuckton/reflect-metadata) | Apache-2.0 | dependency injection metadata |
| [yaml](https://github.com/eemeli/yaml) | ISC | policy and configuration parsing |

The agent resolves 26 Swift packages in total and the control plane a larger
JavaScript tree. The complete lists, with resolved versions, are in
`agent/Package.resolved` and `control-plane/package-lock.json`; `npm ls --all`
prints the second one.

**One thing to settle before shipping binaries publicly.** Nothing above is
redistributed *by this repository*, but the built artefacts do redistribute it:
the agent statically links swift-transformers, and `dai-control-*.pkg` bundles
`node_modules` wholesale. Apache-2.0 §4(d) requires carrying upstream `NOTICE`
file contents along with a redistribution that includes one. If the installers
are published, they should ship a generated notices file covering the bundled
tree rather than relying on this hand-written page, which covers the repository
only.

---

## Models

No model weights are contained in this repository. Models referenced in
documentation and defaults — Qwen2.5, Qwen3, Llama 3.3, and the `mlx-community`
quantisations of them — are downloaded at runtime from their publishers and
carry their own licences, which are **not** MIT and in several cases restrict
commercial use. Check the licence of any model before serving it.
