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

from osa_pty import SETTLE, SINGLETON_BANDS, STATUS, PtySession  # noqa: E402
from stub_backend import StubBackend, set_claude_cli_state  # noqa: E402

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


def assert_chrome_bottom_anchored(session: PtySession, context: str) -> None:
    """The live region occupies the LAST rows of the screen.

    Band counting cannot express this, and that is exactly why the defect it
    guards against shipped through a thousand passing tests. `clear_screen_for_resize`
    homes the cursor to row 0 before erasing, and the `rebuild_inline` that
    follows anchors `Viewport::Inline` on wherever the cursor is
    (ratatui 0.29 `compute_inline_size`: `row = pos.y`). So after one width
    resize the whole live region was rebuilt at the TOP of the screen — and
    there was still exactly ONE of it, so every assertion in this file passed
    while the user watched "the chat thing go all the way to the top".

    The invariant the inline design actually rests on is bottom-anchoring:
    `top == rows - inline_h`, the same equation `resize_clear_top_from_bottom`
    states in `event_loop.rs`. Externally the region's top is not directly
    readable, but its LAST row is: the status bar is the final row the region
    draws, so a bottom-anchored region puts the status bar on the last
    non-blank row of the screen, with nothing but blanks under it.

    Checking the bottom rather than the top is deliberate — it needs no
    knowledge of the region's height, which changes as the composer grows.

    It measures the status bar's distance from the SCREEN BOTTOM, not from the
    last non-blank row. That distinction is the whole assertion: when the region
    is rebuilt at the top, everything below it is blank, so the status bar is
    *still* the last non-blank row and a check written that way passes on the
    broken screen. (It did. This function's first version asserted exactly that
    and stayed green with the fix reverted.) The reported symptom is literally
    "the composer is at the top and there is dead space below it", so the dead
    space is the evidence and must not be ignored.
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
    test_one_lone_escape_closes_a_dialog,
    test_provider_picker_shows_account_plan_and_a_limit_meter,
    test_a_provider_with_no_reported_quota_says_so_instead_of_drawing_zero,
    test_claude_code_is_installed_and_signed_in_without_leaving_osa,
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
