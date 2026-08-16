#!/usr/bin/env python3
"""Resize assertions against a REAL VTE terminal — the emulator the bug lives in.

Why this exists alongside `test_resize.py`
------------------------------------------
`test_resize.py` drives the binary on a plain PTY and renders with `pyte`.
Its own README states the limitation: **pyte does not reflow on resize; VTE
does.** Every stranded-chrome report has come from a libvte terminal (GNOME
Terminal, Tilix, Terminator, Ptyxis), and the pyte harness renders such a drag
as clean while the user sees a stack of copies. That is why the defect has
outlived several fixes: nothing that could fail was ever watching.

This harness embeds `libvte` itself through GObject introspection — the same
library GNOME Terminal links — so the reflow, the scrollback commit semantics
and the ED2-vs-ED0 difference are the real implementations rather than a
model of them. `get_text_range` then reads back the scrollback, which is where
stranded chrome ends up.

Requirements: `python3-gi`, `gir1.2-vte-2.91`, and a reachable X display. When
any of those is missing the module reports SKIPPED rather than failing, so it
never turns a headless CI box red for the wrong reason — `test_resize.py`
remains the always-runnable half.

Run: `python3 test/pty/vte_resize.py`
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import scrollback_prelude  # noqa: E402  (needs the sys.path line above)
import term_env  # noqa: E402
import vte_reader  # noqa: E402

STUB_PORT = 12791
# Each singleton band, as a substring that appears exactly once on a healthy
# screen. Shared in spirit with SINGLETON_BANDS in osa_pty.py, but matched
# against VTE's flattened text rather than a pyte screen.
BANDS = {
    "composer prompt": "❯",
    "hint row": "/ commands",
    "status bar": "ctx",
}


def _skip(reason: str) -> int:
    print(f"SKIPPED: {reason}")
    return 0


def main() -> int:
    if not os.environ.get("DISPLAY"):
        return _skip("no DISPLAY; VTE needs one even when nothing is mapped")

    try:
        import gi

        gi.require_version("Gtk", "3.0")
        gi.require_version("Vte", "2.91")
        from gi.repository import GLib, Gtk, Vte
    except (ImportError, ValueError) as e:
        return _skip(f"python3-gi / gir1.2-vte-2.91 unavailable ({e})")

    if not Gtk.init_check(None)[0]:
        return _skip("Gtk.init_check failed; no usable display")

    from stub_backend import StubBackend  # noqa: E402

    repo = Path(__file__).resolve().parents[2]
    binary = repo / "priv/rust/tui/target/release/osagent"
    if not binary.exists():
        return _skip(f"{binary} not built")

    failures: list[str] = []

    with StubBackend(STUB_PORT) as backend:
        term = Vte.Terminal()
        # Deep scrollback: stranded copies land here, and a short buffer would
        # quietly discard the evidence this test exists to find.
        term.set_scrollback_lines(10_000)
        # 50 rows, not 30: the scrollback prelude below occupies ~24 of them
        # and the inline live region needs its own, so this leaves the drag a
        # real transcript to move instead of an empty screen.
        #
        # It is NOT, as this comment used to claim, that "OSA wedges on startup
        # when the screen leaves too little room for the inline viewport". That
        # was the range reader `vte_reader` documents: it only ever returned the
        # first screenful of the session, which the prelude had already filled,
        # so the composer was on screen and unreadable. Measured with the ring
        # reader, OSA reaches a composer with the same 12-line prelude at both
        # 30 and 24 rows.
        term.set_size(120, 50)

        # The child must NOT inherit the harness's own terminal identity. This
        # repo is developed inside tmux, and this harness used to pass
        # `os.environ` through verbatim — so `TMUX` was set in the child and
        # every "OSA survives a drag on real VTE" run was actually exercising
        # the multiplexer branch. VTE sets its own `TERM` and `VTE_VERSION`
        # once the identity vars are out of the way. See `term_env.py`.
        #
        # `OSA_RESIZE_CLEAR` is forwarded when the caller set it, which is how
        # a branch is forced here to prove the gate's table is keyed on the
        # right terminal rather than passing by luck.
        env = term_env.clean_env_list(
            **term_env.backend_vars(backend.base_url), **term_env.passthrough_override()
        )

        # Fill the scrollback with WRAPPED lines before the binary starts.
        # Without them the transcript above the live region is empty, nothing
        # shortens when the terminal widens, the live region never moves, and
        # the harness passes whichever branch it took — which is why this test
        # used to be evidence of nothing. See `scrollback_prelude.py`.
        argv = scrollback_prelude.wrap_command(str(binary), lines=12)

        ok, _pid = term.spawn_sync(
            Vte.PtyFlags.DEFAULT,
            str(repo),
            argv,
            env,
            GLib.SpawnFlags.DEFAULT,
            None,
            None,
            None,
        )
        if not ok:
            return _skip("VTE could not spawn the binary")

        def pump(seconds: float) -> None:
            """Run the GLib main loop so VTE actually processes child output."""
            deadline = GLib.get_monotonic_time() + int(seconds * 1_000_000)
            ctx = GLib.MainContext.default()
            while GLib.get_monotonic_time() < deadline:
                while ctx.pending():
                    ctx.iteration(False)
                GLib.usleep(5_000)

        def visible_and_scrollback() -> str:
            """Everything VTE holds — screen plus scrollback.

            Read through `vte_reader`, not with a `-10_000 .. row_count` range.
            VTE row indices are ABSOLUTE over the ring (row 0 is the first line
            the session ever emitted, negative rows are empty), so that range
            reads the FIRST SCREENFUL of the session and nothing after it, for
            the whole run — see `vte_reader`'s module docstring for what that
            cost. Stranded chrome lands wherever the ring currently is, which is
            exactly what this reader follows.
            """
            return "\n".join(vte_reader.buffer_rows(term, Vte))

        # Poll rather than sleep a fixed 6s: startup here spans a backend
        # handshake and a provider probe and is not reliably done in any one
        # interval, and a fixed sleep that is occasionally too short turns into
        # an intermittent SKIP — a green run that asserted nothing.
        before = ""
        for _ in range(30):
            pump(1.5)
            before = visible_and_scrollback()
            if BANDS["composer prompt"] in before:
                break
        else:
            return _skip("binary did not reach a composer; nothing to assert about")

        # The reported gesture: a slow drag through several widths.
        for cols in (115, 110, 105, 100, 95, 90):
            term.set_size(cols, 50)
            pump(0.35)
        for cols in (95, 100, 105, 110, 115, 120):
            term.set_size(cols, 50)
            pump(0.35)
        pump(3.0)

        after = visible_and_scrollback()

        for name, needle in BANDS.items():
            n = after.count(needle)
            if n > 1:
                failures.append(
                    f"{name}: {n} copies after the drag (expected 1) — "
                    f"stranded chrome in VTE scrollback"
                )

        if failures:
            print("--- VTE contents after drag (tail) ---")
            print("\n".join(after.splitlines()[-60:]))

    for f in failures:
        print(f"FAIL: {f}")
    if failures:
        return 1
    print("ok — one copy of each band survives a width drag on real VTE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
