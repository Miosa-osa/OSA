# TUI primitives — diagnosis and plan

**Status:** diagnosis + plan only. No product code changed by this pass.
**Date:** 2026-08-12. **Tree:** `96c30705` (v1.0.82) plus uncommitted work.

**Two files are in flight right now** — another agent is implementing the `draw_live`
fix in `priv/rust/tui/src/components/chat/mod.rs` and
`priv/rust/tui/src/render/markdown_stream.rs`. Everything below was read against the
working tree as of this pass, and the `draw_live` slice fix is *already present* in it
(`components/chat/mod.rs:658-698`). Item 2 of the ranked list touches
`markdown_stream.rs` and must be sequenced after that lane lands.

---

## 0. What was actually done, and how much

**References read** (paths confirmed):
`~/projects/research/grok-build-src/crates/codegen/{xai-grok-pager, xai-grok-pager-render, xai-grok-pager-pty-harness, xai-grok-pager-minimal}` and
`~/projects/research/codex-src/codex-rs/tui`.

**Test-name corpus swept.** The prior pass covered ~2,600 of ~9,700 names. This pass
extracted names programmatically across all four grok crates and the Codex TUI crate:

| corpus | `#[test]` fns found | names extracted | keyword-filtered + read |
|---|---|---|---|
| `xai-grok-pager` | 8,726 | 8,629 unique | 804 matched layout/height/scroll/anchor/resize/truncate/overflow/wrap; ~70 read verbatim |
| `xai-grok-pager-render` | 1,065 | 1,050 unique | 57 matched width/wrap/osc8/cache/glyph; all read |
| `xai-grok-pager-pty-harness` | 98 | 98 | all read |
| `xai-grok-pager/src/app/event_loop.rs` | 82 | 82 | all read |
| `codex-rs/tui` | ~3,450 | ~3,438 | ~45 read verbatim |
| **total** | **~13,400** | **~13,300** | |

For comparison, OSA's TUI crate has **1,230 unique test names**
(`priv/rust/tui/src` sweep).

Files the prior pass never opened and this one did: `app/app_view.rs` (12,347),
`views/dashboard/{state,render}.rs` (~20k), `scrollback/state/layout.rs` (4,215),
`scrollback/render.rs` (4,512), `render/osc8.rs` (1,829), `render/wrapping.rs` (1,559),
`scrollback/entry.rs`, `views/prompt_widget/`, plus the whole pty-harness crate.

Not covered: `prompt_images.rs` (4,808) — it is image-protocol plumbing (Kitty/iTerm
graphics), not a layout primitive, and nothing in it bears on the questions asked.
`views/extensions_modal.rs`, `acp/tracker.rs` and the settings-modal trees were skipped
for the same reason.

**Measured vs read.** Everything under "Measured" below was produced by running code on
this machine this session. Everything else is a reading and is labelled as such.

### Measured this session (debug build, `cargo test --bin osagent`, this machine)

`render::stream_bench::draw_live_cost_curve` — per-frame vs per-delta cost of the live
preview against streamed-buffer size:

| buffer lines | per-FRAME `draw_live` | per-DELTA (push + height + draw) |
|---|---|---|
| 50 | 478.6 µs | 601.1 µs |
| 200 | 371.5 µs | 560.0 µs |
| 800 | 360.1 µs | 852.4 µs |

`render::stream_bench::stream_render_cost` — per-delta cost by content shape:

| scenario | deltas | total | per delta |
|---|---|---|---|
| prose, 3 paragraphs | 179 | 224.8 ms | 1,256 µs |
| prose, 30 paragraphs | 1,790 | 4.1 s | 2,264 µs |
| one 60-line code fence | 904 | 2.4 s | 2,696 µs |
| one 200-line code fence | 3,054 | 7.8 s | 2,544 µs |

**Reading of the numbers.** The per-FRAME curve is now flat — 478/371/360 µs across a
16× buffer growth is noise, not a curve. *The `draw_live` cost curve the owner was told
about is fixed in the working tree.* The comment at `components/chat/mod.rs:663-671`
records the pre-fix numbers (1.1 / 3.2 / 11.8 ms). Those are gone.

The per-DELTA path still grows: 601 → 560 → 852 µs. That residual, and the fence rows in
the second table, are what §1.3 explains.

---

## 1. The primitive-level diagnosis

### 1.1 The primitive OSA is missing: an **intra-block** streaming boundary

This is the diagnosis. Everything else is secondary.

OSA has exactly one notion of "this text is final": a **blank line at depth 0 outside an
open code fence** — `render/markdown_stream.rs:205-239` (`find_frozen_boundary`). It is
used in two places:

* `app/assistant_stream.rs:180-199` (`settle`) — hands completed blocks to
  `Chat::add_agent_chunk`, which commits them to the terminal's native scrollback.
* `render/markdown_stream.rs:125-132` (`advance`) — freezes rendered lines so the
  streaming preview does not re-parse them.

