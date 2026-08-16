#!/usr/bin/env python3
"""Step-resolved version of `vte_live_probe.py`'s failing case.

`vte_live_probe.py` shows that a width drag strands copies once a real
transcript exists, on the DEFAULT branch, on the same terminal the existing
`vte_resize.py` calls clean. This narrows that result down:

  * counts after EVERY drag step, so "bounded" and "one per step" are
    distinguishable rather than inferred from a final total;
  * separates TRANSCRIPT PRESENT from TURN IN FLIGHT. The stub never answers,
    so a submitted prompt leaves OSA in `Processing` forever unless it is
    interrupted. Those are two different states and only one of them may
    matter.

Run: `python3 test/pty/vte_step_probe.py`
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import scrollback_prelude  # noqa: E402
import term_env  # noqa: E402
import vte_reader  # noqa: E402

STUB_PORT = 12796
MARKER = "❯"


def _skip(reason: str) -> int:
    print(f"SKIPPED: {reason}")
    return 0


def run_case(Vte, GLib, repo, binary, backend, name, interrupt_turn, submit_first):
    """One fresh session, one drag, counts after every step."""
    print(f"\n=== case: {name} ===")
    term = Vte.Terminal()
    term.set_scrollback_lines(20_000)
    term.set_size(120, 50)
    env = term_env.clean_env_list(
        OSA_URL=backend.base_url,
        OSA_PORT=str(STUB_PORT),
        HOME=os.environ.get("OSA_PTY_HOME", os.environ.get("HOME", "/tmp")),
        **term_env.passthrough_override(),
    )
    argv = scrollback_prelude.wrap_command(str(binary), lines=12)
    ok, _pid = term.spawn_sync(
        Vte.PtyFlags.DEFAULT, str(repo), argv, env, GLib.SpawnFlags.DEFAULT, None, None, None
    )
    if not ok:
        print("  SKIPPED: spawn failed")
        return None

    def pump(seconds):
        deadline = GLib.get_monotonic_time() + int(seconds * 1_000_000)
        ctx = GLib.MainContext.default()
        while GLib.get_monotonic_time() < deadline:
            while ctx.pending():
                ctx.iteration(False)
            GLib.usleep(5_000)

    def text():
        # Whole ring. NOT `-20_000 .. row_count` — VTE row indices are absolute
        # over the ring, so that range pins the reader to the first screenful of
        # the session for the whole run. See `vte_reader`.
        return "\n".join(vte_reader.buffer_rows(term, Vte))

    def visible_only():
        # The visible screen is the LAST `page_size` rows of the ring, not rows
        # `0 .. row_count`. Those are the first screenful, which stops being the
        # visible screen the moment anything scrolls.
        return "\n".join(vte_reader.screen_rows(term, Vte))

    for _ in range(30):
        pump(1.5)
        if MARKER in text():
            break
    else:
        print("  SKIPPED: never reached a composer")
        return None
    pump(2.0)

    if submit_first:
        term.feed_child(
            (
                "probe message padding words that make this line wrap at "
                "any width under test padding padding padding\r"
            ).encode()
        )
        pump(2.0)
        if interrupt_turn:
            # Esc interrupts the turn, so the drag happens with a transcript
            # but with NO turn in flight.
            term.feed_child(b"\x1b")
            pump(2.0)

    print(f"  start: total={text().count(MARKER)} visible={visible_only().count(MARKER)}")
    for cols in (115, 110, 105, 100, 95, 90, 95, 100, 105, 110, 115, 120):
        term.set_size(cols, 50)
        pump(0.4)
        print(
            f"    w={cols:3d}  total={text().count(MARKER):2d}  "
            f"visible={visible_only().count(MARKER):2d}"
        )
    pump(3.0)
    total = text().count(MARKER)
    print(f"  settled: total={total} visible={visible_only().count(MARKER)}")
    return total


def main() -> int:
    if not os.environ.get("DISPLAY"):
        return _skip("no DISPLAY")
    try:
        import gi

        gi.require_version("Gtk", "3.0")
        gi.require_version("Vte", "2.91")
        from gi.repository import GLib, Gtk, Vte
    except (ImportError, ValueError) as e:
        return _skip(f"gi/vte unavailable ({e})")
    if not Gtk.init_check(None)[0]:
        return _skip("no usable display")

    from stub_backend import StubBackend  # noqa: E402

    repo = Path(__file__).resolve().parents[2]
    binary = repo / "priv/rust/tui/target/release/osagent"
    if not binary.exists():
        return _skip(f"{binary} not built")

    results = {}
    with StubBackend(STUB_PORT) as backend:
        for name, interrupt, submit in (
            ("idle, no transcript (matches vte_resize.py)", False, False),
            ("transcript committed, turn INTERRUPTED (idle)", True, True),
            ("transcript committed, turn STILL IN FLIGHT", False, True),
        ):
            results[name] = run_case(
                Vte, GLib, repo, binary, backend, name, interrupt, submit
            )

    print("\n=== summary (copies of the composer glyph after the drag) ===")
    for k, v in results.items():
        print(f"  {v}  {k}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
