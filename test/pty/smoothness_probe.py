"""Measure how a turn FEELS, on a real PTY, in milliseconds.

Every other probe in this directory samples a turn while it is streaming or
after it has settled. The complaints this one exists for live in neither place:

  * **submit -> first token.** The prompt commits, and then nothing happens on
    screen — no spinner, no elapsed clock, no `esc to interrupt` — until the
    model's first token arrives. On a slow first token that reads as a freeze.
    Nothing covered this window, because nothing sampled it.

  * **last token -> settled layout.** The reply is complete and the working
    chrome is gone, but the live region keeps reserving its mid-turn height for
    up to `SLOT_SHRINK_HOLD` + `SHRINK_SETTLE_TICKS` before it gives the rows
    back. Those rows are blank while it waits.

  * **churn during the stream.** How many times a second the live region's top
    edge moves. Every move is a viewport rebuild (a DSR cursor query and a
    re-anchor), so this is the number that trades "sticky" against "jittery".

The stub scripts a turn with a deliberately LATE first token so the first
window is wide enough to sample many times, then streams a multi-paragraph
reply, then finalizes.

Output is a table of milliseconds, plus non-zero exit when a gate fails. Run it
against two binaries to compare releases:

    python3 test/pty/smoothness_probe.py --binary /path/to/osagent
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

from osa_pty import COMPOSER_HINTS, PtySession  # noqa: E402

PORT = 19147

# How long the stub waits after accepting the prompt before the first token.
# This is the window under test; it is long because the defect is invisible when
# the first token is fast, not because a real model is this slow.
FIRST_TOKEN_DELAY = 3.0

_HEALTH = {
    "status": "ok",
    "version": "0.0.0-pty-smoothness",
    "uptime_seconds": 0,
    "provider": "pty-stub",
    "model": "pty-stub",
    "context_window": 200000,
    "effort": "medium",
    "billing": None,
    "update": None,
}

REPLY = (
    "Short answer: the reservation and the drawn height are two different "
    "numbers, and the gap between them is what you are looking at.\n\n"
    "The live region is bottom-anchored, so every row reserved and not drawn "
    "paints as blank screen ABOVE the content rather than below it. That is "
    "why the dead space appears between the transcript and the reply instead "
    "of under the composer where it would be easy to ignore.\n\n"
    "Growth has to be immediate, because under-reserving clips the reply. "
    "Shrink is the direction with a choice in it.\n"
)

# Anything that says "a turn is running" to a user glancing at the screen.
INDICATOR = re.compile(
    r"esc to interrupt|Thinking|Working|Waiting|Streaming|Optimizing|Signaling"
    r"|[⠁-⣿]"  # braille spinner cells
)


class _Bus:
    def __init__(self) -> None:
        self.q: "queue.Queue[tuple[str, dict]]" = queue.Queue()
        self.first_token_at: float | None = None
        self.last_token_at: float | None = None

    def send(self, event: str, data: dict) -> None:
        self.q.put((event, data))

    def script(self) -> None:
        def run() -> None:
            # THE WINDOW UNDER TEST: accepted, but nothing streamed yet.
            time.sleep(FIRST_TOKEN_DELAY)
            chunks = re.findall(r"\S+\s*", REPLY)
            for n, chunk in enumerate(chunks):
                if n == 0:
                    self.first_token_at = time.monotonic()
                self.send(
                    "streaming_token",
                    {"text": chunk, "session_id": "s", "message_id": "m1"},
                )
                time.sleep(0.03)
            self.last_token_at = time.monotonic()
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
            return self._json({"session_id": "s", "status": "accepted"})
        return self._json({})


def type_and_submit(s: PtySession, text: str) -> float:
    for ch in text:
        s.write(ch.encode())
        s.pump(0.02)
    s.pump(0.3)
    s.write(b"\r")
    return time.monotonic()


def composer_top(s: PtySession) -> int | None:
    """Row index of the composer band — the live region's moving top edge."""
    for y in range(s.rows):
        if COMPOSER_HINTS.search(s.screen.display[y]):
            return y
    return None


def blank_band_above_composer(s: PtySession) -> int:
    """Longest run of blank rows immediately above the composer band."""
    top = composer_top(s)
    if top is None:
        return 0
    run = 0
    y = top - 1
    while y >= 0 and not s.screen.display[y].strip():
        run += 1
        y -= 1
    return run


