# Vendored dependencies

## mlx-swift-examples

A fork of [ml-explore/mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples),
branched from `9bff95c` (mlx-swift 0.29.1).

Forked rather than depended on, because splitting a model across machines
cannot be done from outside the library. The layer loop, the weight loader and
the quantisation pass all have to agree about which layers a machine owns, and
none of them are extension points.

Upstream has no pipeline parallelism for Qwen. Python `mlx-lm` has it and
applies it only to certain mixture-of-experts architectures, so a dense model
too large for any one machine cannot be served at all.

Note also that `mlx-swift` deliberately excludes distributed support: its
`Package.swift` excludes `ring.cpp`, `mpi.cpp` and `nccl.cpp` and compiles the
`no_ring.cpp` stub instead. There is no supported path to turn that on, which
is why the transport here is our own.

### What is changed

Four files. The first three are the split and are marked `dAI:` at each change;
the fourth is a one-line visibility change from a different piece of work.

| File | Change |
|---|---|
| `Libraries/MLXLLM/Pipeline.swift` | New. `PipelineSplit`, the `PipelineTransport` seam, and `Pipelineable`. |
| `Libraries/MLXLLM/Models/Qwen2.swift` | Takes the hidden state from the machine holding the earlier layers, and hands its own on. |
| `Libraries/MLXLMCommon/Load.swift` | `loadWeights(..., keepingLayers:)` drops the layers this machine does not own and renumbers the rest. |
| `Libraries/Embedders/EmbeddingModel.swift` | `EmbeddingModelOutput.hiddenStates` and `pooledOutput` made public, so pooling can be done outside the library. See `1b306b09`. |

This table said "three files" for four days after the fourth was added in
`1b306b09` on 2026-08-27. That change is commented where it is and explained in
its commit message, and was still missing from the one place a reader looks to
find out what differs from upstream. **A list of modifications is only useful if
adding a modification also updates it** - and once this fork is published, the
same list is the attribution.

The transport is a protocol the caller supplies. This library never learns
about certificates, fleets or sockets, and the code that owns those does not
have to fork a model library to change how bytes move.

### Its history

The fork keeps its own git history in `.git-fork` rather than `.git`, which is
ignored by the parent repo. The parent tracks the source files themselves, so a
fresh clone of dAI builds with no second checkout step and the fork cannot be
lost by being left on one machine.

To work on the fork as a repository - to diff against upstream, or to rebase
onto a newer release:

```sh
cd agent/vendor/mlx-swift-examples
mv .git-fork .git      # then git log, git diff, git rebase upstream/main
mv .git .git-fork      # put it back before committing in the parent
```

The changes live on the `dai-pipeline` branch.

### Building

SwiftPM cannot compile MLX's Metal shaders. Use `xcodebuild`, which produces
`mlx-swift_Cmlx.bundle`; without it the MLX tests skip themselves.

```sh
xcodebuild build -scheme dai-agent -destination 'platform=OS X' -derivedDataPath .xcbuild
```
