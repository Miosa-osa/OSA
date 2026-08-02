# PTY layout harness

Drives the **real `osagent` binary** on a **real kernel PTY**, resizes it for
real, and asserts that exactly one copy of the live region is on screen
afterwards.

```sh
test/pty/run.sh              # build osagent (release), then run
test/pty/run.sh --no-build   # run against the existing binary
```

Requires `python3` and [`pyte`](https://pypi.org/project/pyte/):

```sh
python3 -m pip install --user pyte
```

No display server is required — a PTY is not a GUI. It also runs in CI, as the
`PTY layout` workflow.

---

## Why this exists

The Rust suite renders through `VT100Backend` (`priv/rust/tui/src/test_backend.rs`),
a perfect in-process terminal emulator. Ratatui's inline viewport re-anchors
itself by asking the terminal where the cursor is — DSR, `ESC[6n` — and against
a perfect emulator that answer is always the correct row. The re-anchor
therefore always lands correctly, and an entire class of defect **cannot
materialise in-process no matter how many tests are written**.

The class it hides is *stranding*: on a resize the viewport re-anchors and
erases only the rect it has just computed, leaving the previous copy of the live
region painted on rows nothing will ever clear. A window drag emits one resize
per intermediate width, so a single drag left **nine stacked composers** on
screen — through roughly a thousand passing tests, none of which could see it.

This harness closes that hole from the outside:

| piece | why |
|---|---|
| `pty.fork` | gives the binary a kernel PTY, so it takes the same code path a terminal does |
| `TIOCSWINSZ` | resizes for real, delivering `SIGWINCH` exactly like a drag |
| `pyte` | renders the resulting byte stream as a screen we can read |
| `ESC[6n` answered from **pyte's** cursor | the emulator answers, not a model that is right by construction |

Then we count composers. One is correct. Nine is the bug.

---

## Known limitation — read this before trusting a green run

**pyte does not reflow on resize. VTE does.**

When a real VTE-backed terminal (GNOME Terminal, Tilix, Terminator — libvte
embedders generally) narrows, it re-wraps existing scrollback, which *moves*
content the TUI believes it knows the position of. pyte instead truncates and
pads columns and leaves rows where they are.

So this harness reproduces the **re-anchor / erase** half of the stranding class
— the half that produced the nine stacked composers — and
**under-reproduces the VTE-specific reflow half.**

A concrete example of what it cannot see: the resize clear in
`app::event_loop` deliberately uses ED0 (`ESC[H` `ESC[J`) rather than ED2
(`ESC[2J`), because VTE implements ED2 by *scrolling the screen into
scrollback* instead of erasing in place — which deposited a full snapshot of the
live region into unreflowable history on every step of a drag. pyte implements
both as a plain erase, so **swapping ED0 back to ED2 would not turn this suite
red.** That defect is guarded by the comment at the call site and by review, not
by this harness.

A green run here is evidence that the band arbiter and the resize settle window
behave. It is **not** proof that a change is safe in GNOME Terminal. Changes
that touch reflow, scrollback commits, or clear semantics still want a human eye
on a real terminal.

Two further scope notes:

- It drives the TUI against `stub_backend.py`, not the Elixir backend. It tests
  **layout**, not agent behaviour.
- It asserts on the composer band and the status bar, not on the arbiter's
  `Bands.hint` row — that row is a right-aligned *notice* slot and renders
  nothing while idle. See the comment on `SINGLETON_BANDS` in `osa_pty.py`.

---

## Files

| file | role |
|---|---|
| `run.sh` | entry point: builds, checks deps, isolates `$HOME`, runs |
| `osa_pty.py` | the PTY session — fork, resize, pump, answer DSR, render, count |
| `stub_backend.py` | the smallest HTTP backend `osagent` will boot against |
| `test_resize.py` | the assertions |

## The tests

- **`test_resize_sweep`** — a width drag (120 → 80 → 120 in 5-column steps, no
  pause between steps) must leave exactly one live region. This is the
  regression the harness was built for.
- **`test_height_resize`** — a vertical drag (40 → 20 → 40 rows). Harsher,
  because height changes what *fits*, so the arbiter sheds and restores bands on
  the way down and back up.
- **`test_small_viewport`** — at 80x10 and squeezed to 80x8, the composer must
  still survive; `fit_bands` must degrade rather than overflow.

## Proving it still works

A test that cannot fail is not a test. To re-verify that this harness genuinely
catches the class, reintroduce the defect and confirm red:

```rust
// priv/rust/tui/src/app/event_loop.rs, in `adopt_frame_size`
- self.resize_dirty = true;
+ // self.resize_dirty = true;
```

Rebuild and run. Expected: `test_resize_sweep` and `test_height_resize` fail
with several stacked copies, e.g.

```
after shortening sweep 40 -> 20: expected exactly one of each live-region band,
got {'composer_top': 8, 'composer': 4, 'composer_hints': 3, 'status': 0}
   1|────────────────────────────────────────────
   2|❯ Ask OSA anything…
   3|─────────────────────  / commands · @ files …
   ...
  10|❯ Ask OSA anything…
   ...
  16|❯ Ask OSA anything…
   ...
  22|❯ 1uk OSA anything…
  23|Error: The cursor position could not be read within a normal duration
```

That is the shipped bug, verbatim — including the failed DSR query bleeding into
the composer's own row. Restore the line and it returns to `3/3 passed`.

## Adding a test

Boot a session, do something to the terminal, call `assert_single_live_region`:

```python
def test_something(backend):
    with PtySession(backend.base_url, cols=100, rows=30) as s:
        s.boot()
        s.write(b"/help\r")     # keystrokes go straight to the PTY
        s.pump(SETTLE * 2)
        assert_single_live_region(s, "after /help")
```

Append it to `TESTS` in `test_resize.py`. Failures print the whole rendered
screen — including scrolled-off history, where stranded chrome usually ends up —
because on this class of bug the screen *is* the evidence.
