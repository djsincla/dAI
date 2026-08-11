# Splitting a model across two machines, in Swift: what went wrong

One model, two machines, neither holding enough to answer alone. This is the
record of getting that working in Swift, written around the failures rather than
the design, because the failures are the part that transfers.

The run at the end of it:

```
rank 0                                  rank 1
listening on 7730, waiting for rank 1   connected to 127.0.0.1:7730
rank 0/2: layers 12..<24 loaded         rank 1/2: layers 0..<12 loaded
---
Three primary colours are red, blue, and yellow.
---
12 tokens, 3.35s to first, 46.4 tok/s, 0.19GB
```

Two operating system processes, mutual TLS between them, each holding half the
layers of Qwen2.5-0.5B-Instruct-4bit. The same model whole on one machine gives
the same sentence at 72.3 tok/s and 0.30GB.

**The throughput figures here are not a measurement of anything.** Both halves
were on one machine sharing one GPU, with a round trip over loopback per token,
in a debug build. The number worth reading is the memory: 0.19GB against 0.30GB,
because that is the entire point. The layers a machine does not own are never
referenced and so are never read off disk, which is how a model larger than any
one machine becomes servable at all. Real throughput needs the Thunderbolt
bridge and two machines.

## The errors

Nine of them, in the order they were hit. Four were silent: they produced a
wrong answer, a hang, or a green test run rather than an error.

---

### 1. A layer owned by nobody

**Looked like:** nothing. The model loaded, ran, and answered.

The obvious way to divide N layers over R machines is to give each machine
`N / R` layers starting at `(R - rank - 1) * (N / R)`. That is correct only when
the division is exact. With 80 layers over 3 machines the shares are 27, 27 and
26, and multiplying by *this* rank's own count leaves layer 26 belonging to no
one.

A skipped layer does not fail. The hidden state is the right shape, the next
machine accepts it, and the model computes fluently from a network that is not
the one on disk. The output is plausible and wrong, which is worse than a crash.

**Fix:** accumulate the boundaries instead of multiplying - a rank's start is
the sum of the counts of every rank above it. Tested by walking all three ranks
and asserting the ranges meet exactly and the counts sum to 80.

This one was found because it was asked for, not because anything failed.

---

### 2. The split reached the forward pass and nothing else

**Looked like:**

```
mismatchedSize(path: ["model", "layers", "0", "self_attn", "q_proj", "weight"],
               modules: [..., "Attention", "Linear"],
               expectedShape: [896, 896], actualShape: [896, 112])
```

which reads as "quantisation was not applied". It had been. `[896, 112]` is a
4-bit weight packed 8 to a word, being handed to a plain `Linear`.

The implementation built the whole model and then kept a slice of the layer
array. Everything said that worked: the config had 24 layers, the model reported
12 after the split, quantisation was decoded from the config, and the renumbered
weights contained exactly the 85 `.scales` keys the owned layers needed.

The evidence that settled it was a count. The quantisation filter was invoked
for **242** modules. A Qwen2 block holds ten leaf modules - four attention
projections, the rotary embedding, three feed-forward projections and two norms
- and the model adds an embedding and a final norm. Twelve layers is 122.
Twenty-four is 242.

`MLXNN.Module` records its children in a private cache during `init`, and
`items()` returns that cache rather than re-reading the properties. Assigning a
new array to `layers` afterwards is visible to the forward pass, which reads the
property, and invisible to quantisation and weight verification, which read the
cache. The model was running twelve layers while being quantised and checked as
twenty-four.

**Fix:** build the model with the layers it owns, by handing the constructor a
reduced `num_hidden_layers`. There is then only one truth. `pipeline()` now only
records the split and the transport, and says in a comment why it must not do
more.

Worth noting how close this came to being silent. It was caught by a shape
check, and only because the model is quantised. An unquantised model would have
had matching shapes throughout and would have loaded the wrong weights into the
wrong layers without complaint.

