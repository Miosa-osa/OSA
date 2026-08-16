"""A real PTY around the real `osagent` binary, rendered through a real emulator.

WHY THIS EXISTS
===============

The Rust suite renders through `VT100Backend`, a perfect in-process emulator that
answers cursor queries from its own model. Ratatui's inline viewport re-anchors
itself by asking the terminal where the cursor is (DSR, `ESC[6n`); against a
perfect emulator that answer is always the right row, so the re-anchor always
lands correctly and a whole class of defect **cannot materialise in-process**.

The defect that class hides is stranding: on a resize, the viewport re-anchors
and erases only the rect it just computed, leaving the previous copy of the live
region painted on rows nothing will ever clear. A window drag emits one resize
per intermediate width, so a single drag left nine stacked composers on screen —
through roughly a thousand passing tests, none of which could see it.

This harness closes that hole from the outside: `pty.fork` gives the binary a
kernel PTY (so it takes the same code path a terminal does), `TIOCSWINSZ`
resizes it for real (delivering SIGWINCH, exactly like a drag), the output is fed
to a `pyte` emulator, and `ESC[6n` is answered from THAT emulator's cursor. Then
we count how many composers are on screen. One is correct. Nine is the bug.

KNOWN LIMITATION — READ BEFORE TRUSTING A PASS
==============================================

**pyte does not reflow on resize; VTE (GNOME Terminal, and most modern
emulators) does.** When a real VTE-backed terminal narrows, it re-wraps the
existing scrollback, which MOVES content the TUI believes it knows the position
of. pyte instead truncates/pads columns and leaves rows where they are.

So this harness reproduces the re-anchor/erase half of the stranding class — the
half that produced the nine stacked composers — and **under**-reproduces the
VTE-specific reflow half. A green run here is evidence that the arbiter and the
resize settle window behave, NOT proof that a change is safe in GNOME Terminal.
Reflow-sensitive changes still want a human eye on a real terminal.

Also worth stating plainly: this drives the TUI against `stub_backend.py`, not
the Elixir backend. It tests LAYOUT, not agent behaviour.
"""

from __future__ import annotations

import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time
from pathlib import Path

try:
    import pyte
except ImportError:  # pragma: no cover - environment guard
    sys.exit(
        "pyte is required by the PTY harness: pip install pyte\n"
        "(see test/pty/README.md)"
    )

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BIN = REPO_ROOT / "priv" / "rust" / "tui" / "target" / "release" / "osagent"

# DSR — Device Status Report, cursor position. Ratatui's inline viewport issues
# this on every rebuild; answering it from the emulator's real cursor is the
# whole point of the harness.
_DSR = re.compile(rb"\x1b\[6n")

# How long to let the TUI reach a quiet state before asserting. The resize
# settle window in the event loop is 50ms and the tick cadence is 200ms, so
# anything above ~1s is comfortably past both.
SETTLE = 1.0


