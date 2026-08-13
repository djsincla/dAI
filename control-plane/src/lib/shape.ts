/**
 * How many machines a model needs, and how much of each.
 *
 * A model that fits on no single machine is run across several, its layers
 * divided, one hidden state crossing the boundary per token. The catalogue has
 * to say so, because otherwise the fleet learns it at dispatch - by hanging.
 *
 * **Shape is about memory, not disk.** A split model still arrives whole on
 * every machine that holds it: ModelSync fetches every file, and the runtime
 * builds a model with a reduced layer count from the same directory. What
 * divides is what gets loaded. E7 measured a 72B at 41.10 GB on one machine and
 * 21.31 GB on each of two, so the per-machine requirement tracks the weights it
 * actually loads rather than the bytes it stores.
 */

export interface Shape {
  /** Machines the model runs across. 1 for everything that fits. */
  machines: number
  /** What each of them has to be able to load, in gigabytes. */
  perMachineGb: number
}

/**
 * Room the runtime needs beyond the weights themselves.
 *
 * The KV cache, activations, and whatever the framework keeps. Measured rather
 * than guessed: E7's 72B is 40.4 GB of 4-bit weights and peaked at 41.10 GB
 * resident on one machine, so about 2%. Rounded up to 10% because that
 * measurement was one prompt at one context length, and the cache grows with
 * both - a floor that is too generous costs a machine, and one that is too tight
 * costs a load that fails after the transfer.
 */
export const RUNTIME_HEADROOM = 1.1

const GIB = 1073741824

/**
 * What a model needs, from what the catalogue records.
 *
 * `machines` is declared because it cannot be derived: whether a 40 GB model
 * runs on one machine or two is a decision about the fleet, not a property of
 * the weights. The per-machine figure is derived unless somebody has measured
 * otherwise, since dividing the weights is exactly what pipelining does.
 */
export function shapeOf(model: {
  size_bytes: number | string
  machines?: number | null
  min_memory_gb?: number | string | null
}): Shape {
  const machines = Math.max(1, Number(model.machines ?? 1))
  const declared = model.min_memory_gb == null ? null : Number(model.min_memory_gb)
  if (declared !== null && Number.isFinite(declared) && declared > 0) {
    return { machines, perMachineGb: declared }
  }
  const gib = Number(model.size_bytes) / GIB
  return { machines, perMachineGb: (gib / machines) * RUNTIME_HEADROOM }
}

export interface Machine {
  hostname: string
  /** What this machine can actually give the GPU, which is not its RAM. */
  metalWorkingSetGb: number | null
  /** Whether the weights are on this machine's disk. */
  holds?: boolean
}

export type Runnability =
  /** Enough machines, big enough, holding the weights. */
  | { state: 'ready' }
  /** Will be able to once a transfer finishes. Nothing to do but wait. */
  | { state: 'pending'; detail: string }
  /** Never will, as the group stands. Somebody has to change something. */
  | { state: 'blocked'; detail: string }

/**
 * Whether a group can run a model now, later, or not as it stands.
 *
 * Three answers rather than two, because "cannot" and "not yet" call for
 * different actions and look identical from a boolean. A group whose machines
 * are too small will never run the model however long anybody waits; a group
 * still fetching the weights needs nothing but time. Reporting both as "no" is
 * how an operator ends up waiting for something that is not coming, or
 * reassigning something that was about to work.
 *
 * Holding is per machine and unchanged by splitting: a split model arrives
 * whole everywhere and divides only what it loads. What splitting changes is
 * this - the question of whether enough machines, together, can run it.
 */
export function runnability(machines: Machine[], shape: Shape): Runnability {
  const blocked = whyGroupCannotHost(machines, shape)
  if (blocked) return { state: 'blocked', detail: blocked }

  const holding = machines.filter(
    (m) => m.holds && m.metalWorkingSetGb !== null
      && m.metalWorkingSetGb >= shape.perMachineGb)
  if (holding.length < shape.machines) {
    return {
      state: 'pending',
      detail: `${holding.length} of ${shape.machines} machines hold the weights`,
    }
  }
  return { state: 'ready' }
}

/**
 * Why this group could never run this model, or null if the shape fits.
 *
 * Answered at assignment rather than at dispatch. A model declared to need two
 * machines, assigned to a group with one, should be refused with a sentence
 * somebody can act on - not accepted and then discovered as a request that
 * hangs, weeks later, by whoever happens to send it.
 *
 * The reason names the shortfall rather than saying no: an operator told "needs
 * 2 machines, this group has 1" knows what to do next, and one told "cannot
 * host" does not.
 *
 * Says nothing about whether the weights have arrived - see `runnability`,
 * which separates what will never work from what has not finished yet.
 */
export function whyGroupCannotHost(machines: Machine[], shape: Shape): string | null {
  // A machine whose working set was never probed fails rather than passes.
  // Guessing upward here puts a model on a machine that cannot load it, and the
  // symptom arrives after the transfer rather than before it.
  const big = machines.filter(
    (m) => m.metalWorkingSetGb !== null && m.metalWorkingSetGb >= shape.perMachineGb)

  if (machines.length < shape.machines) {
    return `needs ${shape.machines} machines and this group has ${machines.length}`
  }
  if (big.length < shape.machines) {
    const short = machines
      .filter((m) => !big.includes(m))
      .map((m) => `${m.hostname} has ${
        m.metalWorkingSetGb === null ? 'an unknown working set' : `${m.metalWorkingSetGb.toFixed(1)} GB`}`)
    return `needs ${shape.machines} machines with ${shape.perMachineGb.toFixed(1)} GB each; `
      + `only ${big.length} qualify (${short.join(', ')})`
  }
  return null
}