`app/handle_backend.rs:240-255` drains `settle()` **to exhaustion** on every delta and
then feeds `assistant_stream.tail()` to the chat. So the buffer the preview renders is,
by construction, exactly one *unterminated* markdown block.

That makes the per-delta cost **O(length of the current open block)**, and markdown has
no safe split point inside a fence, a table, or a list that has not yet closed with a
blank line. A 200-line code fence is one block; every token re-renders and re-highlights
all 200 lines. That is the 2,544 µs/delta row, and it is the mechanism behind *"lag that
grows with answer length"*: it does not grow with the answer, it grows with the current
**block**, which is why a long prose answer feels fine and a long patch or a long table
does not.

**What the references do.** Codex's boundary is the **last newline**, not the last blank
line — `codex-rs/tui/src/markdown_stream.rs:82-93`:

```rust
pub fn commit_complete_source(&mut self) -> Option<Range<usize>> {
    let commit_end = self.buffer.rfind('\n').map(|idx| idx + 1)?;
    ...
}
```

with the doc comment stating the rule: a delta without a newline returns `None`, so an
incomplete *line* is held back — but a complete line inside an open fence is not. The
constructs where a later line can retroactively change an earlier one are handled by a
dedicated holdback layer rather than by coarsening the boundary:
`codex-rs/tui/src/streaming/table_holdback.rs:24-38` (`PendingHeader` / `Confirmed` —
a pipe table stays mutable from its header row onward, because a new row reflows column
widths).

grok does the same thing one level down: `xai-grok-markdown/src/streaming.rs:299-386`
re-renders only `source[frozen.source_bytes..]`, and — critically —
`xai-grok-markdown/src/streaming.rs:151-158` keeps an `OpenCodeHighlighter` carrying
syntect's resumable per-line state **across** re-renders, so a large *open* fence is
O(N) total rather than O(N²).

**So the missing primitive is not "a frozen prefix" — OSA has one. It is a frozen prefix
whose granularity is a line rather than a block, plus per-construct holdback for the few
constructs that genuinely reflow.**

Two consequences follow that are worth stating separately.

**(a) The two frozen-prefix implementations are not redundant, but the cost model assumes
the wrong one is primary.** Because `settle()` is drained to exhaustion before
`update_streaming(tail())`, `find_frozen_boundary(tail)` is provably always `0`: if the
tail contained a further depth-0 blank line, `settle()` would have returned it. Therefore
`StreamingRenderer::frozen_bytes` is `0` and `frozen_lines` is empty on the normal path,
and `body_with_cursor()`'s `self.frozen_lines.clone()`
(`render/markdown_stream.rs:155`) clones an empty vector. The machinery is not dead — it
is the backstop for the one path where `settle()` stops firing, the sticky
guardrail gate at `app/assistant_stream.rs:188` → `app/settle_guard.rs`. **Do not delete
it.** But do not expect it to be doing work either: on the normal path the entire
per-delta cost is one `render_markdown(tail + cursor)`.

**(b) The `stream_bench` harness does not model production.**
`render/stream_bench.rs:58` and `:261` call `chat.update_streaming(&buf)` with the whole
cumulative buffer, whereas production feeds `tail()` (`app/handle_backend.rs:255`). The
prose rows in both tables are therefore pessimistic; the **fence** rows are faithful,
because a fence never settles. This should be fixed when the harness is next touched, or
the tables will keep being read as evidence for the wrong thing.

### 1.2 The primitive OSA built and then never wired: a per-message render cache

`components/chat/message.rs:83` declares `pub cached_height: Option<(u16, u16)>`. It is
read at `:253`, cleared at `:191`, initialised to `None` at `:108`, `:123`, `:141`,
`:159` and `components/chat/mod.rs:371`. **It is never assigned a `Some` value anywhere
in the crate** — verified by an exhaustive grep for `cached_height` across
`priv/rust/tui/src`. The height cache does not exist.

The cost of that shows up on the commit path. `app/event_loop.rs:1304` calls
`msg.height(w)`, which for an agent message runs a full `render_markdown`
(`components/chat/message.rs:288`). Then `app/event_loop.rs:1285` calls
`msg.render_to_buffer(...)` → `draw_agent`, which runs `render_markdown` **again**
(`components/chat/message.rs:466`), because `prerendered_body` is only ever populated for
the live preview (`:279`, `:464`). Every finalized assistant block is parsed twice on its
way into scrollback. (Read, not measured — the fix is cheap enough that measuring first
is not worth a build cycle, but it should be measured after.)

**The reference pattern.** grok's `xai-grok-pager/src/scrollback/entry.rs:74-138` is a
four-tier cache per entry, split *by recompute cost*, not by convenience:

| tier | key | note |
|---|---|---|
| `cached_output` (`:120`) | `(width, raw, theme, is_selected, cwd)` | the full rendered `BlockOutput`; `is_selected` normalised to `false` for kinds that don't vary by it, to avoid thrash (`:115-118`) |
| `cached_truncated_height` (`:127`) | `(width, raw, theme, cwd, cap)` | a `u16` only — kept separate because computing it still triggers full syntect highlighting (`:23-32`) |
| `cached_estimate_lines` (`:132`) | `(content_width, lines)` | cheap approximate count, ignores word boundaries |
| `cached_line_widths` (`:137`) | *none — width-independent* | per-source-line display widths; **survives resize**, with the comment: "re-deriving it per width is what made a resize cost O(total conversation bytes)" (`:134-136`) |

