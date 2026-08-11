#!/usr/bin/env python3
"""Resize assertions with OSA running inside **kitty**.

kitty earns its place here twice over.

**As a terminal.** It is a GPU-accelerated, non-libvte, non-multiplexer
emulator with its own screen and scrollback model — a second independent
sample of the population WezTerm was the sole representative of. The resize
gate sends every non-multiplexer down the full-wipe branch on the strength of
WezTerm alone; one measurement is not a population.

**As the calibration reference for pixel counting.** kitty has a full remote
control protocol (`kitty @ get-text --extent all`) that returns scrollback and
screen as plain text, AND it is an ordinary X window that can be
screenshotted. That makes it the one terminal where the exact band count and
the pixel-derived band count can be compared against each other on the same
frame. `alacritty_resize.py` has no text API and must count from pixels; this
harness is what proves that counter honest. See `--calibrate`.

Requires the `kitty` binary, `xdotool` and a display. Skips otherwise.

Run:
    python3 test/pty/kitty_resize.py
    OSA_RESIZE_CLEAR=surgical python3 test/pty/kitty_resize.py
    python3 test/pty/kitty_resize.py --calibrate   # also check pixels.py
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
import pixels  # noqa: E402
import term_env  # noqa: E402

STUB_PORT = 12798
# A dedicated WM_CLASS, so window discovery cannot pick up a kitty the user
# happens to have open. The other harnesses diff against the class's existing
# windows; a private class means there are none to diff against.
KITTY_CLASS = "osa-kitty-probe"


def main(argv: list[str]) -> int:
    calibrate = "--calibrate" in argv

    if not shutil.which("kitty"):
        return gt.skip("kitty not installed")
    if not shutil.which("xdotool"):
        return gt.skip("xdotool not installed")
    if not os.environ.get("DISPLAY"):
        return gt.skip("no DISPLAY")
    binary = gt.osagent_binary()
    if not binary.exists():
        return gt.skip(f"{binary} not built")
    if calibrate and not pixels.have_pillow():
        return gt.skip("Pillow not installed (needed for --calibrate)")

    from stub_backend import StubBackend  # noqa: E402

    failures: list[str] = []
    windows_before = gt.x_windows(KITTY_CLASS)
    sockdir = tempfile.mkdtemp(prefix="osa-kitty-")
    sock = f"unix:{sockdir}/rc"

    with StubBackend(STUB_PORT) as backend:
        cmd = gt.child_command(backend.base_url)
        # kitty spawns the child itself, so a sanitized environment set here
        # does reach it — unlike wezterm, whose mux server owns the spawn.
        # `child_command` also carries an `env -u` prefix, which is redundant
        # here and load-bearing there; keeping both costs nothing.
        env = term_env.clean_env()
        proc = subprocess.Popen(
            [
                "kitty",
                "--class", KITTY_CLASS,
                "--listen-on", sock,
                "-o", "allow_remote_control=yes",
                "-o", "confirm_os_window_close=0",
                # Kill the startup delay that scrollback pollution would add.
                "-o", "scrollback_lines=10000",
                "/bin/sh", "-c", cmd,
            ],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        def get_text() -> str:
            r = subprocess.run(
                ["kitty", "@", "--to", sock, "get-text", "--extent", "all"],
                capture_output=True, text=True,
            )
            return r.stdout

        wid = gt.await_new_window(KITTY_CLASS, windows_before)
        if wid is None:
            proc.terminate()
            return gt.skip("could not find a new kitty window")

        try:
            # Enlarge before the prelude lands (see `child_command`'s `sleep`),
            # and start wide so the drag has room to narrow into.
            gt.resize_window(wid, gt.WINDOW_W, gt.WINDOW_H)

            before = gt.await_composer(get_text)
            if before is None:
                return gt.skip("binary did not reach a composer inside kitty")

            gt.perform_drag(wid)

            after = get_text()
            counts = gt.count_bands(after)
            failures += gt.failures_from_counts(counts, "kitty scrollback")

            label = gt.branch_label()
            dump = gt.artifact_dir() / f"kitty-{label}.txt"
            dump.write_text(after)
            print(f"kitty[{label}] text band counts: {counts}  (artifact: {dump})")

            if calibrate:
                failures += _calibrate(wid, counts, label)

            if failures:
                print("--- kitty text after drag (tail) ---")
                print("\n".join(after.splitlines()[-50:]))
        finally:
            subprocess.run(["kitty", "@", "--to", sock, "close-window"],
                           capture_output=True)
            try:
                proc.terminate()
            except Exception:
                pass
            shutil.rmtree(sockdir, ignore_errors=True)

    for f in failures:
        print(f"FAIL: {f}")
    if failures:
        return 1
    print("ok — one copy of each band survives a window drag in kitty")
    return 0


def _calibrate(wid: str, text_counts: dict[str, int], label: str) -> list[str]:
    """Check `pixels.py` against kitty's exact text count on the same frame.

    The pixel counter counts full-width horizontal RULES, and OSA's live region
    draws a fixed number of them. So the relationship being checked is not
    "same number" but "same MULTIPLE": if the text says one composer survived,
    the visible screen must show one live region's worth of rules, and if the
    text says three, the rules must have tripled too.

    A mismatch means the pixel counter has drifted away from what it claims to
    measure, and everything `alacritty_resize.py` reports is then worthless.
    Failing here is the point — a derived measurement nobody checks is how this
    whole defect stayed invisible for months.
    """
    # Raise BEFORE reading geometry and grabbing: the screenshot comes from the
    # root composite, so a covered window yields a black image and a silent
    # zero. Geometry is read after the raise because activating can move it.
    gt.raise_window(wid)
    geo = gt.window_geometry(wid)
    if geo is None:
        return ["could not read the kitty window geometry to calibrate pixels.py"]

    shot = gt.artifact_dir() / f"kitty-{label}-calibration.png"
    n_bands, bands = pixels.count_rule_bands(geo, save_to=shot)
    composers = text_counts.get("composer prompt", 0)
    print(
        f"kitty[{label}] CALIBRATION: text says {composers} composer(s); "
        f"pixels see {n_bands} rule band(s) at rows {bands}  (artifact: {shot})"
    )

    if composers == 0:
        return ["calibration inconclusive: the text API found no composer at all"]

    # Rules-per-live-region, derived from the frame rather than hardcoded, then
    # sanity-checked. Hardcoding it would make the calibration a tautology.
    if n_bands == 0:
        return [
            "pixels.py found NO full-width rule while kitty's text API found "
            f"{composers} composer(s) — the pixel counter is not measuring what "
            "it claims and alacritty_resize.py cannot be trusted"
        ]
    if n_bands % composers != 0:
        return [
            f"pixels.py found {n_bands} rule band(s), which is not a whole "
            f"multiple of the {composers} composer(s) the text API found — the "
            "pixel counter does not track copies of the live region"
        ]
    print(
        f"kitty[{label}] CALIBRATION OK: {n_bands // composers} rule band(s) "
        "per live region"
    )
    return []


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
