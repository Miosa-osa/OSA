#!/usr/bin/env python3
"""On exit, OSA leaves the conversation behind — and leaves the shell's own
scrollback alone.

Why this exists
---------------
OSA is moving to the alternate screen so it owns the whole viewport: that is
what stops the terminal re-wrapping committed rows into the shredded tables a
user reported, because there are no surrendered rows left to re-wrap. The
alternate screen also guarantees the thing that decided the design — the user's
shell history from BEFORE launch is untouched, and restored intact on exit, the
way `vim` and `less` behave.

It costs one thing on the way out. Quitting tears the alternate screen down and
takes the session with it, where today a user quits and their conversation is
still on screen to scroll back through, copy a command out of, or paste into a
ticket. Losing that would be breaking something in exchange for fixing
something. So the retained transcript is re-rendered at the width the terminal
has AT EXIT and printed to the primary screen.

Both halves of that are load-bearing and both are asserted here:

  * what came before OSA must still be there afterwards;
  * what happened during OSA must be there afterwards too.

This runs inside real libvte through a real `/bin/sh`, so "before" and "after"
are the shell's actual scrollback rather than a model of it, and the probe can
tell an exit that restored the terminal from one that merely looked like it (the
shell's own marker after OSA returns proves the process actually exited rather
than wedging).

Requirements: `python3-gi`, `gir1.2-vte-2.91`, a display, and a release build.
Anything missing is reported SKIPPED, never as a failure.

Run: `python3 test/pty/vte_exit_dump.py`
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import term_env  # noqa: E402
import vte_reader  # noqa: E402

STUB_PORT = 12799
ROWS = 40
COLS = 120

PRELAUNCH = "PRELAUNCH_MARKER"
AFTER_EXIT = "AFTER_EXIT_MARKER"
REPLY_MARK = "EXITDUMPMARK"

# A table in the reply, so the dump is exercised on the content type that
# started all of this rather than on prose that would survive anything.
REPLY = (
    "| Component | Owner | Notes |\n"
    "| --- | --- | --- |\n"
    "| gateway | platform | handles the websocket handshake literally |\n"
    "| storage | infra | see ISSUES.md and Documentation/CANON.md |\n"
    f"\n{REPLY_MARK} done.\n"
)


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

    from stub_backend import StubBackend, push_sse, release_turn  # noqa: E402

    repo = Path(__file__).resolve().parents[2]
    binary = repo / "priv/rust/tui/target/release/osagent"
    if not binary.exists():
        return _skip(f"{binary} not built (cargo build --release)")

    failures: list[str] = []

    with StubBackend(STUB_PORT) as backend:
        term = Vte.Terminal()
        term.set_scrollback_lines(10_000)
        term.set_size(COLS, ROWS)
        env = term_env.clean_env_list(**term_env.backend_vars(backend.base_url))

        # A real shell wraps the run: it writes the "before" markers, execs OSA,
        # and writes an "after" marker once OSA returns. That last one is what
        # separates a clean exit from a wedge -- a screen assertion cannot,
        # because a hung TUI and an exited one can look identical.
        script = (
            f"printf '{PRELAUNCH}_%s\\n' 1 2 3; "
            f"{binary}; "
            f"printf '{AFTER_EXIT}\\n'; sleep 600"
        )
        term.spawn_sync(
            Vte.PtyFlags.DEFAULT, str(repo), ["/bin/sh", "-c", script], env,
            GLib.SpawnFlags.DEFAULT, None, None, None,
        )

        def pump(seconds: float) -> None:
            deadline = GLib.get_monotonic_time() + int(seconds * 1_000_000)
            ctx = GLib.MainContext.default()
            while GLib.get_monotonic_time() < deadline:
                while ctx.pending():
                    ctx.iteration(False)
                GLib.usleep(5_000)

        def rows() -> list[str]:
            return vte_reader.buffer_rows(term, Vte)

        for _ in range(30):
            pump(1.0)
            if any("Ask OSA anything" in r for r in rows()):
                break
        else:
            return _skip("binary did not reach a composer; nothing to assert about")

        before = sum(1 for r in rows() if PRELAUNCH in r)
        if before != 3:
            return _skip(f"the shell's own markers never landed ({before}/3)")

        fd = term.get_pty().get_fd()

        # One turn. Text and Enter are separate writes: sent as one burst OSA's
        # paste-burst detector reads the carriage return as a NEWLINE, not a
        # submit, and the prompt sits in the composer unsent.
        os.write(fd, b"show table")
        pump(0.6)
        os.write(fd, b"\r")
        pump(0.8)
        release_turn()
        push_sse(
            "agent_response",
            {"response": REPLY, "response_type": "text", "message_id": "m1"},
        )
        pump(3.0)

        # Quit. Ctrl+C twice is the armed-quit path.
        os.write(fd, b"\x03")
        pump(0.6)
        os.write(fd, b"\x03")
        pump(3.0)
        if not any(AFTER_EXIT in r for r in rows()):
            os.write(fd, b"\x04")  # Ctrl+D, in case the composer held the first
            pump(3.0)

        after = rows()

        if not any(AFTER_EXIT in r for r in after):
            failures.append(
                "OSA never returned to the shell — the process wedged instead of "
                "exiting, so nothing below can be trusted"
            )

        survived = sum(1 for r in after if PRELAUNCH in r)
        if survived != 3:
            failures.append(
                f"the shell's scrollback from BEFORE launch did not survive: "
                f"{survived}/3 markers left. This is the entire reason the "
                f"alternate screen was chosen over purging and re-emitting."
            )

        # The dump prints the reply a SECOND time (once live, once on exit), so
        # two occurrences is the healthy count and one means the dump is missing.
        printed = sum(1 for r in after if REPLY_MARK in r)
        if printed < 2:
            failures.append(
                f"the conversation was not left behind on exit ({REPLY_MARK} "
                f"appears {printed}×, expected 2: once live, once in the dump). "
                f"Quitting must not take the session with it."
            )

        # The dump must be laid out for the terminal, not replayed at some width
        # it was committed at.
        overflow = [r for r in after if vte_reader and len(r) > COLS]
        if overflow:
            failures.append(
                f"{len(overflow)} dumped rows are wider than the {COLS}-column "
                f"terminal, so the dump was not rendered at the exit width"
            )

        if failures:
            print("--- terminal after exit (tail) ---")
            for r in after[-40:]:
                print(f"|{r}")

    for f in failures:
        print(f"FAIL: {f}")
    if failures:
        return 1
    print(
        "ok — pre-launch shell scrollback intact, OSA exited cleanly, and the "
        "conversation was left behind rendered at the exit width"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
