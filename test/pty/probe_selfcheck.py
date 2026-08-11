#!/usr/bin/env python3
"""Prove the probes in `duplicate_probe.py` actually reach the states they name.

A probe that silently no-ops passes, and a passing probe that never opened the
popup / never grew the composer / never entered the alternate screen is evidence
of nothing. This dumps the screen and the emitted byte stream at each step so
the state transition itself is visible rather than assumed.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from duplicate_probe import PreludeSession, counts  # noqa: E402
from osa_pty import SETTLE  # noqa: E402
from stub_backend import StubBackend  # noqa: E402

STUB_PORT = 12794


def show(s, label: str, tail: int = 22) -> None:
    print(f"\n--- {label} --- counts={counts(s)}")
    for line in s.dump().splitlines()[-tail:]:
        print("   " + line)


def main() -> int:
    with StubBackend(STUB_PORT) as backend:
        with PreludeSession(backend.base_url, cols=120, rows=40) as s:
            s.boot()
            s.pump(SETTLE * 2)
            show(s, "booted")

            m = s.mark()
            s.write(b"/")
            s.pump(0.6)
            show(s, "after typing '/' (popup should be open)")
            print(f"   bytes emitted since '/': {len(s.emitted_since(m))}")

            s.write(b"\x7f")
            s.pump(0.6)
            show(s, "after backspace (popup should be closed)")

            m = s.mark()
            for _ in range(4):
                s.write(b"filler")
                s.write(b"\x1b\r")
                s.pump(0.3)
            s.pump(SETTLE)
            show(s, "after 4 Alt+Enter newlines (composer should be TALLER)")
            print(f"   bytes emitted while growing: {len(s.emitted_since(m))}")

            for _ in range(80):
                s.write(b"\x7f")
            s.pump(SETTLE * 2)
            show(s, "after erasing it all (composer should be back to 1 line)")

            m = s.mark()
            s.write(b"/help")
            s.pump(0.6)
            s.write(b"\r")
            s.pump(0.6)
            s.write(b"\r")
            s.pump(SETTLE * 2)
            raw = s.emitted_since(m)
            print(
                f"\n--- after /help --- alt_screen_enter={raw.count(b'\\x1b[?1049h')} "
                f"alt_screen_leave={raw.count(b'\\x1b[?1049l')} in_alt={s.in_alt_screen()}"
            )
            show(s, "with /help open")

            for _ in range(3):
                s.write(b"\x1b")
                s.pump(0.5)
            s.pump(SETTLE * 2)
            show(s, "after Esc out of /help")

            m = s.mark()
            s.write(b"\x0c")
            s.pump(0.6)
            print(f"\n--- Ctrl+L emitted {len(s.emitted_since(m))} bytes ---")

            m = s.mark()
            s.write(b"/clear")
            s.pump(0.6)
            s.write(b"\r")
            s.pump(0.6)
            s.write(b"\r")
            s.pump(SETTLE * 2)
            raw = s.emitted_since(m)
            print(
                f"\n--- /clear: ED3(purge)={raw.count(b'\\x1b[3J')} "
                f"ED0={raw.count(b'\\x1b[J')} ED2={raw.count(b'\\x1b[2J')} ---"
            )
            show(s, "after /clear")
    return 0


if __name__ == "__main__":
    sys.exit(main())
