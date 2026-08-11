"""Does every assistant turn carry its `◈ OSA` label?

THE RULE
========

One turn renders exactly ONE `◈ OSA` header row, above the first assistant text
of that turn. Never zero (the reply looks like it came from nobody), never two
(one answer split into two labelled blocks).

WHY A PTY AND NOT A UNIT TEST
=============================

The flag that decides the header (`App::agent_header_sent`) is driven from the
backend event stream, and the interesting orderings are orderings of SSE events
— tool-call-before-text, text-then-tool-then-text. Driving the real binary over
a real stream is the only way to exercise the same transitions the owner hits.

THE THREE SHAPES
================

  T1  tool_call(start) → streamed text → tool_result
      The model goes straight to a tool with NO preamble, then answers.
      This is the overwhelmingly common shape in tool-heavy use.

  T2  streamed text only
      The control: a plain answer with no tool at all.

  T3  streamed text → tool_call(start) → more streamed text → tool_result
      The model speaks, calls a tool, speaks again. One turn, one header.

Each turn is checked in the scrolled-off history as well as on screen, and the
count is taken over the rows belonging to that turn only (turns are delimited by
the `❯  You` row that opens each of them).

Run:  python3 test/pty/header_probe.py [--binary PATH] [--cols N] [--rows N]
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

PORT = 19143

_HEALTH = {
    "status": "ok",
    "version": "0.0.0-pty-header",
    "uptime_seconds": 0,
    "provider": "pty-stub",
    "model": "pty-stub",
    "context_window": 200000,
    "effort": "medium",
    "billing": None,
    "update": None,
}

# Short, one-row replies: this probe is about the header row, not about wrapping.
T1_REPLY = "The build is green and the bundle is under budget."
T2_REPLY = (
    "Nothing regressed at all; the incremental cache was simply stale and the "
    "resolver never re-ran, which is why the second build disagreed with the first."
)
T3_HEAD = (
    "Let me look at the lockfile before I answer, because the resolver version "
    "is pinned there and nothing else in the tree records it."
)
T3_TAIL = "The lockfile pinned an old resolver."

TOOL_OUTPUT = "ok\n"

# The label the transcript draws above the first assistant block of a turn.
# `components/chat/message.rs` draws the glyph and the word; matching the glyph
# alone would also match the status-bar's `⟐`, so require both.
HEADER = re.compile(r"◈\s+OSA")
USER_ROW = re.compile(r"❯\s+You")


class _Bus:
    def __init__(self) -> None:
        self.q: "queue.Queue[tuple[str, dict]]" = queue.Queue()

    def send(self, event: str, data: dict) -> None:
        self.q.put((event, data))

    def _tokens(self, text: str, mid: str, gap: float = 0.03) -> None:
        for chunk in re.findall(r"\S+\s*", text):
            self.send(
                "streaming_token",
                {"text": chunk, "session_id": "s", "message_id": mid},
            )
            time.sleep(gap)

    def _tool_start(self, call_id: str) -> None:
        self.send(
            "tool_call",
            {
                "name": "shell_execute",
                "phase": "start",
                "args": json.dumps({"command": "ls"}),
                "tool_call_id": call_id,
            },
        )
        self.send(
            "command_output_delta",
            {
                "command": "ls",
                "chunk": TOOL_OUTPUT,
                "tail": "ok",
                "seq": 0,
                "tool_call_id": call_id,
            },
        )

    def _tool_end(self, call_id: str) -> None:
        self.send(
            "tool_result",
            {
                "name": "shell_execute",
                "result": "ok",
                "success": True,
                "tool_call_id": call_id,
            },
        )
        self.send(
            "tool_call",
            {
                "name": "shell_execute",
                "phase": "end",
                "duration_ms": 120,
                "success": True,
                "tool_call_id": call_id,
            },
        )

    def _finish(self, text: str, mid: str) -> None:
        self.send(
            "agent_response",
            {
                "response": text,
                "response_type": "text",
                "signal": None,
                "message_id": mid,
            },
        )

    def script_tool_first(self) -> None:
        def run() -> None:
            time.sleep(0.35)
            self._tool_start("c1")
            time.sleep(0.25)
            self._tool_end("c1")
            time.sleep(0.2)
            self._tokens(T1_REPLY, "m1")
            self._finish(T1_REPLY, "m1")

        threading.Thread(target=run, daemon=True).start()

    def script_text_only(self) -> None:
        def run() -> None:
            time.sleep(0.35)
            self._tokens(T2_REPLY, "m2", gap=0.12)
            self._finish(T2_REPLY, "m2")

        threading.Thread(target=run, daemon=True).start()

    def script_text_tool_text(self) -> None:
        def run() -> None:
            time.sleep(0.35)
            self._tokens(T3_HEAD, "m3")
            time.sleep(1.2)
            self._tool_start("c3")
            time.sleep(0.25)
            self._tool_end("c3")
            time.sleep(0.2)
            self._tokens(T3_TAIL, "m3b")
            self._finish(
                (T3_HEAD + " " + T3_TAIL) if FULL_RESPONSE["on"] else T3_TAIL,
                "m3b",
            )

        threading.Thread(target=run, daemon=True).start()


FULL_RESPONSE = {"on": False}
TRACE = {"on": False, "turn": 2}
BUS = _Bus()
TURN = {"n": 0}
SCRIPTS = ["tool_first", "text_only", "text_tool_text"]


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
        if path == "/api/v1/commands":
            return self._json({"commands": []})
        if path == "/api/v1/tools":
            return self._json({"tools": []})
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
            which = SCRIPTS[min(TURN["n"], len(SCRIPTS) - 1)]
            getattr(BUS, "script_" + which)()
            TURN["n"] += 1
            # `OrchestrateResponse` REQUIRES `session_id`; omitting it makes the
            # TUI fail to decode the 202, report "error decoding response body"
            # and never enter `Processing` — which silently drops every
            # `streaming_token` (`handle_backend.rs`, `turn_is_active()` gate).
            return self._json({"session_id": "s", "status": "accepted"})
        return self._json({})


def type_and_submit(s: PtySession, text: str) -> None:
    for ch in text:
        s.write(ch.encode())
        s.pump(0.02)
    s.pump(0.3)
    s.write(b"\r")


def history(s: PtySession) -> list[str]:
    """Every row the session has produced — `lines()` already spans history."""
    return s.lines()


def turns(rows: list[str]) -> list[tuple[int, list[str]]]:
    """Split the transcript at each `❯  You` row."""
    starts = [i for i, r in enumerate(rows) if USER_ROW.search(r)]
    out = []
    for n, i in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(rows)
        out.append((i, rows[i:end]))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=None)
    ap.add_argument("--cols", type=int, default=100)
    ap.add_argument("--rows", type=int, default=24)
    ap.add_argument(
        "--full-response",
        action="store_true",
        help="turn 3's final agent_response carries the WHOLE turn (preamble + tail), "
        "which is what a backend that accumulates the turn sends",
    )
    ap.add_argument("--trace", action="store_true")
    ap.add_argument("--trace-turn", type=int, default=2)
    args = ap.parse_args()
    ap_trace = getattr(args, "trace", False)
    FULL_RESPONSE["on"] = args.full_response
    TRACE["on"] = ap_trace
    TRACE["turn"] = args.trace_turn

    srv = ThreadingHTTPServer(("127.0.0.1", PORT), _Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    failures: list[str] = []
    try:
        with PtySession(
            f"http://127.0.0.1:{PORT}",
            cols=args.cols,
            rows=args.rows,
            binary=Path(args.binary) if args.binary else None,
        ) as s:
            s.boot()
            prompts = ("run the build", "why did it regress", "check the lockfile")
            for n, prompt in enumerate(prompts):
                type_and_submit(s, prompt)
                if TRACE["on"] and n == int(TRACE["turn"]):
                    # Sample the whole of turn 3 so the moment the preamble is
                    # (or is not) committed ahead of the tool cell is visible.
                    for k in range(20):
                        s.pump(0.2)
                        rows = [r for r in s.lines() if r.strip()]
                        print(f"--- t+{(k + 1) * 0.2:.1f}s")
                        for r in rows[-8:]:
                            print("   |" + r)
                else:
                    s.pump(4.0)
            s.pump(1.5)
            rows = history(s)
    finally:
        srv.shutdown()

    labels = ["T1 tool-first", "T2 text-only", "T3 text/tool/text"]
    found = turns(rows)
    print("===== TRANSCRIPT =====")
    for i, r in enumerate(rows):
        print(f"{i:4}|{r}")
    print()

    if len(found) < 3:
        failures.append(f"expected 3 turns, found {len(found)}")
    for n, (start, block) in enumerate(found[:3]):
        count = sum(1 for r in block if HEADER.search(r))
        name = labels[n] if n < len(labels) else f"turn {n}"
        print(f"  {name}: rows {start}..{start + len(block)}  ◈ OSA headers = {count}")
        if count != 1:
            failures.append(
                f"{name}: expected exactly 1 `◈ OSA` header, found {count}\n"
                + "\n".join(f"      | {r}" for r in block)
            )

    # T3's preamble must not vanish: the model said something BEFORE the tool.
    if len(found) >= 3:
        block = found[2][1]
        if not any(T3_HEAD[:20] in r for r in block):
            failures.append(
                "T3: the assistant preamble spoken BEFORE the tool call "
                f"({T3_HEAD!r}) is missing from the transcript"
            )

    print()
    print("=" * 70)
    if failures:
        print("VERDICT: FAIL")
        for f in failures:
            print("  ✗ " + f)
        return 1
    print("VERDICT: PASS — every turn carries exactly one `◈ OSA` header")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
