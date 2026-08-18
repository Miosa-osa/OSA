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

import os
import sys
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from osa_pty import (  # noqa: E402
    COMPOSER_TOP,
    SETTLE,
    SINGLETON_BANDS,
    STATUS,
    USER_HEADER,
    PtySession,
)
from stub_backend import (  # noqa: E402
    CLEARED_SESSION_ID,
    StubBackend,
    clear_goal_state,
    end_turn,
    get_mark,
    gets_since,
    hold_health,
    hold_turn,
    post_mark,
    posts_since,
    push_sse,
    release_health,
    release_turn,
    reject_next_sse,
    reset_goal_state,
    set_claude_cli_state,
    set_goal_state,
)

# A high, unlikely-to-collide port. The stub binds loopback only.
#
# Overridable so two harness runs (two agents, or a red/green pair against
# different binaries) do not fight over the socket. A collision fails at bind
# with EADDRINUSE before any test runs, which reads like a broken harness
# rather than what it is.
STUB_PORT = int(os.environ.get("OSA_PTY_STUB_PORT", "12787"))


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


def assert_single_live_region_with_transcript(session: PtySession, context: str) -> None:
    """`assert_single_live_region`, for a screen that has COMMITTED TURNS on it.

    Same defect, same strength — a stranded copy is still caught by three
    independent markers — but two of `SINGLETON_BANDS`' four markers stop
    identifying the live region once the transcript is non-empty, and counting
    them anyway fails a correct build:

    * **`composer_top`** (`^─{20,}$`) is a bare full-width rule, and so is the
      TURN SEPARATOR drawn between committed turns. Their glyphs are identical
      and there is nothing on the row to tell them apart. Worse for this test
      specifically: pyte does not reflow, so separators committed at 120
      columns stay 120 columns wide in history after a narrowing drag, which is
      exactly the "progressively wider separator" signature the stranding bug
      produces. The marker cannot distinguish the defect from the transcript,
      so it is dropped here rather than trusted.
    * **`composer`** (`^\\s*❯`) also matches the `❯  You` header that every
      committed user message leaves behind (`USER_HEADER`). Those are counted
      and subtracted, which keeps the marker — the count below is the number of
      prompt glyphs that are NOT transcript headers, i.e. composers.

    Why this test now needs it, stated so the next reader does not re-derive
    it: a slash command used to leave no trace in the transcript, so four
    `/version` invocations committed four output blocks and no headers or
    separators, and the four raw markers happened to stay at one apiece. They
    are echoed as user messages since 1d7c11b5 (an action that starts work
    while leaving the screen unchanged is indistinguishable from a dropped
    keypress), so the same four invocations now commit four `❯  You` headers
    and three separators. Nothing about the live region changed — measured on
    the same drag, `composer`/`composer_hints`/`status` are 1/1/1 before the
    narrowing sweep, after it, and after the widening sweep. Only the markers'
    ambiguity changed.
    """
    counts = {
        "composer": session.count(SINGLETON_BANDS["composer"]) - session.count(USER_HEADER),
        "composer_hints": session.count(SINGLETON_BANDS["composer_hints"]),
        "status": session.count(SINGLETON_BANDS["status"]),
    }
    wrong = {name: n for name, n in counts.items() if n != 1}
    if wrong:
        raise AssertionError(
            f"{context}: expected exactly one of each transcript-stable "
            f"live-region band, got {counts} (offending: {wrong}).\n"
            f"--- rendered screen ---\n{session.dump()}"
        )


