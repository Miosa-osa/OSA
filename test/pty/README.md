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

## The terminal matrix, and what each harness can prove

`test_resize.py` (pyte) is the always-runnable half, and its limitation bounds
what a green run means: **pyte does not reflow on a width change.** Real
terminals do, so the whole class of "chrome stranded by a reflow" is invisible
to it. The other harnesses exist to cover what it cannot see.

| harness              | terminal    | reads the screen via      | can it fail on stranded chrome? |
|----------------------|-------------|---------------------------|---------------------------------|
| `test_resize.py`     | pyte model  | pyte                      | no — pyte never reflows         |
| `tmux_resize.py`     | tmux 3.4    | `capture-pane -S`         | yes                             |
| `vte_resize.py`      | libvte 7600 | `get_text_range_format`   | yes                             |
| `wezterm_resize.py`  | WezTerm     | `wezterm cli get-text`    | yes                             |
| `ghostty_resize.py`  | Ghostty 1.2 | **nothing — no API**      | **no** — see below              |
| `reflow_matrix.py`   | all of them | DSR cursor query only     | n/a — measures reflow itself    |

### Two things every emulator harness needs

Both were missing, and both made these tests pass while the bug shipped.

1. **Strip the outer terminal's identity** (`term_env.py`). OSA picks its resize
   branch from `$TMUX` / `$TERM`. This repo is developed inside tmux, and
   `vte_resize.py` used to inherit `os.environ` verbatim — so `$TMUX` was set in
   the child and every "OSA survives a drag on real VTE" run was in fact
   exercising the multiplexer branch. The VTE harness had never tested the path
   it existed to test.

2. **Put wrapped content above the live region** (`scrollback_prelude.py`). With
   an empty transcript nothing shortens when the terminal widens, the live
   region never moves, the remembered top row is trivially correct, and the
   assertion cannot fail whichever branch it took. Measured: WezTerm passes
   **both** branches with no prelude, and separates them cleanly with one.

### Ghostty

Ghostty has no CLI, control socket or escape sequence that reports screen or
scrollback contents, so the band count cannot be asserted there at all.
`ghostty_resize.py` therefore asserts only that OSA *survives* the drag (the
historical "cursor position could not be read" crash), and says so in its own
output rather than implying more. Ghostty's reflow behaviour is measured
separately by `reflow_matrix.py`, which needs no text extraction because the
probe reports on itself through a DSR cursor query.

### Reflow is measured, not assumed

`reflow_matrix.py` drives `reflow_probe.py` inside each terminal and asks a
single question: after a widen, did an already-wrapped line re-join? Measured on
this box — **tmux 3.4, libvte 7600, WezTerm 20240203 and Ghostty 1.2.3 all
reflow.** That refutes the comment this code carried for several releases
("tmux and screen do NOT reflow on a width change"); tmux has reflowed since 2.5.

It also rules out the tempting fix. If reflow were the property that decided the
resize branch, a runtime reflow probe would be the correct gate — right even on
a terminal nobody has tested. It is not that property: everything measurable
reflows, yet tmux needs the surgical clear and WezTerm needs the full wipe. See
`resize_clear_strategy` in `event_loop.rs` for the table and the argument.

`reflow_probe.py --self-test` runs with no display and no real terminal: it
drives the probe against two synthetic emulators with known answers, one
reflowing and one not, so a SKIPPED terminal can never hide a probe whose
mechanics have rotted.

### Forcing a branch

Every emulator harness forwards `$OSA_RESIZE_CLEAR` to the child, so either
branch can be forced on any terminal:

```bash
OSA_RESIZE_CLEAR=surgical python3 test/pty/wezterm_resize.py   # fails
OSA_RESIZE_CLEAR=full     python3 test/pty/tmux_resize.py      # fails
```

A gate that is only ever exercised in its default configuration is a gate whose
table nobody has checked.
