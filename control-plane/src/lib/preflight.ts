/**
 * What an installer may do about certificate material, given what it finds.
 *
 * The installer generates a certificate authority when it does not find one.
 * That is right on a new machine and catastrophic next to a database that
 * already has a fleet in it: every node's certificate was issued by the CA that
 * lives somewhere else, so a fresh one locks all of them out at once - and the
 * install reports success, because from its point of view nothing went wrong.
 *
 * The combination that says so is precise: **no CA here, and nodes there.** Not
 * an empty state directory (that is a first install) and not a populated one
 * (that is an upgrade, which already keeps what it finds). It is the pairing,
 * and nothing in the installer was looking at both halves.
 *
 * Decided here rather than in the shell so it can be tested. An installer's
 * dangerous branch is the one that runs on somebody else's machine, once, with
 * root, and is never seen again.
 */

export type CertAction = 'keep' | 'generate' | 'refuse'

export interface CertDecision {
  action: CertAction
  detail: string
}

export function certDecision(found: {
  /** Whether this machine already holds the fleet's CA. */
  caPresent: boolean
  /**
   * Nodes the database knows about, superseded ones excluded - they are history
   * rather than fleet, and a machine that re-enrolled is counted once by its
   * current identity.
   */
  enrolledNodes: number
  /** Where the CA would be written, for a message somebody can act on. */
  stateDir?: string
}): CertDecision {
  const where = found.stateDir ?? '/var/db/dai-control'

  if (found.caPresent) {
    return {
      action: 'keep',
      detail: 'keeping the certificate authority already here',
    }
  }

  if (found.enrolledNodes > 0) {
    const machines = found.enrolledNodes === 1 ? '1 machine' : `${found.enrolledNodes} machines`
    return {
      action: 'refuse',
      detail:
        `this database has ${machines} enrolled and there is no certificate authority `
        + `at ${where}.\n\n`
        + 'Those machines hold certificates issued by a CA that is somewhere else. '
        + 'Generating a new one here would lock every one of them out of the fleet at '
        + 'once, and they would have to be re-enrolled by hand - which needs somebody '
        + 'at each machine, because the Secure Enclave will not generate a key over ssh.\n\n'
        + 'Bring the existing authority instead:\n'
        + '    sudo ./install.sh --adopt-certs /path/to/certs ...\n\n'
        + 'It is the directory holding ca.crt, ca.key, server.crt, server.key and '
        + 'srv-ca.crt - in a working-tree deployment, control-plane/certs. If this '
        + 'really is a new fleet and those machines are gone, empty the nodes table '
        + 'first and run this again.',
    }
  }

  return {
    action: 'generate',
    detail: `generating a certificate authority at ${where}`,
  }
}
