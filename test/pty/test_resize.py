#!/usr/bin/env python3
"""Layout assertions against the real `osagent` binary on a real PTY.

Run: `test/pty/run.sh` (see test/pty/README.md).

Each test boots the binary, does something to the terminal, and then asserts
that exactly ONE copy of each singleton band (composer, context hint, status
bar) is on screen. That single assertion is the whole point: the defect this
harness exists for — a resize stranding one copy of the live region per resize
step — presents as N copies, and is invisible to the in-process Rust suite
because `VT100Backend` answers cursor queries from a perfect model.

Deliberately a plain script, not pytest: it must be runnable on a bare checkout
with nothing but `pyte` installed, and its failure output has to be a screen
dump rather than a pytest traceback, because the screen IS the evidence.
"""

from __future__ import annotations

import sys
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from osa_pty import SETTLE, SINGLETON_BANDS, PtySession  # noqa: E402
from stub_backend import StubBackend  # noqa: E402

# A high, unlikely-to-collide port. The stub binds loopback only.
STUB_PORT = 12787


def assert_single_live_region(session: PtySession, context: str) -> None:
    """Exactly one composer, one hint row, one status bar. Anything else is a
    stranded copy (too many) or a lost band (too few)."""
    counts = {name: session.count(pat) for name, pat in SINGLETON_BANDS.items()}
    wrong = {name: n for name, n in counts.items() if n != 1}
    if wrong:
        raise AssertionError(
            f"{context}: expected exactly one of each live-region band, got "
            f"{counts} (offending: {wrong}).\n"
            f"--- rendered screen ---\n{session.dump()}"
        )


# --- tests -----------------------------------------------------------------


def test_resize_sweep(backend: StubBackend) -> None:
    """A width drag must leave exactly one live region.

    This is the regression the harness was built for. Dragging a window emits
    one resize per intermediate width; the shipped defect rebuilt and
    re-anchored the inline viewport on each one while erasing only the rect it
    had just computed, stranding the previous copy. Nine drag steps produced
    nine stacked composers.

    The sweep is deliberately step-by-step with no pause between widths, which
    is what a drag looks like, and what the event loop's resize settle window
    has to coalesce.
    """
    with PtySession(backend.base_url, cols=120, rows=30) as s:
        s.boot()
        assert_single_live_region(s, "after boot at 120x30")

        for width in range(119, 79, -5):
            s.resize(width, 30)
            # Just enough pumping to deliver SIGWINCH and let the child read
            # it — NOT enough to outlast the settle window. A drag does not
            # wait for the app between steps.
            s.pump(0.05)
        s.pump(SETTLE * 2)
        assert_single_live_region(s, "after narrowing sweep 120 -> 80")

        for width in range(85, 125, 5):
            s.resize(width, 30)
            s.pump(0.05)
        s.pump(SETTLE * 2)
        assert_single_live_region(s, "after widening sweep 80 -> 120")


def test_height_resize(backend: StubBackend) -> None:
    """A vertical drag must also leave exactly one live region.

    Height changes are the harsher case: they change how many bands FIT, so
    the arbiter sheds and restores bands on the way down and back up. A band
    that is shed and then re-drawn at a stale offset is the same stranding
    class arriving by a different route.
    """
    with PtySession(backend.base_url, cols=100, rows=40) as s:
        s.boot()
        assert_single_live_region(s, "after boot at 100x40")

        for rows in range(38, 19, -2):
            s.resize(100, rows)
            s.pump(0.05)
        s.pump(SETTLE * 2)
        assert_single_live_region(s, "after shortening sweep 40 -> 20")

        for rows in range(22, 42, 2):
            s.resize(100, rows)
            s.pump(0.05)
        s.pump(SETTLE * 2)
        assert_single_live_region(s, "after heightening sweep 20 -> 40")


