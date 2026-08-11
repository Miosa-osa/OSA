"""How much does OSA write to the terminal while it streams?

WHY THIS EXISTS
===============

Every other probe here asks whether the screen ends up CORRECT. This one asks
what it COST to get there, because the cost is itself a defect surface: the
owner runs inside tmux, often over a link, and a live region that repaints the
whole transcript on every token turns a 40-token/second stream into hundreds of
kilobytes a second of escape traffic. That is invisible locally and miserable
remotely, and no existing probe measures it.

WHAT IT MEASURES, ALL FROM THE REAL BYTE STREAM
===============================================

  * **bytes/sec** written to the PTY during the stream.
  * **bytes per delta** — the amortised cost of one token arriving.
  * **draws/sec** — counted as synchronized-update begins (`ESC[?2026h`),
    which ratatui wraps every completed frame in.
  * **rebuilds/sec** — counted as DSR cursor queries (`ESC[6n`), which the
    inline viewport emits once per re-anchor. A rebuild is far more expensive
    than a draw: it re-emits the whole live region undiffed.

There is no pass/fail gate: the useful form of this number is a comparison
between two binaries, or between two token rates. It prints a table.

Run:  python3 test/pty/throughput_probe.py --binary PATH [--rate 40]
"""

from __future__ import annotations

import argparse
import json
import queue
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from osa_pty import PtySession  # noqa: E402

PORT = 19151

_HEALTH = {
    "status": "ok",
    "version": "0.0.0-pty-throughput",
    "uptime_seconds": 0,
    "provider": "pty-stub",
    "model": "pty-stub",
    "context_window": 200000,
    "effort": "medium",
    "billing": None,
    "update": None,
}

PARA = (
    "The incremental typecheck cache is keyed on the resolved module graph, so "
    "a change to a path alias invalidates it wholesale rather than per file. "
    "That is why the second build disagreed with the first: the alias moved, "
    "the graph key changed, and every downstream module was re-resolved against "
    "a lockfile that still pinned the old resolver. "
)
REPLY = (PARA * 6).strip() + "\n"

CURSOR_HIDE = re.compile(rb"\x1b\[\?2026h")
ESCSEQ = re.compile(rb"\x1b(\][^\x07\x1b]*(?:\x07|\x1b\\)|\[[0-9;?]*[A-Za-z]|[A-Za-z0-9])")
DSR = re.compile(rb"\x1b\[6n")

RATE = {"tps": 40.0}


class _Bus:
    def __init__(self) -> None:
        self.q: "queue.Queue[tuple[str, dict]]" = queue.Queue()
        self.deltas = 0
        self.t_first: float | None = None
        self.t_last: float | None = None

    def send(self, event: str, data: dict) -> None:
        self.q.put((event, data))

    def script(self) -> None:
        def run() -> None:
            time.sleep(0.4)
            gap = 1.0 / RATE["tps"]
            for chunk in re.findall(r"\S+\s*", REPLY):
                if self.t_first is None:
                    self.t_first = time.time()
                self.send(
                    "streaming_token",
                    {"text": chunk, "session_id": "s", "message_id": "m1"},
                )
                self.deltas += 1
                self.t_last = time.time()
                time.sleep(gap)
            self.send(
                "agent_response",
                {
                    "response": REPLY,
                    "response_type": "text",
                    "signal": None,
                    "message_id": "m1",
                },
            )

        threading.Thread(target=run, daemon=True).start()


BUS = _Bus()


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *_a):
        pass

    def _json(self, payload, status: int = 200) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _sse(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            self.wfile.write(b'event: connected\ndata: {"session_id":"s"}\n\n')
            self.wfile.flush()
            while True:
                try:
                    ev, data = BUS.q.get(timeout=1.0)
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    continue
                blob = json.dumps(data).encode()
                self.wfile.write(b"event: " + ev.encode() + b"\ndata: " + blob + b"\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/health":
            return self._json(_HEALTH)
        if path.startswith("/api/v1/stream/"):
            return self._sse()
        if path in ("/api/v1/commands", "/api/v1/tools"):
            return self._json({"commands": [], "tools": []})
        if path in ("/api/v1/sessions", "/api/v1/sessions/recent"):
            return self._json({"sessions": []})
        if path == "/api/v1/permission-rules":
            return self._json({"rules": []})
        return self._json({})

    def do_POST(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        if path in ("/api/v1/auth/login", "/api/v1/auth/refresh"):
            return self._json({"token": "t", "refresh_token": "r", "expires_in": 3600})
        if path == "/api/v1/sessions":
            return self._json({"session_id": "s", "id": "s"})
        if path == "/api/v1/orchestrate":
            BUS.script()
            # `session_id` is REQUIRED by `client::generated::OrchestrateResponse`.
            # Omit it and the TUI reports "error decoding response body", never
            # enters `Processing`, and then silently drops every streaming_token
            # (`handle_backend.rs`, the `turn_is_active()` gate) — which makes a
            # stub-driven turn measure nothing a real turn does.
            return self._json({"session_id": "s", "status": "accepted"})
        return self._json({})


def type_and_submit(s: PtySession, text: str) -> None:
    for ch in text:
        s.write(ch.encode())
        s.pump(0.02)
    s.pump(0.3)
    s.write(b"\r")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=None)
    ap.add_argument("--cols", type=int, default=120)
    ap.add_argument("--rows", type=int, default=40)
    ap.add_argument("--rate", type=float, default=40.0, help="deltas per second")
    ap.add_argument("--label", default="current")
    args = ap.parse_args()
    RATE["tps"] = args.rate

    srv = ThreadingHTTPServer(("127.0.0.1", PORT), _Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        with PtySession(
            f"http://127.0.0.1:{PORT}",
            cols=args.cols,
            rows=args.rows,
            binary=Path(args.binary) if args.binary else None,
        ) as s:
            s.boot()
            type_and_submit(s, "explain the cache")
            s.pump(0.45)  # let the POST land; the stub waits 0.4s before token 1
            mark = s.mark()
            t0 = time.time()
            # Pump until the stub has finished emitting, plus a settle window.
            while BUS.t_last is None or time.time() - BUS.t_last < 1.0:
                s.pump(0.1)
                if time.time() - t0 > 60:
                    break
            elapsed = time.time() - t0
            emitted = s.emitted_since(mark)
    finally:
        srv.shutdown()

    n = len(emitted)
    draws = len(CURSOR_HIDE.findall(emitted))
    rebuilds = len(DSR.findall(emitted))
    deltas = max(BUS.deltas, 1)
    print()
    print(f"=== throughput [{args.label}] {args.cols}x{args.rows} @ {args.rate:g} tok/s ===")
    print(f"  stream window          : {elapsed:8.2f} s")
    print(f"  deltas sent            : {deltas:8d}")
    print(f"  bytes written to PTY   : {n:8d}  ({n / 1024:.1f} KiB)")
    print(f"  bytes / second         : {n / elapsed:8.0f}")
    print(f"  bytes / delta          : {n / deltas:8.0f}")
    print(f"  draws (ESC[?2026h)     : {draws:8d}   ({draws / elapsed:.1f}/s)")
    print(f"  viewport rebuilds (DSR): {rebuilds:8d}   ({rebuilds / elapsed:.1f}/s)")
    from collections import Counter

    kinds = Counter()
    for m in ESCSEQ.finditer(emitted):
        seq = m.group(0)
        kinds[seq if len(seq) <= 12 else seq[:6] + b"..."] += 1
    print("  top escape sequences:")
    for seq, c in kinds.most_common(12):
        print(f"      {seq!r:<24} {c:6d}")
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