and three invalidation tiers (`:296-325`): `invalidate_width_caches` (resize — clears the
first three), `invalidate_cache` (content change — clears all four),
`evict_render_cache` (memory pressure — drops **only** the heavy rendered output, keeping
every layout-affecting tier so heights and scroll position stay stable).

OSA needs one tier of this, not four: **cache the rendered `Text` on the message, so
`height()` and `render_to_buffer()` share one parse.** OSA already has the field for it —
`prerendered_body` — used exactly this way for the live preview
(`components/chat/message.rs:276-287`). It just is not populated at commit time.

### 1.3 The primitive OSA has, that is not single-sourced: measurement

OSA measures display width in at least four places, and two of them disagree:

| site | basis | escape-aware |
|---|---|---|
| `util::cols` (`util.rs:117-136`) | **char**, `UnicodeWidthChar` | **yes** — skips CSI/OSC/DCS via `escape_len_at` (`util.rs:74-109`) |
| `util::fit_cols` (`util.rs:29-53`) | **grapheme cluster**, `UnicodeWidthStr` per cluster | no |
| `components/chat/wrap_count::rows_for_line` (`wrap_count.rs:49-`) | grapheme, faithful port of ratatui's `WordWrapper` | no |
| raw `unicode_width` calls | char/str | no — `message.rs:679`, `:830`; `welcome.rs:91`; `render/markdown.rs:4` |

`cols` and `fit_cols` disagree on any multi-codepoint grapheme with more than one
non-zero-width component: `👨‍👩‍👧` is 2 columns to `fit_cols` and 6 to `cols`. The
`util.rs:22-28` doc comment on `fit_cols` argues the grapheme rule correctly and then
`cols` — the function most other call sites use — does not follow it.

**Both references have this same split, so it is not a uniquely OSA failure.** grok:
`util.rs:229-239` (`byte_offset_at_width`, char-based) vs
`render/line_utils.rs:125-187` (`fit_line_to_width`, grapheme-based, with the doc comment
at `:116-121` explicitly promising `⚠\u{FE0F}` is never split). Codex is the cleanest of
the three: one canonical `codex-rs/tui/src/width.rs:18-24`:

```rust
pub(crate) fn display_width(text: &str) -> usize {
    UnicodeWidthStr::width(text)
        + text.chars().filter(|ch| matches!(ch, '\u{FF9E}' | '\u{FF9F}')).count()
}
```

— including a correction for halfwidth katakana sound marks that `unicode-width`
under-counts, verified against ratatui's own rendering
(`width.rs:63-72`, `display_width_matches_ratatui_halfwidth_sound_marks_without_overflow`).
OSA has no equivalent correction.

**Where OSA is ahead: escape-aware measurement.** `util::escape_len_at`
(`util.rs:74-109`) correctly handles CSI, OSC terminated by BEL *or* ST, and the
DCS/SOS/PM/APC family — and the doc comment names the exact bug a naive "ESC then first
ASCII letter" skipper causes. **Neither reference has an escape-aware width function.**
grok avoids needing one structurally: raw ANSI is consumed once, upstream, by a real VTE
emulator (`render/terminal_output.rs:1-16`, built on the `vte` crate) so that by the time
any width code runs it only ever sees plain text with styling out-of-band on `Span`.
Codex handles escapes in the hyperlink layer, not in `width.rs`. OSA's approach is a
legitimate third design and it works; the defect is only that there are two rules, not
that either rule is wrong.

**Where OSA is ahead: the sanitizer.** `render/sanitize.rs` runs a deliberate two-level
policy — a Trojan-Source/invisible-formatting predicate (`:38-56`) separated from the
control-character decision so each display surface can keep the structure it needs. Neither
reference has anything of this shape. **Leave it alone.**

**Not found in either reference: a "width profile" cache.** The candidate primitive list
proposed one. It does not exist. `xai-grok-pager-render/src/appearance/cache.rs` caches UI
*settings*; `theme/cache.rs` caches the active `ThemeKind`; `terminal/tmux_probe.rs` is
the tmux command protocol. A crate-wide grep for
`width.?profile|ambiguous.?width|emoji.?width|wcwidth` returns zero hits. grok trusts
`unicode-width` uniformly regardless of terminal. **Do not build one.**

### 1.4 Layout negotiation — OSA already has this, and it is good

`components/measure.rs:52` defines `Measured::desired_height(&self, width: u16) -> u16`
and the module doc names the exact defect class it removed. `layout_contract.rs` asserts
four properties over a width × height × demand sweep: rects derive from measurements,
no two components share a row, it always fits, and it degrades by priority with the
composer never shed.

This is at parity with, and in the arbiter's case ahead of, both references:

