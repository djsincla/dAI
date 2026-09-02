# Security

## Reporting a vulnerability

Use GitHub's **[private vulnerability reporting](https://github.com/djsincla/dAI/security/advisories/new)**
on this repository. It reaches the maintainer without the report being public
first, and it does not require an email address from either side.

Please do not open a public issue for anything exploitable.

A personal research project with one maintainer. No response SLA and no bounty.
Reports get an answer, and a note here if they change the design.

## What this software is

dAI installs a `LaunchDaemon` on every participating machine, runs an updater as
root, operates a certificate authority, and issues client certificates that
admit machines to a fleet. It is built to run inside one building on a trusted
network, not exposed to the internet.

It runs on a fleet of two, has no users other than its author, and has never
been installed onto a clean machine.

## Reported already, or visible by design

**`DEFAULT_PASSWORD = 'admin'` in `control-plane/src/lib/password.ts`.** The
bootstrap account is created with it once, on a database that has no other
account with a password, and `must_change_password` is set at the same time.
`lib/auth.ts` then refuses every authenticated route except the password change
until that flag clears, so an untouched deployment cannot be driven with the
default - it can only be used to set a real password. `checkPassword` also
refuses `admin` as the replacement.

**`postgres://dai:dai@localhost:5433/dai` throughout the READMEs and scripts.**
A local development default for a database bound to loopback, and the string a
reader needs in order to run the tests. Deployments pass `--db` to `install.sh`,
which writes the real URL into the daemon's plist.

**The certificate in `agent/Tests/DaiAgentTests/PipelineChannelTests.swift`.** A
self-signed test fixture with no private key beside it, so that the fingerprint
is computed over real DER rather than over a string.

## Known weaknesses

- **Isolation is policy-enforced, not hardware-enforced.** Apple Silicon shares
  one memory pool between the agent and whoever is sitting at the machine. The
  agent yields on presence and holds a memory ceiling, but nothing in the
  hardware enforces it. The README lists this as the central risk of the design;
  it is a security property as well as a social one.
- **The peer link between split ranks is mTLS pinned to the node CA**, over
  whatever interface the node declares. A machine that can present a valid node
  certificate can join a pipeline.
- **The agent executes work the control plane sends it.** That is what it is
  for. It runs as a service account rather than root, and the updater - which
  does run as root - is a separate job precisely so the process executing fleet
  payloads cannot rewrite its own binary.
- **No `.pkg` has been installed on a clean machine in CI.** Packaging faults
  here have not been visible to any test of the repository, which is why
  `control-plane/packaging/verify-pkg.sh` takes a built `.pkg` apart. CI now
  runs the packaging suite on a machine that is not the author's, which found
  three tests reading the developer's laptop rather than the code, and a bug in
  `install.sh` that would have failed the documented MDM install. Nothing runs
  `installer -pkg` onto a fresh machine.

## Supported versions

The most recent release. Nothing older is patched.
