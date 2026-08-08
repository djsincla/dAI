#!/usr/bin/env python3
"""
OpenAI-compatible serving front-end for a cluster-tier pool.

This is the reason the cluster tier exists. E6 measured sharding at 6.6x slower
than one machine, so it is never a speed decision; it is how a pool serves a
model no single node can hold. Everything here assumes that framing.

**Why this cannot run on the harvest tier.** Interactive serving needs a
resident model and low latency, and preemption is fatal to both. Harvest nodes
only accept GPU work when LOCKED or ABSENT, poll rather than being pushed to,
and unload mid-unit the moment someone touches the keyboard. A synchronous
request against that fleet would simply hang through the working day.

**The lockstep problem.** Tensor parallelism means every rank executes the same
forward pass and all-reduces after each block. HTTP arrives at one node, so the
prompt has to reach the others before any of them can start, and every rank must
select the same token or the ranks diverge into different sequences.

The protocol is deliberately minimal, built on the only primitive that is always
available: a collective. Non-root ranks block in an all_sum, which is a natural
barrier, so they need no polling loop and no second channel.

    control = all_sum([flag, prompt_len, max_tokens, seed])
    tokens  = all_sum(padded prompt)          # only if flag == GENERATE
    ...all ranks generate in lockstep, rank 0 keeps the text...

Requests are serialised on rank 0. The whole pool is one model, so concurrency
would mean interleaving two lockstep sequences across the same ranks.

    # every rank, rank 0 last so the others are already waiting
    MLX_HOSTFILE=hosts.json MLX_RANK=1 python serve.py --model ...
    MLX_HOSTFILE=hosts.json MLX_RANK=0 python serve.py --model ... --port 8500
"""

import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import mlx.core as mx

SHUTDOWN, GENERATE = 0, 1
CTRL_LEN = 4          # [flag, prompt_len, max_tokens, seed]
MAX_PROMPT = 4096     # padded broadcast width

# Comm-only ceiling realisation measured end to end on gigabit: 11.69 tok/s
# against a 31.72 ceiling. Serving on the raw ceiling would advertise 2.7x what
# the pool delivers.
CEILING_REALISATION = 0.37


def broadcast(values, group, width):
    """Share a vector from rank 0 to every rank.

    all_sum with zeros everywhere but the root is a broadcast, and it doubles as
    the barrier that keeps the ranks aligned. Using send/recv would need an
    explicit topology; this works on any group.
    """
    if group.rank() == 0:
        payload = mx.array(list(values) + [0] * (width - len(values)), dtype=mx.int32)
    else:
        payload = mx.zeros((width,), dtype=mx.int32)
    out = mx.distributed.all_sum(payload, group=group)
    mx.eval(out)
    return out


class ShardedModel:
    def __init__(self, model_name, group):
        self.group = group
        self.name = model_name
        from mlx_lm import load
        from mlx_lm.sample_utils import make_sampler

        t0 = time.perf_counter()
        # lazy=True is mandatory, not an optimisation. Eager loading peaks at
        # 5.01 GB against a 3.99 GB model because each rank briefly holds full
        # weights and its slice at once, so a pool would OOM on exactly the
        # model the extra machines were bought for.
        self.model, self.tokenizer = load(model_name, lazy=True)
        if group.size() > 1:
            self.model.shard(group)
        mx.eval(self.model.parameters())
        self.load_s = time.perf_counter() - t0
        self.resident_gb = mx.get_active_memory() / (1 << 30)
        self.peak_gb = mx.get_peak_memory() / (1 << 30)
        self._make_sampler = make_sampler

    def generate(self, tokens, max_tokens, seed):
        """Run one completion. Every rank calls this with identical arguments."""
        from mlx_lm import stream_generate

        # Seeding every rank identically keeps sampling in lockstep. Logits are
        # all-reduced so the ranks see the same distribution, but they each draw
        # from it locally; without a shared seed they would diverge into
        # different sequences after the first sampled token.
        mx.random.seed(seed)
        sampler = self._make_sampler(temp=0.0)

        pieces = []
        for response in stream_generate(self.model, self.tokenizer, tokens,
                                        max_tokens=max_tokens, sampler=sampler):
            pieces.append(response.text)
        return "".join(pieces)


def worker_loop(shard, group):
    """Non-root ranks: block on the control broadcast until rank 0 has work.

    No polling and no second channel. all_sum does not return until every rank
    has called it, so a rank waiting here is exactly a rank ready to serve.
    """
    while True:
        ctrl = broadcast([], group, CTRL_LEN)
        flag, prompt_len, max_tokens, seed = (int(v) for v in ctrl.tolist())
        if flag == SHUTDOWN:
            return
        tokens = broadcast([], group, MAX_PROMPT)
        prompt = [int(v) for v in tokens.tolist()[:prompt_len]]
        # Output is discarded here; only rank 0 answers the client. This rank's
        # job is to hold its slice of the weights and participate.
        shard.generate(prompt, max_tokens, seed)


