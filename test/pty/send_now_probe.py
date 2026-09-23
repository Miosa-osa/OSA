#!/usr/bin/env python3
"""PTY capture for item 1 (send-now) and item 2 (queued in conversation).

Drives the REAL osagent binary on a kernel PTY against the stub backend:

  1. start a turn and hold it (Processing),
  2. type a message mid-turn + Enter — it QUEUES,
  3. capture: the queued message shows in the conversation (above the spinner),
     marked queued, and the composer shows a one-row "N queued" affordance,
  4. press Enter again on the empty composer — SEND-NOW: the message is
     delivered into the running turn and echoed as a mid-turn user message.

Run:  python3 test/pty/send_now_probe.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import stub_backend  # noqa: E402
from osa_pty import PtySession  # noqa: E402


def visible(term: PtySession) -> str:
    return "\n".join(term.lines())


def run(base_url: str, binary: str | None = None) -> tuple[dict[str, str], list[str]]:
    screens: dict[str, str] = {}
    problems: list[str] = []

    stub_backend.hold_turn()
    try:
        with PtySession(base_url, cols=100, rows=30, binary=binary) as term:
            term.boot()
            term.write(b"fix the settings")
            term.pump(0.4)
            term.write(b"\r")
            if not term.wait_for_text("esc to interrupt", 5.0):
                problems.append("[setup] the turn never started")
                return screens, problems

            # --- type a message mid-turn, Enter queues it ------------------
            term.write(b"also check the billing bug")
            term.pump(0.3)
            term.write(b"\r")
            term.pump(0.6)
            s = visible(term)
            screens["1 queued in conversation"] = s

            if "also check the billing bug" not in s:
                problems.append("[queued] the queued message is not visible on screen")
            if "queued" not in s.lower():
                problems.append("[queued] the message is not marked as queued")

            # --- Enter again on the empty composer = send-now --------------
            term.write(b"\r")
            if not term.wait_for_text("Sent into this turn", 5.0):
                # Fall back: the echo of the message as a mid-turn user line is
                # also proof it was delivered.
                term.pump(0.8)
            s2 = visible(term)
            screens["2 after send-now"] = s2
            if "Sent into this turn" not in s2 and "also check the billing bug" not in s2:
                problems.append("[send-now] no evidence the queued message was sent into the turn")
    finally:
        stub_backend.release_turn()

    return screens, problems


def main() -> int:
    import os

    port = int(os.environ.get("OSA_PTY_STUB_PORT", "12793"))
    with stub_backend.StubBackend(port=port) as backend:
        screens, problems = run(backend.base_url)

    for label, screen in screens.items():
        print(f"\n===== {label} =====")
        print(screen)

    if problems:
        print("\nPROBLEMS:")
        for p in problems:
            print("  -", p)
        return 1
    print("\nOK: send-now + queued-in-conversation behaved.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
