#!/usr/bin/env python3
"""A scrollback prelude that makes REFLOW actually move things.

Why a harness needs one
-----------------------
The resize harnesses assert that a width drag leaves exactly one copy of each
singleton band. They ran against a session whose transcript was essentially
empty — a banner and a composer — and an empty transcript hides the failure mode
that the surgical clear is accused of.

That failure mode needs wrapped text ABOVE the live region:

  * The surgical clear erases from the REMEMBERED live-region top downward.
  * On a reflowing terminal, WIDENING joins wrapped lines. The content above the
    live region gets SHORTER, so the live region moves UP.
  * The real top is then ABOVE the remembered row, and a clear from the
    remembered row leaves the old chrome's first rows on screen.

With nothing above the live region there is nothing to shorten, the region never
moves, the remembered row is trivially right, and the harness passes no matter
which branch it took. That is why "the surgical clear passes on VTE too" was not
evidence of anything.

This module emits lines that are LONGER than the terminal is wide, so every one
of them wraps and every one of them re-joins on a widen. Anything narrower would
be reflow-inert and would restore the very blind spot being closed.

The text deliberately contains none of the singleton band markers (`❯`,
`/ commands`, `ctx`), so it cannot perturb the counts the harnesses assert on.
"""

from __future__ import annotations

import shlex

# Enough wrapped lines to push the live region well down the screen and to leave
# plenty above it that can shorten on a widen.
DEFAULT_LINES = 40
# Comfortably wider than the widest width any harness drags to, so the lines
# wrap at every width under test rather than only the narrow end.
DEFAULT_WIDTH = 200

# No `❯`, no "/ commands", no "ctx" — see the module docstring.
_WORD = "reflowfiller"


def prelude_text(lines: int = DEFAULT_LINES, width: int = DEFAULT_WIDTH) -> str:
    out = []
    for i in range(lines):
        body = f"{i:03d} " + (_WORD + " ") * (width // (len(_WORD) + 1) + 1)
        out.append(body[:width])
    return "\n".join(out) + "\n"


def wrap_command(binary: str, lines: int = DEFAULT_LINES, width: int = DEFAULT_WIDTH) -> list[str]:
    """`[sh, -c, ...]` that prints the prelude and then EXECs the binary.

    `exec` matters: the shell replaces itself, so the binary keeps the same pid
    and the same controlling terminal, and a harness that kills or waits on the
    spawned process still targets the thing under test.
    """
    text = prelude_text(lines, width)
    return [
        "/bin/sh",
        "-c",
        f"printf %s {shlex.quote(text)}; exec {shlex.quote(binary)}",
    ]
