"""Reproduce the "the TUI loses its structure" report on a real PTY.

Drives the REAL `osagent` through a kernel PTY against a scriptable stub that
actually answers a prompt (the shared `stub_backend` holds the SSE open and says
nothing, which is enough for the resize assertions but cannot reproduce a
COMMIT — and the commit path is where the structure is lost).

What it captures, per step:
  * the rendered screen (visible rows only, so "where is the chrome" is literal);
  * where the live region actually is — the row of the composer's top divider —
    versus where the bottom-anchored contract says it must be (`rows - inline_h`);
  * how many copies of each singleton band exist anywhere, history included.

Run:  python3 test/pty/structure_probe.py
"""

from __future__ import annotations

import json
import queue
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from osa_pty import SINGLETON_BANDS, PtySession  # noqa: E402
from test_resize import assert_chrome_follows_the_transcript  # noqa: E402

PORT = 19107

_HEALTH = {
    "status": "ok",
    "version": "0.0.0-pty-structure",
    "uptime_seconds": 0,
    "provider": "pty-stub",
    "model": "pty-stub",
    "context_window": 200000,
    "effort": "medium",
    "billing": None,
    "update": None,
}


class _Bus:
    """Events the SSE stream will emit, pushed by the POST handlers."""

    def __init__(self) -> None:
        self.q: "queue.Queue[tuple[str, dict]]" = queue.Queue()

    def send(self, event: str, data: dict) -> None:
        self.q.put((event, data))

    def reply(self, text: str, delay: float = 0.03) -> None:
        """A streamed assistant turn, the way the backend delivers one."""

        def run() -> None:
            time.sleep(0.4)
            for chunk in re.findall(r"\S+\s*", text):
                self.send("streaming_token", {"text": chunk, "session_id": "s", "message_id": "m1"})
                time.sleep(delay)
            self.send(
                "agent_response",
                {"response": text, "response_type": "text", "signal": None, "message_id": "m1"},
            )

        threading.Thread(target=run, daemon=True).start()


BUS = _Bus()
TURN = 0
# Every turn's reply carries its own marker, so "is this line reachable exactly
# once" is a real question about the renderer and not about the fixture.
REPLY = (
    "REPLY-@N@ opens with a paragraph long enough to wrap, so the streaming "
    "preview grows past its first quantization step.\n\n"
    "- one\n- two\n- three\n\n"
    "REPLY-@N@ ends here."
)


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *_a):  # noqa: D102
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
            return self._json(
                {"token": "t", "refresh_token": "r", "expires_in": 3600}
            )
        if path == "/api/v1/sessions":
            return self._json({"session_id": "s", "id": "s"})
        if path == "/api/v1/orchestrate":
            global TURN
            TURN += 1
            BUS.reply(REPLY.replace("@N@", str(TURN)))
            return self._json({"status": "accepted"})
        return self._json({})


COMPOSER_TOP = re.compile(r"^─{20,}$")


def type_and_submit(s: PtySession, text: str) -> None:
    """Type like a human, then submit.

    A single `os.write` of the whole line lands inside the composer's
    paste-burst window, and a pasted Enter is a NEWLINE, not a submit — so a
    fast write silently fills the composer instead of sending a turn.
    """
    for ch in text:
        s.write(ch.encode())
        s.pump(0.02)
    s.pump(0.35)
    s.write(b"\r")


def visible(s: PtySession) -> list[str]:
    return [line.rstrip() for line in s.screen.display]


def report(s: PtySession, label: str) -> None:
    vis = visible(s)
    tops = [i for i, l in enumerate(vis) if COMPOSER_TOP.match(l)]
    print(f"\n===== {label} =====")
    for i, line in enumerate(vis):
        print(f"{i:3d}|{line}")
    print(f"--- composer-top rows (visible): {tops}  (screen rows={s.rows})")
    for name, pat in SINGLETON_BANDS.items():
        n = s.count(pat)
        flag = "" if n == 1 else "   (turn separator / user label also match)"
        print(f"--- {name}: {n}{flag}")


def assert_transcript_intact(s: PtySession, expected, label: str) -> None:
    """Every line ever committed is still reachable, once, in order.

    The invariant stated the way the owner states it. All four rendering
    symptoms are one event underneath -- a committed row that stopped being
    where it was put -- so a single assertion catches the reply that came out
    short, the reply rendered above the prompt that preceded it, the status bar
    sharing a row with the banner, and the second separator rule.
    """
    lines = s.lines()
    at = -1
    for needle in expected:
        hits = [i for i, l in enumerate(lines) if needle in l]
        if len(hits) != 1:
            raise AssertionError(
                f"{label}: {needle!r} is reachable {len(hits)} times, not once -- "
                f"a commit was written over, or written twice.\n{s.dump()}"
            )
        if hits[0] < at:
            raise AssertionError(
                f"{label}: {needle!r} renders at row {hits[0]}, above the line "
                f"committed before it (row {at}) -- the transcript is out of "
                f"order.\n{s.dump()}"
            )
        at = hits[0]


def check(s: PtySession, label: str, expected) -> None:
    report(s, label)
    assert_chrome_follows_the_transcript(s, label)
    assert_transcript_intact(s, expected, label)


def main() -> int:
    server = ThreadingHTTPServer(("127.0.0.1", PORT), _Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()

    with PtySession(f"http://127.0.0.1:{PORT}", cols=100, rows=30) as s:
        s.boot()
        seen = ["Welcome!"]
        check(s, "A. after boot (banner committed, idle composer)", seen)

        type_and_submit(s, "greeting-one")
        s.pump(1.0)
        seen.append("greeting-one")
        check(s, "B. mid-turn (prompt committed, reply streaming)", seen)
        s.pump(3.0)
        seen.append("REPLY-1 ends here.")
        check(s, "C. after the reply settled into scrollback", seen)

        type_and_submit(s, "prompt-two")
        s.pump(1.0)
        seen.append("prompt-two")
        check(s, "D. second prompt, mid-turn", seen)
        s.pump(3.5)
        seen.append("REPLY-2 ends here.")
        check(s, "E. after the second reply settled", seen)
    server.shutdown()
    print("\nstructure probe: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
