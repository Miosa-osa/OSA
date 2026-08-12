#!/usr/bin/env python3
"""The streaming-paint hunt, run INSIDE A REAL TMUX PANE.

WHY THIS EXISTS
===============

`stream_paint_probe.py` recreates the frame that broke (a live, ANSI-coloured
tool cell with a long assistant reply streaming over it) but it runs on a bare
kernel PTY rendered by `pyte`, and `osa_pty.py:116-122` *deliberately strips
`$TMUX`* from the child. The owner runs OSA inside tmux. So the one environment
that matters had never been exercised end to end, and it is not a cosmetic
difference:

  * `$TMUX` is what selects `ResizeClear::Surgical` in `event_loop.rs`
    (`resize_clear_strategy`), i.e. an in-place `FromCursorDown` erase from a
    remembered row instead of a full-screen wipe. Under the wipe, ANY uncleared
    row is wiped anyway and the whole defect class is invisible.
  * tmux is a second screen model between OSA and the terminal, with its own
    reflow, its own history, and its own answer to the DSR cursor query that
    every `rebuild_inline` depends on.

This harness therefore drives the real binary in a real tmux pane, streams the
screenshot's turn into it, and samples `capture-pane` on every frame — plus the
tmux-only gestures no previous probe could make: a pane resize mid-stream, a
window split and unsplit mid-stream, a copy-mode scroll mid-stream, and a second
message submitted mid-turn.

RESULT OF THE HUNT — READ BEFORE TRUSTING A PASS
================================================

The screenshot's corruption (`Build's1greene— 976rmodules,xclean typecheck.` —
single glyphs substituted for spaces at scattered columns) **did not reproduce**
in any of the configurations below, under real tmux, on this Linux box. What was
established instead:

  * **The emission-level invariant holds under tmux.** Over 32-50 KB of the
    bytes `osagent` actually wrote into a real tmux pane (tapped with
    `pipe-pane`), every viewport rebuild landed inside the span erased for it.
    `surgical_clear_top`'s `min` is doing its job; the uncleared-rows gap that
    was the standing hypothesis is closed in this build.

  * **`stream_paint_probe.check_region_bleed` is unsound and is NOT used here.**
    It assumes the first full-width `─` rule on screen is the composer's top
    divider and that transcript vocabulary below it is therefore a bleed. OSA
    renders an intentional full-width TURN SEPARATOR into the transcript between
    turns (`components/chat/message.rs:166`, `new_turn_separator`). Once a
    session has two turns, every ordinary transcript row sits below a rule and
    trips it: it reported 297 "bleeds" on a healthy run here. Anything diagnosed
    from that check is a false positive.

  * **Single-sample corruption is a probe artefact, not a defect.**
    `capture-pane` reads tmux's internal grid at an arbitrary instant, including
    halfway through a frame. OSA wraps every frame in synchronized output
    (`ESC[?2026h/l` — 97 frames in a 50 KB capture), which defers what an
    attached client displays but does NOT stop tmux's grid from being read
    mid-frame. So a torn row seen in one capture was never on anyone's screen.
    Hence `confirm_persistent`: a finding counts only if the identical row is
    still there ~270 ms later. The reported artefact was photographed, so
    persistence is the correct bar. Transients are counted and printed, never
    failed on.

Run:  python3 test/pty/tmux_stream_paint_probe.py [--only NAME] [--frames N]
"""

from __future__ import annotations

import argparse
import json
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import term_env  # noqa: E402
from stream_paint_probe import (  # noqa: E402
    ANCHORS,
    BUILD_OUTPUT,
    LONG_REPLY,
    check_clear_covers_rebuild,
    check_sentinels,
)

PORT = 19241  # NOT 9089 — the owner's real backend lives there.
SOCKET = "osa-stream-paint"
SESSION = "paint"

_HEALTH = {
    "status": "ok",
    "version": "0.0.0-tmux-stream-paint",
    "uptime_seconds": 0,
    "provider": "pty-stub",
    "model": "claude-opus-5",
    "context_window": 200000,
    "effort": "high",
    "billing": None,
    "update": None,
}


# --------------------------------------------------------------------------
# The stub. Same turn shape as stream_paint_probe, but re-armable so each tmux
# configuration gets a fresh streaming turn, and `/api/v1/orchestrate` ALWAYS
# answers with `session_id` — the client requires it, and two earlier probes
# silently measured turns that never started because they omitted it.
# --------------------------------------------------------------------------