* Codex's `Renderable::desired_height(width)` (`codex-rs/tui/src/render/renderable.rs:17`)
  is the same shape. Composition is a `FlexRenderable` that sums children
  (`chatwidget/rendering.rs:6-53`); the top-level call is
  `App::with_chat_widget_frame` (`app.rs:1408-1416`). **Not cached across frames.**
* grok's `Renderable::desired_height(width)` carries the doc comment "This should be
  efficient (ideally O(1)) as it may be called frequently during scroll position
  calculations". Arbitration is *delegated to ratatui's constraint solver*
  (`views/agent.rs:157-260`): every band is `Constraint::Length(n)` and the scrollback
  region alone is `Constraint::Min(5)`. There is **no priority ladder** — panes damp
  themselves before reaching the arbiter (e.g.
  `views/subagent_catalog_pane.rs:186-199` returns 0 outright below 12 rows).
  grok also has a second, inconsistent convention: `TasksPane::desired_height(view_height)`
  (`views/tasks_pane.rs:1168`), `QueuePane::desired_height()` (`views/queue_pane.rs:624`)
  take *available room*, not content width.

So: **OSA's band arbiter with `SHED_ORDER` and its four asserted properties is stronger
than either reference's.** Nothing here needs replacing.

Two narrower gaps remain:

**(a) `desired_height` is not cached per width in OSA — nor in either reference.** For
most OSA bands that is fine (they are O(items)). It is not fine for `Chat`, and OSA
already special-cases it: `Chat::desired_height` → `streaming_height` →
`ensure_stream_cache`, keyed on `(generation, width)` (`components/chat/mod.rs:539-575`).
That is the right shape. It is not needed elsewhere today.

**(b) Chrome atomicity: OSA deliberately chose partial chrome at the band level.**
`layout_contract.rs:373` asserts `a_one_row_squeeze_costs_exactly_one_row` and the
comment argues for it: "a one-row squeeze costs one row, not a whole feature." For an
unbordered band (activity feed, checklist) that is right. For a **bordered** band —
`SurveyDialog`, `PlanReview`, `Permissions` (`components/measure.rs:127-142`) — a one-row
squeeze is precisely a half-drawn box, which is what grok forbids by name:

```rust
/// Buttons render whole or not at all, and never at the cost of the title:
/// a clipped/overflowing `[Opt in]` must not leave a click target in the
/// blank margin (a stray click there would silently opt the user in).
fn buttons_fit(area_width: u16) -> bool { ... }
```
— `xai-grok-pager/src/views/privacy_banner.rs:90-93`. Note the reason is a *hazard*, not
cosmetics: a clipped affordance leaves a live target the user cannot see.

OSA already applies whole-or-nothing correctly one layer down, in markdown:
`render/markdown_stream.rs:508`
(`full_grid_table_streams_byte_by_byte_without_a_half_drawn_border`) asserts every emitted
`┌` is closed by a `└` at *every* streaming prefix. The primitive exists; it just is not
applied to bordered bands.

### 1.5 Visible-row-only rendering — mostly moot for OSA, and OSA now beats Codex

grok genuinely windows: `scrollback/state/layout.rs:1808-1846` (`compute_paint_window`)
binary-searches a prefix-sum array `LayoutCache.virtual_y` (`:64-65`) with
`partition_point` to find the entry range intersecting the viewport, backs off one entry
when the previous straddles the top (`:1825-1828`), and only that range is materialised
(`entries_in_range`, `:256-260`). Appends extend the cache in O(1)
(`state/mod.rs:584-627`, with the regression test
`test_push_extends_layout_cache_when_present` whose docstring records that the O(N)
rebuild "caused subagent fullscreen scrolling to drop to 0 FPS during streaming").

**Codex does not window.** `chatwidget/rendering.rs:71-84` builds the full wrapped line
set, computes the overflow, and scrolls a `Paragraph`, relying on ratatui to clip.

**OSA now slices before building** (`components/chat/mod.rs:672-693`) — so on the live
path OSA is ahead of Codex and structurally equivalent to grok for the one surface it has.

`components/chat/message.rs:473-476` still uses `Paragraph::scroll`, which lays out all
lines and clips. That is not a defect where it is used: on the `insert_before` path every
row is painted, and on the live path it is now handed a pre-sliced body.

**grok's paint-window and prefix-sum layout cache do not apply to OSA and should not be
built.** They exist because grok owns an in-app scrollback pane with a scroll position.
OSA does not: the chat has no scroll viewport (`components/chat/mod.rs:707-711`), the
terminal owns printed rows (`components/chat/mod.rs:626-631`,
`undo_last_exchange`), and this is settled architecture. Same verdict for grok's
`ScrollAnchor` / `StructuralScrollAnchor` (`scrollback/state/layout.rs:17-42`) and its
`follow_mode` machinery (`scrollback/state/nav.rs:1135-1190`): **moot**. The candidate
list's "ScrollAnchor with a no-above-margin rule" is doubly moot — no such rule exists in
grok either; an explicit search for `no_above_margin` / `above_margin` returned nothing.
The closest real thing is a convention that a gap row is attributed to the entry *above*
it (`scrollback/state/layout.rs:456-458`).

