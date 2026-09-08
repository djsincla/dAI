/**
 * Sampling parameters, read once for both serving surfaces.
 *
 * These were declared in the OpenAPI document and read by nothing. A caller
 * could send `temperature: 0.9`, be validated against a schema that named it,
 * receive a 200, and get greedy output - the request was accepted, the value
 * was dropped between the handler and the dispatch body, and both runtimes
 * hardcoded their own sampler. Nothing anywhere said so. The symptom reaches
 * the caller as "this model is dull", which points at the model rather than at
 * the gateway that discarded the setting.
 *
 * Two rules hold everything below together.
 *
 * The first is that a parameter this fleet cannot honour is refused rather than
 * ignored. That is the whole point of the exercise, and accepting one quietly
 * is the bug being fixed.
 *
 * The second keeps the first usable: a parameter is only refused when its value
 * would change the answer. Clients send `n: 1`, `presence_penalty: 0` and
 * `logit_bias: {}` as inert defaults - refusing those would reject requests
 * that ask for nothing this fleet cannot do, which is a worse failure than the
 * one being fixed and would be blamed on the fleet just as wrongly.
 */

/** What the runtime is asked for, in the runtime's own names. */
export type Sampling = {
  temperature: number
  top_p: number
  /** Absent unless asked for: the runtime treats null as "no penalty". */
  repetition_penalty?: number
  repetition_context_size?: number
  /** Strings that end generation. Never sent empty. */
  stop?: string[]
}

export type SamplingResult =
  | { ok: true; sampling: Sampling; requested: string[] }
  | { ok: false; message: string }

/**
 * Greedy, and deliberately so.
 *
 * Determinism is load-bearing on a harvested fleet in a way it is not on a
 * dedicated one: a request preempted by a returning user is requeued onto a
 * different machine, and an item that answers differently depending on which
 * machine was free is not a reproducible batch. A caller who wants sampling
 * asks for it, and by asking accepts that.
 *
 * It is also the reason this default cannot simply become the runtime's own
 * 0.6 - that would change every existing caller's results to fix a bug about
 * callers being ignored.
 */
export const GREEDY: Sampling = { temperature: 0, top_p: 1 }

/** A number if it is one, with a clear refusal if it is present and is not. */
function num(v: unknown, name: string, lo: number, hi: number):
  { ok: true; value: number } | { ok: false; message: string } {
  if (typeof v !== 'number' || !Number.isFinite(v)) {
    return { ok: false, message: `${name} must be a number` }
  }
  if (v < lo || v > hi) {
    return { ok: false, message: `${name} must be between ${lo} and ${hi}` }
  }
  return { ok: true, value: v }
}

/**
 * Whether a value the fleet cannot honour is actually asking for anything.
 *
 * `0` and `{}` and `false` and `1` are what a client library fills in when the
 * user set nothing. Treating those as a request is how a correctness rule
 * becomes an outage.
 */
function inert(v: unknown, ...noops: unknown[]): boolean {
  if (v === undefined || v === null) return true
  if (typeof v === 'object' && !Array.isArray(v)) return Object.keys(v as object).length === 0
  return noops.includes(v)
}

/**
 * Read sampling out of a request body, in whichever dialect it arrived.
 *
 * `dialect` decides only the spelling of the stop list and which unsupported
 * parameters are worth naming in a refusal; the meaning is the same on both
 * surfaces because it is the same runtime underneath.
 */