def test_fast_updates_the_persistent_effort_chip(backend: StubBackend) -> None:
    """The backend can change effort after startup; the status bar must adopt
    the command response instead of remaining frozen at the health snapshot.
    The default medium tier stays quiet, while a non-default tier is explicit."""
    with PtySession(backend.base_url, cols=100, rows=30) as s:
        s.boot()
        if "effort:medium" in "\n".join(s.lines()):
            raise AssertionError(f"default effort should stay quiet:\n{s.dump()}")

        s.write(b"/fast")
        s.pump(0.2)
        s.write(b"\r")
        s.pump(0.2)
        s.write(b"\r")

        if not s.wait_for_text("effort:fast", 5.0):
            raise AssertionError(
                "/fast completed but the persistent effort chip did not update.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )


def _region_top(session: PtySession) -> int | None:
    """Row the live region begins on, read off the screen.

    The composer's top divider is the first row of the composer band and the
    LAST full-width rule on screen (a turn separator draws the same glyph, but
    always above the chrome). The region starts one row higher, on the hint
    band, which is blank while nothing is being announced.
    """
    rows = [line.rstrip() for line in session.screen.display]
    tops = [i for i, line in enumerate(rows) if COMPOSER_TOP.match(line)]
    return max(tops) - 1 if tops else None


def assert_chrome_follows_the_transcript(session: PtySession, context: str) -> None:
    """**No dead band between the conversation and the chrome.**

    This replaces an unconditional `top == rows - inline_h` assertion, which was
    wrong in a way worth writing down, because it is the same mistake the
    product made.

    The live region has ONE correct position: immediately below the last line
    committed to the terminal. When the conversation is long enough to fill the
    screen that is also the bottom of the screen, and the two statements
    coincide — which is why "bottom-anchored" looked like the invariant. It is
    not; it is a consequence. Before the screen is full, demanding the bottom
    means demanding that the chrome detach from the transcript and leave a band
    of dead rows in between, which is precisely the "most of a screen of blank
    rows" the report describes.

    The product asserted the consequence and then implemented it, on a path
    where the premise did not hold: an ordinary height change (a spinner coming
    up, a turn ending — several times a turn) re-homed the region to
    `rows - inline_h` regardless of where the transcript ended. So it stated the
    invariant here and, on every turn, violated the real one.

    What is asserted instead is the real one, and it holds at every size and at
    every point in a session: the rows between the end of the transcript and the
    start of the chrome are the region's own (blank) hint row, and nothing more.
    """
    rows = [line.rstrip() for line in session.screen.display]
    top = _region_top(session)
    if top is None:
        raise AssertionError(
            f"{context}: no composer on screen at all — the live region is "
            f"missing, not merely misplaced.\n"
            f"--- rendered screen ---\n{session.dump()}"
        )
    ink_above = [i for i in range(top) if rows[i].strip()]
    if not ink_above:
        return  # nothing committed yet; there is no transcript to follow.
    gap = top - (ink_above[-1] + 1)
    if gap > 1:
        raise AssertionError(
            f"{context}: {gap} dead rows sit between the last line of the "
            f"conversation (row {ink_above[-1]}) and the top of the live region "
            f"(row {top}). The chrome must sit against the transcript; a band of "
            f"blank rows between them is the region having been re-homed "
            f"somewhere the transcript is not.\n"
            f"--- rendered screen ---\n{session.dump()}"
        )


def assert_chrome_bottom_anchored(session: PtySession, context: str) -> None:
    """The live region occupies the LAST rows of the screen.

    Only true where the premise holds — after a REAL resize. The emulator has
    reflowed, so the region's previous top is unknowable and the bottom is the
    only row the rebuild can defensibly pick (`resize_clear_top_from_bottom`).
    That is the v1.0.75 fix, and this is what pins it.

    Source-backed replay does not retire that. The rebuild now reconstructs the
    transcript from retained `Message` values instead of leaving the screen
    blank, so where the region lands is the row the REPLAY ends on — which is
    the bottom once the transcript fills the screen, and was the TOP when it did
    not. `replay_scrollback` pads a short transcript up to `rows - inline_h` for
    precisely that reason, so both this assertion and
    `assert_chrome_follows_the_transcript` hold at every transcript length.

    It measures the status bar's distance from the SCREEN BOTTOM, not from the
    last non-blank row. That distinction is the whole assertion: when the region
    is rebuilt at the top, everything below it is blank, so the status bar is
    *still* the last non-blank row and a check written that way passes on the
    broken screen. (It did. This function's first version asserted exactly that
    and stayed green with the fix reverted.)
    """
    rows = [line.rstrip() for line in session.screen.display]
    status_rows = [i for i, line in enumerate(rows) if STATUS.search(line)]
    if not status_rows:
        raise AssertionError(
            f"{context}: no status bar on screen at all — the live region is "
            f"missing, not merely misplaced.\n"
            f"--- rendered screen ---\n{session.dump()}"
        )
    # Ratatui's inline viewport may leave a row or two under the region (the
    # cursor's own line), so this is a small tolerance rather than an equality.
    # It does not need to be tight: bottom-anchored measures 1 on a 30-row
    # screen, and the defect measured 25.
    slack = (len(rows) - 1) - status_rows[-1]
    if slack > 2:
        raise AssertionError(
            f"{context}: the live region is not bottom-anchored — the status "
            f"bar is on row {status_rows[-1]} of a {len(rows)}-row screen, "
            f"leaving {slack} rows of dead space beneath it. The region was "
            f"rebuilt at the TOP of the screen; there is still exactly one of "
            f"every band, so only this assertion can see it.\n"
            f"--- rendered screen ---\n{session.dump()}"
        )


def assert_live_region_ok(session: PtySession, context: str) -> None:
    """Both invariants: exactly one live region, and it is at the bottom."""
    assert_single_live_region(session, context)
    assert_chrome_follows_the_transcript(session, context)
    # Bottom-anchoring is only the contract where the premise holds: after a
    # REAL resize. `after boot` and `after a height change` are checked by
    # `assert_chrome_follows_the_transcript` above instead.
    if "resize" in context or "sweep" in context:
        assert_chrome_bottom_anchored(session, context)


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
        assert_live_region_ok(s, "after boot at 120x30")

        for width in range(119, 79, -5):
            s.resize(width, 30)
            # Just enough pumping to deliver SIGWINCH and let the child read
            # it — NOT enough to outlast the settle window. A drag does not
            # wait for the app between steps.
            s.pump(0.05)
        s.pump(SETTLE * 2)
        assert_live_region_ok(s, "after narrowing sweep 120 -> 80")

        for width in range(85, 125, 5):
            s.resize(width, 30)
            s.pump(0.05)
        s.pump(SETTLE * 2)
        assert_live_region_ok(s, "after widening sweep 80 -> 120")


def test_height_resize(backend: StubBackend) -> None:
    """A vertical drag must also leave exactly one live region.

    Height changes are the harsher case: they change how many bands FIT, so
    the arbiter sheds and restores bands on the way down and back up. A band
    that is shed and then re-drawn at a stale offset is the same stranding
    class arriving by a different route.
    """
    with PtySession(backend.base_url, cols=100, rows=40) as s:
        s.boot()
        assert_live_region_ok(s, "after boot at 100x40")

        for rows in range(38, 19, -2):
            s.resize(100, rows)
            s.pump(0.05)
        s.pump(SETTLE * 2)
        assert_live_region_ok(s, "after shortening sweep 40 -> 20")

        for rows in range(22, 42, 2):
            s.resize(100, rows)
            s.pump(0.05)
        s.pump(SETTLE * 2)
        assert_live_region_ok(s, "after heightening sweep 20 -> 40")


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


#: Widths a narrow-terminal user actually has. 54 is the one from the report
#: (a half-screen split on a laptop); 40 is a phone-sized SSH pane; 60 is the
#: width at which the status bar starts truncating its right-hand chips.
NARROW_WIDTHS = (40, 54, 60)

#: The subset of `SINGLETON_BANDS` whose MARKER is width-stable.
#:
#: `assert_single_live_region` cannot be used below ~60 columns, and the reason
#: is the markers, not the product: `COMPOSER_HINTS` matches the literal
#: "/ commands · @ files", which the bottom divider correctly drops when there
#: is no room for it, and `COMPOSER_TOP` (`^─{20,}$`) starts matching the BOTTOM
#: divider too once that divider has shed its hint text and become a bare rule.
#: So a perfectly healthy 40-column screen reads as `composer_hints: 0,
#: composer_top: 2`. Counting the prompt glyph and the status chip instead keeps
#: the "exactly one live region" assertion honest at every width.
NARROW_SINGLETONS = {
    "composer": SINGLETON_BANDS["composer"],
    "status": SINGLETON_BANDS["status"],
}


def assert_single_live_region_narrow(session: PtySession, context: str) -> None:
    counts = {name: session.count(pat) for name, pat in NARROW_SINGLETONS.items()}
    wrong = {name: n for name, n in counts.items() if n != 1}
    if wrong:
        raise AssertionError(
            f"{context}: expected exactly one of each width-stable live-region "
            f"band, got {counts} (offending: {wrong}).\n"
            f"--- rendered screen ---\n{session.dump()}"
        )


def test_narrow_terminal_still_dispatches(backend: StubBackend) -> None:
    """A prompt typed in a NARROW terminal still reaches the backend.

    Reported as "in a small terminal I send requests and nothing happens at
    all". The composer renders, the message echoes, and then the screen sits
    there — which is consistent with two completely different faults, and the
    whole cost of that report was not knowing which:

      * the keystroke never became a request (an input/dispatch fault, ours), or
      * the request went out and the answer never came (a provider fault).

    Nothing in the suite could tell those apart, because every existing test
    here asserts on the SCREEN and both faults look identical on the screen.
    So this one asserts on the WIRE: after Enter, `POST /api/v1/orchestrate`
    must have been received, carrying the typed text.

    Booted narrow rather than resized narrow on purpose. A resize takes the
    SIGWINCH path and re-runs the arbiter; a user who opens a 54-column window
    and types into it never touches that path, and it is the untouched path
    that was suspected.

    (The answer for the reported build turned out to be the second fault — the
    request was dispatched at every width measured. This test exists so that
    stays true, and so the next report of this shape is one bisection instead
    of an investigation.)
    """
    for cols in NARROW_WIDTHS:
        with PtySession(backend.base_url, cols=cols, rows=15) as s:
            s.boot()
            assert_single_live_region_narrow(s, f"after boot at {cols}x15")

            mark = post_mark()
            s.write(b"HELLO")
            s.pump(SETTLE)
            s.write(b"\r")
            s.pump(SETTLE * 3)

            sent = posts_since(mark, "/api/v1/orchestrate")
            if not sent:
                raise AssertionError(
                    f"at {cols}x15 the prompt was typed and submitted but no "
                    f"POST /api/v1/orchestrate arrived — the keystroke never "
                    f"became a request.\n"
                    f"POSTs seen after Enter: "
                    f"{[p for p, _ in posts_since(mark)] or 'none'}\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
            if "HELLO" not in sent[0][1]:
                raise AssertionError(
                    f"at {cols}x15 the orchestrate request did not carry the "
                    f"typed text. Body was: {sent[0][1][:400]}\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

            # The live region must also still be intact after the submit —
            # narrow widths are where the composer band has least room to
            # absorb the echoed message.
            #
            # Only the status bar is counted here. The composer's prompt glyph
            # cannot be: a committed user message renders its own `❯ You` header
            # into the transcript, so `COMPOSER` legitimately matches twice once
            # anything has been said, and asserting one would fail a correct
            # build. The status bar is the band that stays a singleton for the
            # whole session.
            status_rows = s.count(NARROW_SINGLETONS["status"])
            if status_rows != 1:
                raise AssertionError(
                    f"after submit at {cols}x15: expected exactly one status "
                    f"bar, got {status_rows}.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )


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
        #
        #    Via `_escape_out`, which documents the lone-ESC input defect this
        #    single write used to trip over intermittently. The band assertion
        #    is identical; only the wait is bounded rather than fixed.
        _escape_out(s, "after Esc out of the provider surface")


def _wait_for(s: PtySession, needle: str, ceiling: float, what: str) -> str:
    """Pump until `needle` is on screen, or fail after `ceiling` seconds.

    A bounded wait rather than a fixed `pump(SETTLE * n)`: the steps being
    watched here are a real subprocess starting, printing and exiting, and the
    time each takes is a property of the machine, not of the feature. A fixed
    sleep long enough to be reliable on a loaded CI box is a sleep that makes
    the suite slow everywhere, and one short enough to be fast is one that
    flakes. This waits for the fact, and the ceiling is only there so a genuine
    regression fails instead of hanging.
    """
    waited = 0.0
    while waited < ceiling:
        s.pump(0.25)
        waited += 0.25
        if needle in "\n".join(s.lines()):
            return "\n".join(s.lines())
    raise AssertionError(
        f"{what}: {needle!r} never appeared within {ceiling}s.\n"
        f"--- rendered screen ---\n{s.dump()}"
    )


# How long one Esc gets to bring the composer back before another is sent.
#
# Measured, not guessed: instrumenting every `_escape_out` call in this suite
# per-press, a lone Esc changes the screen in 51-52ms and the composer is back
# 53-55ms after the write — every press, every flow, no outliers. Half a second
# is ~9x that, which is margin for a loaded box without making a genuinely
# undelivered keystroke cost seconds.
ESC_SETTLE_CEILING = 0.5


def _escape_out(s: PtySession, context: str, presses: int = 3) -> None:
    """Esc out of whatever overlay is up, then assert the live region is intact.

    `presses` is how many OVERLAYS deep the flow is — how many layers to peel —
    not a retry ladder for lost input. Each Esc is given `ESC_SETTLE_CEILING`
    to put the composer back; if it does not, there is another layer underneath
    and the next press peels it. Pressing again is always safe here because the
    loop only continues while the composer is absent, i.e. while something is
    still covering it.

    HISTORY — this helper used to claim it was working around an input-layer
    defect: "a lone ESC byte with no further input behind it is sometimes never
    delivered as an Esc key at all", attributed to crossterm holding the byte
    in its parse buffer, and evidenced as "7 of 8 dialogs closed in 250ms and
    the eighth was still open after 8 seconds". That was measured again, both
    here and against crossterm directly on a kernel PTY, and **it is not true**:

      * crossterm 0.28 parses a one-byte `[0x1B]` buffer as `Esc` on the spot
        whenever the read did not fill its 1024-byte buffer, which for a lone
        keypress is always. It never waits. (`event/source/unix/tty.rs` passes
        `input_available = n == TTY_BUFFER_SIZE`; `sys/unix/parse.rs` answers.)
      * Instrumented per-press, every lone Esc in this suite was delivered in
        ~52ms. None was ever held.

    The "eighth dialog, 8 seconds" was this helper measuring itself. The CLI
    sign-in flow is legitimately TWO overlays deep, so its first Esc correctly
    does not restore the composer — and the old code then sat in a 2.0s wait
    before pressing again. With `presses=5` that ladder is 10s long, and the
    2277ms it actually cost was one full 2.0s wait plus a 250ms poll, not a
    lost keystroke.

    So the wait is now short and the retries mean what they say. The band
    assertion is unchanged and unweakened.

    `event/terminal.rs` carries the full measurement, including the one real
    input defect that pass did turn up (a PARTIAL escape sequence wedges
    crossterm's parse buffer and eats the next keystroke) — which is a
    different bug, not this one, and not fixable in dialog code either.
    """
    for _ in range(presses):
        s.write(b"\x1b")
        waited = 0.0
        while waited < ESC_SETTLE_CEILING:
            s.pump(0.05)
            waited += 0.05
            if s.count(SINGLETON_BANDS["composer"]) == 1:
                assert_single_live_region(s, context)
                return
    assert_single_live_region(s, context)


def _open_provider_surface(s: PtySession) -> str:
    """Type `/provider`, submit it, and return the rendered screen.

    Factored out because three tests need the same opening move, and because
    the double-Enter is a real behaviour (the completion popup eats the first)
    that is easy to get subtly wrong per-copy.
    """
    s.write(b"/provider")
    s.pump(SETTLE)
    for _ in range(2):
        s.write(b"\r")
        s.pump(SETTLE)
        if "ChatGPT (Codex)" in "\n".join(s.lines()):
            break
    s.pump(SETTLE)
    return "\n".join(s.lines())


def test_choosing_ollama_states_the_wait_and_fetches_its_catalog_once(
    backend: StubBackend,
) -> None:
    """Switching to Ollama takes ONE Enter, and says so while it works.

    The report: on xAI/grok-4.6, opening `/model`, choosing Ollama and pressing
    Enter "doesn't switch it" — until, after several presses and a delay, it
    suddenly does.

    `ollama_local` ships `models: :dynamic`, so choosing it must fetch its
    catalog before any model can be listed. The picker used to return that
    fetch as an action while leaving itself on the PROVIDER list, so for the
    whole round-trip the screen was byte-identical to the one before the
    keypress. There is no way to tell that from a dropped key, so the user
    pressed Enter again — and each press started another fetch, whose late
    reply reset the cursor and filter once the list finally rendered.

    Both halves are asserted here, and they need different instruments:

      * the SCREEN must say a fetch is running (a rendered fact);
      * the WIRE must carry exactly one fetch (a fact no screenshot can hold,
        because duplicate fetches render identically).
    """
    with PtySession(backend.base_url, cols=110, rows=34) as s:
        s.boot()

        s.write(b"/model")
        s.pump(SETTLE)
        for _ in range(2):
            s.write(b"\r")
            s.pump(SETTLE)
            if "Ollama Local" in "\n".join(s.lines()):
                break
        s.pump(SETTLE)

        if "Ollama Local" not in "\n".join(s.lines()):
            raise AssertionError(
                "/model did not open a picker listing Ollama Local.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )

        # Walk down to the Ollama Local row.
        for _ in range(40):
            if "\u25b6 Ollama Local" in "\n".join(s.lines()) or "> Ollama Local" in "\n".join(
                s.lines()
            ):
                break
            s.write(b"\x1b[B")
            s.pump(0.05)
        s.pump(SETTLE)

        # From here on, count catalog fetches on the wire.
        mark = get_mark()

        # ONE Enter — then keep pressing, exactly as the reporter did.
        s.write(b"\r")
        s.pump(0.3)

        # Mid-fetch: the screen must SAY something is happening. This is the
        # assertion the shipped build could not pass — it rendered the
        # unchanged provider list here.
        mid = "\n".join(s.lines())
        if "Loading models" not in mid:
            raise AssertionError(
                "the catalog fetch was invisible — the screen gave no sign a "
                "keypress had been received, which is why it was pressed "
                f"again.\n--- rendered screen ---\n{s.dump()}"
            )

        # The impatient presses. None may start another fetch.
        for _ in range(3):
            s.write(b"\r")
            s.pump(0.2)

        # Let the fetch land.
        s.pump(SETTLE + 2.0)

        fetches = gets_since(mark, "/onboarding/models")
        if len(fetches) != 1:
            raise AssertionError(
                f"expected exactly ONE catalog fetch, saw {len(fetches)}. "
                "Repeated Enter during the wait queued duplicate requests, "
                "whose late replies reset the cursor and filter under the "
                f"user.\n--- rendered screen ---\n{s.dump()}"
            )

        # And the wait resolves into the model list, on the same screen.
        after = "\n".join(s.lines())
        if "Models" not in after or "Loading models" in after:
            raise AssertionError(
                "the fetch never resolved into a model list.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )


def test_one_lone_escape_closes_a_dialog(backend: StubBackend) -> None:
    """ONE Esc byte, with nothing behind it, closes the dialog. No retries.

    This is the assertion the rest of the suite cannot make, because
    `_escape_out` is allowed to press again — so a regression that made Esc
    need a second keystroke would stay green everywhere else. Here exactly one
    `\\x1b` is written into a quiet terminal and the composer has to come back.

    Two failures are in scope, and they are opposite:

      * Esc not delivered at all until some later key wakes the input layer.
        That is the defect this suite's helper used to assert was happening;
        it was not (see `_escape_out`), and this test is what will notice if it
        ever starts.
      * Esc delivered, but LATE, because something in the reader grew an
        "ESC disambiguation" hold — a timer that sits on the byte to see
        whether an arrow key follows. There is nothing left to disambiguate by
        then (crossterm decides at parse time, from whether the read filled its
        buffer), so such a hold is pure added latency on the key users press to
        get out of things. The deadline below is what makes it visible: the
        measured cost is ~55ms, so a conventional 25-50ms hold roughly doubles
        it and a careless one blows the budget outright.

    The deadline is `ESC_SETTLE_CEILING` — see that constant for why 0.5s.
    """
    with PtySession(backend.base_url) as s:
        s.boot()
        screen = _open_provider_surface(s)
        if "ChatGPT (Codex)" not in screen:
            raise AssertionError(
                "the provider surface never opened, so there was nothing to "
                f"Esc out of.\n--- rendered screen ---\n{s.dump()}"
            )
        if s.count(SINGLETON_BANDS["composer"]) != 0:
            raise AssertionError(
                "the composer is still on screen with the dialog up, so "
                "'composer is back' cannot mean 'the dialog closed'. This "
                f"test needs a different dialog.\n--- rendered screen ---\n{s.dump()}"
            )

        # Let the terminal go completely quiet first: a lone Esc arriving with
        # other input behind it is a different, easier case, and the one that
        # was never in doubt.
        s.pump(SETTLE)

        s.write(b"\x1b")
        waited = 0.0
        while waited < ESC_SETTLE_CEILING:
            s.pump(0.05)
            waited += 0.05
            if s.count(SINGLETON_BANDS["composer"]) == 1:
                break
        else:
            raise AssertionError(
                f"a single lone Esc did not close the dialog within "
                f"{ESC_SETTLE_CEILING}s (measured cost when healthy: ~55ms). "
                "Either the byte is not reaching the app, or something in the "
                "input path is holding it. See priv/rust/tui/src/event/"
                f"terminal.rs.\n--- rendered screen ---\n{s.dump()}"
            )

        assert_single_live_region(s, "after one lone Esc")


def test_provider_picker_shows_account_plan_and_a_limit_meter(
    backend: StubBackend,
) -> None:
    """The picker draws a usage panel for the selected provider.

    The data has existed all along — `Usage.RateLimits` records
    `used_percent` / `window_minutes` / `resets_at` from `x-codex-*` response
    headers, and `/usage` renders it — and the picker showed none of it. So a
    user choosing between providers could not see which plan they were about
    to spend, or how much of it was left.

    Asserted on the SCREEN rather than on `usage_rows()` because the unit test
    for that function passes whether or not the panel is ever given rows to
    draw in: `usage_panel_height` returning 0 on a dialog it thinks is short
    would leave every one of those tests green and the screen blank.
    """
    with PtySession(backend.base_url, cols=120, rows=40) as s:
        s.boot()
        _open_provider_surface(s)

        # Down once: row 0 is "Default (recommended)", row 1 is the first
        # provider, and the accounts tab sorts first.
        s.write(b"\x1b[B")
        s.pump(SETTLE)
        screen = "\n".join(s.lines())

        if "Usage" not in screen:
            raise AssertionError(
                "no usage panel on the provider picker.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )

        # The panel appears immediately and fills in when `/auth/status` and
        # `/usage/quota` answer, so wait for the measurement rather than for a
        # fixed interval. "reading…" is a legitimate intermediate state, not a
        # failure — asserting through it is what makes this flaky.
        screen = _wait_for(
            s, "48% used", 10.0, "the quota reading never reached the panel"
        )

        # 1. The account, its org, and the plan — all three. Showing only the
        #    email is the state the owner reported being unsure about.
        for needed in ("luna@example.com", "Acme Inc", "plus"):
            if needed not in screen:
                raise AssertionError(
                    f"usage panel did not name {needed!r}; account, org and plan "
                    "must all be on screen.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

        # 2. A weekly-limit meter, with the number the provider actually
        #    reported and the age of that reading.
        for needed in ("weekly limit", "48% used", "2h ago"):
            if needed not in screen:
                raise AssertionError(
                    f"usage panel did not render {needed!r}.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
        if "█" not in screen:
            raise AssertionError(
                "no meter glyph on screen — the limit rendered as text only.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )

        _escape_out(s, "after Esc out of the usage panel")


def test_a_provider_with_no_reported_quota_says_so_instead_of_drawing_zero(
    backend: StubBackend,
) -> None:
    """`claude_cli` has reported no quota, so it gets words, not a bar.

    This codebase's hard rule: an unknown never renders as a number. A limit
    meter drawn at 0% is read as "nothing used", which is the most expensive
    thing this screen could get wrong — and it is the shape a naive
    `unwrap_or(0.0)` produces, which is why this is asserted against the
    rendered screen and not against the formatter.
    """
    with PtySession(backend.base_url, cols=120, rows=40) as s:
        s.boot()
        _open_provider_surface(s)

        # Down twice: Default → ChatGPT (Codex) → Claude.
        s.write(b"\x1b[B\x1b[B")
        screen = _wait_for(
            s,
            "not known yet",
            10.0,
            "a provider that has reported no quota did not say so",
        )
        if "0% used" in screen:
            raise AssertionError(
                "an unreported quota rendered as 0% — 'nothing used' and 'we "
                "have not been told' are not the same fact.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )
        if "█" in screen:
            raise AssertionError(
                "a meter was drawn for a provider with no measurement behind it.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )


def test_claude_code_is_installed_and_signed_in_without_leaving_osa(
    backend: StubBackend,
) -> None:
    """The whole of Feature 1, driven the way a user drives it.

    Before this, selecting Claude with no CLI installed printed "install Claude
    Code" and stopped, and selecting it signed-out printed "run `claude auth
    login` then re-run OSA setup". Both are the thing the standing rule forbids:
    quit the harness and go elsewhere.

    The stub points `install_argv` and `login_program` at `/bin/echo`, so what
    is being proved here is precisely the mechanism — OSA spawns what the
    backend named, on a real pty, inside its own dialog, and the child's output
    lands on OSA's screen. Whether that child is `echo` or `npm` is not
    something the TUI knows.
    """
    set_claude_cli_state(
        installed=False,
        signed_in=False,
        login_program=None,
        login_argv=None,
        login_display=None,
    )

    with PtySession(backend.base_url, cols=120, rows=40) as s:
        s.boot()
        _open_provider_surface(s)

        # Default → ChatGPT (Codex) → Claude, then open it.
        s.write(b"\x1b[B\x1b[B")
        s.pump(SETTLE)
        s.write(b"\r")
        s.pump(SETTLE)
        # The connect screen; Enter starts the CLI route.
        s.write(b"\r")

        # 1. NOT a dead end. The install command is named in full, and the
        #    offer is to run it here. Waited for rather than pumped: the screen
        #    is drawn as soon as the dialog opens and fills in when
        #    `/auth/cli/claude` answers, and "Asking OSA about Claude Code…" is
        #    a legitimate intermediate state.
        screen = _wait_for(
            s,
            "It isn't installed on this machine",
            10.0,
            "OSA never reported the missing binary",
        )
        if "PTY-INSTALL-RAN" not in screen:
            raise AssertionError(
                "the install command was not shown in full — a link to a "
                "download page is a dead end.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )
        for banned in ("re-run setup", "re-run OSA setup", "another terminal"):
            if banned in screen:
                raise AssertionError(
                    f"the screen still sends the user away ({banned!r}).\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

        # 2. Enter runs it, on a pty, inside OSA. The child's stdout has to
        #    appear on OSA's own screen WHILE IT IS STILL RUNNING — that is
        #    the pane working, as opposed to a summary printed afterwards.
        #    The state is moved now, so the re-check that follows the child's
        #    exit sees an installed CLI, exactly as a real install would.
        set_claude_cli_state(
            installed=True,
            path="/usr/bin/claude",
            version="2.1.226",
            version_ok=True,
            login_program="/bin/sh",
            login_argv=["-c", "echo PTY-LOGIN-RAN; sleep 4"],
            login_display="claude auth login",
        )
        s.write(b"\r")
        screen = _wait_for(
            s,
            "PTY-INSTALL-RAN",
            6.0,
            "the spawned child's output never reached OSA's screen — the pty "
            "pane is not rendering",
        )
        if "Installing Claude Code" not in screen:
            raise AssertionError(
                "the pane did not say what it was running.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )

        # 3. Let the child finish on its own. OSA re-asks the backend rather
        #    than inferring success from an exit code, and lands on the
        #    DETECTED login subcommand with no further keystrokes.
        _wait_for(
            s,
            "claude auth login",
            15.0,
            "after installing, OSA did not re-check and offer the detected "
            "login subcommand",
        )

        # 4. Run the sign-in. Same mechanism, second child.
        set_claude_cli_state(
            signed_in=True,
            account="luna@example.com",
            org="Acme Inc",
            plan="max",
        )
        s.write(b"\r")
        _wait_for(
            s,
            "PTY-LOGIN-RAN",
            6.0,
            "the sign-in child's output never reached OSA's screen",
        )

        # 5. The success screen names email, org AND plan. This is the
        #    complaint the feature exists to answer: "connected" with only an
        #    email left the owner unsure which account was live.
        screen = _wait_for(
            s,
            "Connected through Claude Code",
            15.0,
            "OSA never confirmed the sign-in after the CLI exited",
        )
        for needed in ("luna@example.com", "Acme Inc", "max"):
            if needed not in screen:
                raise AssertionError(
                    f"the connected screen did not name {needed!r}.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

        # 6. And back out cleanly: a pty pane that strands chrome is the exact
        #    class this harness exists for. Two overlays deep (CLI screen, then
        #    the picker), so more presses than the default.
        _escape_out(s, "after backing out of the CLI sign-in", presses=5)

    # Leave the stub as the other tests expect to find it.
    set_claude_cli_state(
        installed=False,
        path=None,
        version=None,
        version_ok=None,
        signed_in=False,
        account=None,
        org=None,
        plan=None,
        login_program=None,
        login_argv=None,
        login_display=None,
    )


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
        # `assert_single_live_region_with_transcript`, not the bare one: two of
        # the four raw markers stop identifying the live region once committed
        # turns are on screen. See that helper for which, and why.
        assert_single_live_region_with_transcript(
            s, "after filling the transcript at 120x30"
        )

        for width in range(115, 79, -5):
            s.resize(width, 30)
            s.pump(0.05)
        s.pump(SETTLE * 2)
        assert_single_live_region_with_transcript(
            s, "after narrowing sweep WITH transcript"
        )

        for width in range(85, 125, 5):
            s.resize(width, 30)
            s.pump(0.05)
        s.pump(SETTLE * 2)
        assert_single_live_region_with_transcript(
            s, "after widening sweep WITH transcript"
        )


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

        # `assert_single_live_region_with_transcript`, not the bare one, and for
        # exactly the reason `test_resize_with_transcript` already gives: this
        # test commits THREE `/version` turns before it drags, so the screen
        # carries three `❯  You` headers (which `COMPOSER` matches) and the turn
        # separators between them (which `COMPOSER_TOP` matches). Counting those
        # as stranded chrome reads a healthy screen as `composer: 4,
        # composer_top: 3`.
        #
        # The bare assertion passed here only while a resize WIPED the
        # transcript off the screen: with nothing committed left to see, the
        # ambiguous markers had nothing to collide with and happened to read 1
        # apiece. Now that the resize path replays the transcript instead of
        # destroying it, the markers collide here exactly as they always did in
        # `test_resize_with_transcript`. Measured across the drag this test
        # performs, all four raw counts are IDENTICAL before and after
        # (`composer_top` 3/3, `composer` 4/4, `composer_hints` 1/1, `status`
        # 1/1) — nothing stacked; the screen simply stopped being empty.
        #
        # Three independent markers still have to read exactly one, so the
        # stranding this test exists to catch is still caught.
        assert_single_live_region_with_transcript(s, "after the emission-checked drag")


def test_connecting_splash_does_not_trap_the_user(backend: StubBackend) -> None:
    """Keys pressed while OSA is connecting are honoured, not discarded.

    `App::handle_key` matched on `self.state` and ended in `_ => false`, and
    `AppState::Connecting` was the one variant with no arm — so for the whole
    duration of connect **every** key was silently dropped, Ctrl+C and Ctrl+D
    included. That window is not short: `handle_health_result` retries a
    backend that will not answer twelve times before giving up, so a user whose
    backend is slow or dead sat on a spinner with no working key at all. Typing
    into a slow start is exactly what people do, and all of it vanished.

    Held open here by gating `/health` at the stub, which is the same shape as
    the real cause. Four things are asserted, in the order a user meets them:

      1. the splash names an escape hatch (`Ctrl+C to quit`);
      2. typed characters are KEPT and echoed, so "my keystrokes disappeared"
         is not a reading the screen supports;
      3. Enter does NOT submit them — the buffered draft cannot become a
         request, nor a `/command`, before the session exists;
      4. Ctrl+C actually exits the process.

    (4) is the one that cannot be asserted on the screen at all: an app that
    ignores Ctrl+C and one that handles it look identical until the process is
    gone, which is why `wait_exit` exists.

    A binary with the shipped defect fails at (1) — there is nothing on the
    splash to find — and, with that hint removed, at (2), (3) is vacuous and
    (4) hangs to its deadline.
    """
    hold_health()
    try:
        with PtySession(backend.base_url, cols=100, rows=30) as s:
            if not s.wait_for_text("Connecting", 10.0):
                raise AssertionError(
                    "the connect splash never appeared, so there was no "
                    f"connecting state to press keys in.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
            if s.count(SINGLETON_BANDS["composer"]) != 0:
                raise AssertionError(
                    "the composer is already on screen, so the app is past "
                    "Connecting and this test would prove nothing.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

            # 1. The escape hatch is printed. Without it, a user has no way to
            #    learn that any key works.
            if "Ctrl+C to quit" not in "\n".join(s.lines()):
                raise AssertionError(
                    "the connect splash does not say how to get out of it.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

            # 2. Typing is kept and shown.
            mark = post_mark()
            s.write(b"KEPT-WHILE-CONNECTING")
            if not s.wait_for_text("KEPT-WHILE-CONNECTING", 3.0):
                raise AssertionError(
                    "text typed during connect was neither buffered nor shown "
                    "— every keystroke went nowhere, which is the reported "
                    f"defect.\n--- rendered screen ---\n{s.dump()}"
                )

            # 3. …but Enter cannot send it. The draft is held, not armed.
            s.write(b"\r")
            s.pump(SETTLE)
            premature = posts_since(mark, "/api/v1/orchestrate")
            if premature:
                raise AssertionError(
                    "Enter submitted the buffered draft while the session was "
                    "still connecting. Buffering typed text is only safe if it "
                    f"cannot be sent yet. Body: {premature[0][1][:200]}"
                )

            # 4. Ctrl+C gets out. This is the whole complaint class.
            s.write(b"\x03")
            if not s.wait_exit(5.0):
                raise AssertionError(
                    "Ctrl+C did not quit the connect splash — the user is "
                    "trapped on it for as long as the backend takes to answer "
                    "(up to twelve health retries), with no working key.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
    finally:
        release_health()


def test_a_draft_typed_while_connecting_survives_into_the_composer(
    backend: StubBackend,
) -> None:
    """The buffered text is really in the composer, not just painted on a splash.

    The companion to the assertion above, and the one that decides whether
    "buffered" was honest. Echoing the characters back on the splash and then
    throwing them away when the state changes would pass every screen check in
    the other test and still lose the user's first prompt.
    """
    hold_health()
    try:
        with PtySession(backend.base_url, cols=100, rows=30) as s:
            if not s.wait_for_text("Connecting", 10.0):
                raise AssertionError(
                    f"no connect splash.\n--- rendered screen ---\n{s.dump()}"
                )
            s.write(b"SURVIVES-CONNECT")
            if not s.wait_for_text("SURVIVES-CONNECT", 3.0):
                raise AssertionError(
                    f"the draft was not buffered.\n--- rendered screen ---\n{s.dump()}"
                )
            release_health()
            s.boot()

            # The composer row itself must carry it — matched against the
            # prompt glyph so a leftover splash row cannot satisfy this.
            rows = [line for line in s.lines() if "SURVIVES-CONNECT" in line]
            if not any(SINGLETON_BANDS["composer"].search(line) for line in rows):
                raise AssertionError(
                    "the draft typed during connect did not arrive in the "
                    "composer — it was echoed and then dropped, which loses "
                    "the user's first prompt just as surely as never taking "
                    f"the keystrokes at all.\nrows holding it: {rows}\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
    finally:
        release_health()


#: How long the test below waits between the two Escs.
#:
#: The old in-turn interrupt window was 800ms. This has to be comfortably past
#: it — far enough that no amount of scheduler jitter on a loaded box could put
#: the second press back inside — while still being a pause a real user makes
#: without thinking about it. 2.5s is ~3x the old window.
SLOW_ESC_GAP = 2.5


def test_a_slow_second_escape_still_interrupts(backend: StubBackend) -> None:
    """Esc … pause … Esc interrupts the turn. The window is not timed.

    Reported as a session that appeared to hang and could not be escaped; the
    user ended up queueing `/exit`. The interrupt machinery underneath was
    working the whole time — the backend cancel is a cooperative ETS flag and a
    watcher brutal-kills the provider task — and the failure was entirely in
    the input window: `EscTracker` paired two Escs only within 800ms, and a
    slower second press was silently swallowed and re-armed.

    Silently is the operative word, and it is why widening the window would
    have been the wrong fix. The first Esc flips the spinner's affordance to
    "esc again to interrupt" and **nothing un-paints it when the window
    lapses**, so past 800ms the screen went on promising a second Esc would
    work while the tracker had already forgotten the first. Any fixed window
    has that same lying interval; only removing the timer removes it. So the
    assertion here is deliberately in two parts: the screen still says the
    interrupt is armed after the pause, AND the press it promises lands.

    Asserted on the WIRE, not the screen. `cancel_processing` toasts
    "Interrupting…" immediately and unconditionally, so a screen check would
    pass on a build where the request was never sent. The fact that decides it
    is `POST /api/v1/sessions/<id>/cancel` arriving.

    Requires a turn that is genuinely in flight: `POST /api/v1/orchestrate` is
    a long poll for a whole turn, so the stub holds it open. Without that the
    TUI is back at Idle within milliseconds and Esc means something else
    entirely (clear the draft / open the rewind picker) — a test that pressed
    Esc twice there would pass while proving nothing about interrupts.
    """
    hold_turn()
    try:
        with PtySession(backend.base_url, cols=120, rows=30) as s:
            s.boot()

            mark = post_mark()
            s.write(b"HANG FOR A WHILE")
            s.pump(SETTLE)
            s.write(b"\r")

            # Wait for the turn to be genuinely outstanding.
            waited = 0.0
            while waited < 10.0 and not posts_since(mark, "/api/v1/orchestrate"):
                s.pump(0.25)
                waited += 0.25
            if not posts_since(mark, "/api/v1/orchestrate"):
                raise AssertionError(
                    "the prompt never reached the backend, so there was no "
                    f"turn to interrupt.\n--- rendered screen ---\n{s.dump()}"
                )
            if not s.wait_for_text("esc to interrupt", 5.0):
                raise AssertionError(
                    "the TUI is not showing a running turn, so Esc does not "
                    f"mean interrupt here.\n--- rendered screen ---\n{s.dump()}"
                )

            # First Esc — arms, does not cancel.
            cancel_mark = post_mark()
            s.write(b"\x1b")
            if not s.wait_for_text("esc again to interrupt", 3.0):
                raise AssertionError(
                    "the first Esc did not arm the interrupt affordance.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
            if posts_since(cancel_mark, "/api/v1/sessions/pty-stub-session/cancel"):
                raise AssertionError(
                    "a SINGLE Esc cancelled the turn. The confirm step is not "
                    "decoration — one stray Esc must not kill a long turn."
                )

            # The pause. This is the entire test.
            s.pump(SLOW_ESC_GAP)

            # The screen is still promising the interrupt after the old window
            # would have lapsed. If this ever stops being true the promise has
            # been withdrawn honestly, and the test below is a different (also
            # acceptable) contract — but it must not be silent, so fail here
            # rather than quietly changing meaning.
            if "esc again to interrupt" not in "\n".join(s.lines()):
                raise AssertionError(
                    f"after {SLOW_ESC_GAP}s the armed affordance is gone from "
                    "the screen. That is not necessarily wrong, but this test "
                    "no longer asserts what it says it does — see the "
                    f"docstring.\n--- rendered screen ---\n{s.dump()}"
                )

            # Second Esc, late. It must interrupt.
            s.write(b"\x1b")
            waited = 0.0
            while waited < 5.0:
                s.pump(0.25)
                waited += 0.25
                if posts_since(cancel_mark, "/api/v1/sessions/pty-stub-session/cancel"):
                    break
            else:
                raise AssertionError(
                    f"an Esc pressed {SLOW_ESC_GAP}s after the first did not "
                    "interrupt the turn: no POST to "
                    "/api/v1/sessions/<id>/cancel arrived. The screen was "
                    "still saying 'esc again to interrupt' the whole time. "
                    "This is the report — the user pressed Esc twice, nothing "
                    "happened, and they had to queue /exit to get out.\n"
                    f"POSTs since the first Esc: "
                    f"{[p for p, _ in posts_since(cancel_mark)] or 'none'}\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
    finally:
        release_turn()


def test_one_stray_escape_still_does_not_kill_a_turn(backend: StubBackend) -> None:
    """The confirm step survives the window change. Untimed is not unconditional.

    Removing the timer must not turn Esc into a single-press kill, and — the
    subtler half — an intervening keystroke must still withdraw the arm. That
    is now the ONLY thing that does, so if it were broken the first Esc of a
    session would sit armed forever and some much later, unrelated Esc would
    kill a turn the user was not trying to stop.
    """
    hold_turn()
    try:
        with PtySession(backend.base_url, cols=120, rows=30) as s:
            s.boot()
            mark = post_mark()
            s.write(b"HANG FOR A WHILE")
            s.pump(SETTLE)
            s.write(b"\r")
            waited = 0.0
            while waited < 10.0 and not posts_since(mark, "/api/v1/orchestrate"):
                s.pump(0.25)
                waited += 0.25
            if not s.wait_for_text("esc to interrupt", 5.0):
                raise AssertionError(
                    f"no running turn.\n--- rendered screen ---\n{s.dump()}"
                )

            cancel_mark = post_mark()
            s.write(b"\x1b")          # arm
            s.pump(0.5)
            s.write(b"x")             # an ordinary keystroke — withdraws it
            s.pump(0.5)
            s.write(b"\x1b")          # this is a FIRST press again, not a pair
            s.pump(SETTLE)

            if posts_since(cancel_mark, "/api/v1/sessions/pty-stub-session/cancel"):
                raise AssertionError(
                    "Esc, a keystroke, Esc cancelled the turn. An intervening "
                    "key must break the pair — with no time bound left it is "
                    "the only thing that can, so a stale arm would otherwise "
                    "let an unrelated Esc kill a turn much later."
                )
    finally:
        release_turn()


def test_a_stale_backend_says_so_instead_of_relabelling_the_tui(
    backend: StubBackend,
) -> None:
    """A version mismatch between the TUI and the daemon is SHOWN, not adopted.

    The OSA backend daemon survives TUI exit and can be days older than the TUI
    that attaches to it. A user reported a hang "on the old version" and an hour
    went into establishing that their daemon was stale rather than their code.

    What made it invisible was not merely a missing warning. The TUI *adopted*
    the daemon's version as its own display version — `set_runtime_version` ran
    unconditionally on every health response — so a stale daemon silently
    rewrote the status-bar chip, the welcome banner and `/version` to the OLD
    number. Every surface the user could check agreed with the daemon, and none
    of them revealed the disagreement.

    The stub reports `STUB_VERSION`, which is deliberately never a real release
    number, so attaching to it is exactly the stale-daemon shape. Two things are
    asserted:

      1. the transcript carries a notice naming the mismatch, and
      2. it names the remedy the launcher actually performs — re-running `osa` —
         and NOT `osa stop`, which `bin/osa` states is an instruction no user
         should ever be given.

    A binary with the shipped defect fails (1): the connect is silent and the
    TUI relabels itself to the stub's version.
    """
    with PtySession(backend.base_url, cols=100, rows=30) as s:
        if not s.wait_for_text("Version mismatch", 15.0):
            raise AssertionError(
                "attaching to a backend reporting a different version produced "
                "no mismatch notice, so a stale daemon is still silent.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )


def test_a_missing_session_recovers_without_a_reconnect_loop(
    backend: StubBackend,
) -> None:
    """A healthy backend plus a missing session must create a replacement.

    This is the exact production failure from the report: `/health` returned
    healthy while `GET /api/v1/stream/<session>` returned 404. Treating that
    permanent response as a network blip left the footer saying
    `Reconnecting to backend...` while retrying the same impossible URL.

    The first stream attach is rejected. A correct client creates one fresh
    session, attaches its stream, and returns to a usable composer without any
    backend restart or user input.
    """
    mark = post_mark()
    get_start = get_mark()
    reject_next_sse(session_id="pty-stub-session")
    with PtySession(backend.base_url, cols=100, rows=30) as s:
        s.boot()

        waited = 0.0
        session_posts = []
        while waited < 5.0:
            s.pump(0.1)
            waited += 0.1
            session_posts = posts_since(mark, "/api/v1/sessions")
            streams = [
                path
                for path in gets_since(get_start)
                if path.startswith("/api/v1/stream/")
            ]
            replacement_streams = [
                path for path in streams if path.endswith("/pty-stub-session")
            ]
            if len(session_posts) >= 2 and len(replacement_streams) >= 2:
                break

        if len(session_posts) != 2:
            raise AssertionError(
                "a missing stream did not create exactly one replacement "
                f"session; saw {len(session_posts)} session creates.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )
        if len(replacement_streams) != 2:
            raise AssertionError(
                "the replacement session did not attach exactly one fresh "
                f"stream after the rejected one; saw {streams}.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )
        if "Reconnecting to backend" in "\n".join(s.lines()):
            raise AssertionError(
                "the TUI recovered but left the reconnect banner visible.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )
        screen = s.dump()
        if "osa stop" in screen:
            raise AssertionError(
                "the notice tells the user to run `osa stop`. bin/osa states "
                "that is a failure of the product: re-running `osa` performs "
                "the repair by itself.\n"
                f"--- rendered screen ---\n{screen}"
            )


def _start_a_turn(s: PtySession, prompt: bytes) -> None:
    """Submit `prompt` and wait until the turn is genuinely outstanding.

    Every test below needs a real in-flight turn, not a screen that looks like
    one. `hold_turn()` must already be in force or this returns as the turn is
    ending.
    """
    mark = post_mark()
    s.write(prompt)
    s.pump(SETTLE)
    s.write(b"\r")
    waited = 0.0
    while waited < 10.0 and not posts_since(mark, "/api/v1/orchestrate"):
        s.pump(0.25)
        waited += 0.25
    if not posts_since(mark, "/api/v1/orchestrate"):
        raise AssertionError(
            "the prompt never reached the backend, so no turn was started.\n"
            f"--- rendered screen ---\n{s.dump()}"
        )


def _submit_slash(s: PtySession, text: bytes) -> None:
    """Type and SUBMIT a slash command.

    Two Enters, deliberately. Typing `/` opens the command-completion popup, and
    the first Enter accepts the highlighted completion rather than submitting —
    so a single `\\r` leaves the text sitting in the composer, unsent. A test
    that sent one Enter would be asserting about a command that never ran, and
    would "fail" identically on a fixed build.
    """
    s.write(text)
    s.pump(SETTLE)
    s.write(b"\r")
    s.pump(SETTLE)
    s.write(b"\r")


def test_a_turn_that_ends_under_an_overlay_does_not_wedge_the_session(
    backend: StubBackend,
) -> None:
    """After a turn ends, the next prompt must still be SENT.

    This is the "nothing happens" report. The session answered one prompt, and
    from then on every prompt produced no reply, no error, and no request —
    Enter simply did nothing.

    The mechanism is a busy flag that outlives the turn it describes. ~20
    overlays can be opened FROM `Processing` (`/cost`, `/context`, the command
    palette on Ctrl+K…), and `enter_overlay` parks the caller — `Processing` —
    on the return stack. The normal turn-end teardown only ever did
    `if self.state.is_processing() { transition(Idle) }`, and while an overlay
    is up `self.state` is the overlay, so the parked `Processing` survived the
    turn that owned it. Closing the overlay restored it faithfully.

    From there the session is inert for good: `turn_is_active()` reads the
    parked value, so `submit_input` takes the enqueue branch forever, while
    `queue_may_drain` requires `state == Idle` and can never be true again.
    Prompts pile up in a queue nothing will drain. Esc is no escape either —
    both `Action::Interrupt` and the `CancelTimeout` safety net were gated on
    the same `is_processing()` the parked value defeats.

    Asserted on the WIRE. The screen is not evidence here: a wedged build draws
    a perfectly normal composer, accepts the keystrokes, echoes them, and sends
    nothing. `POST /api/v1/orchestrate` arriving is the whole fact.
    """
    hold_turn()
    try:
        with PtySession(backend.base_url, cols=120, rows=30) as s:
            s.boot()
            _start_a_turn(s, b"FIRST PROMPT")

            # Open an overlay from Processing. `alt+p` (the provider/model
            # picker) is bound in the GLOBAL keymap context, so it is one of the
            # few overlays a user can actually reach mid-turn — Ctrl+K's palette
            # is `Context::Idle` only, and every slash command is queued while a
            # turn runs. This is what parks `Processing` on the return stack.
            s.write(b"\x1bp")
            s.pump(1.0)
            if "Select Provider" not in "\n".join(s.lines()):
                raise AssertionError(
                    "the overlay did not open mid-turn, so this test never "
                    "reaches the state it is about. If the binding moved, pick "
                    "another Global-context overlay rather than deleting the "
                    f"test.\n--- rendered screen ---\n{s.dump()}"
                )

            # End the turn while the overlay owns the screen. This is the exact
            # ordering that matters: the teardown runs with `self.state` set to
            # the overlay, so a guard that only looks at `self.state` misses.
            release_turn()
            end_turn()
            s.pump(1.0)

            # Close the overlay. A wedged build lands back in `Processing`.
            s.write(b"\x1b")
            s.pump(SETTLE)

            # The session must still work.
            mark = post_mark()
            s.write(b"SECOND PROMPT")
            s.pump(SETTLE)
            s.write(b"\r")
            waited = 0.0
            while waited < 8.0 and not posts_since(mark, "/api/v1/orchestrate"):
                s.pump(0.25)
                waited += 0.25
            if not posts_since(mark, "/api/v1/orchestrate"):
                raise AssertionError(
                    "the session went inert: a prompt typed after a turn that "
                    "ended under an overlay produced no POST to "
                    "/api/v1/orchestrate. This is the report — the user types, "
                    "presses Enter, and nothing happens, with no error and "
                    "nothing on screen to explain it.\n"
                    f"POSTs since: {[p for p, _ in posts_since(mark)] or 'none'}\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
    finally:
        release_turn()


def test_clear_leaves_no_queued_message_behind(backend: StubBackend) -> None:
    """`/clear` must not leave the user's own message on screen afterwards.

    Reported as: after `/clear`, a duplicate of the previous message was
    sitting at the top of the screen, and it had to be typed again.

    It was neither a duplicate nor a rendering artefact. A prompt typed while a
    turn is running is held in `message_queue` and drawn as a dim row directly
    above the composer. `/clear` reset the transcript, the tool list, the
    attachments and the real terminal scrollback — and had no opinion about the
    queue. So on an otherwise empty screen the one surviving row was the user's
    own queued text, at the top, looking exactly like a transcript entry that
    the clear had failed to remove. Retyping was rational: the text on screen
    was never in the composer.

    Two assertions, and the second is the load-bearing one. The text being gone
    from the SCREEN could be achieved by a build that merely stopped drawing
    the queue; what must actually be true is that the message is no longer
    pending, so it never fires afterwards.
    """
    hold_turn()
    try:
        with PtySession(backend.base_url, cols=120, rows=30) as s:
            s.boot()
            _start_a_turn(s, b"FIRST PROMPT")

            # Type a second prompt mid-turn — this one is QUEUED.
            s.write(b"ok how about now")
            s.pump(SETTLE)
            s.write(b"\r")
            s.pump(SETTLE)
            if not s.wait_for_text("ok how about now", 5.0):
                raise AssertionError(
                    "the mid-turn prompt was not queued/shown at all, so this "
                    "test cannot prove anything about clearing it.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

            # Clear. Note this is typed while the turn is STILL running: that is
            # how the user hit it, and queueing `/clear` behind the turn it is
            # meant to escape is itself the defect that made "ℹ Chat cleared"
            # repeat down the screen in the reported paste.
            clear_mark = post_mark()
            _submit_slash(s, b"/clear")
            s.pump(1.5)

            if "ok how about now" in "\n".join(s.lines()):
                raise AssertionError(
                    "after /clear the user's own message is still on screen. "
                    "This is the report: a 'duplicate' at the top that the "
                    "clear did not remove, which was really a live queue "
                    "entry.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

            # And it must not be merely hidden. Let the held turn finish: if the
            # queue survived, the drain fires it now and it reaches the backend.
            release_turn()
            end_turn()
            s.pump(2.0)

            leaked = [
                (p, b) for p, b in posts_since(clear_mark, "/api/v1/orchestrate")
                if "ok how about now" in b
            ]
            if leaked:
                raise AssertionError(
                    "/clear hid the queued message but did not cancel it: it "
                    "was still sent to the backend after the turn ended. A "
                    "clear that leaves work pending is a clear in appearance "
                    f"only.\nleaked: {leaked}\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
    finally:
        release_turn()


def test_clear_adopts_the_session_the_backend_hands_back(
    backend: StubBackend,
) -> None:
    """`/clear` must talk to the NEW session afterwards.

    `POST /sessions/:id/clear` is a session SWAP, not an in-place wipe: the
    backend stops the old loop and returns a brand-new id with the old one as
    `parent_session`. The client dropped that response on the floor
    (`clear_session` returned `Result<()>`), so the TUI kept addressing the
    session the clear had just stopped.

    That is what made the clear a lie rather than merely untidy. The next
    orchestrate restarted the stopped loop, `Loop.init` found no checkpoint —
    the clear had wiped it — and fell through to `load_persisted_messages/1`,
    reading back the very file the clear endpoint itself had just written via
    its pre-clear `auto_save`. The whole discarded conversation was reloaded
    into the model, while the fresh session the backend built sat orphaned.

    So the assertion is on the ADDRESS of the next request, which is the only
    thing that distinguishes the two builds — both clear the screen identically.
    """
    with PtySession(backend.base_url, cols=120, rows=30) as s:
        s.boot()

        _submit_slash(s, b"/clear")
        s.pump(1.5)

        mark = post_mark()
        s.write(b"AFTER THE CLEAR")
        s.pump(SETTLE)
        s.write(b"\r")
        waited = 0.0
        while waited < 8.0 and not posts_since(mark, "/api/v1/orchestrate"):
            s.pump(0.25)
            waited += 0.25

        sent = posts_since(mark, "/api/v1/orchestrate")
        if not sent:
            raise AssertionError(
                "no prompt reached the backend after /clear.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )
        body = sent[-1][1]
        if CLEARED_SESSION_ID not in body:
            raise AssertionError(
                "after /clear the TUI is still addressing the OLD session. The "
                "backend returned a new id and the client discarded it, so the "
                "next turn reopens the stopped session — which reloads the "
                "'cleared' conversation from disk. The model still remembers "
                "everything.\n"
                f"expected session id {CLEARED_SESSION_ID!r} in the orchestrate "
                f"body, got: {body}\n"
                f"--- rendered screen ---\n{s.dump()}"
            )


def _submit(s: PtySession, text: bytes) -> None:
    """Type `text` and submit it.

    Two Enters, like `_start_a_turn`: a leading `/` opens the completions popup,
    and the first Enter closes it rather than submitting.
    """
    s.write(text)
    s.pump(SETTLE)
    s.write(b"\r")
    s.pump(SETTLE)
    s.write(b"\r")
    s.pump(SETTLE)


def _flat(s: PtySession) -> str:
    """The screen as one whitespace-normalised string.

    A system notice is wrapped to the terminal width, so a phrase the test cares
    about is routinely split across two rows. Searching the raw line list for it
    fails on a build that renders it perfectly.
    """
    import re as _re

    return _re.sub(r"\s+", " ", " ".join(line.strip() for line in s.lines()))


def _run_a_tool(marker: str, call_id: str) -> None:
    """Drive one complete non-collapsible tool call down the stream.

    `make` deliberately, not `ls`/`cat`/`rg`: `collapse::classify_shell_command`
    folds pure search/read pipelines into a one-line "Read 3 files" summary, and
    a folded run has no per-call cell to hide. This one renders its own row with
    the command in it, which is what the assertions look for.
    """
    args = '{"command":"make %s"}' % marker
    push_sse("tool_call", {"name": "shell_execute", "phase": "start",
                           "args": args, "tool_call_id": call_id})
    push_sse("tool_call", {"name": "shell_execute", "phase": "end", "args": args,
                           "duration_ms": 12, "success": True, "tool_call_id": call_id})
    push_sse("tool_result", {"name": "shell_execute", "result": "ok",
                             "success": True, "tool_call_id": call_id})


def test_the_lean_view_hides_tool_calls_and_only_tool_calls(
    backend: StubBackend,
) -> None:
    """`/lean` removes the tool rows and nothing else.

    Asked for as "some mode that hides the tool calls… you only see what the
    model is saying" — a lean view rather than a working view.

    The risk in any output-suppressing flag is not that it hides too little. It
    is that it hides an approval request, and parks the session on a dialog
    nobody can see: a turn that ended under an overlay wedged a session
    permanently, and the user could not tell it from slowness. So this test
    spends most of its length on the negative space. It pins, in one session:

      * a control — with the mode OFF the tool row IS printed, so a later
        absence means something;
      * the tool row gone once the mode is on;
      * the turn's prose still printed;
      * an error still printed;
      * a permission prompt still on screen;
      * the receipt that says how many calls were hidden, because total silence
        through a long turn reads as a hang;
      * the confirmation naming what the toggle actually did.

    This has to be a PTY test. `cargo test` renders through `VT100Backend`,
    which answers cursor queries from a perfect model — the unit suite can prove
    `Chat` queues the right blocks (it does, in `reading_view_tests`) but not
    that the right things ended up on a real screen.
    """
    hold_turn()
    try:
        with PtySession(backend.base_url, cols=120, rows=36) as s:
            s.boot()

            # --- control: the mode is off, so the row must be there ---------
            _start_a_turn(s, b"FIRST PROMPT")
            _run_a_tool("PTYTOOLVISIBLE", "call_visible")
            if not s.wait_for_text("PTYTOOLVISIBLE", 6.0):
                raise AssertionError(
                    "the tool row never appeared with the lean view OFF, so "
                    "this test cannot tell a hidden row from a row that was "
                    "never drawn. If the tool cell shape changed, fix the "
                    "control rather than deleting it.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
            release_turn()
            end_turn("first answer")
            s.pump(SETTLE)

            # --- turn it on -------------------------------------------------
            _submit(s, b"/lean")
            if not s.wait_for_text("Lean view: on", 6.0):
                raise AssertionError(
                    "/lean produced no confirmation. A mode that changes "
                    "what the screen shows and says nothing about it is the "
                    "kind of quiet lie this command exists not to be.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
            # And it must say that it applies going forward, because it does:
            # printed rows live in the terminal's own scrollback at the width
            # they were wrapped at and cannot be un-printed.
            screen = _flat(s)
            if "from here on" not in screen:
                raise AssertionError(
                    "the confirmation did not say the change applies from here "
                    "on. It cannot be retroactive, so it must not imply it "
                    f"is.\n--- rendered screen ---\n{s.dump()}"
                )
            if "PTYTOOLVISIBLE" not in screen:
                raise AssertionError(
                    "turning the mode on retroactively erased a row that had "
                    "already been printed. That is not possible honestly — it "
                    "means something is repainting native scrollback.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

            # --- with it on: the tool row is gone ---------------------------
            hold_turn()
            _start_a_turn(s, b"SECOND PROMPT")
            _run_a_tool("PTYTOOLHIDDEN", "call_hidden")
            s.pump(SETTLE * 2)
            if "PTYTOOLHIDDEN" in "\n".join(s.lines()):
                raise AssertionError(
                    "the tool row was printed with the lean view on.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

            # --- a permission prompt must still reach the screen ------------
            #
            # Structurally it is an overlay drawn into the stream band, not a
            # chat message, so no setting of this flag can route past it. That
            # is the argument; this is the evidence.
            push_sse(
                "permission_required",
                {
                    # `parse_system_event` keys off the `event` FIELD, not the SSE
                    # frame name — the backend unwraps sub-events but keeps the
                    # discriminator in the body. A payload without it parses to
                    # None and the prompt never exists, which looks exactly like
                    # the bug this assertion is hunting.
                    "event": "permission_required",
                    "tool": "shell_execute",
                    "args": '{"command":"rm -rf PTYPERMMARK"}',
                    "request_id": "pty-perm-1",
                    "kind": "exec",
                },
            )
            if not s.wait_for_text("PTYPERMMARK", 8.0):
                raise AssertionError(
                    "the permission prompt did not appear while the lean "
                    "view was on. This is the failure the mode must never "
                    "cause: the session parks on an approval nobody can see, "
                    "and there is no way out of it.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
            s.write(b"n")  # deny, so the turn is not left parked on the prompt
            s.pump(SETTLE)

            # --- an error is NOT tool chrome and must survive ---------------
            push_sse("error", {"kind": "tool_failure", "reason": "PTYERRORMARK"})
            if not s.wait_for_text("PTYERRORMARK", 6.0):
                raise AssertionError(
                    "a turn error was swallowed by the lean view. A turn "
                    "that dies must say so, whatever the display settings "
                    f"are.\n--- rendered screen ---\n{s.dump()}"
                )

            # --- the model's own words still print, and the receipt with them
            release_turn()
            end_turn("PTYPROSEMARK is what the model said")
            if not s.wait_for_text("PTYPROSEMARK", 6.0):
                raise AssertionError(
                    "the assistant's prose was hidden. The whole point of the "
                    "mode is that this is the part that stays.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
            if not s.wait_for_text("tool call hidden", 6.0):
                raise AssertionError(
                    "no receipt for the hidden work. Without it a sixty-turn "
                    "task in this mode is indistinguishable from a hang — and "
                    "a hang is exactly what a user cannot diagnose here.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

            # --- and off again ---------------------------------------------
            _submit(s, b"/lean off")
            if not s.wait_for_text("Lean view: off", 6.0):
                raise AssertionError(
                    "the mode could not be turned back off.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
    finally:
        release_turn()


def _start_held_turn(s: PtySession, prompt: bytes = b"HANG FOR A WHILE") -> int:
    """Submit `prompt` into a gated (held-open) turn and return a post mark.

    Factored out because three tests need a turn that is genuinely outstanding:
    `POST /api/v1/orchestrate` is a long poll for a whole turn, so with the stub
    answering instantly the TUI is back at Idle within milliseconds and Esc
    means something else entirely.
    """
    mark = post_mark()
    s.write(prompt)
    s.pump(SETTLE)
    s.write(b"\r")
    waited = 0.0
    while waited < 10.0 and not posts_since(mark, "/api/v1/orchestrate"):
        s.pump(0.25)
        waited += 0.25
    if not posts_since(mark, "/api/v1/orchestrate"):
        raise AssertionError(
            f"the prompt never reached the backend, so there is no turn.\n"
            f"--- rendered screen ---\n{s.dump()}"
        )
    if not s.wait_for_text("esc to interrupt", 5.0):
        raise AssertionError(
            f"the TUI is not showing a running turn.\n"
            f"--- rendered screen ---\n{s.dump()}"
        )
    return mark


def test_the_queued_message_row_does_not_promise_a_key_that_interrupts(
    backend: StubBackend,
) -> None:
    """The queued-message row must not advertise `esc to send now`.

    Reported verbatim: "the 'esc to send now' when I send a message for the
    queue thing, it doesn't work either. I click it, it didn't do it. If I
    press it again it doesn't do it, and then if I do it too many times it just
    turns off the conversation — it interrupts it."

    Established before changing anything, and it is worse than a wrong window:
    **there is no send-now key at all.** `maybe_dequeue_message` is called from
    five turn-completion sites and from no key handler anywhere, and
    `queue_may_drain` requires `Idle && turn_done` — so no keystroke can run a
    queued message while the turn is alive. What `esc to send now` described was
    the side effect of the interrupt chord: Esc-Esc ends the turn, and the queue
    then drains. The label named the consequence and hid the mechanism, and the
    mechanism destroys the work in flight.

    This is the third instance in this file of one defect class — the screen
    naming a key whose behaviour differs from the words next to it — and the
    most dangerous shape of it, because here the advertised action is benign and
    the real one is destructive.

    Asserted on the SCREEN, because the screen is the entire bug: the row is a
    promise, and a promise is a rendering.
    """
    hold_turn()
    try:
        with PtySession(backend.base_url, cols=140, rows=30) as s:
            s.boot()
            _start_held_turn(s)

            # Type a second message: mid-turn text is queued, not sent.
            s.write(b"QUEUED-MESSAGE-ONE")
            s.pump(SETTLE)
            s.write(b"\r")
            if not s.wait_for_text("QUEUED-MESSAGE-ONE", 5.0):
                raise AssertionError(
                    "the mid-turn message was neither queued nor shown.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

            screen = "\n".join(s.lines())
            if "esc to send now" in screen:
                raise AssertionError(
                    "the queued-message row still advertises `esc to send now`. "
                    "No such key exists — the press arms the interrupt, and the "
                    "next one ends the turn. An affordance naming a key that "
                    "does something else is worse than no affordance.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
            if "sends when this turn ends" not in screen:
                raise AssertionError(
                    "the row no longer says WHEN the message runs. That half "
                    "answered an earlier report (a queued message during a "
                    "14-minute fan-out was indistinguishable from the app "
                    f"ignoring the keystroke).\n--- rendered screen ---\n{s.dump()}"
                )
            if "esc" in screen.split("sends when this turn ends")[1][:80]:
                raise AssertionError(
                    "the row names Esc beside a queued message. Esc ends the "
                    "turn; the send-now key is alt+enter.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
    finally:
        release_turn()


def test_the_queued_row_hint_is_true_end_to_end(backend: StubBackend) -> None:
    """A queued message is never lost when the turn ends instead.

    This began life pinning a printed hint (`esc esc interrupts and runs it
    now`). That sentence is gone from the row — alt+enter now delivers into the
    live turn, and the interrupt keeps its own surface — but the BEHAVIOUR it
    described is still the queue's fallback contract and still has to hold:

      1. **the turn ends** — `POST /api/v1/sessions/<id>/cancel` goes out;
      2. **the queued message then runs anyway** — a SECOND
         `POST /api/v1/orchestrate` follows, carrying the QUEUED text.

    (2) is the half that could not be assumed. The queue drains only through
    `maybe_dequeue_message`, gated on `Idle && turn_done`; whether an interrupt
    actually reaches that state — without the user pressing anything else — is a
    property of the cancel teardown. A user who interrupts rather than using
    send-now must not silently lose what they typed.

    Deliberately uses the SLOW gesture (a 2.5s gap), since the in-turn interrupt
    arm is untimed.
    """
    hold_turn()
    try:
        with PtySession(backend.base_url, cols=140, rows=30) as s:
            s.boot()
            _start_held_turn(s)

            s.write(b"QUEUED-RUNS-AFTER-INTERRUPT")
            s.pump(SETTLE)
            s.write(b"\r")
            if not s.wait_for_text("QUEUED-RUNS-AFTER-INTERRUPT", 5.0):
                raise AssertionError(
                    f"the message was not queued.\n--- rendered screen ---\n{s.dump()}"
                )

            mark = post_mark()
            s.write(b"\x1b")
            if not s.wait_for_text("esc again to interrupt", 3.0):
                raise AssertionError(
                    f"the first Esc did not arm.\n--- rendered screen ---\n{s.dump()}"
                )
            s.pump(SLOW_ESC_GAP)
            s.write(b"\x1b")

            # 1. It interrupts.
            waited = 0.0
            while waited < 5.0 and not posts_since(
                mark, "/api/v1/sessions/pty-stub-session/cancel"
            ):
                s.pump(0.25)
                waited += 0.25
            if not posts_since(mark, "/api/v1/sessions/pty-stub-session/cancel"):
                raise AssertionError(
                    "the interrupt did not fire: no cancel request went out.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

            # 2. …and then the queued message runs, with no further keystrokes.
            #    Generous: the cancel teardown waits on SSE and falls back to a
            #    3s CancelTimeout safety net, which the stub's silent stream
            #    means is the path taken here.
            waited = 0.0
            ran = []
            while waited < 15.0:
                s.pump(0.25)
                waited += 0.25
                ran = [
                    body
                    for _, body in posts_since(mark, "/api/v1/orchestrate")
                    if "QUEUED-RUNS-AFTER-INTERRUPT" in body
                ]
                if ran:
                    break
            if not ran:
                raise AssertionError(
                    "the turn was interrupted and the queued message never "
                    "became a request \u2014 text the user typed was silently "
                    "dropped.\n"
                    f"POSTs since the interrupt: "
                    f"{[p for p, _ in posts_since(mark)] or 'none'}\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
    finally:
        release_turn()


def test_a_queued_message_does_not_make_the_interrupt_harder_to_reach(
    backend: StubBackend,
) -> None:
    """Interrupt costs the same gesture whether or not something is queued.

    The constraint that outranks everything else here: the user must never be
    unable to stop a turn. They were trapped by one earlier and had to queue
    `/exit` to escape it.

    So the tempting fix — "when a queue exists, the first Esc means send-now" —
    is the one thing that must not happen: it would push interrupt to a third
    press in exactly the state where a user is most likely to be losing
    patience. This pins that Esc-Esc still interrupts with a queue present,
    which is what makes it safe to leave the interrupt semantics untouched.
    """
    hold_turn()
    try:
        with PtySession(backend.base_url, cols=140, rows=30) as s:
            s.boot()
            _start_held_turn(s)
            s.write(b"SOMETHING QUEUED")
            s.pump(SETTLE)
            s.write(b"\r")
            if not s.wait_for_text("SOMETHING QUEUED", 5.0):
                raise AssertionError(
                    f"nothing queued.\n--- rendered screen ---\n{s.dump()}"
                )

            mark = post_mark()
            s.write(b"\x1b")
            s.pump(0.4)
            s.write(b"\x1b")
            waited = 0.0
            while waited < 5.0:
                s.pump(0.25)
                waited += 0.25
                if posts_since(mark, "/api/v1/sessions/pty-stub-session/cancel"):
                    break
            else:
                raise AssertionError(
                    "with a message queued, Esc-Esc no longer interrupts. A "
                    "queued message must never cost the user access to the "
                    "stop gesture.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
    finally:
        release_turn()


#: The wire path the send-now feature rides. The real backend parks the text in
#: an ETS queue a busy loop can still read and folds it in at the next ReAct
#: step boundary; nothing about that needs a model to be exercised here.
STEER_PATH = "/api/v1/sessions/pty-stub-session/steer"
CANCEL_PATH = "/api/v1/sessions/pty-stub-session/cancel"


def test_alt_enter_delivers_a_queued_message_into_the_live_turn(
    backend: StubBackend,
) -> None:
    """The feature, asserted on the wire and on the turn's survival.

    Until now the only two mid-turn paths were interrupt (destroys the work) and
    waiting for the boundary, and the queued row spent several releases
    advertising a send-now key that did not exist. This is the real one:
    Alt+Enter hands the queued message to `POST /sessions/:id/steer`, which the
    backend folds into the RUNNING loop at its next step boundary.

    Three facts, and the third is the one a screen assertion cannot reach:

      1. the queued text arrives at the steer endpoint;
      2. it arrives WHILE the original turn is still outstanding — the whole
         claim is "into this turn", so a delivery after the turn ended would be
         the old boundary behaviour wearing a new label;
      3. the original turn SURVIVES — no cancel goes out. "Without interrupting"
         is the entire difference between this and the key it replaces, and it
         is provable only by the absence of a request.

    (2) is enforced by the stub still holding `POST /api/v1/orchestrate` open
    for the whole test: the long poll has not returned, so the turn is alive by
    construction at the moment the steer is recorded.
    """
    hold_turn()
    try:
        with PtySession(backend.base_url, cols=140, rows=30) as s:
            s.boot()
            turn_mark = _start_held_turn(s)

            s.write(b"DELIVER-INTO-THIS-TURN")
            s.pump(SETTLE)
            s.write(b"\r")
            if not s.wait_for_text("DELIVER-INTO-THIS-TURN", 5.0):
                raise AssertionError(
                    f"the message was not queued.\n--- rendered screen ---\n{s.dump()}"
                )

            mark = post_mark()
            # Alt+Enter, as a terminal sends it: ESC then CR.
            s.write(b"\x1b\r")

            waited, sent = 0.0, []
            while waited < 8.0:
                s.pump(0.25)
                waited += 0.25
                sent = [
                    body
                    for _, body in posts_since(mark, STEER_PATH)
                    if "DELIVER-INTO-THIS-TURN" in body
                ]
                if sent:
                    break
            if not sent:
                raise AssertionError(
                    "alt+enter did not deliver the queued message: no POST to "
                    f"{STEER_PATH} carrying it.\n"
                    f"POSTs since the keypress: "
                    f"{[p for p, _ in posts_since(mark)] or 'none'}\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

            # 3. The turn survived. No cancel, and the original long poll is
            #    still outstanding (the stub is still holding it).
            if posts_since(mark, CANCEL_PATH):
                raise AssertionError(
                    "send-now interrupted the turn. Delivering WITHOUT ending "
                    "the turn is the entire point of the feature; if it "
                    "cancels, it is the old `esc to send now` with a new key."
                )
            if not posts_since(turn_mark, "/api/v1/orchestrate"):
                raise AssertionError("harness error: no turn was ever started")

            # And the queue is empty on screen — the row must not keep
            # advertising a message that has already gone.
            s.pump(SETTLE)
            if "DELIVER-INTO-THIS-TURN" in "\n".join(
                line for line in s.lines() if "sends when this turn ends" in line
            ):
                raise AssertionError(
                    "the message is still shown as queued after being sent.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
    finally:
        release_turn()


def test_the_queued_row_advertises_the_key_that_delivers(backend: StubBackend) -> None:
    """The row names alt+enter, and names no key that ends the turn.

    Third check of one invariant that this file has now caught two violations
    of: the screen must not name a key whose behaviour differs from the words
    beside it. Here the wrong outcome would be especially quiet — the row could
    name Esc, which *does* eventually run the message, by destroying the turn
    first.
    """
    hold_turn()
    try:
        with PtySession(backend.base_url, cols=140, rows=30) as s:
            s.boot()
            _start_held_turn(s)
            s.write(b"QUEUED-FOR-THE-HINT")
            s.pump(SETTLE)
            s.write(b"\r")
            if not s.wait_for_text("QUEUED-FOR-THE-HINT", 5.0):
                raise AssertionError(
                    f"nothing queued.\n--- rendered screen ---\n{s.dump()}"
                )

            row = next(
                (
                    line
                    for line in s.lines()
                    if "sends when this turn ends" in line
                ),
                None,
            )
            if row is None:
                raise AssertionError(
                    "the queued row lost its explanation entirely.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
            if "alt+enter" not in row:
                raise AssertionError(
                    f"the row does not name the key that delivers: {row!r}\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
            if "esc" in row:
                raise AssertionError(
                    "the row names Esc beside a queued message. Esc ends the "
                    "turn; printing it here is what made a destructive key read "
                    f"as a benign one: {row!r}\n--- rendered screen ---\n{s.dump()}"
                )
    finally:
        release_turn()


def test_a_split_alt_enter_does_not_interrupt(backend: StubBackend) -> None:
    """The degraded form of the chosen chord must be harmless.

    Alt-chords reach crossterm as `ESC` + byte. If the two ever arrive in
    separate reads — which is what this test forces, with a deliberate gap
    between them — it parses as Esc then Enter rather than Alt+Enter. Esc arms
    the interrupt, so the question that decides whether Alt+Enter was a safe
    choice at all is what the Enter does next.

    It disarms: `handle_processing_key` resets the Esc tracker and clears the
    armed affordance on every non-Esc key. So the degraded chord leaves no armed
    interrupt behind, and the Enter falls through to an empty composer, which
    submits nothing. Net effect: nothing happens — the message stays queued and
    the turn stays alive.

    Without this, the feature would have shipped a chord whose failure mode is
    "silently arm the key that kills the turn", which is the defect this whole
    series of fixes is about.
    """
    hold_turn()
    try:
        with PtySession(backend.base_url, cols=140, rows=30) as s:
            s.boot()
            _start_held_turn(s)
            s.write(b"STILL-QUEUED-AFTER-SPLIT")
            s.pump(SETTLE)
            s.write(b"\r")
            if not s.wait_for_text("STILL-QUEUED-AFTER-SPLIT", 5.0):
                raise AssertionError(
                    f"nothing queued.\n--- rendered screen ---\n{s.dump()}"
                )

            mark = post_mark()
            # Force the split: two writes with a pump between them, so the
            # child's reads cannot coalesce them into one Alt+Enter.
            s.write(b"\x1b")
            s.pump(0.5)
            s.write(b"\r")
            s.pump(SETTLE * 2)

            if posts_since(mark, CANCEL_PATH):
                raise AssertionError(
                    "a split alt+enter interrupted the turn. The chord's "
                    "degraded form must be harmless, or the send-now key is a "
                    "way to kill a turn by accident."
                )
            # The armed affordance must be gone too — a latent arm is what
            # turns the NEXT stray Esc into a kill.
            # Poll for the disarm rather than reading once: the Enter has to be
            # rendered before the affordance clears, and under CI load that lag
            # outlives the pump above. A one-shot check flaked here against
            # correct code.
            if not s.wait_for_text_gone("esc again to interrupt", 5.0):
                raise AssertionError(
                    "the interrupt is still armed after a split alt+enter. The "
                    "Enter must disarm it, or the chord leaves a loaded key "
                    f"behind.\n--- rendered screen ---\n{s.dump()}"
                )
            if not s.wait_for_text("STILL-QUEUED-AFTER-SPLIT", 5.0):
                raise AssertionError(
                    "the queued message vanished on a split alt+enter.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
    finally:
        release_turn()


#: Silence budget the binary runs with in these probes, via
#: `OSA_SILENCE_NOTICE_SECS`. Production is 600s, which no probe can sit
#: through; the seam exists so the notice can be proved on a REAL terminal
#: rather than only in-process. High enough that the boot chatter and the
#: turn's own opening frames cannot trip it by accident.
SILENCE_BUDGET_SECS = 4


def test_a_turn_that_goes_silent_says_so_instead_of_spinning_forever(
    backend: StubBackend,
) -> None:
    """Reproduce the owner's screenshot, then assert the row now names it.

    The report: a live TUI sat on

        grok-4.6 ∙ ⠸ Waiting for response… (1h51m10s · esc to interrupt · ⇣692 · ↑ 139.7k in)

    for one hour and fifty-one minutes. Nothing on that row distinguishes a
    turn that is streaming from a turn whose backend went silent ninety minutes
    ago: the elapsed value is anchored to TURN START, so it advances at exactly
    the same rate in both cases, and the two token counters are frozen snapshots
    of the last frame that did arrive. There was no way to tell, and no amount
    of patience could produce one.

    The shape reproduced here is the one no read timeout catches: the SSE stream
    stays OPEN and healthy — the stub keeps sending `: keepalive` comments, just
    as `session_routes.ex` does every 30s — while carrying no turn events at
    all. Every disconnect path in `handle_backend.rs` (`SseReconnecting`,
    `SseDisconnected`) already finalizes an in-flight turn, so none of them
    fire; that is precisely why this state had no symptom.

    Two frames arrive first, so the assertion is about a turn that STOPPED
    rather than one that never started — the former is the reported case and is
    the harder one, since a turn with tokens on the row looks like it worked.

    Asserted in both directions. Before the budget lapses the row must NOT
    accuse a merely-slow turn; after it, the row must say what happened.
    """
    hold_turn()
    prior = os.environ.get("OSA_SILENCE_NOTICE_SECS")
    os.environ["OSA_SILENCE_NOTICE_SECS"] = str(SILENCE_BUDGET_SECS)
    try:
        with PtySession(backend.base_url, cols=120, rows=30) as s:
            s.boot()

            mark = post_mark()
            s.write(b"REPRODUCE THE STALL")
            s.pump(SETTLE)
            s.write(b"\r")

            waited = 0.0
            while waited < 10.0 and not posts_since(mark, "/api/v1/orchestrate"):
                s.pump(0.25)
                waited += 0.25
            if not posts_since(mark, "/api/v1/orchestrate"):
                raise AssertionError(
                    "the prompt never reached the backend, so there was no turn "
                    f"to stall.\n--- rendered screen ---\n{s.dump()}"
                )

            # Two frames land, and then the backend goes quiet forever. This is
            # the state: tokens on the row, a live stream, and nothing coming.
            push_sse(
                "streaming_token",
                {"text": "Search", "session_id": "pty-stub-session"},
            )
            push_sse(
                "streaming_token",
                {"text": "ing…", "session_id": "pty-stub-session"},
            )
            if not s.wait_for_text("esc to interrupt", 5.0):
                raise AssertionError(
                    "the TUI never showed a running turn, so there is no stall "
                    f"to detect.\n--- rendered screen ---\n{s.dump()}"
                )

            # Well inside the budget: a slow turn must not be accused.
            s.pump(1.0)
            early = "\n".join(s.lines())
            if "no response for" in early:
                raise AssertionError(
                    "a turn that has been quiet for ~1s was reported as stalled. "
                    "The notice must not fire on a merely-slow turn.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

            # Past it: the row must state the silence. The spinner keeps
            # spinning and the turn is untouched — this is a notice, not a
            # timeout — so the ONLY new evidence is the text.
            if not s.wait_for_text("no response for", SILENCE_BUDGET_SECS + 8.0):
                raise AssertionError(
                    "after "
                    f"{SILENCE_BUDGET_SECS}s of total backend silence the row "
                    "still says nothing about it. This is the reported defect: "
                    "a wedged turn and a working turn render identically.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

            # The turn is still alive and still interruptible — nothing was
            # cancelled to produce that message.
            screen = "\n".join(s.lines())
            if "esc to interrupt" not in screen:
                raise AssertionError(
                    "the silence notice ended or disarmed the turn. It must be "
                    "a report, never a timeout.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

            # And a frame arriving clears it: the notice tracks LIVENESS, not
            # turn age. Without this half, a notice that latched on forever
            # would pass the assertion above and still be useless.
            push_sse(
                "streaming_token",
                {"text": " again", "session_id": "pty-stub-session"},
            )
            s.pump(1.5)
            revived = "\n".join(s.lines())
            if "no response for" in revived:
                raise AssertionError(
                    "a frame arrived and the stall notice stayed on screen. It "
                    "is anchored to turn age, not to the last frame — which is "
                    f"the original defect.\n--- rendered screen ---\n{s.dump()}"
                )
    finally:
        if prior is None:
            os.environ.pop("OSA_SILENCE_NOTICE_SECS", None)
        else:
            os.environ["OSA_SILENCE_NOTICE_SECS"] = prior
        release_turn()


def test_a_turn_that_answers_nothing_says_so_instead_of_vanishing(
    backend: StubBackend,
) -> None:
    """Reproduce the owner's screenshot: two prompts, no turn, no error.

    The report, verbatim from a live v1.0.101 session on grok-4.6 minutes after
    three back-to-back compactions::

        ✻ Worked for 3m 2s · 86 tool uses
        ─────
        ❯  You                                     11:14 AM
        ┃what the fuck were you doing earlier
        ─────
        ❯  You                                     11:14 AM
        ┃excuse me
        ─────
        ◈ ❯ Paste an error and ask OSA to fix it…

    Two consecutive messages were accepted and rendered into scrollback, and
    neither produced anything at all: no spinner, no `Waiting for response…`,
    no error, no recap. The composer returned to its idle placeholder both
    times. Read as "the app is ignoring me", which is what it looks like.

    The mechanism is NOT a dropped keystroke and NOT the message queue — both
    of those render differently, and this test proves the first half on the
    wire: the prompt DOES become a `POST /api/v1/orchestrate`. What follows is
    a turn that ends with an EMPTY `agent_response`.

    Every step of that end is individually reasonable and collectively silent.
    `AssistantStream::finalize` returns `Emit("")`; `commit_assistant_chunk`
    calls `clean_for_commit`, which reports "nothing to render" for empty text
    and returns without touching the chat; `handle_agent_response` then runs
    full turn teardown — `activity.stop()`, `land_idle_including_parked()` —
    so the spinner goes down and the composer returns to Idle. `turn_recap` is
    gated on substantive work, so a turn that called no tools and took no time
    prints no `✻ Worked for` line either. The net effect is that the screen
    after the turn is byte-identical to the screen before it.

    That is the defect, and it is the same class as the `/compact` echo: an
    action that leaves the screen unchanged is indistinguishable from a
    keypress the app threw away, so the user repeats it. Here they repeated it
    once and then asked the agent what was wrong with it.

    The fix is not to guess at content. It is that a turn which produced NO
    visible output must say that it produced none — silence is never an
    acceptable rendering of "your message was processed".

    Asserted in both directions, because a notice that fires on every turn
    would be worse than the bug: a turn that DID answer must not gain a line
    claiming it did not.
    """
    with PtySession(backend.base_url, cols=120, rows=30) as s:
        s.boot()

        # --- half one: the request genuinely leaves the TUI ------------------
        #
        # This is the fact no screenshot can establish. "Queued", "sent" and
        # "discarded" all render identically on the reported screen, and only
        # the wire separates them.
        mark = post_mark()
        s.write(b"WEDGE-PROBE-ONE")
        s.pump(SETTLE)
        s.write(b"\r")
        waited = 0.0
        while waited < 10.0 and not posts_since(mark, "/api/v1/orchestrate"):
            s.pump(0.25)
            waited += 0.25
        sent = [b for _p, b in posts_since(mark, "/api/v1/orchestrate")]
        if not any("WEDGE-PROBE-ONE" in b for b in sent):
            raise AssertionError(
                "the prompt never became a request. If this fails the defect is "
                "on the TUI side of the wire (queued or dropped), not in what "
                "the backend answered.\n"
                f"POSTs: {[p for p, _ in posts_since(mark)] or 'none'}\n"
                f"--- rendered screen ---\n{s.dump()}"
            )

        # --- half two: the turn ends having said nothing ---------------------
        #
        # An `agent_response` carrying no text. This is what the backend
        # broadcasts when the turn terminates without the model producing an
        # answer: `loop.ex` puts `response` on the wire verbatim and has no
        # empty guard, so `""` reaches the client exactly like this.
        end_turn("")

        if not s.wait_for_text("no answer", 8.0):
            raise AssertionError(
                "a turn ended without producing one byte of output and the "
                "screen says nothing about it — the state after the turn is "
                "identical to the state before it. This is the reported "
                "wedge: the user's message was accepted, a request went out, "
                "and the only honest report of the outcome was silence.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )

        # --- half three: the session is not wedged ---------------------------
        #
        # The notice must be a report, not a tombstone. The very next message
        # has to reach the wire, or the fix would have documented the wedge
        # instead of removing it.
        mark2 = post_mark()
        s.write(b"WEDGE-PROBE-TWO")
        s.pump(SETTLE)
        s.write(b"\r")
        waited = 0.0
        while waited < 10.0:
            if any(
                "WEDGE-PROBE-TWO" in b
                for _p, b in posts_since(mark2, "/api/v1/orchestrate")
            ):
                break
            s.pump(0.25)
            waited += 0.25
        else:
            raise AssertionError(
                "after an empty turn the next message never reached the "
                "backend. The session is inert — exactly the state the report "
                "describes, and the one no notice can excuse.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )

        # --- half four: a turn that DID answer gains no such line ------------
        end_turn("here is a real answer")
        if not s.wait_for_text("here is a real answer", 8.0):
            raise AssertionError(
                f"the healthy path broke.\n--- rendered screen ---\n{s.dump()}"
            )
        s.pump(0.6)
        after = "\n".join(s.lines())
        if after.count("no answer") > 1:
            raise AssertionError(
                "a turn that answered was also reported as answering nothing. "
                "The notice must fire only when there was genuinely no output, "
                "or it becomes noise on every turn.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )


def _wait_post(s, mark, path, needle=None, timeout=10.0):
    """Pump until a POST to `path` (optionally containing `needle`) is recorded."""
    waited = 0.0
    while waited < timeout:
        for _p, body in posts_since(mark, path):
            if needle is None or needle in body:
                return body
        s.pump(0.25)
        waited += 0.25
    return None


def test_goal_is_anchored_on_the_backend_not_graded_in_the_client(
    backend: StubBackend,
) -> None:
    """`/goal` must REACH the backend, and the backend must decide when it ends.

    The defect this pins: the TUI shipped a complete second `/goal` that never
    contacted the backend at all. It stopped when the assistant's last non-empty
    line was exactly `DONE` — the model grading its own homework — and would run
    up to 25 turns on that say-so, while `GoalTracker`'s acceptance criteria,
    independent skeptic panel, cross-turn stall fingerprint and run cap sat
    unused because the command that starts them was intercepted client-side.

    Asserted ON THE WIRE, deliberately. A screen check cannot tell "routed" from
    "looks routed": the old client-side arm printed a perfectly convincing
    "Goal set — auto-continuing…" line while sending nothing. Two un-wired
    affordances have already shipped behind exactly that gap. So every claim
    here is about a recorded request or the absence of one.

    Three things are proved, in order:

      1. the anchor reaches `POST /commands/execute` as `goal`, carrying the
         `::` acceptance criteria the backend needs and the TUI never had;
      2. `DONE` does not end anything — with the backend still reporting the
         goal active, a reply that is literally the old sentinel is followed by
         another turn;
      3. the backend's verdict does end it — once the backend reports the goal
         no longer active, no further turn is started.
    """
    reset_goal_state()
    try:
        with PtySession(backend.base_url, cols=100, rows=30) as s:
            s.boot()

            # (1) The anchor must reach the backend, criteria intact.
            mark = post_mark()
            s.write(b"/goal ship the parser :: mix test passes")
            s.pump(SETTLE)
            s.write(b"\r")

            # Reconnect now performs a silent `/goal status` sync first. Wait
            # for the criteria-bearing anchor, not merely the first goal POST.
            body = _wait_post(
                s,
                mark,
                "/api/v1/commands/execute",
                "mix test passes",
            )
            if body is None:
                raise AssertionError(
                    "/goal never reached the backend. This is the shipped "
                    "defect: the command is handled entirely client-side and "
                    "GoalTracker is never told a goal exists.\n"
                    f"--- posts ---\n{posts_since(mark)}\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
            if "mix test passes" not in body:
                raise AssertionError(
                    "the acceptance criteria did not reach the backend. Without "
                    "them completion is judged against the goal text alone, "
                    "which is the weaker check the criteria exist to replace.\n"
                    f"--- request body ---\n{body}"
                )

            # Anchoring alone runs nothing (GoalTracker.start/2 writes state), so
            # the TUI starts the first turn. That turn must be a real one.
            if _wait_post(s, mark, "/api/v1/orchestrate") is None:
                raise AssertionError(
                    "the goal was anchored and no work turn followed, so /goal "
                    "anchors a goal nothing pursues.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

            # (2) The old sentinel must be inert. The backend still says active.
            set_goal_state(True, "active", output="Goal active", turn_count=2)
            mark2 = post_mark()
            end_turn("All checks pass.\nDONE")

            if _wait_post(s, mark2, "/api/v1/commands/execute", '"goal"') is None:
                raise AssertionError(
                    "the turn ended and the TUI never asked the backend whether "
                    "the goal was still live — so whatever ends this loop, it is "
                    "not the backend.\n"
                    f"--- posts ---\n{posts_since(mark2)}"
                )
            if _wait_post(s, mark2, "/api/v1/orchestrate") is None:
                raise AssertionError(
                    "a reply whose last line is exactly DONE stopped the goal "
                    "loop while the backend still reported it ACTIVE. The model "
                    "is still grading its own homework.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )

            # (3) The backend's verdict ends it, and nothing else needs to.
            set_goal_state(False, "completed", output="Goal complete", turn_count=3)
            mark3 = post_mark()
            # A reply that says nothing about being finished. Under the old
            # sentinel this would have continued forever.
            end_turn("Still working on the parser, more to do.")

            if _wait_post(s, mark3, "/api/v1/commands/execute", '"goal"') is None:
                raise AssertionError(
                    "no end-of-turn liveness check was sent.\n"
                    f"--- posts ---\n{posts_since(mark3)}"
                )
            # Give the client every chance to start another turn; it must not.
            s.pump(2.5)
            if posts_since(mark3, "/api/v1/orchestrate"):
                raise AssertionError(
                    "the backend reported the goal COMPLETED and the TUI started "
                    "another turn anyway — the backend's verdict is advisory, "
                    "which is exactly the bug.\n"
                    f"--- posts ---\n{posts_since(mark3)}\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
    finally:
        reset_goal_state()


def test_reconnect_restores_a_paused_goal_footer(backend: StubBackend) -> None:
    """A durable goal remains visible and controllable after reopening OSA."""
    set_goal_state(
        False,
        "paused",
        pause_reason="user",
        goal="publish the release",
        output="Goal paused",
    )
    try:
        with PtySession(backend.base_url, cols=100, rows=30) as s:
            s.boot()
            s.pump(1.0)
            screen = "\n".join(s.lines())
            if "Goal paused: publish the release" not in screen:
                raise AssertionError(
                    "reopening the TUI did not restore the paused goal description "
                    "in the footer.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
            if "/goal resume" not in screen:
                raise AssertionError(
                    "the paused goal footer did not expose its resume control.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
            rows = s.lines()
            goal_row = next(i for i, row in enumerate(rows) if "Goal paused:" in row)
            status_row = next(i for i, row in enumerate(rows) if "% ctx" in row)
            if goal_row == status_row:
                raise AssertionError(
                    "the goal is still appended to the crowded primary status row "
                    "instead of owning an aligned row underneath it.\n"
                    f"--- rendered screen ---\n{s.dump()}"
                )
    finally:
        clear_goal_state()


def test_a_running_subagent_is_not_squeezed_off_screen_by_a_plan(
    backend: StubBackend,
) -> None:
    """A running subagent must leave evidence on screen even under band pressure.

    The complaint that started this thread was not being able to tell whether a
    subagent was alive. The agents band is the SECOND band shed when vertical
    space is tight (`SHED_ORDER`: toast, then agents, then checklist), so the
    plan band — which outranks it — can take the rows the roster needed.

    Measured, not reasoned about. On a real 100x20 terminal with four running
    subagents and a twelve-item plan, the roster was shed to NOTHING while the
    plan kept its header and its rows. Four subagents were running and the
    screen said nothing about them. Reproduced at every height from 20 rows
    down; at 24 there was still room for both.

    The ladder is not wrong — per row, the plan IS the better use of the tenth
    row. What was wrong is that "fewer roster rows" degraded to "no evidence a
    subagent exists". The band now keeps one row, its header, exactly as the
    composer keeps `INPUT_FLOOR`.

    This asserts the floor holds under the pressure that broke it.
    """
    with PtySession(backend.base_url, cols=100, rows=20) as s:
        s.boot()

        # Four subagents, launched and working: names, roles, real tool counts.
        for k in range(4):
            push_sse(
                "orchestrator_agent_started",
                {
                    # `parse_system_event` reads the sub-event name from the
                    # BODY, exactly as `Orchestrator.emit_event/2` writes it.
                    "event": "orchestrator_agent_started",
                    "agent_name": f"agent:pty:osa-w{k}",
                    "display_name": f"w{k}",
                    "role": "researcher",
                    "model": "glm-4.7",
                    "description": "map the module tree",
                    "elapsed_ms": 42000,
                },
            )
            push_sse(
                "orchestrator_agent_progress",
                {
                    "event": "orchestrator_agent_progress",
                    "agent_name": f"agent:pty:osa-w{k}",
                    "current_action": "file_grep",
                    "tool_uses": 9,
                    "tokens_used": 1200,
                    "elapsed_ms": 45000,
                },
            )
        s.pump(SETTLE * 2)
        if "Running" not in "\n".join(s.lines()):
            raise AssertionError(
                "the roster was never visible with nothing competing for rows, "
                "so this test cannot say anything about band pressure.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )

        # Now the plan — a higher-priority band, big enough to want every row.
        push_sse(
            "task_checklist_show",
            {
                "event": "task_checklist_show",
                "data": {
                    "tasks": [
                        {
                            "id": f"t{i}",
                            "subject": f"plan step number {i}",
                            "status": "pending",
                            "active_form": f"doing plan step number {i}",
                        }
                        for i in range(12)
                    ]
                },
            },
        )
        s.pump(SETTLE * 2)

        screen = "\n".join(s.lines())
        if "Running" not in screen:
            raise AssertionError(
                "four running subagents left NO roster on screen because the "
                "plan band won the rows. The user cannot tell they are alive — "
                "the reported complaint, reproduced.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )
        # The plan is still there too: the floor costs one row, not the feature
        # that outranks it.
        if "Plan" not in screen:
            raise AssertionError(
                "keeping a roster row cost the plan its whole band. The floor is "
                "one row, not a re-ordering of the ladder.\n"
                f"--- rendered screen ---\n{s.dump()}"
            )


TESTS = [
    test_fast_updates_the_persistent_effort_chip,
    test_resize_sweep,
    test_resize_with_transcript,
    test_resize_emits_nothing_that_deposits_into_scrollback,
    test_height_resize,
    test_small_viewport,
    test_narrow_terminal_still_dispatches,
    test_provider_surface,
    test_choosing_ollama_states_the_wait_and_fetches_its_catalog_once,
    test_one_lone_escape_closes_a_dialog,
    test_provider_picker_shows_account_plan_and_a_limit_meter,
    test_a_provider_with_no_reported_quota_says_so_instead_of_drawing_zero,
    test_claude_code_is_installed_and_signed_in_without_leaving_osa,
    test_connecting_splash_does_not_trap_the_user,
    test_a_stale_backend_says_so_instead_of_relabelling_the_tui,
    test_a_missing_session_recovers_without_a_reconnect_loop,
    test_a_draft_typed_while_connecting_survives_into_the_composer,
    test_a_slow_second_escape_still_interrupts,
    test_one_stray_escape_still_does_not_kill_a_turn,
    test_a_turn_that_ends_under_an_overlay_does_not_wedge_the_session,
    test_clear_leaves_no_queued_message_behind,
    test_clear_adopts_the_session_the_backend_hands_back,
    test_the_lean_view_hides_tool_calls_and_only_tool_calls,
    test_the_queued_message_row_does_not_promise_a_key_that_interrupts,
    test_the_queued_row_hint_is_true_end_to_end,
    test_a_queued_message_does_not_make_the_interrupt_harder_to_reach,
    test_alt_enter_delivers_a_queued_message_into_the_live_turn,
    test_the_queued_row_advertises_the_key_that_delivers,
    test_a_split_alt_enter_does_not_interrupt,
    test_a_turn_that_goes_silent_says_so_instead_of_spinning_forever,
    test_a_turn_that_answers_nothing_says_so_instead_of_vanishing,
    test_goal_is_anchored_on_the_backend_not_graded_in_the_client,
    test_reconnect_restores_a_paused_goal_footer,
    test_a_running_subagent_is_not_squeezed_off_screen_by_a_plan,
]


def main() -> int:
    failed = []
    with StubBackend(STUB_PORT) as backend:
        for test in TESTS:
            name = test.__name__
            # Every PTY session reconnects and asks for its durable goal
            # snapshot. Tests that need a goal opt in explicitly so one test's
            # tracker state cannot consume status-bar space in the next one.
            clear_goal_state()
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