---

### 3. An address is not a name

**Looked like:**

```
NIOSSLExtraError.cannotUseIPAddressInSNI: IP addresses cannot validly be
used for Server Name Indication, got 127.0.0.1
```

SNI carries a hostname, and TLS forbids putting an address in it. NIOSSL
enforces that by throwing rather than by dropping the field.

This is not an edge case for this system. A machine on the Thunderbolt bridge is
192.168.99.2 and has no name anybody resolves.

**Fix:** offer no server name when the peer is reached by address. It costs
nothing, because a peer is trusted for presenting a certificate signed by the
fleet CA, not for what it is called, and the name was never checked.

---

### 4. The node CA was never given to the node

**Looked like:** `TLSV1_ALERT_UNKNOWN_CA`, received by the listening half.

There are two certificate authorities. The **server CA** signs the control
plane's certificate, and agents pin it so that a node can verify the control
plane. The **node CA** signs agent identities. The separation is deliberate: it
is what stops anything holding a node key from posing as the control plane.

Enrolment wrote the server CA to `ca.crt` and dropped the node CA on the floor,
with a comment explaining that the node CA "is not useful here". That was true
for as long as nodes only ever talked to the control plane. It stopped being
true the moment one machine had to verify another.

The control plane had been returning `nodeCaPem` in the enrolment response the
whole time. The agent read past it.

**Fix:** write it to `node-ca.crt`, in a second file rather than appended to the
first, so that trusting a peer never quietly widens what may pose as a control
plane. The peer connection pins `node-ca.crt`.

---

### 5. Client-auth-only certificates

**Looked like:** `verify error:num=26: unsuitable certificate purpose`, from
`openssl s_client`. Inside the agent it looked like a closed connection.

Node certificates carried `extendedKeyUsage = clientAuth` and nothing else,
under a comment reading "A node certificate must not be usable to impersonate
the control plane to another node". A sound instinct aimed at the wrong control.
A node is a client to the control plane and a **server** to another node: the
half holding the last layers listens, because it is the half that produces a
token.

The impersonation concern was already handled, and better, by the two CAs.
Nothing signed by the node CA can satisfy a client pinning the server CA,
whatever its key usage bits say.

**Fix:** issue with both `clientAuth` and `serverAuth`. Tested twice - once by
reading the extension, once by asking `openssl verify -purpose sslserver`, which
is the check that actually rejected it.

**Operational consequence:** every certificate issued before this change is
client-only, and every node enrolled before it has no `node-ca.crt`. Those nodes
can be the connecting half of a split but not the listening half.

They do not need re-enrolling. Renewal now exists and hands back both CAs, so a
node acquires what it was never given on its next renewal, or immediately with
`dai-agent renew <url> --force`.

---

### 6. The real reason was always overwritten

**Looked like:** `the other machine closed the link`, on both ends, for three
different underlying causes in a row.

`errorCaught` recorded the real failure and closed the channel. Closing makes
the channel go inactive, `channelInactive` fired, and it recorded "peer closed"
over the top. Every cause reached the operator as the same generic message.

This is why errors 4 and 5 each took a round of guessing: the handshake failures
were being reported as a network event.

**Fix:** keep the first reason. Tested.

---

### 7. Listening returned only once someone had arrived

**Looked like:** a deadlock at startup.

`listen()` returned the bound port, but only resolved after the peer connected.
The caller needs the port *before* the other machine can be told where to
connect, so nobody ever connected.

**Fix:** bind and return, and hold the accept as a separate future. Port 0 then
works properly too, which matters when a scheduler assigns ports.

---

### 8. One machine talking to a machine that was not there

**Looked like:** a hang, in the single-machine case only.

After sampling a token, the machine with the output head broadcasts it to the
others, because both halves must feed the *same* token into the next step. Left
to sample independently, the half without the output head reads meaningless
logits, picks a different token, and the two quietly diverge into a conversation
neither of them is having.

