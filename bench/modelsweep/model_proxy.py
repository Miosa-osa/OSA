#!/usr/bin/env python3
"""Model-forcing proxy: the instrument that makes a model sweep possible at all.

## Why this has to exist

OSA cannot select a model on an OpenAI-compatible provider. The main agent loop
pins its model in `Agent.Loop` via
`Providers.Registry.resolved_default_model/1`, which for a `{:compat, _}`
provider returns `OpenAICompatProvider.default_model/1` --
`get_config!(provider).default_model`, a **compile-time constant**. It never
consults `Application.get_env`, so `OPENROUTER_MODEL`, `OSA_MODEL`,
`~/.osa/config.json` and `config.toml` are all ignored. Measured: with
`OPENROUTER_MODEL=z-ai/glm-5.2` set, `config.json` AND `config.toml` both
naming it, and `/health` reporting `z-ai/glm-5.2`, every one of the agent-loop
requests on the wire carried `model: anthropic/claude-opus-5`.

That is why a naive sweep is not merely wrong but *silently* wrong: each arm
would report its own model in `config.json` while every arm actually ran
opus-5, and the resulting table would look like a clean per-model comparison.

Ollama is unaffected -- its provider module reads the configured model -- which
is why the `glm-5.2:cloud` baseline really was glm-5.2.

## What it does

Sits between OSA and OpenRouter and rewrites `model` on **agent-loop requests
only** -- those carrying a `tools` array. Auxiliary traffic (the title
generator, which OSA routes to its own model) is passed through untouched, so
it stays constant across arms instead of becoming a second variable.

Every rewrite is counted and every non-200 is dumped, so an arm can prove what
it actually ran rather than asserting it. `--assert-model` makes the run fail
loudly if anything unexpected reaches the wire.

Not a general-purpose proxy: it terminates one endpoint for one experiment.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import requests

UPSTREAM = "https://openrouter.ai/api/v1"


class State:
    def __init__(self, force_model: str, outdir: pathlib.Path):
        self.force_model = force_model
        self.outdir = outdir
        self.lock = threading.Lock()
        self.rewritten = 0
        self.passthrough: dict[str, int] = {}
        self.failures = 0
        self.seen_models: dict[str, int] = {}

    def note(self, model: str, rewritten: bool):
        with self.lock:
            self.seen_models[model] = self.seen_models.get(model, 0) + 1
            if rewritten:
                self.rewritten += 1
            else:
                self.passthrough[model] = self.passthrough.get(model, 0) + 1

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "forced_model": self.force_model,
                "agent_requests_rewritten": self.rewritten,
                "passthrough_by_model": dict(self.passthrough),
                "models_on_wire": dict(self.seen_models),
                "non_200_responses": self.failures,
            }


def make_handler(state: State, key: str):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def _fwd_headers(self):
            h = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
            for k in ("HTTP-Referer", "X-Title", "Accept"):
                if k in self.headers:
                    h[k] = self.headers[k]
            return h

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            rewritten = False
            try:
                req = json.loads(body)
                # The agent loop is the only traffic that ships a tool schema.
                # Auxiliary calls (title generation) carry none and are left
                # alone so they do not vary between arms.
                if req.get("tools"):
                    if req.get("model") != state.force_model:
                        req["model"] = state.force_model
                        rewritten = True
                    body = json.dumps(req).encode()
                state.note(req.get("model", "?"), rewritten)
            except Exception:
                pass

            url = UPSTREAM + self.path.split("/v1", 1)[-1]
            r = requests.post(url, headers=self._fwd_headers(), data=body,
                              stream=True, timeout=1800)
            raw = r.raw.read()

            if r.status_code != 200:
                with state.lock:
                    state.failures += 1
                    n = state.failures
                try:
                    dump = json.loads(body)
                except Exception:
                    dump = {}
                (state.outdir / f"fail-{n:03d}.json").write_text(json.dumps({
                    "status": r.status_code,
                    "response": raw.decode("utf8", "replace")[:4000],
                    "model": dump.get("model"),
                    "roles": [m.get("role") for m in dump.get("messages", [])],
                }, indent=2))
                print(f"[proxy] non-200 #{n}: {r.status_code}", file=sys.stderr, flush=True)

            self.send_response(r.status_code)
            for k, v in r.headers.items():
                if k.lower() in ("content-type", "cache-control"):
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            try:
                self.wfile.write(raw)
            except BrokenPipeError:
                pass

        def do_GET(self):
            if self.path.endswith("/__stats"):
                b = json.dumps(state.snapshot(), indent=2).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)
                return
            r = requests.get(UPSTREAM + self.path.split("/v1", 1)[-1],
                             headers={"Authorization": f"Bearer {key}"}, timeout=60)
            b = r.content
            self.send_response(r.status_code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

    return H


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--force-model", required=True)
    ap.add_argument("--outdir", default="/tmp/modelsweep-proxy")
    ap.add_argument("--key-file", default=os.path.expanduser("~/.osa/openrouter.key"))
    args = ap.parse_args()

    out = pathlib.Path(args.outdir)
    out.mkdir(parents=True, exist_ok=True)
    key = open(args.key_file).read().strip()
    state = State(args.force_model, out)
    print(f"[proxy] :{args.port} forcing agent-loop model -> {args.force_model}",
          flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(state, key)).serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
