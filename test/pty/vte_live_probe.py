#!/usr/bin/env python3
"""What the resize harnesses never put on screen: a GROWING transcript.

`vte_resize.py`, `tmux_resize.py` and `wezterm_resize.py` all drag an IDLE
session whose transcript is the boot banner plus a static scrollback prelude.
Nothing is committed to native scrollback during the gesture. But the transcript
commit path -- `Terminal::insert_before`, run-loop step 2 -- is the one path in
the program that deliberately SCROLLS the screen, and anything scrolled is in
history where no erase can reach it. Its geometry comes from ratatui's
`last_known_area` / `viewport_area`, not from OSA's per-frame `FrameSize`, so it
is exactly the path a stale size corrupts.

So this harness keeps the transcript MOVING. Submitting a prompt appends a user
message, which finalizes immediately and drains to native scrollback through
`insert_before` -- no model response required, which is why this works against
the silent stub.

It also drags the HEIGHT. Every existing harness changes only the width
(`set_size(cols, 50)`, `resize-window -x`), so a vertical drag -- which changes
`size.rows`, the screen height every `insert_before` scroll amount is computed
from -- has never been exercised at all.

Run: `python3 test/pty/vte_live_probe.py`
Force a branch: `OSA_RESIZE_CLEAR=surgical python3 test/pty/vte_live_probe.py`
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import scrollback_prelude  # noqa: E402
import term_env  # noqa: E402
import vte_reader  # noqa: E402

STUB_PORT = 12795

# Same bands as vte_resize.py, matched against VTE's flattened text.
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
        term.set_scrollback_lines(20_000)
        term.set_size(120, 50)

        # `OSA_BASE_URL` is NOT a variable the binary reads. `config/mod.rs`
        # reads `OSA_URL` (and `OSA_PORT`), defaulting to localhost:9089 — so a
        # harness that only sets `OSA_BASE_URL` silently runs against whatever
        # real backend the developer happens to have on 9089, not the stub.
        # Every existing real-terminal harness (vte/tmux/wezterm) does exactly
        # that. `HOME` is redirected for the same reason `osa_pty` redirects it:
        # a harness must never touch real ~/.osa state.
        env = term_env.clean_env_list(
            OSA_URL=backend.base_url,
            OSA_PORT=str(STUB_PORT),
            HOME=os.environ.get("OSA_PTY_HOME", os.environ.get("HOME", "/tmp")),
            **term_env.passthrough_override(),
        )
        argv = scrollback_prelude.wrap_command(str(binary), lines=12)

        ok, _pid = term.spawn_sync(
            Vte.PtyFlags.DEFAULT, str(repo), argv, env,
            GLib.SpawnFlags.DEFAULT, None, None, None,
        )
        if not ok:
            return _skip("VTE could not spawn the binary")

        def pump(seconds: float) -> None:
            deadline = GLib.get_monotonic_time() + int(seconds * 1_000_000)
            ctx = GLib.MainContext.default()
            while GLib.get_monotonic_time() < deadline:
                while ctx.pending():
                    ctx.iteration(False)
                GLib.usleep(5_000)

        def text() -> str:
            # Whole ring, read through `vte_reader`. A `-20_000 .. row_count`
            # range does NOT mean "scrollback plus screen": VTE row indices are
            # absolute over the ring, so it reads the first screenful of the
            # session and nothing after it, forever. See `vte_reader`.
            return "\n".join(vte_reader.buffer_rows(term, Vte))

        def send(s: str) -> None:
            term.feed_child(s.encode())

        def check(label: str) -> None:
            after = text()
            counts = {n: after.count(v) for n, v in BANDS.items()}
            bad = {k: v for k, v in counts.items() if v > 1}
            print(f"  [{'DUPLICATED' if bad else 'ok':10}] {label}: {counts}")
            if bad:
                failures.append(f"{label}: {bad}")
                print("    --- tail ---")
                for line in after.splitlines()[-40:]:
                    print("    " + line)

        # Boot.
        for _ in range(30):
            pump(1.5)
            if BANDS["composer prompt"] in text():
                break
        else:
            return _skip("binary did not reach a composer; nothing to assert about")
        pump(2.0)
        check("booted, idle")

        # ---- Build a REAL transcript. Each submit finalizes a user message,
        # which drains to native scrollback through `insert_before`. Long
        # enough to wrap, so a width change reflows it.
        def submit(n: int) -> None:
            for i in range(n):
                send(
                    f"probe message {i:02d} "
                    + "padding words that make this line wrap at any width under test " * 2
                    + "\r"
                )
                pump(0.5)

        submit(6)
        pump(2.0)
        check("after 6 submits (transcript committed via insert_before)")

        # ---- A: WIDTH drag with a transcript present.
        for cols in (115, 110, 105, 100, 95, 90):
            term.set_size(cols, 50)
            pump(0.35)
        for cols in (95, 100, 105, 110, 115, 120):
            term.set_size(cols, 50)
            pump(0.35)
        pump(3.0)
        check("after width drag with a live transcript")

        # ---- B: HEIGHT drag. No existing harness does this.
        for rows in (46, 42, 38, 34, 30, 26):
            term.set_size(120, rows)
            pump(0.35)
        for rows in (30, 34, 38, 42, 46, 50):
            term.set_size(120, rows)
            pump(0.35)
        pump(3.0)
        check("after height drag")

        # ---- C: DIAGONAL drag (both axes at once), which is what a corner
        # drag on a real window manager actually delivers.
        for cols, rows in ((114, 47), (108, 44), (102, 41), (96, 38), (90, 35)):
            term.set_size(cols, rows)
            pump(0.35)
        for cols, rows in ((96, 38), (102, 41), (108, 44), (114, 47), (120, 50)):
            term.set_size(cols, rows)
            pump(0.35)
        pump(3.0)
        check("after diagonal drag")

        # ---- D: resize DURING transcript commits. `insert_before` scrolls
        # using ratatui's `last_known_area`; a resize landing between the
        # per-frame size sample and the commit is the case no gate covers.
        widths = [118, 112, 106, 100, 106, 112, 118, 120]
        for i, cols in enumerate(widths):
            send(f"interleaved {i:02d} " + "wrapping padding text " * 6 + "\r")
            term.set_size(cols, 50)
            pump(0.25)
        pump(4.0)
        check("after resizes interleaved with transcript commits")

    for f in failures:
        print(f"FAIL: {f}")
    if failures:
        return 1
    print("ok — one copy of each band throughout")
    return 0


if __name__ == "__main__":
    sys.exit(main())
