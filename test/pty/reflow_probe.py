#!/usr/bin/env python3
"""Measure, empirically, whether a terminal REFLOWS on a width change.

Why this exists
---------------
The resize fix in `event_loop.rs` used to be gated on "am I inside a
multiplexer". That is a proxy for the property that actually matters:

    when the width changes, does the emulator re-wrap already-committed
    lines to the new width?

If it does, the remembered live-region top row is stale after a resize and a
surgical clear from it misses chrome that moved. If it does NOT, the remembered
top stays valid and a full-screen wipe is both unnecessary and harmful (the old
live region scrolls into history where no erase can reach it, which is the
"13 stacked composers after a 12-step drag" defect).

`tmux` happens not to reflow, which is why the multiplexer gate worked. But
"multiplexer" and "does not reflow" are different sets: Alacritty is widely
reported not to reflow either, and is not a multiplexer.

How it measures
---------------
Text extraction is not available on every emulator (Ghostty has no such API),
so this probe does not read the screen. It reports on ITSELF, using only the
DSR cursor-position report, which every VT100-descended terminal implements:

  1. Clear the screen and home the cursor.
  2. Write a single logical line of `cols + 5` characters. It wraps, so the
     cursor lands on row 2, column 6.
  3. Wait for the driver to WIDEN the terminal to at least `cols + 40`.
  4. Ask again where the cursor is.

     * row 1  -> the emulator re-wrapped the line to the new width. REFLOW.
     * row 2  -> the wrap point is frozen where it was. NO REFLOW.

Widening (never narrowing) is deliberate: with a cleared screen and two rows of
content, widening cannot scroll, so a row-number change can only come from
reflow. Narrowing can add rows and scroll, which would confound the reading.

Usage
-----
    reflow_probe.py --probe /path/to/result.json     # run INSIDE the terminal
    reflow_probe.py --self-test                      # sanity-check on a raw PTY

The driver (`reflow_matrix.py`) launches this under each terminal it can find.
"""

from __future__ import annotations

import json
import os
import sys
import termios
import time
import tty

# Widen by at least this many columns beyond the wrapped line's length so the
# line unambiguously fits on one row afterwards.
WIDEN_MARGIN = 40
OVERFLOW = 5


def _write_result(out_path: str, result: dict) -> None:
    """Publish the result atomically.

    The driver polls for this file's existence, so a partially-written file
    would be read as corrupt JSON and reported as a probe failure.
    """
    tmp = out_path + ".part"
    with open(tmp, "w") as f:
        json.dump(result, f)
        f.flush()
        os.fsync(f.fileno())
    os.rename(tmp, out_path)


def _dsr(fd: int, timeout: float = 2.0) -> tuple[int, int] | None:
    """Ask the terminal for the cursor position. `None` if it does not answer.

    A dropped reply is a real outcome, not an error: some emulators drop DSR
    while a resize is in flight, and a probe that hung there would be worse
    than one that reports "unknown".
    """
    os.write(fd, b"\x1b[6n")
    buf = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            import select

            r, _, _ = select.select([fd], [], [], 0.05)
            if not r:
                continue
            chunk = os.read(fd, 64)
        except OSError:
            return None
        if not chunk:
            continue
        buf += chunk
        if b"R" in buf:
            break
    else:
        return None

    # Reply is ESC [ row ; col R, possibly preceded by junk.
    try:
        body = buf[buf.rindex(b"\x1b[") + 2 : buf.rindex(b"R")]
        row_s, col_s = body.split(b";")
        return int(row_s), int(col_s)
    except (ValueError, IndexError):
        return None