export function readSampling(
  body: Record<string, unknown>, dialect: 'openai' | 'anthropic',
): SamplingResult {
  const out: Sampling = { ...GREEDY }
  const requested: string[] = []

  if (body.temperature !== undefined && body.temperature !== null) {
    // 2 is OpenAI's ceiling and higher than Anthropic's 1. The wider of the two
    // is accepted on both, because the runtime divides by it and any positive
    // value is meaningful - refusing 1.5 on the Anthropic surface would be this
    // gateway inventing a limit that neither the API nor the model has.
    const r = num(body.temperature, 'temperature', 0, 2)
    if (!r.ok) return r
    out.temperature = r.value
    requested.push('temperature')
  }

  if (body.top_p !== undefined && body.top_p !== null) {
    const r = num(body.top_p, 'top_p', 0, 1)
    if (!r.ok) return r
    out.top_p = r.value
    requested.push('top_p')
  }

  // Not in either API. It is the parameter people actually reach for on local
  // models, the runtime implements it natively, and there is no standard
  // spelling to conform to - so it is offered under the name mlx and llama.cpp
  // both use, and reported back so nobody has to guess whether it landed.
  if (body.repetition_penalty !== undefined && body.repetition_penalty !== null) {
    const r = num(body.repetition_penalty, 'repetition_penalty', 0.01, 2)
    if (!r.ok) return r
    out.repetition_penalty = r.value
    requested.push('repetition_penalty')
  }
  if (body.repetition_context_size !== undefined && body.repetition_context_size !== null) {
    const r = num(body.repetition_context_size, 'repetition_context_size', 1, 4096)
    if (!r.ok) return r
    if (!Number.isInteger(r.value)) {
      return { ok: false, message: 'repetition_context_size must be a whole number' }
    }
    out.repetition_context_size = r.value
    requested.push('repetition_context_size')
  }
  // A window with no penalty to apply in it does nothing, and silently doing
  // nothing is the failure this file exists to remove.
  if (out.repetition_context_size !== undefined && out.repetition_penalty === undefined) {
    return { ok: false, message:
      'repetition_context_size sets the window for repetition_penalty, which was not given' }
  }

  const stopField = dialect === 'anthropic' ? 'stop_sequences' : 'stop'
  const raw = body[stopField]
  if (raw !== undefined && raw !== null) {
    // OpenAI accepts a bare string here and clients send one.
    const list = typeof raw === 'string' ? [raw] : raw
    if (!Array.isArray(list) || list.some((s) => typeof s !== 'string')) {
      return { ok: false, message: `${stopField} must be a string or an array of strings` }
    }
    // An empty string matches at position zero, so a completion that honoured
    // it would always be empty. Both APIs reject it and so does this.
    if (list.some((s) => s === '')) {
      return { ok: false, message: `${stopField} must not contain an empty string` }
    }
    if (list.length > 4) {
      return { ok: false, message: `${stopField} accepts at most 4 sequences` }
    }
    if (list.length > 0) {
      out.stop = list as string[]
      requested.push(stopField)
    }
  }

  // Everything the runtime has no sampler for. Named individually, with the
  // reason, because "unsupported parameter" sends somebody to read this source
  // to find out whether it is unsupported here or unsupported everywhere.
  const unsupported: [string, unknown, unknown[], string][] = [
    ['seed', body.seed, [],
     'the runtime seeds each sampler from the clock, so a seed could be accepted '
     + 'and would not reproduce anything'],
    ['top_k', body.top_k, [],
     'the pinned MLX runtime has no top-k sampler; use top_p'],
    ['min_p', body.min_p, [0],
     'the pinned MLX runtime has no min-p sampler; use top_p'],
    ['n', body.n, [1], 'a completion is dispatched to one node as one unit'],
    ['logprobs', body.logprobs, [false],
     'the runtime returns sampled tokens and not their distribution'],
    ['top_logprobs', body.top_logprobs, [],
     'the runtime returns sampled tokens and not their distribution'],
    ['logit_bias', body.logit_bias, [],
     'the runtime applies no logit processor other than repetition_penalty'],
    // Deliberately not mapped onto repetition_penalty. They are different
    // functions - OpenAI's are additive on the logit, the runtime's is
    // multiplicative on a sliding window - and quietly substituting one for the
    // other would be the same class of lie as dropping it, with the added
    // problem that the answer would look like it worked.
    ['frequency_penalty', body.frequency_penalty, [0],
     'not the same function as repetition_penalty, which this fleet does support'],
    ['presence_penalty', body.presence_penalty, [0],
     'not the same function as repetition_penalty, which this fleet does support'],
  ]
  for (const [name, value, noops, why] of unsupported) {
    if (!inert(value, ...noops)) {
      return { ok: false, message: `${name} is not supported: ${why}` }
    }
  }

  return { ok: true, sampling: out, requested }
}

/**
 * What to tell the caller was applied.
 *
 * Reported for the same reason `maxTokensApplied` is: on this fleet the values
 * a request asked for and the values a machine used are not the same thing by
 * default, and a caller that cannot see the difference cannot debug it.
 */
export function samplingReport(s: Sampling, requested: string[]) {
  return {
    temperature: s.temperature,
    topP: s.top_p,
    ...(s.repetition_penalty !== undefined
      ? { repetitionPenalty: s.repetition_penalty } : {}),
    ...(s.stop ? { stop: s.stop } : {}),
    // Empty when the caller asked for nothing, which is how a reader tells
    // "greedy because that is the default" from "greedy because I said 0".
    requested,
  }
}
