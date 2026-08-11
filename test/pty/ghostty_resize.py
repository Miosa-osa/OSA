#!/usr/bin/env python3
"""Resize assertions with OSA running inside **Ghostty** — with a real band count.

Ghostty DOES have a text-extraction API
---------------------------------------
This file used to open by stating that Ghostty has "no CLI, no control socket
and no escape sequence that reports screen or scrollback contents", and
therefore asserted only that OSA *survived* a drag. That was wrong, and it left
the one terminal the owner is most likely to be running as the only one whose
band count nobody had ever measured.

Ghostty ships two keybind actions that dump the terminal's own text:

    write_screen_file       the visible screen
    write_scrollback_file   the scroll history

Each takes a target, and `:copy` puts the path of a plain-text dump on the
clipboard. `ghostty +list-keybinds` lists both, and Ghostty 1.2.3 binds
`write_screen_file:open` by default. Bind them to keys, press the keys, read
the clipboard, read the files: that is exact text, the same currency
`capture-pane` and `wezterm cli get-text` pay in.

Three details make it actually work, each of which silently produces an empty
clipboard if got wrong:

1. **The keybinds must arrive via `$XDG_CONFIG_HOME`, not the command line.**
   Ghostty accepts config keys as `--key=value` flags for the emulator, but
   `+list-keybinds` shows they do not register from there, and `--config-file`
   makes the action exit non-zero with no output. Pointing `$XDG_CONFIG_HOME`
   at a scratch directory containing `ghostty/config` registers them, and has
   the added virtue of not touching the user's real configuration.

2. **The keystroke must be a REAL X event, not a synthetic one.** Ghostty is a
   GTK application and GTK ignores `XSendEvent` key events by default, so
   `xdotool key --window <id>` never fires the binding. The window has to be
   activated and the key injected through XTEST (`gui_terminals.focus_and_key`).

3. **`F9` not `f9`.** xdotool's keysym table is case-sensitive for function
   keys and answers a lowercase `f9` with "No such key name", on stderr, while
   still exiting zero.

So the band count IS available here, and this harness now makes the same
assertion every other emulator harness makes. The surviving honest caveat is
that the two dumps are separate files: history and screen are concatenated in
that order, which is the same thing `wezterm cli get-text --start-line -2000`
returns as one string.

It also keeps the older, weaker assertion — that OSA is still alive after the
drag — because the resize path has a documented crash mode (`rebuild_inline`
issues a DSR cursor query, and a terminal that drops it mid-resize surfaced as
"cursor position could not be read" and killed the session). That is the
failure a user notices first, and it is worth catching separately from a band
count that a dead process cannot produce at all.

Requires the `ghostty` binary, `xdotool`, `xclip` and a display. Skips otherwise.

Run:
    python3 test/pty/ghostty_resize.py
    OSA_RESIZE_CLEAR=surgical python3 test/pty/ghostty_resize.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gui_terminals as gt  # noqa: E402  (needs the sys.path line above)

STUB_PORT = 12797
GHOSTTY_CLASS = "com.mitchellh.ghostty"

SCREEN_KEY = "ctrl+shift+F9"
SCROLLBACK_KEY = "ctrl+shift+F10"

CONFIG = """\
keybind = ctrl+shift+F9=write_screen_file:copy
keybind = ctrl+shift+F10=write_scrollback_file:copy
gtk-single-instance = false
confirm-close-surface = false
"""


def _clipboard() -> str:
    r = subprocess.run(
        ["xclip", "-selection", "clipboard", "-o"], capture_output=True, text=True
    )
    return r.stdout.strip() if r.returncode == 0 else ""


def _clear_clipboard() -> None:
    subprocess.run(
        ["xclip", "-selection", "clipboard", "-i", "/dev/null"], capture_output=True
    )


def _dump(wid: str, key: str) -> str:
    """Trigger a Ghostty dump action and read back the file it wrote.

    The clipboard is cleared first so a stale path from the previous dump
    cannot be mistaken for this one's — the two actions write to different
    temp directories, but a failed keypress would otherwise read the previous
    success and report it as fresh.
    """
    _clear_clipboard()
    gt.focus_and_key(wid, key)
    # The action writes a file and then sets the clipboard; both are async with
    # respect to the keypress.
    for _ in range(20):
        time.sleep(0.25)
        path = _clipboard()
        if path and Path(path).is_file():
            try:
                return Path(path).read_text(errors="replace")
            except OSError:
                return ""
    return ""


def main() -> int:
    for tool in ("ghostty", "xdotool", "xclip", "xwininfo"):
        if not shutil.which(tool):
            return gt.skip(f"{tool} not installed")
    if not os.environ.get("DISPLAY"):
        return gt.skip("no DISPLAY")
    binary = gt.osagent_binary()
    if not binary.exists():
        return gt.skip(f"{binary} not built")

    from stub_backend import StubBackend  # noqa: E402

    failures: list[str] = []
    windows_before = gt.x_windows(GHOSTTY_CLASS)

    # An isolated config directory: the keybinds have to be registered somehow,
    # and editing the user's own ~/.config/ghostty/config to run a test would
    # be an unacceptable side effect.
    cfgroot = Path(tempfile.mkdtemp(prefix="osa-ghostty-cfg-"))
    (cfgroot / "ghostty").mkdir()
    (cfgroot / "ghostty" / "config").write_text(CONFIG)

    with StubBackend(STUB_PORT) as backend:
        # Ghostty closes its window when the child dies, so "did OSA survive"
        # cannot be read from the window alone — a closed window and a
        # never-opened one look identical by the time anyone looks.
        alive = Path(tempfile.gettempdir()) / f"osa-ghostty-probe-{os.getpid()}"
        cmd = gt.child_command(backend.base_url, exit_flag=str(alive))

        env = dict(os.environ, XDG_CONFIG_HOME=str(cfgroot))
        proc = subprocess.Popen(
            ["ghostty", "-e", "/bin/sh", "-c", cmd],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        wid = gt.await_new_window(GHOSTTY_CLASS, windows_before)
        if wid is None:
            proc.terminate()
            shutil.rmtree(cfgroot, ignore_errors=True)
            return gt.skip("could not find a new ghostty window")

        def get_text() -> str:
            """History then screen, concatenated — the whole readable buffer.

            Order matters: stranded chrome ends up ABOVE the live region, i.e.
            in history, and a count taken from the visible screen alone would
            miss exactly the copies this harness is looking for.
            """
            history = _dump(wid, SCROLLBACK_KEY)
            screen = _dump(wid, SCREEN_KEY)
            return history + "\n" + screen

        try:
            gt.resize_window(wid, gt.WINDOW_W, gt.WINDOW_H)

            before = gt.await_composer(get_text, tries=20, interval=1.5)
            if before is None:
                if alive.exists():
                    return gt.skip("OSA exited before the drag; nothing to assert about")
                return gt.skip(
                    "binary did not reach a composer inside ghostty "
                    "(or the dump keybinds never fired)"
                )

            gt.perform_drag(wid)

            # The older, weaker assertion, kept: a drag that kills the session
            # is the failure a user notices first.
            if alive.exists():
                failures.append(
                    "OSA exited during the width drag — the resize path did not "
                    "survive Ghostty (historically: a dropped DSR cursor query "
                    "surfacing as 'cursor position could not be read')"
                )
                after = ""
            else:
                after = get_text()

            if after:
                counts = gt.count_bands(after)
                failures += gt.failures_from_counts(counts, "ghostty scrollback")
                label = gt.branch_label()
                dumpfile = gt.artifact_dir() / f"ghostty-{label}.txt"
                dumpfile.write_text(after)
                print(
                    f"ghostty[{label}] text band counts: {counts}  "
                    f"(artifact: {dumpfile})"
                )
                if failures:
                    print("--- ghostty text after drag (tail) ---")
                    print("\n".join(after.splitlines()[-50:]))
        finally:
            gt.kill_window(wid)
            try:
                proc.terminate()
            except Exception:
                pass
            try:
                alive.unlink()
            except FileNotFoundError:
                pass
            shutil.rmtree(cfgroot, ignore_errors=True)

    for f in failures:
        print(f"FAIL: {f}")
    if failures:
        return 1
    print("ok — one copy of each band survives a window drag in Ghostty")
    return 0


if __name__ == "__main__":
    sys.exit(main())