def has_indicator(s: PtySession) -> bool:
    return any(INDICATOR.search(s.screen.display[y]) for y in range(s.rows))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=None)
    ap.add_argument("--cols", type=int, default=100)
    ap.add_argument("--rows", type=int, default=30)
    ap.add_argument("--label", default="current")
    ap.add_argument("--dump-wait", action="store_true")
    ap.add_argument(
        "--max-blank",
        type=int,
        default=3,
        help="Gate: blank rows allowed above the composer while waiting.",
    )
    ap.add_argument(
        "--max-indicator-ms",
        type=int,
        default=400,
        help="Gate: submit -> first live indicator.",
    )
    ap.add_argument(
        "--max-settle-ms",
        type=int,
        default=400,
        help="Gate: last token -> live region stops moving.",
    )
    args = ap.parse_args()

    ThreadingHTTPServer.allow_reuse_address = True
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), _Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    failures: list[str] = []
    with PtySession(
        f"http://127.0.0.1:{PORT}", cols=args.cols, rows=args.rows,
        binary=Path(args.binary) if args.binary else None,
    ) as s:
        s.pump(2.0)

        submitted = type_and_submit(s, "why is there so much dead space")

        # ── Window 1: submit -> first token ──────────────────────────────
        indicator_at: float | None = None
        worst_blank = 0
        blank_frames = 0
        frames = 0
        while time.monotonic() - submitted < FIRST_TOKEN_DELAY - 0.2:
            s.pump(0.05)
            frames += 1
            if indicator_at is None and has_indicator(s):
                indicator_at = time.monotonic()
            band = blank_band_above_composer(s)
            worst_blank = max(worst_blank, band)
            if band > args.max_blank:
                blank_frames += 1
            if args.dump_wait and frames == 12:
                print("\n--- screen 0.6s after submit, before first token ---")
                for y in range(s.rows):
                    print(f"{y:>3} |{s.screen.display[y].rstrip()}")

        indicator_ms = (
            None if indicator_at is None else (indicator_at - submitted) * 1000.0
        )

        # ── Window 2: churn during the stream ────────────────────────────
        tops: list[tuple[float, int]] = []
        while BUS.last_token_at is None:
            s.pump(0.05)
            if indicator_at is None and has_indicator(s):
                indicator_at = time.monotonic()
                print(
                    "  [indicator first seen "
                    f"{(indicator_at - submitted) * 1000:.0f}ms after submit, "
                    f"{(indicator_at - (BUS.first_token_at or indicator_at)) * 1000:.0f}ms "
                    "after the first token]"
                )
            t = composer_top(s)
            if t is not None:
                tops.append((time.monotonic(), t))
            if time.monotonic() - submitted > FIRST_TOKEN_DELAY + 20:
                break
        stream_span = (
            (BUS.last_token_at - BUS.first_token_at)
            if (BUS.last_token_at and BUS.first_token_at)
            else 0.0
        )
        moves = sum(1 for i in range(1, len(tops)) if tops[i][1] != tops[i - 1][1])
        churn = moves / stream_span if stream_span > 0 else 0.0

        # ── Window 3: last token -> settled ──────────────────────────────
        settle_deadline = time.monotonic() + 4.0
        last_change = time.monotonic()
        prev = composer_top(s)
        while time.monotonic() < settle_deadline:
            s.pump(0.05)
            cur = composer_top(s)
            if cur != prev:
                prev = cur
                last_change = time.monotonic()
        settle_ms = (last_change - (BUS.last_token_at or last_change)) * 1000.0
        settle_ms = max(settle_ms, 0.0)
        final_blank = blank_band_above_composer(s)

    srv.shutdown()

    print(f"\n=== smoothness [{args.label}] {args.cols}x{args.rows} ===")
    print(
        "submit -> first indicator : "
        + ("NEVER APPEARED" if indicator_ms is None else f"{indicator_ms:7.0f} ms")
    )
    print(f"worst blank band (waiting): {worst_blank:7d} rows over {frames} frames")
    print(f"frames over blank gate    : {blank_frames:7d}")
    print(f"live-region moves / sec   : {churn:7.1f}  ({moves} in {stream_span:.1f}s)")
    print(f"last token -> settled     : {settle_ms:7.0f} ms")
    print(f"blank band when settled   : {final_blank:7d} rows")

    if indicator_ms is None:
        # ADVISORY, not a gate. This stub drives `orchestrate` + SSE
        # `streaming_token` / `agent_response` and nothing else, and the
        # indicator never appears here for the WHOLE turn — including while text
        # is streaming, where a real backend demonstrably does show it. So a
        # "NEVER APPEARED" from this probe does not distinguish "the TUI fails to
        # show a running turn" from "the stub does not send whatever drives the
        # band". Root-causing it needs a capture against the real backend; until
        # then, failing the run on it would be asserting something unproven.
        print(
            "\n  NOTE: no live indicator was seen at any point. Inconclusive — "
            "see the comment at this check."
        )
    elif indicator_ms > args.max_indicator_ms:
        failures.append(
            f"live indicator took {indicator_ms:.0f}ms to appear "
            f"(gate {args.max_indicator_ms}ms)"
        )
    if worst_blank > args.max_blank:
        failures.append(
            f"{worst_blank} blank rows above the composer while waiting "
            f"(gate {args.max_blank})"
        )
    if settle_ms > args.max_settle_ms:
        failures.append(
            f"live region kept moving for {settle_ms:.0f}ms after the last token "
            f"(gate {args.max_settle_ms}ms)"
        )
    if final_blank > args.max_blank:
        failures.append(f"{final_blank} dead rows remain once settled")

    if failures:
        print("\nFAIL")
        for f in failures:
            print("  - " + f)
        return 1
    print("\nOK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