def probe(out_path: str) -> int:
    result: dict[str, object] = {"reflow": None, "why": "", "terminal": {}}
    for key in ("TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TMUX"):
        if os.environ.get(key):
            result["terminal"][key] = os.environ[key]  # type: ignore[index]

    def bail(why: str) -> int:
        result["why"] = why
        _write_result(out_path, result)
        return 1

    try:
        fd = os.open("/dev/tty", os.O_RDWR)
    except OSError as e:
        return bail(f"no controlling tty: {e}")

    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)

        # Optional start handshake. A GUI terminal is launched at whatever size
        # its config says and only then resized by the driver, so measuring the
        # instant we start would sample a width that is about to change. The
        # driver touches `<out>.go` once the window has settled at the narrow
        # size. Drivers that control the size up front (tmux, VTE) simply never
        # create it, and the wait falls through.
        go = out_path + ".go"
        deadline = time.monotonic() + 8.0
        while time.monotonic() < deadline and not os.path.exists(go):
            time.sleep(0.1)

        cols0 = os.get_terminal_size(fd).columns

        # Cleared screen + home. ED0-from-home, never ED2 (VTE scrolls the
        # screen into scrollback for ED2) and never ED3 (purges history).
        os.write(fd, b"\x1b[H\x1b[J")
        os.write(fd, b"R" * (cols0 + OVERFLOW))
        time.sleep(0.3)

        first = _dsr(fd)
        if first is None:
            return bail("terminal did not answer the first DSR")
        if first[0] != 2:
            return bail(
                f"line of {cols0 + OVERFLOW} cols at width {cols0} did not land on "
                f"row 2 (got row {first[0]}); cannot measure"
            )

        # Hand off to the driver, which widens the window.
        target = cols0 + WIDEN_MARGIN
        result["width_before"] = cols0
        result["width_target"] = target
        with open(out_path + ".ready", "w") as f:
            f.write(str(target))

        deadline = time.monotonic() + 45.0
        while time.monotonic() < deadline:
            if os.get_terminal_size(fd).columns >= cols0 + OVERFLOW + 1:
                break
            time.sleep(0.1)
        else:
            return bail("driver never widened the terminal")

        # Let the emulator settle; a reflow is not necessarily synchronous with
        # the SIGWINCH.
        time.sleep(1.2)
        cols1 = os.get_terminal_size(fd).columns
        result["width_after"] = cols1

        second = _dsr(fd)
        if second is None:
            return bail("terminal did not answer the DSR after the resize")

        result["row_before"] = first[0]
        result["row_after"] = second[0]

        if second[0] == 1:
            result["reflow"] = True
            result["why"] = (
                f"the {cols0 + OVERFLOW}-char line re-wrapped to one row at "
                f"width {cols1}: cursor moved row 2 -> row 1"
            )
        elif second[0] == 2:
            result["reflow"] = False
            result["why"] = (
                f"the {cols0 + OVERFLOW}-char line kept its old wrap point at "
                f"width {cols1}: cursor stayed on row 2"
            )
        else:
            return bail(f"cursor landed on row {second[0]}; content scrolled, unreadable")
    finally:
        try:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
            os.write(fd, b"\x1b[H\x1b[J")
        except Exception:
            pass
        os.close(fd)

    _write_result(out_path, result)
    return 0


def _fake_terminal_run(reflowing: bool) -> dict | None:
    """Drive the probe against a synthetic emulator with a KNOWN answer.

    The probe is only trustworthy if it can come back with either answer. A
    self-test that exercised one direction would pass just as happily on a
    probe hard-wired to that direction, so both are run.

    There is no emulator behind a bare PTY, so this stands in for one. It
    tracks the single fact the probe reads — which row the cursor is on after
    `n` characters — and differs between the two modes in exactly the way real
    emulators differ: a reflowing terminal re-wraps at the CURRENT width, a
    non-reflowing one keeps the width that was in force when the text arrived.
    """
    import pty
    import select
    import struct
    import fcntl
    import tempfile

    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, "r.json")
        pid, fd = pty.fork()
        if pid == 0:
            os.execv(sys.executable, [sys.executable, __file__, "--probe", out])
            os._exit(1)

        def setsize(cols: int, rows: int = 24) -> None:
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

        start_cols = 80
        setsize(start_cols)
        cols = start_cols
        text_cols = start_cols  # width in force when the text was written
        written = 0
        widened = False
        deadline = time.monotonic() + 40

        while time.monotonic() < deadline:
            r, _, _ = select.select([fd], [], [], 0.1)
            if r:
                try:
                    data = os.read(fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                if b"\x1b[H\x1b[J" in data:
                    written = 0
                    text_cols = cols
                written += data.replace(b"\x1b[H\x1b[J", b"").count(b"R")
                if b"\x1b[6n" in data:
                    # The DSR query itself ends in 'n', not 'R', so the count
                    # above is unaffected by it.
                    wrap_at = cols if reflowing else text_cols
                    row = 1 + (written - 1) // wrap_at if written else 1
                    col = (written - 1) % wrap_at + 1 if written else 1
                    os.write(fd, f"\x1b[{row};{col}R".encode())
            if not widened and os.path.exists(out + ".ready"):
                cols = start_cols + WIDEN_MARGIN
                setsize(cols)
                widened = True
            if os.path.exists(out):
                break

        try:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
        except (ChildProcessError, ProcessLookupError):
            pass
        try:
            os.close(fd)
        except OSError:
            pass

        if not os.path.exists(out):
            return None
        with open(out) as f:
            return json.load(f)


def self_test() -> int:
    """Verify the probe reports BOTH answers correctly against known fakes.

    This runs with no display and no real terminal, so it is the always-
    runnable half: a SKIPPED terminal in the matrix can never hide a probe
    whose mechanics (raw mode, DSR round trip, widen handshake) have rotted.
    """
    failures = []
    for reflowing in (False, True):
        label = "reflowing" if reflowing else "non-reflowing"
        res = _fake_terminal_run(reflowing)
        if res is None:
            failures.append(f"{label} fake: probe produced no result")
            continue
        if res.get("reflow") is not reflowing:
            failures.append(
                f"{label} fake: probe said reflow={res.get('reflow')} "
                f"(expected {reflowing}) — {res.get('why')}"
            )
        else:
            print(f"ok — {label} fake read as reflow={reflowing}: {res['why']}")

    for f in failures:
        print(f"FAIL: {f}")
    return 1 if failures else 0


def main(argv: list[str]) -> int:
    if "--probe" in argv:
        return probe(argv[argv.index("--probe") + 1])
    if "--self-test" in argv:
        return self_test()
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