class Server:
    def __init__(self, shard, group):
        self.shard = shard
        self.group = group
        # One model spread over the pool means one sequence at a time.
        # Concurrency would interleave two lockstep runs across the same ranks.
        self.lock = threading.Lock()
        self.seed = 0

    def complete(self, messages, max_tokens):
        with self.lock:
            tokenizer = self.shard.tokenizer
            prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
            if len(prompt) > MAX_PROMPT:
                raise ValueError(f"prompt of {len(prompt)} tokens exceeds {MAX_PROMPT}")

            self.seed = (self.seed + 1) % (2**31 - 1)
            t0 = time.perf_counter()
            if self.group.size() > 1:
                broadcast([GENERATE, len(prompt), max_tokens, self.seed],
                          self.group, CTRL_LEN)
                broadcast(prompt, self.group, MAX_PROMPT)
            text = self.shard.generate(prompt, max_tokens, self.seed)
            elapsed = time.perf_counter() - t0
            return text, len(prompt), elapsed

    def shutdown_ranks(self):
        if self.group.size() > 1:
            broadcast([SHUTDOWN, 0, 0, 0], self.group, CTRL_LEN)


def make_handler(server: Server, model_name: str):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def _send(self, payload, code=200):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path in ("/v1/models", "/models"):
                self._send({"object": "list", "data": [
                    {"id": model_name, "object": "model", "owned_by": "dai"}]})
                return
            if self.path == "/healthz":
                self._send({"ok": True, "nodes": server.group.size(),
                            "residentGb": round(server.shard.resident_gb, 2)})
                return
            self._send({"error": {"message": "not found"}}, 404)

        def do_POST(self):
            if self.path not in ("/v1/chat/completions", "/chat/completions"):
                self._send({"error": {"message": "not found"}}, 404)
                return
            length = int(self.headers.get("Content-Length", 0))
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
                messages = body["messages"]
                max_tokens = int(body.get("max_tokens", 256))
            except (json.JSONDecodeError, KeyError, ValueError) as exc:
                self._send({"error": {"message": f"bad request: {exc}"}}, 400)
                return

            try:
                text, prompt_tokens, elapsed = server.complete(messages, max_tokens)
            except Exception as exc:
                self._send({"error": {"message": str(exc)}}, 500)
                return

            completion_tokens = len(server.shard.tokenizer.encode(text))
            self._send({
                "id": f"chatcmpl-{int(time.time() * 1000)}",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": model_name,
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": text},
                    "finish_reason": "stop",
                }],
                "usage": {
                    "prompt_tokens": prompt_tokens,
                    "completion_tokens": completion_tokens,
                    "total_tokens": prompt_tokens + completion_tokens,
                },
                # Not part of the OpenAI schema, but the number that decides
                # whether this pool is worth serving from at all.
                "dai": {
                    "nodes": server.group.size(),
                    "seconds": round(elapsed, 3),
                    "tokens_per_second": round(completion_tokens / elapsed, 2) if elapsed else 0,
                },
            })

    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True)
    ap.add_argument("--port", type=int, default=8500)
    ap.add_argument("--min-tok-s", type=float, default=0.0,
                    help="refuse to serve below this measured throughput")
    args = ap.parse_args()

    group = mx.distributed.init(backend="ring")
    rank, size = group.rank(), group.size()

    shard = ShardedModel(args.model, group)
    if rank == 0:
        print(json.dumps({
            "event": "loaded", "model": args.model, "nodes": size,
            "load_s": round(shard.load_s, 2),
            "resident_gb": round(shard.resident_gb, 2),
            "peak_gb": round(shard.peak_gb, 2),
        }), flush=True)

    if rank != 0:
        worker_loop(shard, group)
        return 0

    server = Server(shard, group)

    # Measure before advertising. A pool that cannot clear the floor should say
    # so at startup rather than serving something unusable, and the measurement
    # is one real completion rather than a projection: the comm-only ceiling
    # proved 2.7x optimistic against actual generation.
    if args.min_tok_s > 0:
        _, _, elapsed = server.complete(
            [{"role": "user", "content": "Say hello in one short sentence."}], 32)
        rate = 32 / elapsed if elapsed else 0
        print(json.dumps({"event": "admission", "measured_tok_s": round(rate, 2),
                          "floor": args.min_tok_s}), flush=True)
        if rate < args.min_tok_s:
            print(json.dumps({
                "event": "refused",
                "reason": f"{rate:.1f} tok/s is below the {args.min_tok_s} floor. "
                          f"Model depth times all-reduce latency bounds this: a "
                          f"faster interconnect is the only fix.",
            }), flush=True)
            server.shutdown_ranks()
            return 2

    httpd = ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(server, args.model))
    print(json.dumps({"event": "serving", "port": args.port,
                      "endpoint": f"http://0.0.0.0:{args.port}/v1/chat/completions"}),
          flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown_ranks()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
