"""Words glued together in interim narration lines.

The report, verbatim from the operator's screen (several models, v1.0.201
through v1.0.204):

    "Collecting the duplicateinventory."
    "Checking the audit's own progress fileinstead."
    "Waiting for it to finish thesweep."

Almost always the LAST word or two of a narration line (the ┃ prose between two
tool calls), with the space before a word dropped.

This drives the REAL binary on a REAL PTY with a stub backend that streams each
narration line the way a provider does - token by token, the space riding at the
FRONT of the next token - and then opens a tool call, which is what commits the
narration into scrollback. It then reads every narration sentence back off the
emulated screen + history and fails if any word boundary was lost.

Several chunkings are exercised, because the defect only shows for some of them:

  * word tokens with a leading space (`"Checking", " the", " audit's", ...`);
  * a line split exactly before its last word (`[..."file", " instead."]`);
  * a whitespace-only delta between two words (`["...the", " ", "sweep."]`);
  * clumped arrival (big chunks with gaps) that engages the de-jitter pacer.

Result, and why this stays as a guard: the TUI renders every one of these
chunkings with its word boundaries intact. The glue the operator saw was already
in the bytes the backend received from Ollama (see
`lib/optimal_system_agent/providers/tool_boundary_space.ex`); this probe pins the
render half so a regression there cannot hide behind the upstream one.
`--control` feeds the glued upstream shape and must FAIL.

Run:  python3 test/pty/glue_probe.py [--binary PATH] [--control]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import stub_backend  # noqa: E402
from osa_pty import PtySession  # noqa: E402


def word_tokens(s: str) -> list[str]:
    """BPE-shaped tokens: every token after the first carries its leading space."""
    return re.findall(r"\s*\S+", s)


def split_before_last(s: str) -> list[str]:
    i = s.rstrip().rfind(" ")
    return [s[:i], s[i:]]


def ollama_trimmed(s: str) -> list[str]:
    """The shape Ollama actually delivers before a tool call: the last piece
    with its leading space trimmed away. Used only by `--control`."""
    head, last = split_before_last(s)
    return [head, last.lstrip()]


def space_alone(s: str) -> list[str]:
    i = s.rstrip().rfind(" ")
    return [s[:i], " ", s[i + 1 :]]


# (sentence, chunker, per-delta sleep). The sentences are the operator's.
NARRATION = [
    ("Collecting the duplicate inventory.", word_tokens, 0.02),
    ("Checking the audit's own progress file instead.", split_before_last, 0.05),
    ("Waiting for it to finish the sweep.", space_alone, 0.05),
    ("I want to be sure before I touch anything.", word_tokens, 0.0),
    ("Let me find out why the settings read isn't picking it up.", word_tokens, 0.02),
    (
        "Using Spotlight and git's own worktree registry, both instant.",
        split_before_last,
        0.0,
    ),
]

# A clumped segment: large bursts with gaps longer than the pacer's burst window,
# so `stream_pace` engages and releases slices on the animation cadence.
CLUMPED = (
    "It defaults to true in the shipped config, so the reasoning watchdog is on by default."
)

FINAL = "Done - whether the live node rebuilt is now answered."


def send(event: str, data: dict) -> None:
    stub_backend.push_sse(event, data)


def tool(n: int) -> None:
    call = f"call-{n}"
    send(
        "tool_call",
        {
            "name": "file_read",
            "phase": "start",
            "args": json.dumps({"path": f"lib/f{n}.ex"}),
            "tool_call_id": call,
        },
    )
    time.sleep(0.1)
    send(
        "tool_result",
        {"name": "file_read", "result": "ok", "success": True, "tool_call_id": call},
    )
    send(
        "tool_call",
        {
            "name": "file_read",
            "phase": "end",
            "duration_ms": 12,
            "success": True,
            "tool_call_id": call,
        },
    )
    time.sleep(0.15)


CONTROL = False


def script() -> None:
    """One turn: six narration lines each followed by a tool, a clumped
    segment, then the final answer. Runs on a thread while the PTY is pumped."""
    n = 0
    for i, (sentence, chunker, pause) in enumerate(NARRATION):
        mid = f"m{i}"
        if CONTROL and chunker is split_before_last:
            chunker = ollama_trimmed
        for part in chunker(sentence):
            send("streaming_token", {"text": part, "session_id": "s", "message_id": mid})
            if pause:
                time.sleep(pause)
        n += 1
        tool(n)

    # Clumped arrival: bursts of ~24 chars, 130 ms apart.
    mid = "m-clump"
    for burst in re.findall(r".{1,24}", CLUMPED, flags=re.S):
        send("streaming_token", {"text": burst, "session_id": "s", "message_id": mid})
        time.sleep(0.13)
    n += 1
    tool(n)

    mid = "m-final"
    for part in word_tokens(FINAL):
        send("streaming_token", {"text": part, "session_id": "s", "message_id": mid})
        time.sleep(0.02)
    send(
        "agent_response",
        {"response": FINAL, "response_type": "text", "signal": None, "message_id": mid},
    )


def type_and_submit(s: PtySession, text: str) -> None:
    for ch in text:
        s.write(ch.encode())
        s.pump(0.02)
    s.pump(0.35)
    s.write(b"\r")


def prose(history: str) -> str:
    """Every ┃ gutter row, gutter stripped, rows of one block joined by a space.

    A sentence that word-wrapped across two rows reads back whole, with the
    break counted as the space it replaced. A glued pair ("fileinstead") stays
    glued whatever the wrap.
    """
    rows = []
    for line in history.splitlines():
        # `PtySession.dump()` prefixes every row with "NNN|".
        stripped = re.sub(r"^\s*\d+\|", "", line).strip()
        if stripped.startswith("┃"):
            rows.append(stripped[1:].strip())
    return " ".join(r for r in rows if r)


def check(history: str) -> list[str]:
    text = prose(history)
    bad = []
    for sentence in [s for s, _, _ in NARRATION] + [CLUMPED, FINAL]:
        if sentence not in text:
            # Name the exact glued pair, so the failure reads like the report.
            words = sentence.split()
            glued = [
                a + b for a, b in zip(words, words[1:]) if (a + b) in text
            ]
            bad.append(
                f"{sentence!r} is not on screen verbatim"
                + (f"; glued: {glued}" if glued else "")
            )
    return bad


def main() -> int:
    import os

    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=None)
    ap.add_argument("--cols", type=int, default=100)
    ap.add_argument("--rows", type=int, default=40)
    ap.add_argument(
        "--control",
        action="store_true",
        help="feed the glued upstream shape; the probe must then FAIL, proving "
        "it can see a glued word at all",
    )
    args = ap.parse_args()
    global CONTROL
    CONTROL = args.control
    port = int(os.environ.get("OSA_PTY_STUB_PORT", "12797"))

    failures: list[str] = []
    with stub_backend.StubBackend(port=port) as backend:
        # Two widths: the wrap point moves, and a glue that only shows when the
        # last word lands at the row edge must not slip past at one width.
        for cols in (args.cols, 44):
            stub_backend.hold_turn()
            try:
                with PtySession(
                    backend.base_url,
                    cols=cols,
                    rows=args.rows,
                    binary=Path(args.binary) if args.binary else None,
                ) as s:
                    s.boot()
                    type_and_submit(s, "audit the worktrees")
                    if not s.wait_for_text("esc to interrupt", 5.0):
                        failures.append(f"{cols} cols: [setup] the turn never started")
                        continue
                    t = threading.Thread(target=script, daemon=True)
                    t.start()
                    while t.is_alive():
                        s.pump(0.1)
                    s.pump(2.0)
                    history = s.dump()
                    print(f"\n{'=' * 78}\nHISTORY at {cols} cols\n{'=' * 78}")
                    print(history)
                    failures += [f"{cols} cols: {f}" for f in check(history)]
            finally:
                stub_backend.release_turn()

    print(f"\n{'=' * 78}\nVERDICT\n{'=' * 78}")
    if failures:
        for f in failures:
            print(f"  FAIL  {f}")
        return 1
    print("  PASS  every narration sentence reads back with its word boundaries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
