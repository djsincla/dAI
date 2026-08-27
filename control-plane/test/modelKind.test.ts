import { describe as group, expect, it } from 'vitest'
import { describeModel, runtimeFor } from '../src/lib/import.js'

/**
 * What the catalogue decides about a model at import, from its name and its
 * files.
 *
 * Both decisions are load-bearing in a way that is not obvious from the code.
 * `kind` decides whether a model appears in the catalogue at all and which
 * endpoint will accept it. `runtime` decides **presence gating**: an embedding
 * model on the Neural Engine may run while somebody is using their machine,
 * and one on the GPU may not. A wrong answer here dispatches GPU work to an
 * occupied desktop, which is the failure this project cannot afford socially.
 */
group('what kind of model this is', () => {
  it('recognises the embedding families', () => {
    for (const id of ['mlx-community/Qwen3-Embedding-0.6B-8bit',
                      'BAAI/bge-base-en-v1.5',
                      'intfloat/multilingual-e5-small',
                      'nomic-ai/nomic-embed-text-v1.5',
                      'mlx-community/nomicai-modernbert-embed-base-bf16',
                      'sentence-transformers/all-MiniLM-L6-v2',
                      'thenlper/gte-small']) {
      expect(describeModel(id).kind, id).toBe('embed')
    }
  })

  it('leaves generation models alone', () => {
    for (const id of ['mlx-community/Qwen2.5-Coder-32B-Instruct-4bit',
                      'meta-llama/Llama-3.1-8B-Instruct',
                      'mistralai/Mistral-7B-Instruct-v0.3']) {
      expect(describeModel(id).kind, id).toBe('generate')
    }
  })

  it('does not match an embedding family inside an unrelated word', () => {
    // The pattern was /embed|bge|e5|gte|minilm/ unanchored. Mislabelling a chat
    // model as an embedding one hides it from the catalogue and refuses every
    // completion sent to it, which reads as the model having disappeared.
    expect(describeModel('org/base5-chat').kind).toBe('generate')
    expect(describeModel('org/agte-7b').kind).toBe('generate')
  })
})

group('which runtime can load what was staged', () => {
  const files = (...paths: string[]) => paths.map((path) => ({ path }))

  it('reads Core ML from a compiled bundle', () => {
    expect(runtimeFor(files('model.mlpackage/Manifest.json'))).toBe('coreml')
    expect(runtimeFor(files('encoder.mlmodelc'))).toBe('coreml')
  })

  it('reads MLX from safetensors', () => {
    expect(runtimeFor(files('model.safetensors', 'config.json'))).toBe('mlx')
  })

  it('calls an embedding model with MLX weights mlx, not coreml', () => {
    // The case the old code got wrong: it decided runtime from kind, so every
    // embedding model was labelled coreml. /v1/embeddings reads this field to
    // decide presence gating, so MLX weights labelled coreml would be
    // dispatched to a machine somebody is using.
    expect(runtimeFor(files('model.safetensors',
                            'tokenizer.json',
                            'config.json'))).toBe('mlx')
  })

  it('defaults to mlx when the files say nothing either way', () => {
    // Failing towards the stricter gate. An MLX label is presence-gated like
    // generation, so an unknown model is treated as GPU work and kept off an
    // occupied machine; the reverse default would let it through.
    expect(runtimeFor(files('README.md'))).toBe('mlx')
  })
})
