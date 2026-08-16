"""Visual proof that context compaction is VISIBLE while it runs.

Drives the REAL `osagent` binary over a real PTY, feeds it the real
`compaction_started` / `compaction_progress` / `compaction_completed` /
`compaction_failed` SSE frames that `Agent.CompactionEvents` broadcasts, and
reads the resulting screen back off a real terminal emulator.

The defect this pins: compaction announced itself on `Events.Bus` only, which
the TUI does not consume. A step that blocks the turn for minutes rendered as a
frozen UI — no spinner verb, no timer, no completion line. Unit tests could not
see it because nothing was wrong with any single component; the two halves were
simply never connected.

It also pins the honesty rule on the progress bar. The bar is drawn ONLY from
`chunk_index`/`chunk_total`, which the backend emits per completed
divide-and-conquer chunk. A compaction that does not chunk (the `/compact`
single-summarizer path) must show spinner + elapsed and NO bar, because there is
no measured ratio to draw. This probe asserts both directions.

Every assertion reads a style-stripped screen, so anything that survives here is
legible without colour.

Usage:
    python3 test/pty/compaction_probe.py [--port N] [--keep]

Exits 0 when the running, progress, completion and failure states all render.
"""

from __future__ import annotations

import argparse
import json
import queue
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import stub_backend  # noqa: E402
from osa_pty import PtySession  # noqa: E402

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
    payload = {"type": "system_event", "event": event,
               "session_id": "pty-stub-session", **payload}
    EVENTS.put(f"event: {event}\ndata: {json.dumps(payload)}\n\n".encode())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=12933)
    ap.add_argument("--keep", action="store_true", help="print every screen")
    opts = ap.parse_args()

    stub_backend._Handler._sse = _sse_with_events
    problems: list[str] = []

    with stub_backend.StubBackend(opts.port) as stub:
        with PtySession(stub.base_url, cols=100, rows=24) as term:
            term.boot()

            # ── 1. RUNNING, un-chunked: spinner + elapsed, and NO bar ────────
            # This is the `/compact` shape: one summarizer call, no measured
            # ratio. A bar here would be invented.
            emit("processing_started", {})
            term.pump(0.4)
            emit("compaction_started", {"trigger": "manual",
                                        "tokens_before": 84000})
            term.pump(1.6)
            running = term.dump()

            if "Compacting" not in running:
                problems.append(
                    "running: the spinner never named the wait 'Compacting'")
            # The one turn timer must be ticking next to it.
            if not any(f"{n}s" in running for n in range(1, 9)):
                problems.append(
                    "running: no elapsed timer on screen while compaction ran")
            # THE honesty assertion: no measured progress was reported, so no
            # bar may be drawn.
            if "▰" in running or "▱" in running:
                problems.append(
                    "running: a progress bar was drawn with no measured "
                    "progress to draw it from")

            # ── 2. RUNNING, chunked: a bar that tracks real chunks ───────────
            emit("compaction_progress", {"chunk_index": 3, "chunk_total": 10})
            term.pump(0.9)
            partial = term.dump()
            if "▰" not in partial or "▱" not in partial:
                problems.append(
                    "progress: measured chunk progress drew no bar")
            if "30%" not in partial or "chunk 3/10" not in partial:
                problems.append(
                    "progress: the bar did not state the real ratio it came from")
            # Partial work must not read as finished.
            if "100%" in partial:
                problems.append("progress: 3/10 rendered as 100%")

            emit("compaction_progress", {"chunk_index": 10, "chunk_total": 10})
            term.pump(0.9)
            full = term.dump()
            if "100%" not in full or "chunk 10/10" not in full:
                problems.append("progress: the final chunk never reached 100%")

            # ── 3. COMPLETION: one short factual line, indicator gone ────────
            emit("compaction_completed", {
                "tokens_before": 84000, "tokens_after": 21000,
                "messages_before": 52, "messages_after": 14,
                "duration_ms": 134000,
            })
            term.pump(1.2)
            done = term.dump()

            if "Compacted" not in done:
                problems.append("completion: no line said compaction happened")
            for want in ("~84.0k", "~21.0k", "38 messages folded"):
                if want not in done:
                    problems.append(
                        f'completion: line is missing "{want}"')
            # Success must be legible with every style stripped.
            if "✓" not in done:
                problems.append("completion: no success glyph (style-stripped)")
            # The running indicator must be GONE, not left spinning.
            if "Compacting" in done:
                problems.append(
                    "completion: the running indicator outlived the compaction")
            if "▰" in done or "▱" in done:
                problems.append("completion: the progress bar was never cleared")

            # ── 4. FAILURE: says so, and says history is intact ──────────────
            emit("compaction_started", {"trigger": "auto",
                                        "tokens_before": 84000})
            term.pump(0.8)
            emit("compaction_failed", {"reason": "summarizer timeout",
                                       "duration_ms": 90000})
            term.pump(1.2)
            failed = term.dump()

            if "✗" not in failed:
                problems.append("failure: no failure glyph (style-stripped)")
            if "Compaction failed" not in failed:
                problems.append("failure: the failure was never stated")
            if "summarizer timeout" not in failed:
                problems.append("failure: did not say WHY it failed")
            # The critical one: a vanished spinner reads as success.
            if "conversation unchanged" not in failed:
                problems.append(
                    "failure: did not tell the user the history is intact")
            if "Compacting" in failed:
                problems.append(
                    "failure: the running indicator outlived the failure")

            # ── 5. LEAN VIEW: compaction is a primitive, never hidden ────────
            # Standing requirement: "If I do the compact thing, it must show me
            # that it's compacting. Even if I have the lean command on."
            #
            # `/lean` suppresses TOOL CELLS. Compaction is not tool chatter —
            # it is the harness rewriting the conversation, and it blocks the
            # turn for minutes. Structurally it is out of lean's reach (the
            # spinner is chrome, and the completion line is SystemInfo, not
            # ToolCall), but nothing asserted that on a real screen, so a
            # widened predicate would have silently taken it away.
            # Land the turn first. A command typed while a turn is live is
            # QUEUED, not run (`submit_input` -> `enqueue_message`), and the
            # queued row also contains the text — so asserting on the echo alone
            # would pass against a `/lean` that never executed.
            emit("done", {})
            term.pump(1.0)

            # Type and submit as two separate writes. A single write carrying
            # the text AND the Enter looks like a paste burst
            # (`input/paste_burst.rs`), and a pasted newline is a literal
            # newline in the composer, not a submit.
            term.write(b"/lean on")
            term.pump(0.6)
            term.write(b"\r")
            term.pump(1.5)
            lean_on = term.dump()
            if "/lean on" not in lean_on:
                problems.append(
                    "lean: the typed command left no record on screen")
            if "Lean view" not in lean_on and "lean" not in lean_on.lower():
                problems.append(
                    "lean: /lean produced no confirmation — it may not have run")

            emit("compaction_started", {"trigger": "manual",
                                        "tokens_before": 135400})
            term.pump(1.6)
            lean_running = term.dump()
            if "Compacting" not in lean_running:
                problems.append(
                    "lean: compaction ran invisibly with the lean view on — "
                    "the spinner never named the wait")
            if not any(f"{n}s" in lean_running for n in range(1, 9)):
                problems.append(
                    "lean: no elapsed timer while compaction ran under /lean")

            emit("compaction_completed", {
                "tokens_before": 135400, "tokens_after": 6700,
                "messages_before": 990, "messages_after": 14,
                "duration_ms": 76000,
            })
            term.pump(1.2)
            lean_done = term.dump()
            if "Compacted" not in lean_done or "✓" not in lean_done:
                problems.append(
                    "lean: the completion line was suppressed by the lean view")
            if "Compacting" in lean_done:
                problems.append(
                    "lean: the running indicator outlived the compaction")

            # ── 6. The numbers must describe the CURRENT conversation ────────
            # Reported live, one frame, right after a successful compaction:
            #
            #     Context low (6% remaining) · Run /compact to compact & continue
            #     ⟐ grok-4.6 │ ⣿⣿⣿⣿⣿⣿⣿░ 88% ctx
            #
            # and later, once the bar had self-healed but the banner had not:
            #
            #     Context low (6% remaining)   ⣿⢿░░░░░░ 15% ctx
            #
            # grok-4.6 clamps to a 200k operative window: compact_at 167k,
            # warn_at 147k, meter denominator 180k.
            emit("context_pressure", {
                "estimated_tokens": 157500, "max_tokens": 180000,
                "utilization": 87.5, "percent_left": 6, "context_low": True,
                "compact_at": 167000, "warn_at": 147000,
            })
            term.pump(1.0)
            loaded = term.dump()
            if "Context low" not in loaded:
                problems.append(
                    "pressure: the low-context banner never appeared at 157.5k")

            # The fold lands. Only the next request's size carries the new
            # total — this is the `llm_response` self-heal path, the one the
            # banner did not share.
            emit("llm_response", {"duration_ms": 900,
                                  "usage": {"input_tokens": 29300,
                                            "output_tokens": 120}})
            term.pump(1.2)
            after = term.dump()

            if "Context low" in after:
                problems.append(
                    "pressure: the low-context banner outlived the compaction — "
                    "it still reads 'Context low' with 29.3k of a 167k budget in use")
            if "6% remaining" in after:
                problems.append(
                    "pressure: the banner still reports the pre-compaction "
                    "'6% remaining'")
            if "88% ctx" in after:
                problems.append(
                    "pressure: the meter still reports the pre-compaction 88%")

    if opts.keep:
        for name, snap in (("running", running), ("partial", partial),
                           ("full", full), ("done", done), ("failed", failed),
                           ("lean_running", lean_running),
                           ("lean_done", lean_done),
                           ("loaded", loaded), ("after", after)):
            print(f"\n--- {name} ---\n{snap}")

    if problems:
        print("FAIL")
        for p in problems:
            print(f"  - {p}")
        if not opts.keep:
            print("\n--- last screen ---")
            print(failed)
        return 1

    print("PASS — running (spinner+elapsed, no invented bar), measured bar "
          "3/10→10/10, completion line, failure line all rendered")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