The one OSA surface with a scroll position is the transcript viewer overlay
(`dialogs/transcript_viewer.rs`), a full-screen dialog. It is out of the live region's
hot path and is not part of this diagnosis.

### 1.6 Draw scheduling — OSA's policy is defensible; one real gap

OSA: drain the backlog into one frame (`app/event_loop.rs:1371-1383`); apply a 16 ms
floor **only** when the batch just consumed *and* the previous batch were both
stream-only (`:789`, `:1391-1411`); wrap the frame in DEC 2026 BSU/ESU
(`:1357-1359`). The narrowness of the gate is deliberate and the comment at `:780-788`
argues it: the first delta of a message never waits, so latency-to-first-token is not
taxed.

* **Codex**: 120 fps cap, `MIN_FRAME_INTERVAL = 8_333_334 ns`
  (`tui/frame_rate_limiter.rs:13`), plus a `FrameRequester` / `FrameScheduler` actor pair
  (`tui/frame_requester.rs:98-125`) that collapses many `schedule_frame()` calls before
  the next deadline into a single broadcast — true request dedup. On top of that, an
  independent *paint pacing* policy: `streaming/chunking.rs` `AdaptiveChunkingPolicy`,
  two gears with hysteresis — `Smooth` drains one queued line per tick, `CatchUp` drains
  the whole backlog; enter at queue depth 8 or oldest-age 120 ms (`:79`, `:84`), exit at
  depth 2 / age 40 ms held for 250 ms (`:89`, `:94`, `:97`), re-entry cooldown 250 ms
  (`:102`) bypassed when severe (depth 64 / age 300 ms, `:107`, `:109`).
* **grok**: a `Presenter` (`app/event_loop.rs:323-421`) with **write-side backpressure** —
  `try_present` refuses while `in_flight_target.is_some()` (`:359`), and the target is
  cleared only by `acknowledge()` driven by `WriterEvent::Written(sequence)` / `Failed`
  (`:344-351`, `:423-428`). Test `presenter_coalesces_until_ack` (`:4677-4695`): five
  requests while in flight produce one draw. Plus `request_throttled` at a 16 ms
  `min_draw_interval` (`:378-387`, default `DISPLAY_REFRESH_DEFAULT_CADENCE_MS = 16`),
  and `ACP_DRAIN_BATCH_MAX = 32` (`:1841`) so wheel/key events wait at most one batch
  during a token flood.

**The gap is write-side backpressure.** OSA's rate cap measures *elapsed time since the
last draw*, not *whether the terminal consumed the last frame*. On a fast local terminal
those are the same thing. Over SSH or inside tmux they are not: the bottleneck is the tty
write, the 16 ms floor is always satisfied, and OSA keeps handing frames to a pipe that
is behind — which is what "chunked streaming" looks like from the outside. Both references
solve this and neither does it with a timer.

The second gap is smaller: OSA has no equivalent of Codex's Smooth/CatchUp pacing. OSA
paints whatever a batch produced, so the *paint* cadence tracks the *arrival* cadence
once the floor is met. Uniform paint cadence is what reads as smooth; frame count is not.

**Where OSA is ahead:** the `DampedSlot` hysteresis (`app/event_loop.rs:466-530`) — growth
immediate, shrink held for `SLOT_SHRINK_HOLD` (200 ms) with any upward move re-arming the
timer, and an explicit "gone is not oscillating" carve-out at `:511-515`. **Neither
reference has asymmetric grow-fast/shrink-slow damping at all.** grok's 16 ms resize
debounce (`event_loop.rs:1832`) is a debounce, not hysteresis; a grep for `hysteresis|damp`
in grok's `event_loop.rs` and `effects/mod.rs` returns nothing. And OSA's damping is
*measured* — `app/event_loop.rs:711-721` records the PTY-probe ladder
(46 ms → 897 ms → 441 ms → 265 ms) that tuned it. Leave it alone.

### 1.7 Resize — OSA is ahead of grok outright; the "resize bench" is a myth

The candidate list said the references "reportedly have a resize bench". They do not, in
the sense implied.

**grok's is a crash-and-perf bench, not an invariant.**
`xai-grok-pager-pty-harness/src/scenarios/resize_storm.rs` is 42 lines: 25 resizes
alternating 35×100 / 55×160 at 40 ms intervals (`:14-15`), asserting only that (a) the
process is still running after each resize (`:25-27`) and (b) the screen does not contain
the string `"panicked"` (`:36-40`). It then reports frame-time statistics. There is no
cell-matrix equality check and no anchor-visibility property. The `scroll_matrix`
invariant suite (`src/scroll_matrix/invariants.rs`, 800 lines, IDs `Ord`, `Cap`,
`DropEq`, `Cadence`, `ConsW`, `ConsA`, `Accel`, `Carry`, `Cfg`, `MuxNoOver`,
`SmoothCoast`, `NoDrop`, `Screen`, `Quiet` — `:28-98`) is entirely about mouse-wheel and
trackpad gesture physics. An explicit search for "resize" across `scroll_matrix/` and the
harness `tests/` tree returned zero hits.

