"""Visual proof that a fast tool call does not render as "zero seconds".

Drives the REAL `osagent` binary over a real PTY, feeds it real `tool_call`
SSE frames (a 40 ms read, a 12 ms failed grep, a 2.5 s bash), and reads the
resulting live activity feed back off a real terminal emulator.

Unit tests render the feed through ratatui's TestBackend; this reads the bytes
that actually reach a terminal. The defect it pins — every completed tool call
printed as `{:.1}s`, so a 40 ms call rendered `0.0s` — was invisible to 1162
passing tests.

Usage:
    python3 test/pty/tool_duration_probe.py [--port N] [--keep]

Exits 0 when every expected duration string is on screen and no `0.0s` is.
"""

from __future__ import annotations

import argparse
import json
import queue
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import stub_backend  # noqa: E402
from osa_pty import PtySession  # noqa: E402

# The stub's SSE handler holds the stream open with keepalives only. Tool events
# are pushed onto this queue and drained by the patched handler below, so the
# stub itself stays the "no behaviour" module its docstring promises.
EVENTS: "queue.Queue[bytes]" = queue.Queue()


def _sse_with_events(self) -> None:
    """`stub_backend._Handler._sse`, plus a drain of the EVENTS queue."""
    self.send_response(200)
    self.send_header("Content-Type", "text/event-stream")
    self.send_header("Cache-Control", "no-cache")
    self.send_header("Connection", "keep-alive")
    self.end_headers()
    try:
        while not self.server._stopping:
            try:
                frame = EVENTS.get(timeout=0.2)
            except queue.Empty:
                self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
                continue
            self.wfile.write(frame)
            self.wfile.flush()
    except (BrokenPipeError, ConnectionResetError, OSError):
        pass


def emit(event: str, payload: dict) -> None:
    EVENTS.put(
        f"event: {event}\ndata: {json.dumps(payload)}\n\n".encode()
    )


def tool(term, name: str, call_id: str, args: str, duration_ms: int,
         success: bool) -> None:
    """One complete tool call: start frame, then end frame with a duration.

    Pumps between the two so the TUI actually processes the start (and opens a
    feed row) before the end frame closes it.
    """
    emit("tool_call", {"name": name, "phase": "start", "args": args,
                       "tool_call_id": call_id})
    term.pump(0.5)
    emit("tool_call", {"name": name, "phase": "end", "args": args,
                       "tool_call_id": call_id, "duration_ms": duration_ms,
                       "success": success})
    term.pump(0.5)
    return term.dump()


def main() -> int:
    ap = argparse.ArgumentParser()
    # 12787 is hard-coded in run.sh and another agent may hold it; default off it.
    ap.add_argument("--port", type=int, default=12931)
    ap.add_argument("--keep", action="store_true", help="print the full screen")
    opts = ap.parse_args()

    stub_backend._Handler._sse = _sse_with_events

    with stub_backend.StubBackend(opts.port) as stub:
        with PtySession(stub.base_url, cols=100, rows=24) as term:
            term.boot()

            # The feed only paints while a turn is active.
            emit("processing_started", {})
            term.pump(0.5)

            # The live feed is only a few rows tall, so a later call scrolls an
            # earlier one out of it. Snapshot after each call and assert over
            # the union — every duration must have been on screen at its moment,
            # which is exactly what the user sees.
            seen: list[str] = []
            for name, cid, args, ms, ok in (
                ("file_read", "c1", '{"path":"/tmp/x.rs"}', 40, True),
                ("file_grep", "c2", '{"pattern":"todo"}', 12, False),
                ("shell_execute", "c3", '{"command":"make"}', 2500, True),
            ):
                seen.append(tool(term, name, cid, args, ms, ok))

            # A FAILED non-collapsible call: its failure must be legible as
            # text, not only as the colour of its bullet (this screen is read
            # with every style stripped, which is exactly the point).
            emit("tool_call", {"name": "file_edit", "phase": "start",
                               "args": '{"path":"/tmp/x.rs"}',
                               "tool_call_id": "c5"})
            term.pump(0.5)
            # Order matches the backend: the tool_call `end` frame first, then
            # the `tool_result` carrying the body. `success` is REQUIRED by the
            # parser — omitting it silently drops the whole frame.
            emit("tool_call", {"name": "file_edit", "phase": "end",
                               "args": '{"path":"/tmp/x.rs"}',
                               "tool_call_id": "c5", "duration_ms": 30,
                               "success": False})
            term.pump(0.4)
            emit("tool_result", {"name": "file_edit", "tool_call_id": "c5",
                                 "success": False,
                                 "result": "Error: no match for the search string"})
            term.pump(0.9)
            failure_screen = term.dump()
            seen.append(failure_screen)

            # Leave one call in flight so the running row is on screen too.
            emit("tool_call", {"name": "web_fetch", "phase": "start",
                               "args": '{"url":"https://example.com"}',
                               "tool_call_id": "c4"})
            term.pump(1.2)

            screen = term.dump()
            seen.append(screen)

    if opts.keep:
        print(screen)

    problems: list[str] = []
    for i, snap in enumerate(seen):
        if "0.0s" in snap:
            problems.append(
                f"snapshot {i} contains \"0.0s\" (a fast call read as zero)"
            )
    union = "\n".join(seen)
    for want in ("40ms", "12ms", "2.5s"):
        if want not in union:
            problems.append(f'expected duration "{want}" never rendered')

    # Outcome must survive style-stripping: the failed edit needs a glyph that
    # is not the success bullet, and its reason in words.
    if "✗" not in failure_screen:
        problems.append("a failed tool call carried no failure glyph")
    if "no match for the search string" not in failure_screen:
        problems.append("a failed tool call did not say why on screen")

    if problems:
        print("FAIL")
        for p in problems:
            print(f"  - {p}")
        print("\n--- screen ---")
        print(screen)
        return 1

    print("PASS — 40ms / 12ms / 2.5s all rendered, no 0.0s on screen")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
