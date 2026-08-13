import type { Server } from 'node:http'

/**
 * The sockets groups answer on, opened and closed while the process runs.
 *
 * A group's port is allocated when the group is created, and it has to start
 * answering then rather than at the next restart - a group that looks created
 * and refuses connections is worse than one that failed to be created at all,
 * because only the second says so.
 *
 * Kept behind an interface because binding is the one part of this that cannot
 * be tested without opening real sockets. The routes take this, a test passes a
 * recorder, and what the routes decide - which port, when to open it, when to
 * give it back - is tested without a listener anywhere.
 */
export interface GroupListeners {
  /** Start answering on this port. Idempotent: opening one already open is fine. */
  open(port: number): Promise<void>
  /** Stop answering, and let the port be allocated again. */
  close(port: number): Promise<void>
  /** Which ports are currently bound, in ascending order. */
  bound(): number[]
}

/** Records what was asked for without binding anything. For tests. */
export class RecordingListeners implements GroupListeners {
  private open_ = new Set<number>()
  readonly opened: number[] = []
  readonly closed: number[] = []

  async open(port: number): Promise<void> {
    this.opened.push(port)
    this.open_.add(port)
  }

  async close(port: number): Promise<void> {
    this.closed.push(port)
    this.open_.delete(port)
  }

  bound(): number[] { return [...this.open_].sort((a, b) => a - b) }
}

/**
 * Real listeners, one per group.
 *
 * `make` builds a server for a port without listening; this owns when it binds
 * and when it stops. Separated that way because the server needs TLS material
 * and an Express app, neither of which belongs in the bookkeeping.
 */
export class BoundListeners implements GroupListeners {
  private servers = new Map<number, Server>()

  constructor(
    private readonly make: (port: number) => Server,
    private readonly log: (message: string) => void = () => {},
  ) {}

  async open(port: number): Promise<void> {
    if (this.servers.has(port)) return
    const server = this.make(port)
    await new Promise<void>((resolve, reject) => {
      // A port that is taken by something else fails here rather than leaving a
      // half-registered listener behind. The group still exists and the
      // operator gets a reason, which beats a silent gap between what the
      // database says a group answers on and what actually does.
      server.once('error', (err) => { this.servers.delete(port); reject(err) })
      server.listen(port, () => {
        this.servers.set(port, server)
        this.log(`[group] listening on :${port}`)
        resolve()
      })
    })
  }

  async close(port: number): Promise<void> {
    const server = this.servers.get(port)
    if (!server) return
    this.servers.delete(port)
    await new Promise<void>((resolve) => server.close(() => resolve()))
    this.log(`[group] released :${port}`)
  }

  bound(): number[] { return [...this.servers.keys()].sort((a, b) => a - b) }
}