**OSA's harness asserts an actual correctness property.** `test/pty/` drives the real
`osagent` binary on a real kernel PTY, resizes with real `TIOCSWINSZ`, renders the byte
stream with `pyte`, answers `ESC[6n` from *pyte's* cursor rather than from a model that
is right by construction, and then counts composers — "One is correct. Nine is the bug"
(`test/pty/README.md`). Thirty scripts including per-emulator resize matrices
(`ghostty_resize.py`, `kitty_resize.py`, `vte_resize.py`, `wezterm_resize.py`,
`tmux_resize.py`, `reflow_matrix.py`). The README also documents its own limitation
honestly (pyte does not reflow; VTE does), which is more than either reference does.

The runtime side is correspondingly careful: a 50 ms settle window that produces *nothing
observable* while the size is still moving (`app/event_loop.rs:749-767`, and the note that
this is a coalescer, not the fix); a surgical-vs-full-screen clear chosen by terminal
identity (`:1105-1121`); ED0-from-home rather than ED2, with the reason spelled out —
VTE implements ED2 by scrolling the screen into scrollback, which is how a 15-column drag
deposited 15 stacked copies (`:1059-1080`).

**Codex has one thing OSA does not:** it re-emits the whole transcript at the new width
after a resize rather than clearing it — `transcript_reflow.rs:1-13`, debounced 75 ms
(`:18`), with per-terminal row caps to keep the replay bounded
(`resize_reflow_cap.rs:19-22`: VSCode 1,000 / Windows Terminal 9,001 / WezTerm 3,500 /
Alacritty 10,000). OSA deliberately clears instead and relies on scrollback plus the
transcript viewer, with the rationale written down at `app/event_loop.rs:1047-1057`. That
is a defensible trade and reversing it is a large, risky change that would need Codex's
cap table to be safe. **Not recommended.**

### 1.8 Symptom → cause

| symptom the owner reports | primitive | evidence |
|---|---|---|
| lag that grows with answer length | §1.1 — boundary is a blank line, so per-delta cost is O(open block); plus §1.2 — every committed block is parsed twice | measured: 2,544 µs/delta on a 200-line fence vs 1,256 on 3 short paragraphs; read: `cached_height` never written |
| chunked streaming | §1.6 — no write-side backpressure; paint cadence = arrival cadence once the 16 ms floor is met | read: `app/event_loop.rs:1391-1411` vs grok `event_loop.rs:353-370` |
| dead window before the first token | **not diagnosed.** It is *not* a draw-scheduling defect — the rate cap requires `prev_batch_stream_only` (`:1391`), so the first delta of a turn always draws immediately. While waiting on the backend the only repaint driver is the 200 ms tick (`:652`), i.e. a 5 fps spinner. Whether the window is backend TTFT or a missing paint is **unmeasured**; see item 7 | — |
| layout that loses its structure | §1.4(b) — bordered bands squeezed one row at a time; plus `STREAM_FLOOR = 1` (`:165`) means the reply band can legitimately collapse to a single row on a short terminal while the arbiter reports success | read |

---

## 2. Ranked sequence

Ordered so each item is independently shippable and does not depend on any later one.

### 1. Populate `prerendered_body` at commit time (kill the double parse)

* **Fixes:** every finalized assistant block is markdown-parsed twice on its way into
  scrollback — once by `height()` (`components/chat/message.rs:288`), once by
  `draw_agent` (`:466`).
* **Evidence:** `cached_height` is declared, read and invalidated but **never assigned**
  (exhaustive grep, `priv/rust/tui/src`). `prerendered_body` already short-circuits both
  paths (`:279`, `:464`) and is used exactly this way for the live preview.
* **Shape:** at `app/event_loop.rs:1293-1314`, render once, stash into `prerendered_body`,
  take the height from it. Or move the render into `Message` behind a `RefCell`, matching
  grok's `cached_output` tier (`scrollback/entry.rs:120`).
* **Size:** small (~40 lines plus tests).
* **Could break:** a message mutated after its body is cached. Two callers mutate:
  `Chat::end_agent_chunk_flow` (`components/chat/mod.rs:269-273`) and
  `update_last_tool_result` (`:415`) — both already call `invalidate_cache`, which must
  also clear `prerendered_body`. Raw-view toggling (`set_raw_view`) must invalidate too.
  Width changes are already routed through `invalidate_cache` (`:639-649`).
* **Then:** delete `cached_height`, or wire it. Leaving a field that four constructors
  initialise and nothing writes is how the next reader loses an hour.

### 2. Move the streaming render boundary from "blank line" to "newline + holdback"

* **Fixes:** the per-delta cost curve inside a single long block — the fence, the table,
  the long list. This is the primary diagnosis.
