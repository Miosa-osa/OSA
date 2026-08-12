#!/usr/bin/env python3
"""A markdown link must not render as a link until its URL is closed.

THE DEFECT
==========

`render/markdown.rs`'s inline parser scanned `[text](url)` with no "closed"
flag on the URL loop:

    if found_bracket && chars.peek() == Some(&'(') {
        chars.next();
        let mut url = String::new();
        for c in chars.by_ref() {
            if c == ')' { break; }        // <- and if it never comes?
            url.push(c);
        }
        ... hyperlink_span(link_text, &url, ...)

When the loop reached end-of-line without a `)` it fell through and emitted an
OSC 8 hyperlink anyway, pointing at whatever bytes had arrived. Two
consequences — one interactive, one plainly visible:

  * mid-stream the element is CLICKABLE and its destination mutates on every
    delta: `[docs](https://osa.dev/gu` was a live link to `https://osa.dev/gu`;
  * the `](url` source is SWALLOWED, so an unterminated link renders as its
    bare label with the URL deleted — in the live preview *and* in the
    permanent transcript.

Every other unterminated inline construct in that file (`**`, `*`, `$$`, `$`,
bare `[`) already falls back to its literal source, and the reference renderers
(codex, Claude Code) deliberately keep half-drawn *emphasis* on screen. A link
is the one case where the intermediate state is interactive rather than merely
visual, which is why this one is suppressed and the others are not.

WHAT THIS PROBE ASSERTS
=======================

The swallowed source is the deterministic consequence, so it is the gate:
after a real turn on a real PTY, an unterminated link must appear on screen as
its literal source. The screen is the evidence — no escape parsing needed.
`osa_pty.PtySession` sets `NO_COLOR`, so `components::osc8::supports_hyperlinks`
is false here and the OSC 8 bytes are never emitted; that makes the swallowed
source *more* visible, not less.

A complete link in the same reply must still render the normal way
(`label (url)`), so the probe cannot be passed by disabling links altogether.

The mid-stream frames are covered deterministically by the Rust unit tests in
`render/markdown.rs` — `unterminated_link_renders_literally_not_as_a_hyperlink`,
`unterminated_link_partial_url_is_not_bare_autolinked`,
`unterminated_link_with_streaming_cursor_is_literal`, and
`link_becomes_clickable_only_on_the_closing_paren`, which walks every prefix of
a streamed link and asserts no underlined span exists before the `)` lands.

RUN
===

    python3 test/pty/link_stream_probe.py --binary priv/rust/tui/target/debug/osagent

Exit 0 = literal source for the open link, rendered link for the closed one.

PROVING IT CAN FAIL
===================

    priv/rust/tui/src/render/markdown.rs, in `parse_inline`
    -                    if !closed {
    +                    if false && !closed {

Rebuild and rerun. Expected: the second link's row loses everything from `](`
onward and the probe reports

    FAIL  unterminated link was swallowed: ... got ['|Cut: the holdback notes']
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

PORT = 18809

# One reply, two links. The first closes; the second never does — which is both
# what a model emits when it cuts a URL short and what the live tail looks like
# on every delta while a URL is still arriving.
CLOSED_LINK_SRC = "[the OSA streaming guide](https://osa.dev/guide/streaming)"
CLOSED_LINK_LABEL = "the OSA streaming guide"
CLOSED_LINK_URL = "https://osa.dev/guide/streaming"
OPEN_LINK_SRC = "[the holdback notes](https://osa.dev/guide/holdback"

REPLY = (
    "Docs: see " + CLOSED_LINK_SRC + " for the boundary rule.\n"
    "\n"
    "Cut: " + OPEN_LINK_SRC + "\n"
)

_HEALTH = {
    "status": "ok",
    "version": "0.0.0-pty-link-stream",
    "uptime_seconds": 0,
    "provider": "pty-stub",
    "model": "pty-stub",
    "context_window": 200000,
    "effort": "medium",
    "billing": None,
    "update": None,
}


class _Bus:
    def __init__(self) -> None:
        self.q: "queue.Queue[tuple[str, dict]]" = queue.Queue()

    def send(self, event: str, data: dict) -> None:
        self.q.put((event, data))

    def script(self) -> None:
        def run() -> None:
            time.sleep(0.4)
            # Sub-word chunks: the interesting deltas land *inside* the URL,
            # which a word-at-a-time stream steps straight over (a `\S+\s*`
            # split keeps `label](https://…/4712)` in a single chunk).
            for chunk in re.findall(r".{1,4}", REPLY, re.S):
                self.send(
                    "streaming_token",
                    {"text": chunk, "session_id": "s", "message_id": "m1"},
                )
                time.sleep(0.01)
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
            return self._json({"status": "accepted"})
        return self._json({})


def type_and_submit(s: PtySession, text: str) -> None:
    for ch in text:
        s.write(ch.encode())
        s.pump(0.02)
    s.pump(0.35)
    s.write(b"\r")


def snapshot(s: PtySession) -> list[str]:
    """Visible rows plus everything that has scrolled off the top.

    Completed blocks settle into the terminal's NATIVE scrollback as the turn
    runs, so the row under test can sit above the viewport. Reading only
    `display` would let the probe pass by never seeing it.
    """
    history = ["".join(c.data for c in row.values()) for row in s.screen.history.top]
    return [r.rstrip() for r in history] + [
        s.screen.display[y].rstrip() for y in range(s.rows)
    ]


def check(rows: list[str]) -> list[str]:
    # The renderer wraps, so assert on the whole screen with row breaks and the
    # quote gutter removed rather than on any single row.
    joined = " ".join(r.lstrip("┃").strip() for r in rows if r.strip())
    bad = []

    # 1. The unterminated link keeps its literal source.
    if OPEN_LINK_SRC not in joined.replace("  ", " "):
        swallowed = [r for r in rows if "holdback notes" in r]
        bad.append(
            "unterminated link was swallowed: expected the literal "
            f"{OPEN_LINK_SRC!r} on screen, got {swallowed or 'no row at all'}"
        )

    # 2. A complete link still renders as a link (label, then the URL in dim
    #    parens) — so the probe cannot be satisfied by turning links off.
    if CLOSED_LINK_LABEL not in joined:
        bad.append("the closed link's label vanished — links stopped rendering")
    elif CLOSED_LINK_SRC in joined:
        bad.append(
            "the closed link rendered as raw source — the suppression is too "
            "broad; only UNTERMINATED links may fall back to literal"
        )
    elif f"({CLOSED_LINK_URL})" not in joined:
        bad.append("the closed link lost its URL suffix")
    return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=None)
    ap.add_argument("--cols", type=int, default=100)
    ap.add_argument("--rows", type=int, default=24)
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
        type_and_submit(s, "link please")
        s.pump(6.0)
        rows = snapshot(s)
        failures = check(rows)

    srv.shutdown()

    print(f"\n{'=' * 78}\nSCREEN (scrolled-off + visible)\n{'=' * 78}")
    for y, r in enumerate(rows):
        if r:
            print(f"{y:>3} |{r}")

    print(f"\n{'=' * 78}\nVERDICT\n{'=' * 78}")
    if failures:
        for f in failures:
            print(f"  FAIL  {f}")
        return 1
    print("  PASS  unterminated link rendered as literal source; complete link")
    print("        still rendered as a link")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
