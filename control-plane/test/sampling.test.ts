import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import YAML from 'yaml'
import { describe, expect, it } from 'vitest'
import { GREEDY, readSampling, samplingReport } from '../src/lib/sampling.js'

/**
 * Sampling parameters, which were declared and dropped.
 *
 * `temperature`, `top_p` and `stop_sequences` were named in the OpenAPI
 * document, validated against it, and read by nothing: the handler built its
 * dispatch body from `messages`, `max_tokens`, `model` and the tool fields, and
 * both runtimes hardcoded their own sampler. A caller asking for 0.9 got a 200
 * and greedy output, and the only visible symptom was a model that seemed dull -
 * which points at the model, not at the gateway that discarded the setting.
 *
 * These tests are mostly about refusals, because the refusals are the part that
 * can silently rot back into the old behaviour. A parameter that stops being
 * honoured while still being accepted looks exactly like one that works.
 */
describe('reading sampling out of a request', () => {
  it('is greedy when nothing is asked for', () => {
    const r = readSampling({}, 'openai')
    expect(r).toMatchObject({ ok: true, sampling: GREEDY })
    // Empty, not absent. A caller reading the report can tell "greedy because
    // that is the default" from "greedy because I sent temperature: 0", and
    // those are different conversations to have about a dull answer.
    expect(r.ok && r.requested).toEqual([])
  })

  it('carries what was asked for', () => {
    const r = readSampling(
      { temperature: 0.7, top_p: 0.9, repetition_penalty: 1.1 }, 'openai')
    expect(r).toMatchObject({
      ok: true,
      sampling: { temperature: 0.7, top_p: 0.9, repetition_penalty: 1.1 },
    })
  })

  it('takes the stop list under each API\'s own name', () => {
    // Same meaning, different spelling, and reading the wrong one is a silent
    // drop rather than an error - which is the bug this file is about.
    expect(readSampling({ stop_sequences: ['\n\nHuman:'] }, 'anthropic'))
      .toMatchObject({ ok: true, sampling: { stop: ['\n\nHuman:'] } })
    expect(readSampling({ stop: ['</task>'] }, 'openai'))
      .toMatchObject({ ok: true, sampling: { stop: ['</task>'] } })
    // Under the other surface's name it is not a stop list and is not read as
    // one. Honouring a field the API does not define is how two clients end up
    // disagreeing about what the API is, and the caller who meant it would be
    // relying on something no Anthropic client will send.
    expect(readSampling({ stop: ['x'] }, 'anthropic')).toMatchObject({ ok: true })
    expect((readSampling({ stop: ['x'] }, 'anthropic') as { sampling: object }).sampling)
      .not.toHaveProperty('stop')
  })

  it('accepts the bare string OpenAI clients send', () => {
    expect(readSampling({ stop: '###' }, 'openai'))
      .toMatchObject({ ok: true, sampling: { stop: ['###'] } })
  })

  it('never carries an empty stop list', () => {
    // `stop: []` reaching the agent as an empty array is harmless; reaching it
    // as a *present* field is what makes the runtime build a scanner and decode
    // the whole answer once per token for nothing.
    const r = readSampling({ stop: [] }, 'openai')
    expect(r.ok && r.sampling).not.toHaveProperty('stop')
  })

  it('refuses an empty stop sequence', () => {
    // It matches at position zero, so an answer honouring it is always empty.
    // Both APIs refuse it and a fleet that accepted it would return blank
    // completions with a successful status.
    expect(readSampling({ stop: [''] }, 'openai')).toMatchObject({ ok: false })
  })

  it('refuses values outside the range the runtime can use', () => {
    expect(readSampling({ temperature: -1 }, 'openai')).toMatchObject({ ok: false })
    expect(readSampling({ temperature: 3 }, 'openai')).toMatchObject({ ok: false })
    expect(readSampling({ top_p: 1.5 }, 'openai')).toMatchObject({ ok: false })
    expect(readSampling({ temperature: 'hot' }, 'openai')).toMatchObject({ ok: false })
    expect(readSampling({ stop: [1, 2] }, 'openai')).toMatchObject({ ok: false })
    expect(readSampling({ stop: ['a', 'b', 'c', 'd', 'e'] }, 'openai'))
      .toMatchObject({ ok: false })
  })

  it('refuses a repetition window with no penalty to apply in it', () => {
    // The runtime ignores the window unless a penalty is set, so accepting this
    // would be accepting a parameter that does nothing - the exact failure the
    // rest of this file exists to prevent.
    expect(readSampling({ repetition_context_size: 64 }, 'openai'))
      .toMatchObject({ ok: false })
    expect(readSampling({ repetition_context_size: 64, repetition_penalty: 1.1 }, 'openai'))
      .toMatchObject({ ok: true })
  })

  it('refuses what this fleet cannot honour, by name and with a reason', () => {
    for (const body of [
      { seed: 42 }, { top_k: 40 }, { min_p: 0.05 }, { n: 2 },
      { logprobs: true }, { logit_bias: { 1234: -100 } },
      { frequency_penalty: 0.5 }, { presence_penalty: 0.5 },
    ]) {
      const r = readSampling(body, 'openai')
      expect(r.ok, JSON.stringify(body)).toBe(false)
      // The name of the offending parameter has to be in the message. "One or
      // more parameters are unsupported" sends somebody to read this source to
      // find out which, and by then they have already assumed it is the model.
      expect(!r.ok && r.message).toContain(Object.keys(body)[0]!)
    }
  })

  it('does not refuse a default a client library filled in', () => {
    // The rule that keeps the rule above usable. Clients send these unasked, and
    // rejecting a request for asking for nothing is a worse failure than the one
    // being fixed - and would be blamed on the fleet just as wrongly.
    expect(readSampling({
      n: 1, frequency_penalty: 0, presence_penalty: 0,
      logit_bias: {}, logprobs: false, min_p: 0,
      seed: null, top_k: undefined, stop: null,
    }, 'openai')).toMatchObject({ ok: true, sampling: GREEDY })
  })

  it('reports what was applied and what was asked for', () => {
    const r = readSampling({ temperature: 0.7, stop: ['x'] }, 'openai')
    expect(r.ok).toBe(true)
    if (!r.ok) return
    expect(samplingReport(r.sampling, r.requested)).toEqual({
      temperature: 0.7, topP: 1, stop: ['x'], requested: ['temperature', 'stop'],
    })
    // Absent rather than null when unset, so `if (dai.sampling.repetitionPenalty)`
    // reads correctly instead of every answer carrying a field nobody set.
    expect(samplingReport(r.sampling, r.requested)).not.toHaveProperty('repetitionPenalty')
  })
})