* **Evidence:** measured 2,544–2,696 µs/delta on 60- and 200-line fences vs 1,256 on
  short prose; `find_frozen_boundary` (`render/markdown_stream.rs:205-239`) has no
  intra-block split point by construction.
* **Shape:** a second, *render-only* boundary in `StreamingRenderer` — freeze at the last
  `\n` that is not inside a construct which a later line can reflow. Codex's rule
  (`codex-rs/tui/src/markdown_stream.rs:82-93`) plus its holdback layer
  (`streaming/table_holdback.rs:24-38`) is the model. Constructs needing holdback in
  OSA's renderer: pipe tables (column widths reflow), setext headings (a following
  `====` retro-changes the line above — OSA's own `NEW_LAYERS` fixture at
  `render/markdown_stream.rs:454-456` already exercises this), and lazy-continuation
  paragraphs. Fences do **not** need holdback for wrapping, only for highlighting — take
  grok's approach and carry resumable syntect state across re-renders
  (`xai-grok-markdown/src/streaming.rs:151-158`); OSA already memoizes the highlighter
  (`render/stream_bench.rs:162-208` pins it cell-identical to a cold render).
* **Critically: keep the commit boundary as it is.** `AssistantStream::settle` writes to
  `insert_before`, which is irreversible. The blank-line rule there is load-bearing and
  the guardrail mirror (`app/settle_guard.rs`) depends on it. Only the *render* boundary
  moves.
* **Size:** medium. The correctness bar is already built: `assert_stream_matches_full`
  (`render/markdown_stream.rs:380-394`) asserts byte-identity to a one-shot render at
  **every** prefix length, char by char, over four fixtures including a full-grid table
  and setext headings. Any boundary that is unsafe fails it immediately.
* **Could break:** any construct where `render(a) ++ render(b) != render(a ++ b)`. The
  invariant above is the guard. Also `full_grid_table_streams_byte_by_byte_without_a_half_drawn_border`
  (`:508`) must stay green — a table frozen mid-frame is exactly the half-drawn box it
  forbids, which is why tables need holdback rather than a line boundary.
* **Sequencing:** this file is in flight. Land after that lane.

### 3. Fix `stream_bench` to model production

* **Fixes:** the harness feeds the whole cumulative buffer
  (`render/stream_bench.rs:58`, `:261`) where production feeds `tail()`
  (`app/handle_backend.rs:255`). Prose numbers are pessimistic; the tables read as
  evidence for a cost curve that production does not have.
* **Size:** small. Drive `AssistantStream` + `Chat` together, as
  `layout_invariants.rs:4270` and `:4408` already do.
* **Could break:** nothing — test-only. Do this before item 2 so item 2's numbers mean
  something.

### 4. Write-side backpressure on the draw

* **Fixes:** chunked streaming over SSH / tmux. OSA gates on elapsed time, not on whether
  the terminal consumed the last frame.
* **Evidence:** `app/event_loop.rs:1391-1411` measures `last_draw.elapsed()`; grok's
  `Presenter::try_present` refuses while `in_flight_target.is_some()`
  (`event_loop.rs:359`) and clears it only on `WriterEvent::Written(sequence)`
  (`:423-428`).
* **Shape:** a flush-ack around the `terminal.draw` at `app/event_loop.rs:1358` — track a
  sequence, do not begin the next frame until the previous write completed. The DEC 2026
  BSU/ESU pair already brackets the write, so the ack point is well-defined.
* **Size:** medium.
* **Could break:** wedging if an ack is lost — grok names the failure in a test,
  `presenter_no_output_does_not_wedge` (`event_loop.rs`). Any implementation needs the
  same test plus a timeout fallback to the current elapsed-time gate.

### 5. One canonical `display_width`

* **Fixes:** `util::cols` (char-based) and `util::fit_cols` (grapheme-based) disagree on
  ZWJ sequences and flags. `cols` is the one most call sites use and it is the one with
  the weaker rule.
* **Evidence:** `util.rs:117-136` vs `util.rs:29-53`, plus the doc comment at `:22-28`
  arguing for the grapheme rule that `cols` does not follow.
