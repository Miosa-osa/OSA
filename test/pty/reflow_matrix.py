#!/usr/bin/env python3
"""Run `reflow_probe.py` under every terminal on this box and tabulate reflow.

This is the measurement that decides the resize gate in `event_loop.rs`. The
gate used to ask "am I in a multiplexer"; what it needs to ask is "does this
terminal reflow on a width change". Those are different questions, and only
measurement can say which terminals fall where.

Each backend does the same three things:

  1. Launch `reflow_probe.py --probe <out>` inside the terminal.
  2. Size the terminal NARROW, then touch `<out>.go` to release the probe.
  3. Wait for `<out>.ready`, then WIDEN, and read the verdict from `<out>`.

Backends report SKIPPED (never failure) when their terminal is not installed
or there is no display, so this stays runnable on a headless box — the probe's
own `--self-test` is the part that always runs.

Run:
    python3 test/pty/reflow_matrix.py            # all backends
    python3 test/pty/reflow_matrix.py wezterm    # one backend
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROBE = HERE / "reflow_probe.py"

# Narrow/wide window geometry in PIXELS for the GUI backends. The probe only
# needs the width to grow by more than its overflow (5 columns); these are
# deliberately far past that so cell-size differences between terminals and
# fonts cannot make the gesture too small to read.
NARROW_PX = (700, 500)
WIDE_PX = (1700, 500)


class Skip(Exception):
    pass


def _wait_for(path: Path, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return True
        time.sleep(0.1)
    return False


def _read(out: Path) -> dict:
    with open(out) as f:
        return json.load(f)


# --------------------------------------------------------------------------
# tmux
# --------------------------------------------------------------------------
def run_tmux(out: Path) -> dict:
    if not shutil.which("tmux"):
        raise Skip("tmux not installed")
    sock = "osa-reflow-probe"

    def tmux(*a: str, check: bool = True) -> str:
        r = subprocess.run(["tmux", "-L", sock, *a], capture_output=True, text=True)
        if check and r.returncode != 0:
            raise RuntimeError(f"tmux {' '.join(a)}: {r.stderr.strip()}")
        return r.stdout

    tmux("kill-server", check=False)
    try:
        # A dedicated tmux SERVER (-L) so this can never touch the user's
        # sessions, and a stuck probe cannot outlive this process.
        tmux(
            "new-session", "-d", "-s", sock, "-x", "80", "-y", "24",
            sys.executable, str(PROBE), "--probe", str(out),
        )
        (out.parent / (out.name + ".go")).touch()
        if not _wait_for(Path(str(out) + ".ready"), 25):
            raise Skip("probe never reached the widen handshake inside tmux")
        tmux("resize-window", "-t", sock, "-x", "140", "-y", "24")
        if not _wait_for(out, 25):
            raise Skip("probe produced no verdict inside tmux")
        return _read(out)
    finally:
        tmux("kill-server", check=False)


# --------------------------------------------------------------------------
# libvte (GNOME Terminal / Tilix / Terminator / Ptyxis all embed this)
# --------------------------------------------------------------------------
def run_vte(out: Path) -> dict:
    if not os.environ.get("DISPLAY"):
        raise Skip("no DISPLAY")
    try:
        import gi

        gi.require_version("Gtk", "3.0")
        gi.require_version("Vte", "2.91")
        from gi.repository import GLib, Gtk, Vte
    except (ImportError, ValueError) as e:
        raise Skip(f"python3-gi / gir1.2-vte-2.91 unavailable ({e})")
    if not Gtk.init_check(None)[0]:
        raise Skip("Gtk.init_check failed")

    term = Vte.Terminal()
    term.set_scrollback_lines(10_000)
    term.set_size(80, 24)
    env = [f"{k}={v}" for k, v in os.environ.items() if k not in ("LINES", "COLUMNS")]
    ok, _pid = term.spawn_sync(
        Vte.PtyFlags.DEFAULT,
        str(HERE),
        [sys.executable, str(PROBE), "--probe", str(out)],
        env,
        GLib.SpawnFlags.DEFAULT,
        None,
        None,
        None,
    )
    if not ok:
        raise Skip("VTE could not spawn the probe")

    def pump(seconds: float) -> None:
        deadline = GLib.get_monotonic_time() + int(seconds * 1_000_000)
        ctx = GLib.MainContext.default()
        while GLib.get_monotonic_time() < deadline:
            while ctx.pending():
                ctx.iteration(False)
            GLib.usleep(5_000)

    Path(str(out) + ".go").touch()
    ready = Path(str(out) + ".ready")
    for _ in range(250):
        pump(0.1)
        if ready.exists():
            break
    else:
        raise Skip("probe never reached the widen handshake in VTE")

    term.set_size(140, 24)
    for _ in range(250):
        pump(0.1)
        if out.exists():
            break
    else:
        raise Skip("probe produced no verdict in VTE")
    return _read(out)


# --------------------------------------------------------------------------
# GUI terminals driven through the real window manager (xdotool)
# --------------------------------------------------------------------------
def _x_windows(classname: str) -> set[str]:
    r = subprocess.run(
        ["xdotool", "search", "--onlyvisible", "--class", classname],
        capture_output=True, text=True,
    )
    return {w for w in r.stdout.split() if w.strip()}


def _run_gui(out: Path, launch: list[str], classname: str, label: str) -> dict:
    """Common driver for a GUI terminal: launch, find its NEW window, resize.

    The window is identified by diffing the visible windows of `classname`
    before and after launch. Matching on pid is what a previous attempt did and
    it does not work for terminals that route the spawn through an already
    running instance — the pid that owns the window is not the pid we started.
    """
    if not os.environ.get("DISPLAY"):
        raise Skip("no DISPLAY")
    if not shutil.which("xdotool"):
        raise Skip("xdotool not installed")

    before = _x_windows(classname)
    proc = subprocess.Popen(launch, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    wid = None
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        new = _x_windows(classname) - before
        if new:
            wid = sorted(new)[-1]
            break
        time.sleep(0.2)
    if wid is None:
        proc.terminate()
        raise Skip(f"could not find a new {label} window of class {classname!r}")

    try:
        subprocess.run(["xdotool", "windowsize", wid, str(NARROW_PX[0]), str(NARROW_PX[1])],
                       capture_output=True)
        time.sleep(2.0)
        Path(str(out) + ".go").touch()

        if not _wait_for(Path(str(out) + ".ready"), 30):
            raise Skip(f"probe never reached the widen handshake in {label}")

        subprocess.run(["xdotool", "windowsize", wid, str(WIDE_PX[0]), str(WIDE_PX[1])],
                       capture_output=True)
        if not _wait_for(out, 30):
            raise Skip(f"probe produced no verdict in {label}")
        return _read(out)
    finally:
        subprocess.run(["xdotool", "windowkill", wid], capture_output=True)
        try:
            proc.terminate()
        except Exception:
            pass


def run_wezterm(out: Path) -> dict:
    if not shutil.which("wezterm"):
        raise Skip("wezterm not installed")
    return _run_gui(
        out,
        # `start --always-new-process` keeps this window out of any mux server
        # the user already has running, so the probe cannot be handed to a
        # pre-existing window whose size we are not driving.
        ["wezterm", "start", "--always-new-process", "--",
         sys.executable, str(PROBE), "--probe", str(out)],
        "org.wezfurlong.wezterm",
        "wezterm",
    )


def run_ghostty(out: Path) -> dict:
    if not shutil.which("ghostty"):
        raise Skip("ghostty not installed")
    return _run_gui(
        out,
        ["ghostty", "-e", sys.executable, str(PROBE), "--probe", str(out)],
        "com.mitchellh.ghostty",
        "ghostty",
    )


def run_xterm(out: Path) -> dict:
    if not shutil.which("xterm"):
        raise Skip("xterm not installed")
    return _run_gui(
        out,
        ["xterm", "-e", sys.executable, str(PROBE), "--probe", str(out)],
        "xterm",
        "xterm",
    )


def run_alacritty(out: Path) -> dict:
    if not shutil.which("alacritty"):
        raise Skip("alacritty not installed")
    return _run_gui(
        out,
        ["alacritty", "-e", sys.executable, str(PROBE), "--probe", str(out)],
        "Alacritty",
        "alacritty",
    )


def run_kitty(out: Path) -> dict:
    if not shutil.which("kitty"):
        raise Skip("kitty not installed")
    return _run_gui(
        out,
        ["kitty", "--single-instance=no", sys.executable, str(PROBE), "--probe", str(out)],
        "kitty",
        "kitty",
    )


BACKENDS = {
    "tmux": run_tmux,
    "vte": run_vte,
    "wezterm": run_wezterm,
    "ghostty": run_ghostty,
    "xterm": run_xterm,
    "alacritty": run_alacritty,
    "kitty": run_kitty,
}


def main(argv: list[str]) -> int:
    wanted = [a for a in argv if not a.startswith("-")] or list(BACKENDS)
    rows: list[tuple[str, str, str]] = []

    for name in wanted:
        fn = BACKENDS.get(name)
        if fn is None:
            print(f"unknown backend {name!r}; known: {', '.join(BACKENDS)}", file=sys.stderr)
            return 2
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "verdict.json"
            try:
                res = fn(out)
            except Skip as e:
                rows.append((name, "SKIPPED", str(e)))
                continue
            except Exception as e:  # a broken backend must not hide the others
                rows.append((name, "ERROR", f"{type(e).__name__}: {e}"))
                continue
            verdict = res.get("reflow")
            rows.append((
                name,
                {True: "REFLOWS", False: "NO REFLOW"}.get(verdict, "UNKNOWN"),
                str(res.get("why", "")),
            ))

    width = max(len(r[0]) for r in rows)
    print()
    print("reflow-on-width-change, measured on this box")
    print("=" * 44)
    for name, verdict, why in rows:
        print(f"{name:<{width}}  {verdict:<10}  {why}")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