class _Bus:
    def __init__(self) -> None:
        self.q: "queue.Queue[tuple[str, dict]]" = queue.Queue()
        self.n = 0

    def send(self, event: str, data: dict) -> None:
        self.q.put((event, data))

    def script(self) -> None:
        self.n += 1
        mid = f"m{self.n}"
        call = f"call-{self.n}"

        def run() -> None:
            time.sleep(0.4)
            self.send(
                "tool_call",
                {
                    "name": "shell_execute",
                    "phase": "start",
                    "args": json.dumps({"command": "tsc -b && vite build"}),
                    "tool_call_id": call,
                },
            )
            for i, line in enumerate(BUILD_OUTPUT[:4]):
                self.send(
                    "command_output_delta",
                    {
                        "command": "tsc -b && vite build",
                        "chunk": line + "\n",
                        "tail": line,
                        "seq": i,
                        "tool_call_id": call,
                    },
                )
                time.sleep(0.08)
            for n, chunk in enumerate(re.findall(r"\S+\s*", LONG_REPLY)):
                self.send(
                    "streaming_token",
                    {"text": chunk, "session_id": "s", "message_id": mid},
                )
                if n in (6, 14):
                    idx = 4 if n == 6 else 5
                    self.send(
                        "command_output_delta",
                        {
                            "command": "tsc -b && vite build",
                            "chunk": BUILD_OUTPUT[idx] + "\n",
                            "tail": BUILD_OUTPUT[idx],
                            "seq": idx,
                            "tool_call_id": call,
                        },
                    )
                time.sleep(0.09)
            self.send(
                "agent_response",
                {
                    "response": LONG_REPLY,
                    "response_type": "text",
                    "signal": None,
                    "message_id": mid,
                },
            )
            time.sleep(0.3)
            self.send(
                "tool_result",
                {
                    "name": "shell_execute",
                    "result": "\n".join(BUILD_OUTPUT),
                    "success": True,
                    "tool_call_id": call,
                },
            )
            self.send(
                "tool_call",
                {
                    "name": "shell_execute",
                    "phase": "end",
                    "duration_ms": 3400,
                    "success": True,
                    "tool_call_id": call,
                },
            )

        threading.Thread(target=run, daemon=True).start()