class PtySession:
    """A running `osagent` on a PTY, with a `pyte` screen tracking its output."""

    def __init__(
        self,
        base_url: str,
        cols: int = 100,
        rows: int = 30,
        binary: Path | None = None,
        history: int = 4000,
    ) -> None:
        self.binary = Path(binary) if binary else DEFAULT_BIN
        if not self.binary.exists():
            raise FileNotFoundError(
                f"{self.binary} not found — build it first:\n"
                f"  cd {REPO_ROOT}/priv/rust/tui && cargo build --release"
            )
        self.base_url = base_url
        self.cols = cols
        self.rows = rows
        # HistoryScreen keeps rows that scroll off the top. Stranded chrome very
        # often ends up there (the viewport scrolls past the copy it abandoned),
        # so counting only the visible screen would miss real strandings.
        self.screen = pyte.HistoryScreen(cols, rows, history=history)
        self.stream = pyte.Stream(self.screen)
        # Every byte the child has written, appended by `pump`. The rendered
        # screen is the primary evidence; this is for the defects the renderer
        # cannot show (see `emitted_since`).
        self.raw = bytearray()
        self.pid: int | None = None
        self.fd: int | None = None

    # -- lifecycle ---------------------------------------------------------

    def __enter__(self) -> "PtySession":
        port = self.base_url.rsplit(":", 1)[-1]
        pid, fd = pty.fork()
        if pid == 0:  # child
            env = {
                k: v
                for k, v in os.environ.items()
                # TMUX makes the TUI wrap sequences in tmux passthrough (DCS)
                # and take tmux-specific code paths. We are not under tmux.
                if k not in ("TMUX", "TMUX_PANE")
            }
            env["TERM"] = "xterm-256color"
            env["OSA_URL"] = self.base_url
            env["OSA_PORT"] = port
            # Never let a harness run touch the developer's real state.
            env["HOME"] = os.environ.get("OSA_PTY_HOME", env.get("HOME", "/tmp"))
            env["NO_COLOR"] = ""
            os.execve(str(self.binary), [str(self.binary)], env)
            os._exit(127)  # unreachable
        self.pid, self.fd = pid, fd
        self.resize(self.cols, self.rows)
        return self

    def __exit__(self, *_exc) -> None:
        self.close()

    def close(self) -> None:
        if self.pid is not None:
            try:
                os.kill(self.pid, signal.SIGKILL)
                os.waitpid(self.pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
            self.pid = None
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None

    # -- driving -----------------------------------------------------------

    def resize(self, cols: int, rows: int) -> None:
        """Resize the PTY for real — this delivers SIGWINCH to the child."""
        assert self.fd is not None
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.cols, self.rows = cols, rows
        self.screen.resize(rows, cols)

    def write(self, data: bytes) -> None:
        assert self.fd is not None
        os.write(self.fd, data)

    def mark(self) -> int:
        """Current position in the emitted byte stream, for `emitted_since`."""
        return len(self.raw)

    def emitted_since(self, mark: int) -> bytes:
        """Bytes the child wrote after `mark`.

        Exists because pyte does not reflow on resize and VTE does, so a
        sequence that scrolls the live region into unreflowable history renders
        identically here to one that erases it in place. The distinction is
        entirely in the bytes: ED2 (`ESC[2J`) is implemented by VTE as a scroll
        into scrollback, whereas ED0 (`ESC[J`) is an in-place erase everywhere.
        Asserting on the emission makes the invariant checkable on any
        emulator, including this one.
        """
        return bytes(self.raw[mark:])

    def in_alt_screen(self) -> bool:
        """True if the last alt-screen toggle emitted was an enter.

        ED2 is harmless inside the alternate screen — it has no scrollback to
        scroll into — so the scrollback-safety assertions only apply to the
        inline path, and need to know which one is live.
        """
        enter = self.raw.rfind(b"\x1b[?1049h")
        leave = self.raw.rfind(b"\x1b[?1049l")
        return enter > leave

    def pump(self, duration: float) -> None:
        """Read and render output for `duration` seconds, answering DSR."""
        assert self.fd is not None
        deadline = time.time() + duration
        while time.time() < deadline:
            remaining = max(0.0, deadline - time.time())
            readable, _, _ = select.select([self.fd], [], [], min(0.05, remaining))
            if not readable:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            # Keep the raw bytes as well as the rendered screen. Some defects
            # are invisible in the rendering but obvious in the byte stream:
            # pyte does not reflow on resize, so a sequence that deposits the
            # live region into scrollback on VTE leaves this screen looking
            # perfectly correct. Asserting on what OSA *emitted* sidesteps the
            # emulator's fidelity entirely. See `emitted_since`.
            self.raw.extend(chunk)
            self.stream.feed(chunk.decode("utf-8", "replace"))
            # Answer every cursor query from the EMULATOR's cursor, which is
            # what a real terminal does and what the in-process backend cannot
            # get wrong. 1-based, row then column.
            for _ in _DSR.findall(chunk):
                y = self.screen.cursor.y + 1
                x = self.screen.cursor.x + 1
                self.write(b"\x1b[%d;%dR" % (y, x))

    def boot(self, timeout: float = 20.0) -> None:
        """Pump until the composer is on screen, or fail loudly."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.pump(0.25)
            if self.count(COMPOSER) >= 1:
                # Give the boot toasts / status chips a beat to settle.
                self.pump(SETTLE)
                return
        raise AssertionError(
            "osagent never rendered a composer within "
            f"{timeout}s. Screen was:\n{self.dump()}"
        )

    def wait_for_text(self, needle: str, timeout: float) -> bool:
        """Pump until `needle` is anywhere on the rendered screen."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.pump(0.1)
            if needle in "\n".join(self.lines()):
                return True
        return False

    def wait_exit(self, timeout: float) -> bool:
        """Pump until the child process exits, or give up.

        The only way to prove a quit key actually quits. Asserting on the screen
        cannot: a TUI that ignores Ctrl+C and one that handles it draw the same
        thing right up until the process is gone.
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.pump(0.1)
            if self.pid is None:
                return True
            try:
                pid, _ = os.waitpid(self.pid, os.WNOHANG)
            except (ChildProcessError, ProcessLookupError):
                self.pid = None
                return True
            if pid:
                self.pid = None
                return True
        return False

    # -- observing ---------------------------------------------------------

    def lines(self) -> list[str]:
        """Every rendered line: scrolled-off history, then the live screen.

        Stranded chrome frequently scrolls off the top, so history is not
        optional — a visible-screen-only count is how this class of bug stays
        invisible.
        """
        out: list[str] = []
        for row in self.screen.history.top:
            out.append("".join(cell.data for _, cell in sorted(row.items())))
        out.extend(self.screen.display)
        for row in self.screen.history.bottom:
            out.append("".join(cell.data for _, cell in sorted(row.items())))
        return [line.rstrip() for line in out]

    def count(self, pattern: re.Pattern[str]) -> int:
        """How many rendered lines match `pattern`."""
        return sum(1 for line in self.lines() if pattern.search(line))

    def dump(self) -> str:
        return "\n".join(f"{i:3d}|{line}" for i, line in enumerate(self.lines()))


# --- The markers the assertions count -------------------------------------
#
# Each identifies exactly ONE band of the live region, by something that band
# always draws exactly once and no other band draws. The stranding bug is
# precisely "more than one copy of these on screen", so the marker only has to
# be unique per live region — it does not have to be structural.
#
# They are matched against `lines()`, which includes scrolled-off history:
# a stranded copy usually ends up there.

# The composer's TOP divider: a row that is nothing but horizontal rule. The
# welcome box also draws long runs of `─`, but always fenced by `╭`/`│`/`╰`, so
# anchoring the match to the whole line keeps this to the composer.
COMPOSER_TOP = re.compile(r"^─{20,}$")
# The composer's prompt glyph, at the start of its row.
COMPOSER = re.compile(r"^\s*❯")
# The header a COMMITTED user message draws into the transcript: the same
# prompt glyph, then the literal "You" (`components/chat/message.rs::draw_user`
# renders `"❯  "` + `"You"`). It is transcript, not live region, but `COMPOSER`
# cannot tell the two apart — subtract this to count composers alone.
USER_HEADER = re.compile(r"^\s*❯\s{2}You(\s|$)")
# The composer's BOTTOM divider, which carries the right-aligned key hints.
COMPOSER_HINTS = re.compile(r"/ commands · @ files")
# The status line's context-percentage chip.
STATUS = re.compile(r"%\s*ctx")

#: Rows a healthy live region renders EXACTLY ONE of, by name.
#:
#: Three of the four are rows of the composer band (top divider, prompt, bottom
#: divider) and the fourth is the status bar — chosen because stranding leaves a
#: whole extra live region behind, so every one of them doubles at once, and
#: because between them they span the top and bottom of the region.
#:
#: NOT included: the arbiter's `ROW_HINT` band (`Bands.hint`). It is a
#: right-aligned NOTICE row that is empty while the app is idle, so it renders
#: no glyphs to count. The boot banner's "/help for commands …" line looks like
#: a hint row but is scrollback, not a band — it is legitimately wiped by the
#: destructive clear a real resize takes, so counting it would fail a correct
#: build. The composer's bottom divider is used in its place: it is a real row
#: of the live region, always present, and duplicates under exactly the same
#: defect.
SINGLETON_BANDS = {
    "composer_top": COMPOSER_TOP,
    "composer": COMPOSER,
    "composer_hints": COMPOSER_HINTS,
    "status": STATUS,
}