/**
 * The document does not get to set the defaults.
 *
 * `express-openapi-validator` fronts these routes and materialises every
 * `default:` it finds into the request body before a handler sees it. Writing
 * the defaults into the schema as documentation - which is what they look like -
 * put `temperature: 0`, `top_p: 1` and `repetition_context_size: 20` into every
 * request, so the guard that refuses a repetition window with no penalty to
 * apply in it refused *everything*. A 400 on every completion, from a change
 * whose visible part was three lines of YAML that read as prose.
 *
 * It is the same fault as the one this whole change set fixes, inverted. There,
 * the schema named a parameter and nothing read it. Here, the schema would have
 * set one and nobody wrote it. Both are the document and the code disagreeing
 * about which of them is in charge, and the code is.
 */
describe('the OpenAPI document as documentation, not as behaviour', () => {
  const spec = YAML.parse(
    readFileSync(join(process.cwd(), 'openapi', 'dai.yaml'), 'utf8')) as any

  const sampled = ['temperature', 'top_p', 'repetition_penalty',
                   'repetition_context_size', 'stop', 'stop_sequences']

  for (const path of ['/v1/chat/completions', '/v1/messages']) {
    it(`declares no default the validator would inject on ${path}`, () => {
      const props = spec.paths[path].post
        .requestBody.content['application/json'].schema.properties
      for (const name of sampled) {
        if (!props[name]) continue
        expect(props[name], `${path} ${name}`).not.toHaveProperty('default')
      }
    })

    it(`still documents the sampling parameters on ${path}`, () => {
      // The other half of the pin. Deleting the defaults must not turn into
      // deleting the declarations - that is where this started, with three
      // parameters named in the document and read by nothing.
      const props = spec.paths[path].post
        .requestBody.content['application/json'].schema.properties
      expect(Object.keys(props)).toEqual(expect.arrayContaining(
        ['temperature', 'top_p', 'repetition_penalty']))
    })
  }
})