def test_small_viewport(backend: StubBackend) -> None:
    """On a viewport too short for every band, the composer still survives.

    The arbiter's contract (`fit_bands`) is that the live region DEGRADES
    rather than overflows: bands shed in priority order and the composer keeps
    at least `INPUT_FLOOR` rows on any viewport. In-process tests pin that
    against the arbiter's arithmetic; this pins it against a real terminal,
    where an overflow shows up as chrome scribbled outside the viewport (and
    therefore as a duplicate composer or a lost status bar).
    """
    with PtySession(backend.base_url, cols=80, rows=10) as s:
        s.boot()
        assert_single_live_region(s, "after boot at 80x10")

        # Squeeze to a genuinely hostile height, then back.
        s.resize(80, 8)
        s.pump(SETTLE * 2)
        composers = s.count(SINGLETON_BANDS["composer"])
        if composers != 1:
            raise AssertionError(
                f"at 80x8 expected exactly one composer, got {composers}.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )

        s.resize(80, 24)
        s.pump(SETTLE * 2)
        assert_single_live_region(s, "after growing back to 80x24")


def test_provider_surface(backend: StubBackend) -> None:
    """`/provider` opens a grouped provider surface, and an account provider
    that is not signed in does NOT surface an HTTP error.

    This is the harness half of the reported bug. The symptoms were:

      * "Failed to load models — HTTP 401" on clicking a provider;
      * no `/provider` command at all;
      * account providers reading as "needs key".

    All three are screen facts, and all three were invisible to the Rust suite:
    the picker's unit tests construct a `ModelPicker` directly and never go
    near the HTTP client or the command dispatcher. So this drives the real
    binary: type the command a user types, and read the screen.
    """
    with PtySession(backend.base_url, cols=110, rows=34) as s:
        s.boot()

        # Typed, then submitted separately: with a `/` prefix the composer
        # opens a completion popup that consumes the first Enter to accept the
        # highlighted entry, so a single `"/provider\r"` write leaves the text
        # sitting in the composer. That is real behaviour, not a harness
        # artefact — a user presses Enter twice too.
        s.write(b"/provider")
        s.pump(SETTLE)
        for _ in range(2):
            s.write(b"\r")
            s.pump(SETTLE)
            if "ChatGPT (Codex)" in "\n".join(s.lines()):
                break
        s.pump(SETTLE)

        screen = "\n".join(s.lines())

        # 1. The command exists. An unknown slash command leaves the composer
        #    holding the text (or toasts) rather than opening a dialog.
        if "ChatGPT (Codex)" not in screen:
            raise AssertionError(
                "/provider did not open a provider surface listing the catalog.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )

        # 2. Grouped. The accounts heading has to be on screen, above the keys
        #    one — a flat list of 31 rows is why account providers were
        #    indistinguishable from key-only ones.
        if "Connect an account" not in screen:
            raise AssertionError(
                "provider surface is not grouped: no 'Connect an account' "
                f"section heading.\n--- rendered screen ---\n{s.dump()}"
            )

        # 3. No raw HTTP error anywhere. The 401 arrived as a toast reading
        #    "Failed to load models: HTTP 401 …", so the string is the assertion.
        for bad in ("Failed to load models", "HTTP 401", "401 Unauthorized"):
            if bad in screen:
                raise AssertionError(
                    f"provider surface surfaced a raw transport error ({bad!r}).\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

        # 4. Esc gets back out. Reversibility is part of the contract: every
        #    step of this flow has to be exitable, or a user who opens the
        #    wrong provider is stuck.
        s.write(b"\x1b")
        s.pump(SETTLE)
        assert_single_live_region(s, "after Esc out of the provider surface")


def test_resize_with_transcript(backend: StubBackend) -> None:
    """A width drag with REAL transcript content in scrollback.

    `test_resize_sweep` drags an empty screen. The user's report is a drag on a
    session that has already produced output, and it corrupts the transcript as
    well as the chrome — five stacked copies of composer + hint + status, each
    with a progressively wider separator (one per intermediate width).

    Transcript content is not incidental to that. Finalized lines reach the
    terminal's real scrollback through `terminal.insert_before`, which is a
    full viewport rebuild and re-anchors exactly like a draw does. A drag on an
    empty screen never exercises it. This test fills scrollback first, then
    drags, which is the reported shape.
    """
    with PtySession(backend.base_url, cols=120, rows=30) as s:
        s.boot()

        # Fill scrollback with committed transcript lines. `/help` is
        # client-side, so it needs no model and no backend behaviour, and its
        # output is finalized content that goes through the same commit path
        # as a model reply.
        # NOT `/help` — that opens the command palette, an overlay, rather than
        # committing anything to the transcript.
        for _ in range(4):
            s.write(b"/version")
            s.pump(0.3)
            s.write(b"\r")
            s.pump(0.2)
            s.write(b"\r")
            s.pump(0.4)
            s.write(b"\x1b")
            s.pump(0.2)
        s.pump(SETTLE)
        assert_single_live_region(s, "after filling the transcript at 120x30")

        for width in range(115, 79, -5):
            s.resize(width, 30)
            s.pump(0.05)
        s.pump(SETTLE * 2)
        assert_single_live_region(s, "after narrowing sweep WITH transcript")

        for width in range(85, 125, 5):
            s.resize(width, 30)
            s.pump(0.05)
        s.pump(SETTLE * 2)
        assert_single_live_region(s, "after widening sweep WITH transcript")


def test_resize_emits_nothing_that_deposits_into_scrollback(
    backend: StubBackend,
) -> None:
    """The reflow-independent half of the resize contract.

    Every other test here asserts on the RENDERED screen, and that is exactly
    where this defect hides: pyte does not reflow on resize and VTE does, so a
    sequence that shoves the live region into unreflowable history renders here
    identically to one that erases it in place. `test_resize_with_transcript`
    passes on this harness while the same drag stacks copies on the user's
    GNOME Terminal, which is why the bug has survived several fixes.

    So assert on what OSA EMITS instead of how this emulator draws it. Two
    families are unsafe while inline:

    * **ED2 (`ESC[2J`)** — visually identical to ED0, but VTE (GNOME Terminal,
      Tilix, Terminator, every libvte embedder) implements it by SCROLLING the
      screen into the scrollback buffer rather than erasing it. Emitting it
      once per drag step deposits a full copy of composer + status per step.
      ED0 (`ESC[J` / `ESC[0J`) is an in-place erase on VTE, xterm, kitty and
      Alacritty alike, and is what the resize path is supposed to use.
    * **Explicit scrolls** (`ESC[S`, `ESC[T`, and the `ESC[NL`/`ESC[NM`
      insert/delete-line pair) — these move real lines into history by
      definition.

    Inside the alternate screen both are harmless: there is no scrollback to
    scroll into. The assertion is therefore scoped to the inline path, which is
    the one the user lives in.

    A failure here names the exact sequence, so the fix is immediate rather
    than another round of hypotheses.
    """
    unsafe = {
        b"\x1b[2J": "ED2 — VTE scrolls this into scrollback instead of erasing",
        b"\x1b[S": "scroll-up — moves lines into history",
        b"\x1b[T": "scroll-down — moves lines into history",
        b"\x1b[L": "insert-line — scrolls the region, pushing lines out",
        b"\x1b[M": "delete-line — scrolls the region, pushing lines out",
    }
    # NOT covered, and worth stating rather than implying completeness: a
    # newline written on the last row scrolls the screen IMPLICITLY, with no
    # escape sequence to match on. That is how `insert_before` makes room, so
    # this test cannot by itself exonerate the transcript-commit path — it
    # rules out the explicit families only.

    with PtySession(backend.base_url, cols=120, rows=30) as s:
        s.boot()

        # Commit real transcript content first: `insert_before` is a full
        # viewport rebuild, so a drag on an empty screen never exercises the
        # path where the stranding was reported.
        for _ in range(3):
            s.write(b"/version")
            s.pump(0.3)
            s.write(b"\r")
            s.pump(0.2)
            s.write(b"\r")
            s.pump(0.4)
            s.write(b"\x1b")
            s.pump(0.2)
        s.pump(SETTLE)

        if s.in_alt_screen():
            raise AssertionError(
                "expected to be inline before the drag; an overlay is open, so "
                "this test would vacuously pass"
            )

        mark = s.mark()
        for width in range(115, 79, -5):
            s.resize(width, 30)
            s.pump(0.05)
        for width in range(85, 125, 5):
            s.resize(width, 30)
            s.pump(0.05)
        s.pump(SETTLE * 2)

        emitted = s.emitted_since(mark)
        found = [
            f"{seq!r} ({why}) x{emitted.count(seq)}"
            for seq, why in unsafe.items()
            if seq in emitted
        ]
        if found:
            raise AssertionError(
                "the resize path emitted sequences that deposit the live "
                "region into scrollback:\n  "
                + "\n  ".join(found)
                + "\n\nThis is invisible on pyte (no reflow) and visible on "
                "VTE. Use ED0 (ESC[J) from home instead of ED2, and do not "
                "scroll to make room during a rebuild."
            )

        # The erase must actually have happened — a resize path that emits
        # nothing at all would pass the check above for the wrong reason.
        if b"\x1b[J" not in emitted and b"\x1b[0J" not in emitted:
            raise AssertionError(
                "the resize path emitted no ED0 erase at all; either the "
                "rebuild did not run, or it is clearing by some other means "
                "that this assertion no longer covers"
            )

        assert_single_live_region(s, "after the emission-checked drag")


TESTS = [
    test_resize_sweep,
    test_resize_with_transcript,
    test_resize_emits_nothing_that_deposits_into_scrollback,
    test_height_resize,
    test_small_viewport,
    test_provider_surface,
]


def main() -> int:
    failed = []
    with StubBackend(STUB_PORT) as backend:
        for test in TESTS:
            name = test.__name__
            sys.stdout.write(f"  {name} ... ")
            sys.stdout.flush()
            try:
                test(backend)
            except Exception:  # noqa: BLE001 - a harness reports, it does not raise
                failed.append(name)
                print("FAIL")
                traceback.print_exc()
            else:
                print("ok")

    total = len(TESTS)
    if failed:
        print(f"\n{len(failed)}/{total} PTY tests FAILED: {', '.join(failed)}")
        return 1
    print(f"\n{total}/{total} PTY tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
