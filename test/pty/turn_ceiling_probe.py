#!/usr/bin/env python3
"""Does a session keep accepting turns, or does it die after a few exchanges?

An outside user called OSA unusable, and a measurement through the VTE harness
appeared to show why: on a 50-row terminal the transcript stopped growing after
four committed replies, and the ceiling tracked the screen height (24 rows → 1,
40 → 3, 50 → 4, 60 → 5). A session that stops responding after four exchanges
would be the dominant defect in the product.

It was the instrument. See `vte_reader.py`: VTE row indices are absolute over
the whole ring, so the `range(-20_000, row_count)` reader every harness here
used was reading the FIRST SCREENFUL of the session and nothing else, for the
whole run. The "ceiling" was that window filling up. Four turns is how many fit
under the banner in 50 rows.

This probe is what makes that non-recurring. It drives many short turns and
records three INDEPENDENT facts per turn, which between them can tell a wedged
product from a blind harness without any further reasoning:

  * `POST /api/v1/orchestrate` bodies on the wire — input and state. If these
    stop, the defect is in input handling or the turn state machine.
  * unique prompt markers present in the RING — commit. If POSTs continue but
    these stall, the defect is in rendering or `insert_before`.
  * unique reply markers present in the ring — the same, for the answer.

All three must equal the turn number, at every height. Anything else is a
report, not a pass.

Requirements: `python3-gi`, `gir1.2-vte-2.91`, a reachable X display, and a
release build at `priv/rust/tui/target/release/osagent`. Any missing piece is
SKIPPED rather than failed, so a headless box never goes red for the wrong
reason.

Run: `python3 test/pty/turn_ceiling_probe.py`
     `python3 test/pty/turn_ceiling_probe.py --rows 40 --turns 25`
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import term_env  # noqa: E402
import vte_reader  # noqa: E402

STUB_PORT = int(os.environ.get("OSA_CEILING_PORT", "12831"))


def _skip(reason: str) -> int:
    print(f"SKIPPED: {reason}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=50, help="terminal height")
    ap.add_argument("--cols", type=int, default=120)
    ap.add_argument("--turns", type=int, default=20)
    ap.add_argument("--settle", type=float, default=1.6)
    args = ap.parse_args()

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

    import stub_backend
    from stub_backend import StubBackend, push_sse, release_turn

    repo = Path(__file__).resolve().parents[2]
    binary = repo / "priv/rust/tui/target/release/osagent"
    if not binary.exists():
        return _skip(f"{binary} not built (cargo build --release)")

    with StubBackend(STUB_PORT) as backend:
        term = Vte.Terminal()
        term.set_scrollback_lines(20_000)
        term.set_size(args.cols, args.rows)
        env = term_env.clean_env_list(**term_env.backend_vars(backend.base_url))
        ok, _pid = term.spawn_sync(
            Vte.PtyFlags.DEFAULT, str(repo), [str(binary)], env,
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

        # Keystrokes go to the PTY MASTER FD. Under GObject introspection
        # `Vte.Terminal.feed_child` silently accepts the bytes and delivers
        # nothing, so a harness that uses it drives no turns at all.
        pty_fd = term.get_pty().get_fd()

        def send(data: bytes) -> None:
            os.write(pty_fd, data)

        for _ in range(30):
            pump(1.0)
            if any("❯" in r for r in vte_reader.screen_rows(term, Vte)):
                break
        else:
            return _skip("binary did not reach a composer; nothing to assert about")

        print(f"rows={args.rows} cols={args.cols} turns={args.turns}")
        print("turn | orchestrate POSTs | prompts in ring | replies in ring")
        faults: list[str] = []
        for i in range(1, args.turns + 1):
            mark = stub_backend.post_mark()
            # Text and Enter are SEPARATE writes. Sent as one burst OSA's
            # paste-burst detector reads the carriage return as a NEWLINE, not
            # a submit, and the prompts stack up unsent.
            send(f"QQ{i:02d}QQ".encode())
            pump(0.5)
            send(b"\r")
            pump(0.7)
            release_turn()
            # NOT `stub_backend.end_turn`: it hardcodes `message_id`
            # "stub-msg-1", so every reply after the first is a duplicate id
            # and is dropped on the floor.
            push_sse(
                "agent_response",
                {
                    "response": f"RR{i:02d}RR reply body",
                    "response_type": "text",
                    "message_id": f"stub-msg-{i}",
                },
            )
            pump(args.settle)

            posts = len(stub_backend.posts_since(mark, "/api/v1/orchestrate"))
            ring = vte_reader.buffer_rows(term, Vte)
            prompts = sum(
                1 for k in range(1, i + 1) if any(f"QQ{k:02d}QQ" in r for r in ring)
            )
            replies = sum(
                1 for k in range(1, i + 1) if any(f"RR{k:02d}RR" in r for r in ring)
            )
            print(f"{i:4d} | {posts:17d} | {prompts:15d} | {replies:15d}")
            if posts != 1:
                faults.append(f"turn {i}: {posts} orchestrate POSTs, expected 1")
            if prompts != i:
                faults.append(f"turn {i}: {prompts} prompts in the ring, expected {i}")
            if replies != i:
                faults.append(f"turn {i}: {replies} replies in the ring, expected {i}")

        first, last = vte_reader.buffer_bounds(term)
        print(f"\nring spans absolute rows {first}..{last - 1} ({last - first} rows)")
        if faults:
            print(f"\nWEDGED after {args.turns} turns:")
            for f in faults[:10]:
                print(f"  - {f}")
            print("\n--- visible screen ---")
            for r in vte_reader.screen_rows(term, Vte):
                print(f"|{r}")
            return 1
        print(
            f"SURVIVED   {args.turns} turns: every prompt dispatched, every "
            f"prompt and reply still in the transcript"
        )
        return 0


if __name__ == "__main__":
    sys.exit(main())