With one rank there is no other machine. A single rank is both the first and the
last, and the broadcast went to a peer that did not exist.

**Fix:** broadcast only when the model is actually split. The single-machine
path is kept because it is the baseline that says whether a wrong answer came
from the split or from the model.

---

### 9. Five tests that never ran

**Looked like:** a green test run.

The MLX tests skip themselves when the Metal shader bundle is absent, because
SwiftPM cannot compile those shaders - only `xcodebuild` produces
`mlx-swift_Cmlx.bundle`. Detection looked for the bundle next to `argv[0]`,
which under `xctest` is the test runner, not the product. So the tests skipped
under `xcodebuild` too, where the bundle was present and they should have run.

A skip that is reported as a pass is indistinguishable from a pass.

**Fix:** search `Bundle.allBundles`. The 5 tests now run under `xcodebuild` and
still skip under SwiftPM, which is the honest outcome for a toolchain that
cannot build the shaders.

---

### A tenth, from the Python prototype

Kept because the Swift port inherited the fix.

Non-zero ranks discarded the computed graph before evaluating it, so the `send`
inside the forward pass never dispatched. MLX is lazy: a graph nobody evaluates
is a hidden state that never leaves the machine. It surfaced as a Metal GPU
timeout, which points at the GPU rather than at the missing `eval`.

The Swift `step()` evaluates before handing on, with a comment saying why.

## What is tested

| | |
|---|---|
| Swift | 163 tests, green under SwiftPM and xcodebuild |
| Control plane | 347 tests |

The socket path is tested over loopback with a throwaway CA generated per run,
because a Secure Enclave key cannot be created inside a test process. The
signing differs; the handshake, framing, partial reads and peer loss above it
are the code that ships.

## Renewal

Certificates last thirty days on purpose. These live on laptops that leave the
building, and a machine that stops checking in should stop being a fleet member
on its own rather than because somebody remembered. That is only affordable if
the machines still here renew unattended, and until now they could not: expiry
was indistinguishable from an outage, and the remedy was visiting every machine
once a month.

A node renews by calling `POST /agent/v1/renew` with a new CSR, authenticated by
the certificate it already holds. That certificate proves it controls the key it
names, so there is nothing left for an admin to decide that was not decided at
approval. No token, no human.

- **Asked at two thirds of life**, which for a thirty-day certificate leaves ten
  days. The margin is how many consecutive failures a node can survive, and
  these are machines that spend weekends asleep. Expressed as a fraction rather
  than a number of days, so shortening what the CA issues tightens renewal with
  it instead of quietly leaving nodes renewing too late.
- **The old certificate stops working immediately.** Renewal replaces the
  fingerprint the control plane checks, so a loop still presenting the old one
  would be told it was unknown moments after renewing. The renewer therefore
  hands the loop a replacement client rather than only writing a file.
- **Refused for a revoked, superseded or already-expired node.** Renewal extends
  an identity; it does not resurrect one. Without the first of those, revoking a
  stolen machine would last only until it renewed itself back in.
- **Both CAs come back**, so a rotated CA reaches the fleet without anybody
  visiting it.

The Enclave key does not change, because it cannot leave the machine and has no
reason to. A CSR carrying a different key is accepted, for a machine that has
had to rebuild its key, and the change is recorded: it is the only trace of that
happening.

`dai-agent renew <url>` does it by hand, with `--force` for a machine that has
been off for a month or a fleet that has changed what a certificate must carry.

## Still missing

Named because they are load-bearing, not because they are nice to have.

- **Gang admission.** A split job must not start unless every member is present.
  Right now starting one without its partner produces a hang, and the scheduler
  has no concept of a job that needs two machines at once.
- **Losing half a model mid-token.** One process disappearing currently ends
  both. There is no re-plan and no fallback to a smaller model.
- **Routing.** A split model should present as one servable endpoint. The half
  with the output head is the one to address, but nothing yet publishes that.