* **Shape:** make `cols` grapheme-based while keeping its escape skipping (which is
  OSA's advantage over both references — keep it). Add Codex's halfwidth-katakana
  correction (`codex-rs/tui/src/width.rs:18-24`) with its ratatui-verified test
  (`:63-72`). Then route the raw `unicode_width` call sites (`message.rs:679`, `:830`;
  `welcome.rs:91`) through it.
* **Size:** small.
* **Could break:** padding arithmetic that silently compensated for the char-based count.
  Guarded by the existing budget assertions —
  `components/status_bar.rs:1927`, `:1942`, `:1948`, and
  `layout_invariants.rs:575`, `:1521`, `:1556`.

### 6. Whole-or-nothing for bordered bands

* **Fixes:** half-drawn survey / plan-review / permission boxes when the viewport is one
  row short.
* **Evidence:** `layout_contract.rs:373` asserts a one-row squeeze costs exactly one row
  — right for unbordered bands, wrong for bordered ones. grok forbids it by name and for
  a hazard reason (`views/privacy_banner.rs:90-93`), and panes return `0` rather than
  clip (`views/subagent_catalog_pane.rs:189-191`).
* **Shape:** add `Measured::min_intact_height(&self, width) -> u16`, defaulting to 1;
  `fit_bands` (`app/event_loop.rs:304`) drops a band to 0 rather than granting it fewer
  rows than its intact minimum. Bordered bands return `border + 1`.
* **Size:** small. Fits the existing sweep in `layout_contract.rs` directly.
* **Could break:** a band that previously showed 4 of 6 rows now shows none. That is the
  intended trade, but it changes visible behaviour on short terminals — worth a line in
  the release notes. `the_composer_is_never_shed` (`layout_contract.rs:314`) must stay
  green; the composer's floor stays 1.

### 7. Measure the dead window before the first token

* **Not a change — a measurement.** This symptom is currently undiagnosed and should not
  be "fixed" by guessing. The rate cap provably does not cause it
  (`app/event_loop.rs:1391` requires `prev_batch_stream_only`).
* **Shape:** extend `test/pty/stream_paint_probe.py` to timestamp submit-keypress →
  first non-chrome cell change, against `test/pty/stub_backend.py` with a known TTFT.
  That separates backend latency from a missing paint. If the gap exceeds stub TTFT, the
  next suspect is the 200 ms tick (`:652`) being the only repaint driver while waiting.
* **Size:** small.

---

## 3. What NOT to do

**Reference patterns that would be wrong for OSA:**

* **Do not build a paint-window / prefix-sum layout cache.** grok's
  `compute_paint_window` + `LayoutCache.virtual_y`
  (`scrollback/state/layout.rs:64-65`, `:1808-1846`) exists because grok owns an in-app
  scrollback pane with a scroll position. OSA does not, by settled design: the chat has no
  scroll viewport (`components/chat/mod.rs:707-711`) and printed rows belong to the
  terminal (`:626-631`).
* **Do not build a `ScrollAnchor`.** Same reason —
  `scrollback/state/layout.rs:17-42`, `state/nav.rs:1135-1190`. And the "no-above-margin
  rule" from the candidate list does not exist in grok; the search returned nothing.
* **Do not build a "width profile" cache.** It does not exist in grok. The named files
  (`appearance/cache.rs`, `theme/cache.rs`, `terminal/tmux_probe.rs`) cache settings,
  theme kind and the tmux command protocol respectively.
* **Do not copy grok's "resize bench".** It asserts only that the process did not panic
  (`scenarios/resize_storm.rs:25-40`). OSA's PTY suite already asserts a real invariant
  against a real kernel PTY. OSA is ahead.
* **Do not copy Codex's transcript re-emit on resize** (`transcript_reflow.rs`). It needs
  a per-terminal row-cap table (`resize_reflow_cap.rs:19-22`) to be safe, and OSA has a
  written rationale for the opposite trade (`app/event_loop.rs:1047-1057`).
* **Do not delete `StreamingRenderer` as dead code.** Its frozen prefix is `0` on the
  normal path *only because* `settle()` drains first (`app/handle_backend.rs:240-255`).
  It is the backstop for the guardrail-shut path (`app/assistant_stream.rs:188`).

**OSA code that is already correct and should be left alone:**

* `render/sanitize.rs` — the two-level sanitizer keeping ZWJ intact for rich renderers
  while scrubbing Trojan-Source controls (`:38-56`). Neither reference has this.
* `render/colors.rs:126` — `NoColor → Color::Reset`. Neither reference has an equivalent
  degradation ladder.
* `util::escape_len_at` / `util::cols`'s escape handling (`util.rs:74-136`). **Neither
  reference has an escape-aware width function.** Item 5 changes the grapheme rule inside
  `cols`; it must not touch the escape skipping.
* `layout_contract.rs` and the `SHED_ORDER` band arbiter. grok delegates to ratatui's
  constraint solver with no priority ladder (`views/agent.rs:157-260`); OSA's is stronger.
  Item 6 adds one predicate; it does not restructure the arbiter.
* `DampedSlot` (`app/event_loop.rs:466-530`) and `SHRINK_SETTLE_TICKS`
  (`:722`). Asymmetric grow-fast/shrink-slow damping exists in neither reference, and
  OSA's constants were tuned against real PTY measurements recorded in the source
  (`:711-721`).
* The resize clear machinery: ED0-not-ED2 (`:1059-1080`), surgical-vs-full-screen by
  terminal ident (`:1105-1121`), the pure-height-change scroll-then-erase path
  (`:1122-1168`). Every branch has a recorded failure behind it.
* `components/chat/wrap_count.rs` — the faithful `WordWrapper` port. It is the height
  oracle the `insert_before` rect depends on; an approximation here clips rows out of
  scrollback permanently (`components/chat/message.rs:303-308`).
* `components/chat/mod.rs:672-693` — the `draw_live` slice. Measured flat this session.
  It is done. Do not revisit it.
