"""Reproduce the two defects visible in the owner's live screenshot.

The report, verbatim: "it's like rendering the way it does it over its own
things" and "there's a ton of space". Concretely, on one 30-row screen:

  * ~11 consecutive blank rows between a committed assistant line and the
    following `● Bash(...)` cell — a region reserving rows it never draws;
  * a rendered line reading `Build's1greene— 976rmodules,xclean typecheck.`
    where the text was `Build's green — 976 modules, clean typecheck.` — ANSI
    escapes partly consumed, remainder printed as literal text.

The Rust suite was green throughout, because it renders through a perfect
in-process emulator against reservations it computed itself. This drives the
REAL binary on a REAL PTY through the sequence that produced the screen:

    assistant message  ->  tool call streaming ANSI-coloured output  ->
    tool result  ->  assistant message

and dumps the screen so both claims can be read off a real capture rather than
inferred.

Run:  python3 test/pty/blank_rows_probe.py [--binary PATH]
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

PORT = 19131

_HEALTH = {
    "status": "ok",
    "version": "0.0.0-pty-blank-rows",
    "uptime_seconds": 0,
    "provider": "pty-stub",
    "model": "pty-stub",
    "context_window": 200000,
    "effort": "medium",
    "billing": None,
    "update": None,
}

# The exact prose from the screenshot, so the corrupted render is comparable
# character for character. The ANSI is what a build tool really emits: SGR
# colour around the status word, and an OSC 8 hyperlink, which is the case a
# CSI-only escape skipper gets wrong.
GREEN = "\x1b[32m"
RESET = "\x1b[0m"
BOLD = "\x1b[1m"
OSC8_ON = "\x1b]8;;http://localhost:5173\x1b\\"
OSC8_OFF = "\x1b]8;;\x1b\\"

BUILD_OUTPUT = [
    f"{BOLD}vite v5.4.10{RESET} building for production...",
    "transforming...",
    f"{GREEN}✓{RESET} 976 modules transformed.",
    f"dist/index.html  {GREEN}0.46 kB{RESET}",
    f"dist/assets/index-4f2c.css  {GREEN}12.10 kB{RESET}",
    f"{GREEN}✓ built in 3.41s{RESET}",
    f"preview at {OSC8_ON}http://localhost:5173{OSC8_OFF}",
]

REPLY_1 = "Now the real verification — typecheck plus production build."
REPLY_2 = "Build's green — 976 modules, clean typecheck."


class _Bus:
    _resize_hook = None

    def __init__(self) -> None:
        self.q: "queue.Queue[tuple[str, dict]]" = queue.Queue()

    def send(self, event: str, data: dict) -> None:
        self.q.put((event, data))

    def script(self) -> None:
        """One turn: message, ANSI-heavy tool, message."""

        def run() -> None:
            time.sleep(0.5)
            # ── first assistant message, streamed then finalized ──
            for chunk in re.findall(r"\S+\s*", REPLY_1):
                self.send(
                    "streaming_token",
                    {"text": chunk, "session_id": "s", "message_id": "m1"},
                )
                time.sleep(0.02)
            self.send(
                "agent_response",
                {
                    "response": REPLY_1,
                    "response_type": "text",
                    "signal": None,
                    "message_id": "m1",
                },
            )
            time.sleep(0.4)

            # ── a shell tool streaming coloured build output ──
            self.send(
                "tool_call",
                {
                    "name": "shell_execute",
                    "phase": "start",
                    "args": json.dumps({"command": "tsc -b && vite build"}),
                    "tool_call_id": "call-1",
                },
            )
            tail = ""
            for i, line in enumerate(BUILD_OUTPUT):
                tail = line
                self.send(
                    "command_output_delta",
                    {
                        "command": "tsc -b && vite build",
                        "chunk": line + "\n",
                        "tail": tail,
                        "seq": i,
                        "tool_call_id": "call-1",
                    },
                )
                time.sleep(0.12)
            self.send(
                "tool_result",
                {
                    "name": "shell_execute",
                    "result": "\n".join(BUILD_OUTPUT),
                    "success": True,
                    "tool_call_id": "call-1",
                },
            )
            self.send(
                "tool_call",
                {
                    "name": "shell_execute",
                    "phase": "end",
                    "duration_ms": 3400,
                    "success": True,
                    "tool_call_id": "call-1",
                },
            )
            time.sleep(0.4)

            # ── MID-TURN HOLD (the owner's screenshot) ──
            # A second tool runs and finishes, so the activity feed carries its
            # `$ executing` rows, and then the turn simply STAYS OPEN waiting on
            # the provider. No `agent_response`. This is the exact state in the
            # report: a committed tool cell above, the live activity band below,
            # and the blank band between them.
            for call in ("call-2", "call-3"):
                self.send("tool_call", {
                    "name": "shell_execute", "phase": "start",
                    "args": json.dumps({"command": f"git status {call}"}),
                    "tool_call_id": call,
                })
                time.sleep(0.15)
                self.send("tool_result", {
                    "name": "shell_execute", "result": "ok",
                    "success": True, "tool_call_id": call,
                })
                self.send("tool_call", {
                    "name": "shell_execute", "phase": "end",
                    "duration_ms": 157, "success": True, "tool_call_id": call,
                })
                time.sleep(0.3)
            # Hold here — the turn never completes, exactly as in the screenshot.
            # A RESIZE lands mid-turn: this is the ingredient every other probe
            # lacks. Under tmux the strategy is `Surgical`, which erases from the
            # OLD region top downward while the rebuild re-anchors bottom — so a
            # region that SHRANK leaves the difference blank. tmux fires these on
            # focus changes and splits, which is why the band is constant in a
            # real session and invisible in every test.
            time.sleep(4.0)

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
            BUS.script()
            return self._json({"status": "accepted"})
        return self._json({})


def type_and_submit(s: PtySession, text: str) -> None:
    for ch in text:
        s.write(ch.encode())
        s.pump(0.02)
    s.pump(0.35)
    s.write(b"\r")


def dump(s: PtySession, label: str) -> list[str]:
    rows = [s.screen.display[y].rstrip() for y in range(s.rows)]
    print(f"\n{'=' * 78}\n{label}\n{'=' * 78}")
    for y, row in enumerate(rows):
        print(f"{y:>3} |{row}")
    return rows


def report_blank_runs(rows: list[str]) -> None:
    """Longest run of blank rows that has content both above and below it."""
    runs = []
    y = 0
    while y < len(rows):
        if rows[y].strip():
            y += 1
            continue
        start = y
        while y < len(rows) and not rows[y].strip():
            y += 1
        above = any(rows[i].strip() for i in range(0, start))
        below = any(rows[i].strip() for i in range(y, len(rows)))
        if above and below:
            runs.append((start, y - start))
    print("\n-- interior blank-row runs (start, length) --")
    print(runs if runs else "none")
    if runs:
        worst = max(runs, key=lambda r: r[1])
        print(f"LONGEST INTERIOR BLANK RUN: {worst[1]} rows, starting at row {worst[0]}")


def report_escape_leakage(rows: list[str]) -> None:
    """Any literal remnant of an escape sequence that reached the screen."""
    suspects = []
    for y, row in enumerate(rows):
        for pat in ("[0m", "[32m", "[1m", ";;http", "8;;", "\x1b"):
            if pat in row:
                suspects.append((y, pat, row))
    print("\n-- literal escape remnants on screen --")
    if suspects:
        for y, pat, row in suspects:
            print(f"  row {y}: {pat!r} in {row!r}")
    else:
        print("none")

    print("\n-- the reply line, as rendered --")
    for y, row in enumerate(rows):
        if "976" in row or "typecheck" in row or "Build" in row:
            print(f"  row {y}: {row!r}")


# The two defects, as machine-checkable gates. The probe used to only PRINT its
# findings, which is how two releases of layout fixes shipped against it while
# the owner's screen stayed broken: nothing ever failed. These return a list of
# complaints, and `main` exits non-zero if any survive.

# A blank run this long between content above and content below is a reserved
# band that is not being drawn. One row is a legitimate inter-block spacer; two
# is the spacer plus the composer's own gap. Three is a defect.
MAX_INTERIOR_BLANK_RUN = 2


def check_blank_runs(rows: list[str], label: str) -> list[str]:
    bad = []
    y = 0
    while y < len(rows):
        if rows[y].strip():
            y += 1
            continue
        start = y
        while y < len(rows) and not rows[y].strip():
            y += 1
        above = any(rows[i].strip() for i in range(0, start))
        below = any(rows[i].strip() for i in range(y, len(rows)))
        run = y - start
        if above and below and run > MAX_INTERIOR_BLANK_RUN:
            bad.append(
                f"{label}: {run} consecutive blank rows at row {start} — a band "
                f"reserved rows it never drew"
            )
    return bad


def check_escape_leakage(rows: list[str], label: str) -> list[str]:
    """Literal remnants of an escape sequence that reached the screen as text."""
    bad = []
    for y, row in enumerate(rows):
        if "\x1b" in row:
            bad.append(f"{label}: raw ESC on row {y}: {row!r}")
        for pat in ("[0m", "[1m", "[32m", "]8;;", "]0;"):
            if pat in row:
                bad.append(
                    f"{label}: escape remnant {pat!r} painted as text on row "
                    f"{y}: {row!r}"
                )
    return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=None)
    ap.add_argument("--cols", type=int, default=100)
    ap.add_argument("--rows", type=int, default=30)
    args = ap.parse_args()

    srv = ThreadingHTTPServer(("127.0.0.1", PORT), _Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    with PtySession(
        f"http://127.0.0.1:{PORT}",
        cols=args.cols,
        rows=args.rows,
        binary=Path(args.binary) if args.binary else None,
    ) as s:
        s.boot()
        type_and_submit(s, "verify the build")

        # Mid-turn: the first message is committed, the tool is streaming.
        s.pump(1.8)

        # THE MISSING INGREDIENT: a resize lands mid-turn. Under tmux the clear
        # strategy is `Surgical` — it erases from the OLD region top downward
        # while the rebuild re-anchors to the bottom, so a region that SHRANK
        # leaves the difference blank. tmux fires resizes on focus changes and
        # splits, which is why this is constant in a real session and absent
        # from every existing test.
        s.resize(args.cols, args.rows - 4)
        s.pump(0.6)
        s.resize(args.cols, args.rows)
        s.pump(1.2)
        mid = dump(s, "MID-TURN (tool streaming coloured output)")
        report_blank_runs(mid)
        report_escape_leakage(mid)

        # Settled: the whole turn is done.
        s.pump(4.0)
        end = dump(s, "AFTER THE TURN SETTLES")
        report_blank_runs(end)
        report_escape_leakage(end)

        print("\n===== FULL HISTORY (scrolled-off + visible) =====")
        print(s.dump())

        failures = (
            check_blank_runs(mid, "mid-turn")
            + check_escape_leakage(mid, "mid-turn")
            + check_blank_runs(end, "settled")
            + check_escape_leakage(end, "settled")
        )
    srv.shutdown()

    print(f"\n{'=' * 78}\nVERDICT\n{'=' * 78}")
    if failures:
        for f in failures:
            print(f"  FAIL  {f}")
        return 1
    print("  PASS  no dead rows, no escape remnants")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