BUS = _Bus()


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *_a):
        pass

    def _json(self, payload, status: int = 200) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _sse(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            self.wfile.write(b'event: connected\ndata: {"session_id":"s"}\n\n')
            self.wfile.flush()
            while True:
                try:
                    ev, data = BUS.q.get(timeout=1.0)
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    continue
                blob = json.dumps(data).encode()
                self.wfile.write(b"event: " + ev.encode() + b"\ndata: " + blob + b"\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/health":
            return self._json(_HEALTH)
        if path.startswith("/api/v1/stream/"):
            return self._sse()
        if path == "/api/v1/commands":
            return self._json({"commands": []})
        if path == "/api/v1/tools":
            return self._json({"tools": []})
        if path in ("/api/v1/sessions", "/api/v1/sessions/recent"):
            return self._json({"sessions": []})
        if path == "/api/v1/permission-rules":
            return self._json({"rules": []})
        return self._json({})

    def do_POST(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        if path in ("/api/v1/auth/login", "/api/v1/auth/refresh"):
            return self._json({"token": "t", "refresh_token": "r", "expires_in": 3600})
        if path == "/api/v1/sessions":
            return self._json({"session_id": "s", "id": "s"})
        if path == "/api/v1/orchestrate":
            BUS.script()
            # `session_id` is REQUIRED by the client. Without it the turn never
            # starts and the probe measures an idle screen.
            return self._json({"session_id": "s", "status": "accepted"})
        return self._json({})


# --------------------------------------------------------------------------
# tmux driving
# --------------------------------------------------------------------------


def tmux(*args: str, check: bool = True) -> str:
    r = subprocess.run(
        ["tmux", "-L", SOCKET, *args], capture_output=True, text=True
    )
    if check and r.returncode != 0:
        raise RuntimeError(f"tmux {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout


class TmuxSession:
    """OSA in a real tmux pane, on a private tmux server."""

    def __init__(self, binary: Path, cols: int, rows: int, strategy: str | None):
        self.binary = binary
        self.cols = cols
        self.rows = rows
        self.strategy = strategy
        self.pane = ""

    def __enter__(self) -> "TmuxSession":
        tmux("kill-server", check=False)
        extra = {}
        if self.strategy:
            extra["OSA_RESIZE_CLEAR"] = self.strategy
        env = term_env.clean_env(
            **term_env.backend_vars(f"http://127.0.0.1:{PORT}"), **extra
        )
        subprocess.run(
            [
                "tmux", "-L", SOCKET, "new-session", "-d", "-s", SESSION,
                "-x", str(self.cols), "-y", str(self.rows), str(self.binary),
            ],
            env=env,
            check=True,
            capture_output=True,
        )
        self.pane = tmux(
            "list-panes", "-t", SESSION, "-F", "#{pane_id}"
        ).strip().splitlines()[0]
        # Tap the pane's OUTPUT — the exact bytes osagent writes while running
        # under tmux. The rendering is timing-dependent; the emission is not, so
        # the uncleared-rows invariant can be checked deterministically.
        self.tap = Path(f"/tmp/osa-tmux-tap-{self.pane.strip('%')}.bin")
        self.tap.unlink(missing_ok=True)
        tmux("pipe-pane", "-t", self.pane, "-o", f"cat >> {self.tap}", check=False)
        return self

    def emitted(self) -> bytes:
        try:
            return self.tap.read_bytes()
        except OSError:
            return b""

    def geometry(self) -> tuple[int, int]:
        out = tmux(
            "display-message", "-p", "-t", self.pane, "#{pane_width} #{pane_height}"
        ).split()
        return (int(out[0]), int(out[1])) if len(out) == 2 else (0, 0)

    def __exit__(self, *_exc) -> None:
        tmux("pipe-pane", "-t", self.pane, check=False)
        tmux("kill-server", check=False)

    # -- observing ---------------------------------------------------------

    def screen(self) -> list[str]:
        """The VISIBLE pane, as tmux itself believes it to be."""
        out = tmux("capture-pane", "-p", "-t", self.pane)
        return [line.rstrip() for line in out.split("\n")]

    def history(self) -> list[str]:
        out = tmux("capture-pane", "-p", "-t", self.pane, "-S", "-3000")
        return [line.rstrip() for line in out.split("\n")]

    def booted(self) -> bool:
        return any("❯" in line for line in self.screen())

    def boot(self, timeout: float = 25.0) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.booted():
                time.sleep(1.0)
                return
            time.sleep(0.4)
        raise AssertionError(
            "osagent never reached a composer inside tmux. Pane:\n"
            + "\n".join(self.screen())
        )

    # -- driving -----------------------------------------------------------

    def submit(self, text: str) -> None:
        tmux("send-keys", "-t", self.pane, "-l", text)
        time.sleep(0.4)
        tmux("send-keys", "-t", self.pane, "Enter")

    def resize(self, cols: int, rows: int) -> None:
        tmux("resize-window", "-t", SESSION, "-x", str(cols), "-y", str(rows))
        self.cols, self.rows = cols, rows

    def split(self) -> str:
        """Split the window — the OSA pane shrinks *without a window resize*.

        This is a gesture no PTY harness can make: the pane's height changes
        while the outer terminal's does not.
        """
        out = tmux(
            "split-window", "-t", self.pane, "-P", "-F", "#{pane_id}", "-d"
        ).strip()
        return out

    def kill(self, pane: str) -> None:
        tmux("kill-pane", "-t", pane, check=False)

    def scroll(self, lines: int = 3) -> None:
        tmux("copy-mode", "-t", self.pane, check=False)
        for _ in range(lines):
            tmux("send-keys", "-t", self.pane, "-X", "scroll-up", check=False)

    def unscroll(self) -> None:
        tmux("send-keys", "-t", self.pane, "-X", "cancel", check=False)


# --------------------------------------------------------------------------
# Checks — reused from the non-tmux probe, plus a tmux-history variant.
# --------------------------------------------------------------------------

DIVIDER = re.compile(r"^─{20,}$")


HINTS = "/ commands · @ files"
STATUS = re.compile(r"%\s*ctx")


def check_duplicate_bands(rows: list[str], label: str) -> list[str]:
    """Exactly one live region may be on screen.

    The composer's hint divider and the status bar are drawn once per live
    region and by nothing else, so two of either is a stranded copy — the
    unambiguous signature of an erase that did not reach the old chrome. This
    is deliberately not a heuristic: it needs no guess about which row "should"
    be prose.
    """
    bad = []
    n_hints = sum(1 for r in rows if HINTS in r)
    n_status = sum(1 for r in rows if STATUS.search(r))
    if n_hints > 1:
        bad.append(f"{label}: {n_hints} composer hint rows on screen (expected 1)")
    if n_status > 1:
        bad.append(f"{label}: {n_status} status bars on screen (expected 1)")
    return bad


def check_frame(rows: list[str], label: str) -> list[str]:
    """The two checks that cannot be argued with.

    `stream_paint_probe.check_region_bleed` is deliberately NOT used here. It
    anchors on "the first full-width `─` rule is the composer's top divider,
    so anything below it is chrome", and that premise is false: OSA renders an
    intentional full-width turn separator INTO the transcript between turns
    (`components/chat/message.rs:166` `new_turn_separator` — "an understated dim
    horizontal rule drawn between turns"). Every transcript row below the first
    separator therefore trips it. Run with it enabled, a healthy multi-turn
    session reports hundreds of "bleeds" that are simply the conversation.
    """
    return check_sentinels(rows, label) + check_duplicate_bands(rows, label)


def check_history_sentinels(rows: list[str], label: str) -> list[str]:
    """The same corruption gate, over tmux's pane HISTORY.

    A row can be corrupted, scroll into history and be replaced on screen
    before the next sample. tmux history is unreflowable and permanent, so it
    is the one place the evidence cannot evaporate.
    """
    return check_sentinels(rows, label)


def _quoted_row(finding: str) -> str:
    """The row text a finding quotes, so the same row can be re-identified."""
    i = finding.rfind(": ")
    return finding[i + 2 :] if i >= 0 else finding


def confirm_persistent(
    s: "TmuxSession", found: list[str], label: str, tries: int = 3, gap: float = 0.09
) -> list[str]:
    """Keep only findings whose exact row is STILL there several samples later.

    `capture-pane` reads tmux's screen at an arbitrary instant, so a frame
    sampled while tmux is halfway through applying a repaint looks precisely
    like overpaint. Every TUI produces those, they are not this defect, and
    mistaking one for the defect is how this gets misdiagnosed.

    The reported artefact was PHOTOGRAPHED — it sat on screen. So the gate is
    persistence: the identical corrupted row must survive `tries` further
    captures. A row still being streamed changes between captures and drops
    out; a row nothing will ever repaint does not.
    """
    survivors = {_quoted_row(f): f for f in found}
    for _ in range(tries):
        if not survivors:
            return []
        time.sleep(gap)
        try:
            again = s.screen()
        except RuntimeError:
            return []
        rows_now = set(again)
        still = check_frame(again, label)
        quoted_now = {_quoted_row(f) for f in still}
        survivors = {
            k: v
            for k, v in survivors.items()
            # The row is still corrupted AND is still literally the same row.
            if k in quoted_now or any(k.strip("'\"") == r for r in rows_now)
        }
    return list(survivors.values())


def dump(rows: list[str], label: str) -> None:
    print(f"\n{'=' * 78}\n{label}\n{'=' * 78}")
    for y, row in enumerate(rows):
        print(f"{y:>3} |{row}")


# --------------------------------------------------------------------------
# The configurations
# --------------------------------------------------------------------------


def run_config(
    name: str,
    binary: Path,
    cols: int,
    rows: int,
    gesture,
    frames: int = 70,
    strategy: str | None = None,
    verbose: bool = False,
) -> list[str]:
    print(f"\n### {name}  ({cols}x{rows}, strategy={strategy or 'auto/tmux'})")
    failures: list[str] = []
    worst: list[str] | None = None
    # LIVENESS. A probe that never started a turn asserts nothing and passes.
    # Two earlier probes did exactly that. `saw_reply` requires the streamed
    # prose on screen; `saw_tool` requires the coloured tool cell above it.
    # Both must be true or the configuration is reported as a FAILURE, not a
    # pass.
    saw_reply = False
    saw_tool = False
    prev: list[str] | None = None
    n_transient = [0]
    with TmuxSession(binary, cols, rows, strategy) as s:
        s.boot()
        s.submit("verify the build")
        for frame in range(frames):
            time.sleep(0.06)
            try:
                gesture(s, frame)
            except RuntimeError as e:
                print(f"  (gesture at frame {frame} failed: {e})")
            try:
                scr = s.screen()
            except RuntimeError:
                break
            if verbose:
                dump(scr, f"{name} FRAME {frame}")
            blob = "\n".join(scr)
            saw_reply = saw_reply or any(a in blob for a in ANCHORS)
            saw_tool = saw_tool or ("modules transformed" in blob or "vite" in blob)
            found = check_frame(scr, f"{name} frame {frame}")
            if found:
                transient = list(found)
                found = confirm_persistent(s, found, f"{name} frame {frame}")
                if found and worst is None:
                    worst = scr
                    if prev is not None:
                        dump(prev, f"{name}: FRAME BEFORE THE CORRUPTION")
                    print(f"  geometry at corruption: {s.geometry()}")
                for f in transient:
                    if f not in found:
                        n_transient[0] += 1
                        print(f"  (transient, not persistent) {f}")
            failures += found
            prev = scr
        time.sleep(2.5)
        end = s.screen()
        failures += check_frame(end, f"{name} settled")
        hist = s.history()
        failures += check_history_sentinels(hist, f"{name} history")
        blob = "\n".join(hist)
        saw_reply = saw_reply or any(a in blob for a in ANCHORS)
        saw_tool = saw_tool or ("modules transformed" in blob or "vite" in blob)
        if not saw_reply:
            failures.append(f"{name}: LIVENESS — the streamed reply never appeared")
        if not saw_tool:
            failures.append(f"{name}: LIVENESS — the tool cell never appeared")
        # The deterministic gate: over every byte osagent wrote INSIDE tmux,
        # every viewport rebuild must land inside the span that was erased for
        # it. Independent of whether stale glyphs happened to be visible.
        raw = s.emitted()
        print(f"  ({len(raw)} bytes tapped from the pane)")
        emission = check_clear_covers_rebuild(raw, f"{name} emission")
        failures += emission
        if failures:
            dump(worst or end, f"{name}: FIRST CORRUPTED FRAME")
            print(f"\n--- {name}: pane history ---")
            print("\n".join(hist))
        elif verbose:
            dump(end, f"{name} SETTLED")
    print(
        f"  {'FAIL' if failures else 'ok'}  {name} — {len(failures)} persistent, "
        f"{n_transient[0]} transient (single-sample, not on screen 270ms later)"
    )
    return failures


# -- gestures ---------------------------------------------------------------


def g_none(s: TmuxSession, frame: int) -> None:
    pass


def g_resize(s: TmuxSession, frame: int) -> None:
    """Width around the owner's 93-100, plus height, mid-stream."""
    if 4 <= frame <= 30:
        w = [100, 97, 93, 96, 100, 94][frame % 6]
        h = 30 if frame % 4 else 27
        s.resize(w, h)


def g_split(s: TmuxSession, frame: int) -> None:
    """Split and unsplit the window mid-stream — pane height changes with no
    window resize, so tmux repaints the pane at a new origin."""
    if frame == 8:
        s._other = s.split()
    if frame == 16 and getattr(s, "_other", None):
        s.kill(s._other)
        s._other = None
    if frame == 24:
        s._other = s.split()
    if frame == 32 and getattr(s, "_other", None):
        s.kill(s._other)
        s._other = None


def g_scroll(s: TmuxSession, frame: int) -> None:
    """Scroll the pane while it is streaming, then come back."""
    if frame in (10, 22, 34):
        s.scroll(4)
    if frame in (14, 26, 38):
        s.unscroll()


def g_second_message(s: TmuxSession, frame: int) -> None:
    """Submit a second message while the first turn is still streaming."""
    if frame == 12:
        s.submit("and the bundle size")
    if frame == 40:
        s.submit("verify the build")


def g_everything(s: TmuxSession, frame: int) -> None:
    g_resize(s, frame)
    g_split(s, frame)
    if frame in (18, 36):
        s.scroll(3)
    if frame in (21, 39):
        s.unscroll()
    if frame == 28:
        s.submit("and the bundle size")


def g_height_only(s: TmuxSession, frame: int) -> None:
    """HEIGHT only, width untouched — the case `resize_clear_strategy`'s comment
    says is safe under tmux because "tmux does not reflow"."""
    if 4 <= frame <= 40 and frame % 3 == 0:
        s.resize(100, 30 if (frame // 3) % 2 else 24)


def g_width_only(s: TmuxSession, frame: int) -> None:
    if 4 <= frame <= 40 and frame % 3 == 0:
        s.resize(100 if (frame // 3) % 2 else 93, 30)


def g_split_repeat(s: TmuxSession, frame: int) -> None:
    if 4 <= frame <= 50 and frame % 6 == 0:
        if getattr(s, "_other", None):
            s.kill(s._other)
            s._other = None
        else:
            s._other = s.split()


def g_halve_when_tall(s: TmuxSession, frame: int) -> None:
    """HALVE the pane's height at the moment the live region is TALLEST.

    The derived failure condition is `h_new < h_old`: tmux moves existing
    content UP by `old_rows - new_rows` on a height shrink, while OSA anchors
    its surgical clear at a `last_inline_top` recorded in the OLD screen's
    coordinates. The erase therefore starts `h_old - h_new` rows BELOW the old
    chrome, and those rows are never erased.

    A pane split halves the height in one step, which forces the tall streaming
    region (reply preview + live tool feed + spinner) to clamp — that is
    `h_new < h_old`, on purpose.
    """
    if frame in (22, 34, 46):
        if not getattr(s, "_other", None):
            s._other = s.split()
    if frame in (28, 40, 52):
        if getattr(s, "_other", None):
            s.kill(s._other)
            s._other = None


def g_shrink_below_region(s: TmuxSession, frame: int) -> None:
    """Shrink the pane BELOW the live region's height, then restore it.

    tmux implements a pane height shrink by pushing the top rows of the screen
    into the pane's HISTORY. If the live region is taller than the pane becomes,
    the rows pushed away are CHROME rows — and pane history is the one surface
    no erase OSA can emit will ever reach. Growing the pane again pulls them
    straight back onto the screen, underneath the current region.

    Starting from a short pane makes the region most of the screen, so a split
    is guaranteed to cross that threshold.
    """
    if frame in (18, 30, 42):
        if not getattr(s, "_other", None):
            s._other = s.split()
    if frame in (24, 36, 48):
        if getattr(s, "_other", None):
            s.kill(s._other)
            s._other = None


def _ablate(drop: str):
    """`g_everything` with one ingredient removed, to isolate what is necessary."""

    def g(s: TmuxSession, frame: int) -> None:
        if drop != "resize":
            g_resize(s, frame)
        if drop != "split":
            g_split(s, frame)
        if drop != "scroll":
            if frame in (18, 36):
                s.scroll(3)
            if frame in (21, 39):
                s.unscroll()
        if drop != "message":
            if frame == 28:
                s.submit("and the bundle size")

    return g


GESTURES = {
    "no-resize": (100, 30, _ablate("resize")),
    "no-split": (100, 30, _ablate("split")),
    "no-scroll": (100, 30, _ablate("scroll")),
    "no-message": (100, 30, _ablate("message")),
    "shrink-below-region": (100, 16, g_shrink_below_region),
    "shrink-below-region-93": (93, 18, g_shrink_below_region),
    "pane-halve": (100, 30, g_halve_when_tall),
    "height-only": (100, 30, g_height_only),
    "width-only": (100, 30, g_width_only),
    "split-repeat": (100, 30, g_split_repeat),
    "plain-100": (100, 30, g_none),
    "plain-93": (93, 30, g_none),
    "resize-100": (100, 30, g_resize),
    "resize-93": (93, 28, g_resize),
    "split": (100, 30, g_split),
    "scroll": (100, 30, g_scroll),
    "second-message": (100, 30, g_second_message),
    "short-100": (100, 21, g_resize),
    "everything": (100, 30, g_everything),
    "everything-93": (93, 24, g_everything),
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=None)
    ap.add_argument("--only", default=None, help="comma-separated config names")
    ap.add_argument("--frames", type=int, default=70)
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument(
        "--strategy",
        default=None,
        help="force OSA_RESIZE_CLEAR (surgical|full). Default: let tmux decide.",
    )
    args = ap.parse_args()

    if not shutil.which("tmux"):
        print("SKIPPED: tmux not installed")
        return 0
    repo = Path(__file__).resolve().parents[2]
    binary = (
        Path(args.binary)
        if args.binary
        else repo / "priv/rust/tui/target/release/osagent"
    )
    if not binary.exists():
        print(f"SKIPPED: {binary} not built")
        return 0

    srv = ThreadingHTTPServer(("127.0.0.1", PORT), _Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    names = args.only.split(",") if args.only else list(GESTURES)
    failures: list[str] = []
    try:
        for name in names:
            cols, rows, gesture = GESTURES[name]
            failures += run_config(
                name,
                binary,
                cols,
                rows,
                gesture,
                frames=args.frames,
                strategy=args.strategy,
                verbose=args.verbose,
            )
    finally:
        tmux("kill-server", check=False)
        srv.shutdown()

    print(f"\n{'=' * 78}\nVERDICT\n{'=' * 78}")
    if failures:
        seen = set()
        for f in failures:
            key = f.split(":", 1)[1]
            if key in seen:
                continue
            seen.add(key)
            print(f"  FAIL  {f}")
        return 1
    print(f"  PASS  {len(names)} tmux configurations, no corrupted row")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
