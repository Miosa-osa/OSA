"""Every second of a long turn must be attributed on screen: model, tool, or user.

The report (v1.0.201, from the operator's backend log):

  * a file edit sat 202 s waiting for the USER'S approval while the screen
    read only `Edit settings.json 3m 22s` — the user thought OSA was grinding;
  * a shell command ran ~124 s with no visible row or timer; the daemon's
    "still running after 60s" signal went only to the log;
  * the 2nd/3rd call of a sequential batch did not appear until it finished.

This drives the REAL `osagent` binary on a real PTY against `stub_backend.py`,
holds a turn open, and pushes the SSE frames the backend sends in each of the
three states. It reads the VISIBLE screen (the live region is what the user is
looking at; scrollback is history) and asserts that each state is named:

  1. model wait     -> "waiting for <model>" with a live timer
  2. slow 2nd call  -> a live row naming the tool + command + timer, and once
                       the daemon reports it past 60s, "still running"
  3. approval wait  -> a banner that says OSA is waiting for YOU, what it
                       wants to do, how to answer, and a countdown
  4. turn end       -> none of the above is left on screen

Run:  python3 test/pty/turn_attribution_probe.py [--port N] [--keep]
Exits 0 when every state is attributed, 1 otherwise (with the screens).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import stub_backend  # noqa: E402
from osa_pty import SINGLETON_BANDS, USER_HEADER, PtySession  # noqa: E402

MODEL = "pty-stub"

# A reasoning pass the shape Ollama Cloud streams: several short paragraphs.
REASONING = (
    "The user wants the settings fixed. Let me look at what is wrong first.\n\n"
    "The config loader reads settings.json at boot, so a bad value there would "
    "explain the crash on startup.\n\n"
    "Plan: list the directory, run the tests, then edit the file.\n\n"
    "I should check the configured key before editing the file."
)


def visible(term: PtySession) -> str:
    """The rows currently on the terminal (no scrollback)."""
    return "\n".join(line.rstrip() for line in term.screen.display)


def numbered(text: str) -> str:
    return "\n".join(f"{i:3d}|{line}" for i, line in enumerate(text.split("\n")))


def tool_start(name: str, call_id: str, args: str) -> None:
    stub_backend.push_sse(
        "tool_call",
        {"name": name, "phase": "start", "args": args, "tool_call_id": call_id},
    )


def tool_end(name: str, call_id: str, args: str, ms: int) -> None:
    stub_backend.push_sse(
        "tool_call",
        {
            "name": name,
            "phase": "end",
            "args": args,
            "tool_call_id": call_id,
            "duration_ms": ms,
            "success": True,
        },
    )
    stub_backend.push_sse(
        "tool_result",
        {"name": name, "tool_call_id": call_id, "success": True, "result": "EXIT: 0"},
    )


def run(base_url: str, binary: str | None = None) -> tuple[dict[str, str], list[str]]:
    """Drive every state against the backend at `base_url`.

    Returns `(screens, problems)`; an empty `problems` is a pass. Shared by
    this script and by `test_resize.py`, which runs it in the CI PTY suite.
    """
    screens: dict[str, str] = {}
    problems: list[str] = []
    final_lines: list[str] = []

    def expect(label: str, screen: str, pattern: str, why: str) -> None:
        if not re.search(pattern, screen):
            problems.append(f"[{label}] {why}  (wanted /{pattern}/)")

    def expect_not(label: str, screen: str, pattern: str, why: str) -> None:
        if re.search(pattern, screen):
            problems.append(f"[{label}] {why}  (found /{pattern}/)")

    stub_backend.hold_turn()
    try:
        with PtySession(base_url, cols=110, rows=30, binary=binary) as term:
            term.boot()
            # Text and Enter as separate writes: in one write the Enter
            # rides a paste burst and becomes a newline, not a submit.
            term.write(b"fix the settings")
            term.pump(0.4)
            term.write(b"\r")
            if not term.wait_for_text("esc to interrupt", 5.0):
                problems.append("[setup] the turn never started")

            # --- 1. waiting on the model -------------------------------
            stub_backend.push_sse("llm_request", {"iteration": 1})
            term.pump(3.2)
            s = visible(term)
            screens["1 model wait"] = s
            expect("model", s, rf"[Ww]aiting for {MODEL}", "model wait is not labelled with the model")
            expect("model", s, rf"{MODEL}\s*·\s*[2-9]s", "model wait has no live timer")

            # --- 1b. long streamed reasoning ----------------------------
            # Ollama Cloud streams reasoning as small `thinking_delta` chunks.
            # The row must show the LIVE TAIL of that text (not one word)
            # plus a timer, for the whole reasoning phase.
            chunks = [REASONING[i:i + 5] for i in range(0, len(REASONING), 5)]
            for i, chunk in enumerate(chunks):
                stub_backend.push_sse("thinking_delta", {"text": chunk})
                term.pump(0.04)
            term.pump(0.6)
            s = visible(term)
            screens["1b reasoning streaming"] = s
            expect("reasoning", s, r"Thinking", "reasoning phase is not labelled")
            expect("reasoning", s, r"\d+(\.\d)?s", "reasoning phase has no timer")
            tail_rows = [ln for ln in s.split("\n") if ln.startswith("  ") and ln.strip()]
            wanted_tail = "configured key before editing the file."
            expect("reasoning", s, re.escape(wanted_tail), "the newest reasoning text is not on screen")
            if sum(1 for ln in tail_rows if len(ln.strip()) > 20) < 2:
                problems.append("[reasoning] fewer than 2 substantial lines of live reasoning on screen")

            # --- 2. batch: fast 1st call, slow 2nd call ----------------
            tool_start("shell_execute", "b1", "ls -la")
            term.pump(0.6)
            s = visible(term)
            screens["2a first call, right after reasoning"] = s
            # The finished thought collapses to its one-row summary, and the
            # running call is on screen beneath it rather than hidden by it.
            expect("reasoning", s, r"Thought for", "reasoning summary vanished at the tool edge")
            expect("tool", s, r"Bash\(ls -la\) · running", "first call after reasoning hidden by the thought")
            expect_not("reasoning", s, re.escape("configured key before"), "reasoning tail still painted after it ended")
            tool_end("shell_execute", "b1", "ls -la", 40)
            term.pump(0.3)
            tool_start("shell_execute", "b2", "sleep 120 && make test")
            term.pump(3.2)
            s = visible(term)
            screens["2 slow 2nd call"] = s
            # Reasoning ended at the first tool edge: its summary may stay
            # as ONE row, but it must not hide the running call or keep
            # painting the tail as if the model were still thinking.
            expect_not("reasoning", s, r"Thinking…", "reasoning still shown as live after a tool started")
            expect_not("reasoning", s, re.escape("configured key before"), "stale reasoning tail left on screen during the tool")
            expect("tool", s, r"sleep 120 && make test", "running 2nd call has no visible row")
            expect(
                "tool",
                s,
                r"sleep 120 && make test.*\b[2-9]s\b|\b[2-9]s\b.*sleep 120 && make test",
                "running 2nd call row has no live elapsed timer",
            )

            # The daemon's "still running after 60s" signal, as forwarded.
            stub_backend.push_sse(
                "tool_call_stalled",
                {"event": "tool_call_stalled", "tools": "shell_execute", "elapsed_s": 60, "pending": 1},
            )
            stub_backend.push_sse(
                "tool_heartbeat",
                {"name": "shell_execute", "tool_call_id": "b2", "elapsed_ms": 62_000, "stalled": True},
            )
            term.pump(1.5)
            s = visible(term)
            screens["2b past 60s"] = s
            expect("stall", s, r"still running", "past 60s is not shown on screen")
            expect("stall", s, r"1m\s?0[2-9]s|1m0[2-9]s|6[2-9]s", "row timer did not adopt the daemon's elapsed")

            tool_end("shell_execute", "b2", "sleep 120 && make test", 62_500)
            term.pump(0.5)

            # --- 3. approval wait --------------------------------------
            stub_backend.push_sse("llm_request", {"iteration": 2})
            term.pump(0.4)
            # The real hint for an edit is its JSON args (ToolHint keeps them
            # so the TUI can render a diff).
            edit_args = '{"path":"settings.json","old_string":"1","new_string":"2"}'
            tool_start("file_edit", "e1", edit_args)
            term.pump(0.3)
            stub_backend.push_sse(
                "permission_required",
                {
                    # The real frame is a system_event: the sub-event name
                    # rides in `event`, and the TUI parser keys on it.
                    "event": "permission_required",
                    "tool": "file_edit",
                    "args": edit_args,
                    "request_id": "perm_233730",
                    "target": "settings.json",
                    "kind": "edit",
                    "old_content": '{"a": 1}\n',
                    "new_content": '{"a": 2}\n',
                    "timeout_ms": 300_000,
                },
            )
            term.pump(3.2)
            s = visible(term)
            screens["3 approval wait"] = s
            expect("approval", s, r"Waiting for you\b", "approval wait does not say OSA is waiting for the user")
            expect("approval", s, r"y allow", "approval wait does not say how to answer")
            expect("approval", s, r"settings\.json", "approval wait does not say what OSA wants to do")
            expect("approval", s, r"4m5\ds|4:5\d", "approval wait has no countdown to the 300s timeout")

            # Answer it (Enter on the default choice = allow once).
            term.write(b"\r")
            term.pump(1.0)
            tool_end("file_edit", "e1", edit_args, 3_500)
            term.pump(0.8)
            s = visible(term)
            screens["3b answered"] = s
            expect_not("approval", s, r"Waiting for you\b", "approval banner survived the answer")
            # The finished cell says whose time its duration was.
            expect("approval", s, r"Edit.*waiting for your approval", "finished edit does not attribute its approval wait")

            # --- 3c. an approval nobody answers expires off the screen --
            tool_start("shell_execute", "x1", "rm -rf build")
            term.pump(0.3)
            stub_backend.push_sse(
                "permission_required",
                {
                    "event": "permission_required",
                    "tool": "shell_execute",
                    "args": "rm -rf build",
                    "request_id": "perm_expiring",
                    "target": "rm -rf build",
                    "kind": "bash",
                    "timeout_ms": 2_000,
                },
            )
            term.pump(1.0)
            s = visible(term)
            screens["3c approval pending (2s timeout)"] = s
            expect("expiry", s, r"Waiting for you\b", "short approval never showed")
            term.pump(2.5)
            s = visible(term)
            screens["3d approval expired"] = s
            expect_not("expiry", s, r"Waiting for you\b", "expired approval is still on screen")
            expect("expiry", s, r"approval timed out", "expiry was not said on screen")
            # The backend's own answer to the timeout: the call ends blocked.
            tool_end("shell_execute", "x1", "rm -rf build", 2_100)
            term.pump(0.5)

            # --- 4. turn end: nothing stale ----------------------------
            stub_backend.end_turn("Updated settings.json.")
            term.pump(2.0)
            s = visible(term)
            screens["4 turn end"] = s
            for pat, why in (
                (r"Waiting for you\b", "approval banner left after turn end"),
                (rf"[Ww]aiting for {MODEL}", "model-wait label left after turn end"),
                (r"still running", "stall notice left after turn end"),
            ):
                expect_not("end", s, pat, why)
            final_lines = term.lines()
    finally:
        stub_backend.release_turn()

    # One-chrome invariant, on every state: the new rows are chrome INSIDE the
    # live region, so none of them may cost a second composer or status bar.
    # Counted over the whole session (history included), where strandings land.
    for name, pattern in SINGLETON_BANDS.items():
        rows = [ln for ln in final_lines if pattern.search(ln)]
        if name == "composer":
            rows = [ln for ln in rows if not USER_HEADER.search(ln)]
        if len(rows) != 1:
            problems.append(f"[chrome] expected exactly one {name} row, found {len(rows)}")
    # Per state: the composer's key-hint divider and the status bar. (The
    # prompt row itself reads `◈ ❯` while a turn runs, which the idle-anchored
    # `composer` marker deliberately does not match.)
    for label, s in screens.items():
        for name in ("composer_hints", "status"):
            n = sum(1 for ln in s.split("\n") if SINGLETON_BANDS[name].search(ln))
            if n != 1:
                problems.append(f"[chrome] {label}: {n} {name} rows on screen")

    return screens, problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=12947)
    ap.add_argument("--keep", action="store_true", help="print every screen")
    ap.add_argument("--binary", default=None, help="osagent to drive (default: release build)")
    opts = ap.parse_args()

    with stub_backend.StubBackend(opts.port) as stub:
        screens, problems = run(stub.base_url, opts.binary)

    if opts.keep or problems:
        for label, s in screens.items():
            print(f"\n=== {label} ===")
            print(numbered(s))

    if problems:
        print("\nFAIL")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("\nPASS — model / tool / user waits are all attributed on screen")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
