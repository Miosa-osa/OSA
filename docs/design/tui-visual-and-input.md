# OSA TUI — visual design language and input/queue surfaces

**Status:** design specification. Nothing here is implemented yet unless a section says so.
**Scope:** the persistent chrome (header row, block decoration, turn-status line, queue rows,
keybind hints, composer footer) and the semantics of typing while a turn is running.

This document is written so it can be implemented without reference screenshots. Every glyph,
spacing rule, alignment rule, colour role and truncation rule is stated explicitly. OSA
citations are `path:line` relative to `priv/rust/tui/` unless otherwise noted.

Where a design decision was derived from studying a reference harness, it is stated here
directly as OSA's intended design; the reference is not reproduced or attributed.

---

## 0. Layout model

The agent screen is a vertical stack. Top to bottom:

```
row 0        status/header row          (1 row, always)
rows 1..N    scrollback                 (flex)
             ── divider ──              (1 row)
             queued rows                (0..3 rows)
             turn-status line           (0 or 1 row, only while a turn runs)
             composer body              (1..N rows, grows with content)
             ── divider + model footer ─(1 row)
             keybind hint bar           (1 row, always)
```

Two rules govern the whole stack:

- **Reserved-width first.** Any element that overlays a line (timestamp, scroll marker) has its
  width subtracted from the content wrap width *before* the content is wrapped, never painted
  over finished text. A timestamp that would collide is dropped, not overlapped.
- **Hard truncate, never wrap.** Every single-row chrome element truncates. Multi-item rows
  (hint bar, header) stop emitting items when the next item would not fit — they do not
  ellipsise the row as a whole. Single-string fields (paths, queue text) ellipsise with `…`
  (U+2026), one column, appended after the budget minus one.

### 0.1 Block horizontal layout

Every scrollback block is laid out as four horizontal regions:

| region | width | contents |
|---|---|---|
| accent | **1** | the left rail glyph, or a space |
| left pad | **2** (configurable) | blank |
| content | flex (min 1) | the block's text |
| right pad | **1** (configurable) | blank |

Chrome width = `accent + pad_left + pad_right` = **4** at the defaults. In a minimal/flat screen mode the accent column
is reclaimed (width 0) and the rail is not drawn at all.

---

## 1. Header row (row 0)

One row. Left segment is the working directory context; right segment is a right-aligned group
of status items separated by a dim pipe.

### 1.1 Left segment — path and repo context

Painted at `x = area.x`, left to right, each part optional:

1. **Git branch** — `{branch_icon} {branch}` , or `{branch_icon} detached` when the branch name
   is empty. Style: `text_primary` + DIM. Followed by one space.
2. **Worktree label** — literal `worktree ` (with trailing space) when the cwd is a linked
   worktree. Style: accent/user colour.
3. **Sandbox label** — `sandbox:{profile} ` (with trailing space) when a sandbox profile is
   active. Style: warning colour.
4. **Path** — the cwd with `$HOME` collapsed to `~`, e.g. `~/projects/osa/OSA`. Style: dimmest
   gray normally, `text_primary` on mouse hover. **The full relative path, not the basename.**
5. **Main-repo suffix** — ` (worktree of {main_repo})` when in a linked worktree. Dim gray.

The assembled left line is truncated (styled-line truncation, `…` on the span that overflows) to
`min_x(right group) - x - 1` columns, so it can never touch the right group.

### 1.2 Right segment — status items

Items are built in a fixed push order and the **whole group** is right-aligned to the row's right
edge. Separator between adjacent items is exactly `" │ "` — space, U+2502 LIGHT VERTICAL, space
(3 columns) — in the dimmest gray. **No separator before the first item or after the last.**

Push order (each item is skipped when not applicable):

| id | content | style |
|---|---|---|
| `link_url` | the hovered link's URL, truncated to `width - 20` with `…` | link colour |
| `bg_tasks` | `{dot-spinner frame} {N}` running background tasks | running accent, BOLD on hover |
| `plan` | literal `plan` | plan accent |
| `goal` | goal chip (phase label + counters) | goal accent |
| `mcp` | MCP init progress | gray |
| `context` | **the context fraction** — see §1.3 | graded, see §1.3 |
| `queue` | **`+{N}`** — the `+1` indicator, see §1.4 | accent/user, BOLD on hover |
| `badge` | todo counts badge | per-state |
| `version` | `v{semver}` | dim gray |

Each item's painted `Rect` is recorded for hit-testing (click on the context item opens the
context breakdown; click on `+N` toggles the queue pane; click on the path copies it).

### 1.3 Context usage — a fraction, not a bar

The default form is **`{used} / {total}`**, e.g. `95K / 500K`, `8.5K / 1.0M`, `52K / 200K`.
Spacing is exactly one space, slash, one space.

Token abbreviation (`fmt_tokens`), max 4 characters:

| range | form | example |
|---|---|---|
| `0 – 999` | bare integer | `999` |
| `1 000 – 9 999` | one decimal + `K` | `8.5K` |
| `10 000 – 999 999` | integer + `K` | `95K`, `999K` |
| `1 000 000 – 9 999 999` | one decimal + `M` | `1.0M` |
| `≥ 10 000 000` | integer + `M` | `12M` |

Rounding is truncation-toward-zero at the chosen precision (integer division for the integer
forms).

The string is right-padded with spaces to a **minimum of 6 columns** so the alternate hover form
occupies exactly the same width and hovering causes no layout shift.

**Colour is graded by utilisation** and is applied to the whole fraction (not just the numerator),
so the pressure signal is visible without hovering. Breakpoints, linearly interpolated in RGB
between neighbours and then quantised to the terminal's colour depth:

| % of window | colour role |
|---|---|
| 0 | `text_primary` |
| 50 | accent/user |
| 65 | accent/user |
| 75 | warning |
| 85 | warning |
| 95 | error |

(The flat 50→65 and 75→85 segments are deliberate: they hold a colour steady through the band
where the user should not be alarmed, so the transitions read as discrete steps rather than a
continuous smear.)

**On hover** the fraction is replaced in place by `{progress bar} {pct}` where the percentage is
a fixed-width 5-character field: `X.XX%` below 10, `XX.X%` from 10 to 99.9, and the literal
`MAX %` at 100 or above. The bar width is `total_width - 6` so the hover form is exactly as wide
as the default form.

The context item is **suppressed entirely** for sessions where OSA does not own the context
window (a remote/hosted chat session): render nothing rather than a wrong number.

### 1.4 The `+N` indicator

`+{N}` where N = number of prompts queued and not yet running. Rendered in the accent/user
colour, BOLD while the mouse is over it, immediately to the right of the context fraction. With
one queued message this reads `+1`. Omitted entirely when N is 0.

N counts local queue entries plus any server-side queue entries whose id is not the currently
running prompt — i.e. it never counts the turn you are watching.

---

## 2. Per-block chrome

### 2.1 Left accent rail

A **1-column** rail in the accent region of every block, glyph `┃` (U+2503 HEAVY VERTICAL), with
legacy fallback `│` (U+2502) on consoles without the box-drawing heavy set. It is painted on
**every row of the block**, not just the first.

Three states:

- **Static** — solid, full accent colour. Completed blocks.
- **Animated (running)** — a luminance wave travels down the rail. For each row, brightness =
  `wave(tick, logical_row, wave_rows, speed)` in `[0,1]`; the painted colour is
  `blend(block_background, accent_colour, brightness)`. `logical_row` is the row's index within
  the block *including rows scrolled above the viewport*, so the wave does not jump when the
  block is partially scrolled.
- **Frozen** — a running block that is blocked on the user (permission prompt, question) paints
  the rail solid at full accent colour with **no** animation. "Paused on you" must not look like
  "loading".

**Collapsed** groupable blocks use a thinner glyph — **`❙` (U+2759 LIGHT VERTICAL BAR)**, legacy
fallback `|` — blended **0.5 toward the block background**, so adjacent collapsed rows do not
visually merge into one long bar. A *selected* collapsed row falls through to the static
full-colour branch instead, so selection always reads as undimmed.

**Finish flash:** when a tool or thinking block finishes, its rail paints a static accent for a
short flash window. Tool kinds with no natural accent flash in the success colour; thinking
blocks flash in their own accent.

Accent colour by block kind:

| block | accent role |
|---|---|
| user prompt | `text_primary` |
| assistant message | **none** — prose gets no rail; the rail is a *machine-activity* signal |
| thinking | `accent_thinking` |
| tool call: exec/shell | `accent_success` when ok, `accent_error` when failed |
| tool call: other | `accent_tool`; **running** = animated wave on `accent_running`; failed = `accent_error`; collapsed = none |
| tool call: read / edit / list / search | **none** — cheap, non-destructive reads stay quiet |
| background task / subagent | `accent_running` while running, none once finished |
| side-note | `accent_plan` |
| system / session event / context info | **none** |

The "assistant message has no rail" rule is deliberate and load-bearing: if every block has a
rail, the rail stops meaning anything. Reserve it for blocks that represent the machine *doing*
something.

### 2.2 Bullet glyph

The first content row of a bulleted block is prefixed with `{glyph} ` — glyph plus **one space**,
inserted as a span at index 0 of the first line. Default glyph is **`◆`** (U+25C6 BLACK DIAMOND),
legacy fallback `♦` (U+2666). The glyph is user-configurable: `·`, `•`, `●`, `▸`, `▶`, `◆`, or
none.

Bullet colour:
- block supplies a bullet style → that colour;
- otherwise collapsed → medium gray, expanded → bright gray.

Bullet animation: a running block's bullet takes the **same wave brightness** as row 0 of its
rail, so glyph and rail pulse in phase. A block blocked on user input freezes the bullet at a
static colour (falling back to the accent/user colour for blocks with no bullet style), matching
the frozen rail and the status-line diamond — every "your turn" cue is the same hue everywhere.

Related diamonds, used consistently:

| glyph | codepoint | legacy | meaning |
|---|---|---|---|
| `◆` | U+25C6 | `♦` | filled — active/primary |
| `◇` | U+25C7 | `○` | hollow — idle/free |
| `◈` | U+25C8 | `♦` | dotted — derived/secondary category |

### 2.3 Right-aligned timestamps

Shown on **user prompts, assistant messages and side-notes only** — never on tool calls, never
on system events.

- **Reserved width: 10 columns.** Content is wrapped at `content_width - 10` whenever timestamps
  are enabled for that block kind, so text and timestamp never collide.
- **Painted on the first content row only**, right-aligned to the content area's right edge:
  `x = content.x + content.width - ts_width`.
- **Format: `"  %-I:%M %p"`** — two leading spaces, no leading zero on the hour, 12-hour clock,
  uppercase AM/PM. Renders as `  3:04 AM`, `  11:57 PM`. The two leading spaces are part of the
  string; they guarantee a visual gap from the content even at exactly the reserve width.
- **On hover** the field expands to `"  %H:%M:%S | %b %d"` (e.g. `  03:04:17 | Aug 13`). The hover
  hit zone is the rightmost 10 columns of that row.
- Style: medium gray, no modifiers.
- Suppressed when `content_width <= ts_width + 1`, or when the row would fall outside the
  viewport.
- Globally toggleable (a `/timestamps` command); default state is OSA's choice, but the reserve
  must follow the toggle so disabling it returns the 10 columns to content.

---

## 3. Tool summary lines

A tool summary line is: `{rail}{pad}{bullet} {verb} {subject}{hook suffix}`.

### 3.1 Hook-run counter suffix

Appended to the summary line, right after the subject. Two shapes.

**Compact** (individual tool rows, where per-hook detail is reachable by expanding):

```
  [hooks: {completed}]                 e.g.   [hooks: 9]
  [hooks: {completed}/{failed}]        e.g.   [hooks: 9/1]
  [hooks: {failed}]                    e.g.   [hooks: 3]
```

- Literal prefix is exactly `"  [hooks: "` — **two leading spaces**, then `[hooks: `.
- `completed` = successes + blocked (blocked hooks *did* complete; they belong in the green
  numerator).
- The `/` separator appears only when both counts are non-zero, and is muted.
- `completed` is painted in the success colour + DIM; `failed` in the error colour + DIM.
- Closing `]` is muted.
- The whole suffix is omitted when no hooks ran.

**Labeled** (aggregate/group rows, where no member detail is visible, so every outcome must be
named):

```
  [hooks: {n} ok, {n} blocked, {n} failed]     e.g.   [hooks: 10 ok, 3 failed]
```

- Only non-zero categories are emitted, in the fixed order `ok`, `blocked`, `failed`.
- Separator between categories is `", "` (comma + space), muted.
- Each `"{count} {label}"` takes its category colour + DIM: `ok` = success, `blocked` = running
  accent, `failed` = error.
- When every hook succeeded, the labels collapse to the bare count: `[hooks: 10]`.

**Turn-terminal marker lines** merge one suffix per hook-event group, event name in bold muted,
groups joined by **two spaces**:

```
stop  [hooks: 1]
stop_failure  [hooks: 1]  stop  [hooks: 1]
```

---

## 4. Turn-status line

One row, present only while a turn is running or cancelling. Sits directly above the composer
(below the queued rows). Layout:

```
{spinner} {label}{phase timer}                          {turn timer} {tokens}{bg}{stop}
└────────── left, painted from area.x ──────────┘       └──── right-aligned group ────┘
```

Rendered example: `⠧ Responding… 30s` on the left, `3m19s ⇣95.3k [stop]` on the right.

### 4.1 Spinner

- Frames: braille `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧` (U+280B, U+2819, U+2839, U+2838, U+283C, U+2834, U+2826,
  U+2827). Legacy fallback: 1-column ASCII `| / - \`.
- Advance rule: `frame = (tick / 4) % 8` — one frame every 4 ticks, ≈133 ms/frame, ≈7.5 fps.
  Deliberately slow: the "still running" cue should read as a heartbeat, not a strobe. (OSA's
  current 133 ms cadence at `activity.rs:1665-1669` is already exactly this — keep it.)
- The spinner string is the glyph **plus one trailing space**.
- **Blocked on user input** (permission prompt / question) replaces the spinner with a pulsing
  `◆` — same glyph and hue as the frozen bullet and rail.

### 4.2 Label

Gray, one of: `Thinking…`, `Responding…`, `Waiting…`, `Verifying…`, `Retrying (attempt N)…`
(warning colour), `Cancelling…` (error colour), or a tool-specific present-continuous title
(`Run command`, `Edit file`, …) in the tool accent. Trailing character is the ellipsis `…`
(U+2026), never three dots.

### 4.3 Timers

Both timers use one format function:

| elapsed | form | example |
|---|---|---|
| `< 10s` | one decimal + `s` | `0.5s`, `5.2s`, `9.9s` |
| `10s – 59s` | integer + `s` | `10s`, `32s`, `59s` |
| `60s – 59m59s` | `{m}m{s}s` | `1m0s`, `1m20s`, `10m0s` |
| `≥ 1h` | `{h}h{m}m` | `1h0m`, `1h2m` |

- **Phase timer** — how long the current activity has been running. Rendered on the LEFT,
  preceded by one space, immediately after the label. Gray. **Suppressed for question/ask
  activities** — do not put a stopwatch on the user while they are answering.
- **Turn timer** — total turn elapsed. Rendered on the RIGHT, first item of the right group.
  Gray.

### 4.4 Token counter

`⇣{n}` — U+21E3 DOWNWARDS DASHED ARROW (legacy fallback `↓` U+2193), no space between arrow and
number. Separated from the turn timer by one space. Shown only when the count is > 0.

Number format (`format_tokens_short`):

| range | form | example |
|---|---|---|
| `< 1 000` | bare integer | `847` |
| `1 000 – 9 999` | 2 decimals + `k` | `1.23k` |
| `10 000 – 99 999` | 1 decimal + `k` | `95.3k` |
| `100 000 – 999 999` | integer + `k` | `128k` |
| `1 000 000 – 9 999 999` | 2 decimals + `m` | `1.23m` |
| `≥ 10 000 000` | 1 decimal + `m` | `12.4m` |

### 4.5 Affordances

- **`[stop]`** — always that literal string. Preceded by one space *unless* the background button
  is present, in which case they are adjacent. Shown while running **and** while cancelling (a
  second click re-sends a lost cancel). Hidden on keyboard-only hosts. Colour: medium gray at
  rest, error red on hover — **the label text never changes on hover**. It is a *mouse*
  affordance for the same action the keyboard reaches via Ctrl+C (or Esc when Esc is currently
  bound to cancel); the words `esc to interrupt` remain the keyboard-discoverable form.
- **`[↓]`** — send-to-background, preceded by one space; expands to `[send to bg]` on hover
  (this one *does* swap text, because the icon alone is not self-explanatory). Only shown while a
  foregrounded shell/exec tool is running, never while cancelling.

All right-group cells must set foreground, background **and** `remove_modifier` explicitly — the
left content is painted first and can leak modifiers into the right zone.

---

## 5. Queued messages

Queued prompts are pinned as their own rows directly **above** the turn-status line and below the
scrollback.

- **Height:** `min(queue_len, 3)` rows. Hidden at 0. The pane is a scrollable list; more than 3
  entries scroll within the 3 rows.
- **Row prefix:** `#{position}` followed by **one space**, `position` **1-based** so the top row
  reads `#1 fix the flaky test`. Prefix style: medium gray. Prefix column budget is
  `2 + digit_count(max_position)` — reserve it before truncating the body.
- **Indent:** the pane's content starts at `accent + pad_left − 1` = **2** columns, one less than
  the scrollback, so `#N` lines up vertically with the turn-status spinner directly below it.
  The right edge is **not** inset, so a row's `[cancel]` affordance lines up with `[stop]`.
- **Row body:** the prompt's **first line only**, in the accent/user colour.
- **Multi-line suffix:** ` (+1 line)` / ` (+{N} lines)` in medium gray, appended after the body.
  The body's truncation budget is reduced by the suffix width *first*, so the suffix is never
  itself truncated.
- **Truncation:** the body is truncated to the remaining width with `…` (U+2026) appended.
- **Kind styling:**
  - plain prompt — accent/user
  - slash command — `/command` token in accent/assistant, arguments in bright gray
  - bash — `! ` prefix + text, both in the command colour (yellow), 2 columns reserved for the
    prefix
  - scheduled — `↻  ` prefix (U+21BB + two spaces) in dim gray, text in accent/user
- **Scroll markers:** when the queue has more entries than fit, a dim `▲` is painted in the
  top-right cell of the pane and a dim `▼` in the bottom-right cell (see §8).

---

## 6. Keybind hint bar

The bottom row of the screen. Always present.

- **Item format:** `{key}:{label}` — key in `text_secondary` + BOLD, the colon and the label in
  medium gray. **No space around the colon.**
- **Separator:** exactly `"  │  "` — two spaces, U+2502, two spaces (5 columns), medium gray +
  DIM. Between items only; never leading or trailing.
- **Multi-key items:** joined with `/` (e.g. `J/K:reorder`), the `/` in the separator style.
- **Truncation:** when the next separator, key, colon or label would exceed the row width, the bar
  **stops emitting** at that boundary. No ellipsis, no wrap.
- **Right-aligned tail:** an optional right-aligned text (team/profile name) may be painted at the
  right edge, but only if it starts at least 2 columns past where the hints ended.
- **Pending-confirmation takeover:** when a double-press action is armed, the bar is replaced
  entirely by `{key}:press again to {label}` and nothing else.

Rendered example:

```
→:expand  │  Enter:open  │  Ctrl+e:expand thinking  │  Esc:cancel  │  Ctrl+;:queue
```

### 6.1 Contextual hint selection

Hints are assembled per focused pane, then compacted to a fixed budget: **5 slots plus a
trailing help hint** (`Ctrl+.` → `shortcuts`, remapped to `Ctrl+x` where `Ctrl+.` is unreliable).
**Pinned** hints are always kept regardless of budget; the remaining `5 - pinned_count` slots are
filled with unpinned hints in their original order; the help hint is appended unconditionally
last. This is why a narrow bar ends in a bare `Ctrl+x:` — the key and colon fit, the label
`shortcuts` did not, and the bar truncates rather than ellipsising.

| pane / state | hints |
|---|---|
| composer, idle, has text | `Enter:send`, `Shift+Enter:newline` (or `Alt+Enter` where Shift+Enter is unavailable) |
| composer, **turn running**, has text | `Enter:queue` — **the submit label changes from `send` to `queue` while a turn runs.** This is the primary discoverability surface for queue semantics. |
| composer, turn running, empty, queue non-empty | `Enter:send now` |
| composer, editing a queued row | `Enter:save`, `Esc:cancel` |
| composer, history search active | `↑/↓:nav`, `PgUp/PgDn:page`, `Enter:select`, `Esc:cancel` |
| queue pane focused | `x:delete row`, `e:edit`, `J/K:reorder`, `y:copy`, + send-now chord while running |
| any | `Tab:mode`, plus registry hints for the focused context and global context |

---

## 7. Composer

### 7.1 Box

- **Side borders:** `│` (U+2502) painted in the border colour at `x = area.x` and
  `x = area.x + width - 1` on every text row.
- **Bottom divider:** a full-width rule on the row below the text area:
  `╰` (U+2570) at the left corner, `╯` (U+256F) at the right corner, `─` (U+2500) between.
- Border colour has two states: dim when unfocused, brighter when focused.
- **Unfocused dimming:** the box *interior* (excluding all border cells) is blended 66 % toward
  the background. Borders are never dimmed by this pass — they have their own two-state colour.

### 7.2 Prompt marker and placeholder

- **Marker: `❯ ` — U+276F HEAVY RIGHT-POINTING ANGLE QUOTATION MARK ORNAMENT plus one space,
  2 columns**, legacy fallback `> `. Painted on the first text row only; the textarea itself
  starts 2 columns in. This is *not* `›` (U+203A) — that lighter chevron is reserved for folds,
  breadcrumbs and steppers, and using it here makes the composer look like a disclosure widget.
  - Colour: accent/user when focused, dimmest gray when not. Plan/comment modes override it to
    the plan accent.
  - Priority of marker overrides: active history search → `? ` in accent/user; else a mode
    prefix (bash mode → `! ` in the command yellow); else `❯ `.
  - A distinct marker may be used while a turn is running to signal that Enter will queue.
- **Placeholder:** the literal `Build anything`, painted at the text area's origin in medium gray
  when the composer is empty and either unfocused, or focused with placeholder-when-focused
  enabled. Truncated to the text-area width (it is painted with a raw string set, which would
  otherwise clip at the *buffer* edge and paint over the border).
- The placeholder is suppressed while live voice-transcription interim text is showing.

### 7.3 Growth

The composer grows with content up to a cap, then scrolls internally. Height is recomputed on
every keystroke. Newline entry: Shift+Enter where the terminal reports it, Alt+Enter as the
documented fallback, plus a universal trailing-backslash continuation.

### 7.4 Model / approval footer

The footer is **painted into the bottom divider row**, overwriting the `─` fill. It is not a
separate row — this is what makes it read as a label on the box rather than a status line.

- **Right-aligned** on the divider row: `x = area.x + area.width - text_width`. It sits against
  the `╯` corner, not the `╰` corner. (A left-aligned footer collides with the prompt marker's
  visual column and reads as a caption on the *text*; right-aligned it reads as a label on the
  *box*.) With the multiline indicator present the row is `[left group][1-col gap][right
  indicator]`, the whole thing right-aligned.
- One **leading space** and one **trailing space** in the box background colour, so the corner
  glyphs `╰` / `╯` are visually separated from the text.
- Content: `{model name}` then, for each flag, `" · "` + flag text. The separator is exactly
  space, `·` (U+00B7 MIDDLE DOT), space.
- An optional usage warning is prepended before the model name, followed by its own `" · "`;
  it takes the warning colour when critical, otherwise the separator colour.
- Styles: model name in the chrome-caption style (readable, not dim); separator in the dimmest
  gray; flags in medium gray. A flag may declare its own colour and/or BOLD — bold flags use full
  colour, non-bold coloured flags are blended 75 % toward the background when focused, 50 % when
  not.
- Right-aligned on the same row: the multiline-mode indicator.

Rendered example for OSA:

```
╰──────────────────────────────── claude-opus-5 (high) · overdrive ╯
```

The model label is built as `format!("{model_id} ({effort})")` when a reasoning effort is set,
and the bare `{model_id}` otherwise — the `(high)` is part of the model string, not a flag.
Effort vocabulary: `none | minimal | low | medium | high | xhigh | max`.

Flag vocabulary is OSA's own approval/permission modes, each with its own colour:

| flag | colour role |
|---|---|
| `plan` | plan accent (gold) |
| `plan approval` | plan accent |
| `commenting` / `commenting L12` / `commenting L12-18` | plan accent |
| `overdrive` | default gray (no colour) |
| `always-approve` | default gray |
| `ask` | default gray |
| `sandbox:{profile}` | warning |

All flags are non-bold by default. Two whole-label overrides replace the model name entirely and
clear the flags: editing a queued row → `editing queued #{n}`, and an active input-mode override
→ that mode's label.

---

## 8. Scroll affordance markers

Single-character corner indicators, painted **over** the last column of a pane's first and last
rows.

- **Top-right `▲`** (U+25B2), medium gray: content exists above the viewport (`scroll_offset > 0`).
- **Bottom-right `▼`** (U+25BC), medium gray: content exists below the viewport.
- **Bottom-right `▶`** (U+25B6), command yellow: the pane is in follow/tail mode. Replaces `▼`.
- Nothing is drawn at the bottom when the pane is at the bottom in non-follow mode.
- The indicator clears its cell's modifiers but **preserves the cell background**.

Panes with a reserved header/footer row (e.g. a tasks pane) may instead draw the same two glyphs
**centred** on that row — blank the row, then write the glyph at `x + width/2`. Pick per pane;
do not mix within one pane.

Do **not** confuse these with the disclosure triangles `▾` (U+25BE, open) / `▸` (U+25B8, closed)
used on collapsible section headers, or the timeline chevrons `▴` (U+25B4) / `▾` (U+25BE). Three
different triangle families, three different meanings — keep them distinct.

**Collision rule.** Before painting, inspect the indicator cell and the cell to its left. If
either has non-whitespace content, write `…` two cells left of the indicator and a space one cell
left, producing `content… ▼`. The `…` inherits the fg colour of the content it replaced; the
indicator uses the indicator colour; both preserve the cell background (so a selection highlight
survives).

---

## 9. Colour roles

The spec above names roles, not literals. This is the role table with the reference RGB values
for a Tokyo-Night-family dark theme, and the OSA token each maps onto.

| role | dark RGB | OSA token (`style/mod.rs`) |
|---|---|---|
| `bg_base` | `36,40,59` | theme background |
| `bg_highlight` | `41,46,66` | `selection_bg` |
| `text_primary` | `192,202,245` | `primary` |
| `text_secondary` | `169,177,214` | `secondary` |
| `gray_dim` (dimmest — meta punctuation) | `59,66,97` | `dim` |
| `gray` (medium — muted text, collapsed) | `86,95,137` | `muted` |
| `gray_bright` (tool accents, secondary labels) | `115,122,162` | between `muted` and `secondary` |
| `accent_user` | `122,162,247` | `msg_border_user` |
| `accent_assistant` | `187,154,247` | `msg_border_agent` |
| `accent_tool` | `115,122,162` | — (new) |
| `accent_thinking` | `59,66,97` | `thinking_header` base |
| `accent_success` | `158,206,106` | `success` |
| `accent_error` | `247,118,142` | `error` |
| `accent_running` | `187,154,247` | `tool_status_running` |
| `warning` | `224,175,104` | `warning` |
| `command` (shell yellow) | `224,175,104` | `code_keyword` family |
| `path` (orange) | `255,158,100` | `file_path` |
| `running` (cyan) | `125,207,255` | `tool_status_running` alt |
| `accent_plan` (golden) | `230,180,50` | `plan_selected` |
| `prompt_border` / `_active` | `60,75,120` / `75,92,140` | `prompt_border` |

OSA's palette struct is `ThemeColors` (`src/style/mod.rs:11-42`, 31 fields) with four built-in
themes (`src/style/themes.rs:18` dark, `:56` light, `:93` catppuccin, `:130` tokyo_night). The
roles above that have no OSA token yet (`accent_tool`, `gray_bright`, `accent_plan`) are the only
palette additions this design requires; everything else maps onto existing derived tokens listed
in `style/mod.rs` (`status_sep():634`, `status_glyph():639`, `context_bar_color():644`,
`msg_meta():120`, `spinner():127`, `spinner_verb():133`, `prompt_char():101`,
`input_placeholder():504`, `prompt_border():614`, `hint():270`, `help_key():540`).

Every decorative glyph must have a **same-width legacy fallback** resolved at startup from the
terminal's capability probe: `┃→│`, `❙→|`, `◆→♦`, `◇→○`, `◈→♦`, `⇣→↓`, `❯ →> `, `●→•`, `▏→│`, `↗→o`, `⧉→c`,
braille spinner → `|/-\`, dot spinner `⋅:⸬⁙` → `.:·`, `✓→√`, `✗→x`, `⚠→!`.
All colours quantise to truecolor / 256 / 16 / none. Multi-column glyph groups
(`[✗]`, `[↗]`, `❯ `) must keep their exact column count across the swap.

---

## 10. Input semantics: queue vs. interrupt

### 10.1 The rule

> **While a turn is running, Enter queues. It never interrupts.**
>
> Interrupting is always an explicit, separate gesture.

Everything below follows from that one sentence.

### 10.2 State machine

States: `Idle`, `Running`, `Cancelling`, `Blocked` (turn parked on a permission/question
overlay), `EditingQueued`.

```
                    Enter (text)                  turn ends
        Idle ─────────────────────────► Running ─────────────► Idle
          │                              │  ▲                    │
          │ Enter (text)                 │  │ drain next queued  │
          │  → send immediately          │  └────────────────────┘
          │                              │
          │                    Enter (text) while Running
          │                              │  → APPEND to queue, clear composer,
          │                              │    show "Queued · Enter to send now"
          │                              ▼
          │                          Running (queue = [..])
          │                              │
          │            Enter on EMPTY composer, queue non-empty
          │                              │  → SEND NOW: cancel the running turn
          │                              │    and run the top queued row next
          │                              ▼
          │                          Cancelling ──► Running(new prompt)
          │
          │  Esc (running, non-vim) ──► Cancelling ──► Idle   [queue survives]
          │  Esc (running, vim mode) ──► swallowed (Ctrl+C is the cancel gesture there)
          │  Esc (Blocked)          ──► swallowed (never kill the turn the card blocks on)
          │  Esc (Cancelling)       ──► re-send cancel (recovers a lost cancel notification)
          │
          └─ Esc (idle, composer non-empty) ──► arm; Esc again clears the composer
             Esc (idle, composer empty)     ──► arm; Esc again opens the rewind picker
```

### 10.3 Enter, precisely

At the moment Enter is pressed in the composer:

1. **Multi-line mode + non-empty composer** → insert a newline. (Exceptions: bash mode always
   sends; a slash dropdown that accepted a no-arg command always sends.)
2. **Composer has text + turn running** → **enqueue**. Clear the composer, drain any attached
   images into the queued entry, insert the text into up-arrow history, and show a
   seen-capped ephemeral hint reading `Queued · Enter to send now` (bold `Enter`, rest dim).
   Capped at 3 showings per session.
3. **Composer has text + idle** → send immediately as a new turn.
4. **Composer EMPTY + turn running + queue non-empty** → **send now**: cancel-and-send the
   **top** visible queued row (the one that would drain next). This is the double-Enter gesture,
   and it is why the hint in step 2 exists — after queueing, the composer is empty, so a second
   Enter is exactly this. In multi-line mode this path is checked *before* the newline insert,
   because inserting a blank line into an empty composer is never useful.
5. **Composer empty, nothing to send** → no-op (redraw only).

Note step 4 is only reached on a genuinely empty composer — a trailing-backslash continuation
also produces "no text to send" but leaves a non-empty draft, and must fall through to the
newline insert instead.

### 10.4 Explicit queue and interject chords

| gesture | action |
|---|---|
| `Ctrl+;` (alt `Ctrl+'`) | **toggle the queue pane** and focus it. Not "queue this message" — Enter already does that. Remap to `Ctrl+4` on terminal emulators that swallow `Ctrl+;`. |
| send-now chord (`Ctrl+Enter`, alt `Ctrl+I`; `Ctrl+L` on VS-Code-family terminals; `Ctrl+O` on Apple Terminal) | with composer text: cancel the running turn and run that text next. With empty composer + a queued row: same as bare Enter (send the top row now). Idle: no-op. On the queue pane: send the **selected** row now. |
| `Esc` | cancel — see the state machine. Never queues, never sends. |
| `Ctrl+C` | hard interrupt; escalates to quit while already cancelling. |

### 10.5 Queue pane editing

While the queue pane is focused:

| key | action |
|---|---|
| `x` / `Delete` / `Backspace` | delete the selected row |
| `e` / `Enter` | load the selected row into the composer for editing |
| `J` / `K` | reorder the selected row down / up |
| `y` | copy the row text |
| `j` / `k`, arrows, PgUp/PgDn | navigate |
| send-now chord | promote the selected row to run next |

**Edit hold:** while a row is being edited, the drain is blocked if that row is at the front, and
a combine pass stops before it if it is a follower. Deleting the row under edit exits edit mode
*before* the removal, so an auto-hide of the pane cannot fire while the edit lock is held.

### 10.6 Drain semantics

When a turn ends, drain **one** queued entry and start it as the next turn. Drain is blocked
when any of these hold:

- the session is not idle (a turn is still running or cancelling);
- a model switch is in flight;
- a session replay/load is in progress;
- the user is editing the front row;
- there is no bound session id;
- the server owns the next turn (a server-side queue entry that is not the running prompt).

Each blocked drain logs a reason with the queue depth — a silently stuck queue is the worst
failure mode this subsystem has, and it must always be explainable from the log.

**Combining is opt-in and defaults OFF.** With `combine_queued_prompts` enabled, the drain takes
the longest mergeable prefix of the queue and joins their texts with `"\n\n"`, sending one turn.
Merge eligibility:

- **Front** may merge if it is a plain user prompt, not synthetic (auto-wake / nudge), not a
  client-expanded skill payload, not a bash command, and has non-empty text. The front *may*
  carry images.
- **Followers** must satisfy all of the above **and** carry no images **and** not be under an
  edit hold.
- The run stops at the first ineligible entry.
- When ≥2 entries merged, the outgoing message carries a `combinedDisplayTexts` metadata array of
  the original per-prompt texts so the UI can still render them as separate bubbles.

### 10.7 Optimistic echo and reconciliation

A send-now dispatch paints the user block **immediately** and pushes an optimistic queue echo,
then reconciles against the authoritative queue broadcast. Two invariants:

- A send-now fired against a row whose own send is still in flight must **park**, not fire — a
  premature promote would overtake the row server-side and silently no-op. It fires on the
  confirming broadcast, carrying the row's authoritative version.
- A queue edit carries a monotonic `version`; an edit against a stale version is a no-op, not a
  clobber.

Wire shape for the queue broadcast (per session): `entries[]` of
`{id, version, owner?, lastEditor?, kind, text, combinedTexts?, position}` plus
`runningPromptId?`, `runningText?`, `runningKind?`, `runningCombinedTexts?`. The running row is
**omitted** from `entries` and carried in the `running*` fields — which is why the `+N` badge
subtracts the running prompt.

---

## 11. What OSA does today, and the port plan

### 11.1 Chrome gap table

| element | OSA today | action |
|---|---|---|
| header row | two-row status bar at the **bottom**; `components/header.rs:48` exists but is never drawn (its only caller is its own `Component::draw` at `header.rs:92`) | **Move** the identity row to row 0 or keep it at the bottom — but pick one and delete the dead component. |
| working directory | **basename only** — `components/status_bar.rs:1002`, field `cwd_basename` at `status_bar.rs:367`, set by `set_cwd_path` (`status_bar.rs:461-477`), called from `app/handle_backend.rs:837` | **Change to the `~`-collapsed full path** per §1.1. Keep the basename for the OSC-0 window title (`components/title.rs:29-49`) — that one is correct as-is. |
| context usage | 8-cell braille bar + percent — `status_bar.rs:1080-1091`, `braille_bar()` at `status_bar.rs:129-146` (`⣿`/`⢿`/`░`); unknown-window fallback prints `~52.1k ctx` at `status_bar.rs:1071-1078` | **Replace the default form with the fraction** (§1.3). Keep the bar as the **hover** form. Reuse `theme.context_bar_color` (`style/mod.rs:644`) for the gradient, re-pointed at the §1.3 breakpoints. `compact_tokens` (`status_bar.rs:311`) becomes the 4-char `fmt_tokens`. |
| `+N` queue badge | none | **Add** to the status item group next to context, per §1.4. Count source: `app/mod.rs:409` (`message_queue`). |
| timestamps | **already right-aligned and correct in shape** — `components/chat/message.rs:800-830` (`format_timestamp`, `2:34 PM` / `Mar 7, 2:34 PM`), placed by `build_header_line` at `message.rs:890-925`, dropped when it would collide (`message.rs:915`) | **Keep.** Two adjustments: reserve the 10 columns *before* wrapping rather than dropping on collision, and add the hover-expand form. |
| left accent rail | two rails already: per-message `Borders::LEFT` + `BorderType::Thick` (`message.rs:486-489` user, `:533-536` agent) and the live wave rail `draw_rail` (`components/activity.rs:1494-1521`, `RAIL_W = 2` at `activity.rs:1638`, glyph `heavy_rail()` `render/glyphs.rs:109`) | **Unify.** One rail owned by a block wrapper, width **1** (not 2), with the three states in §2.1. The wave logic in `activity.rs:1509` is the right implementation — lift it into the wrapper and delete the per-message `Block` border. |
| bullet glyph | `⏺` (U+23FA) on macOS / `●` (U+25CF) elsewhere — `tools/mod.rs:331-338`, used at `tools/mod.rs:346`, `tools/agent.rs:154`, `tools/collapse.rs:279`. Sub-results use `⎿` (`render/glyphs.rs:93`) | **Switch the default to `◆`** and make it configurable per §2.2. Keep `⎿` for result branches and `◐` for awaiting-permission (`tools/mod.rs:339-360`). Move bullet painting into the wrapper so it can share the rail's wave phase. |
| hook counter | **none in the chrome.** Hooks exist only as backend concepts: `client/sse.rs:1606` (`hook_blocked`), `app/commands.rs:54,633` (`/hooks`), `client/http.rs:346` | **Add** §3.1. Requires per-tool-call hook-run outcomes on the SSE payload. |
| turn-status line | `components/activity.rs:1602` — already very close: braille spinner (`render/glyphs.rs:153-166`, 133 ms cadence at `activity.rs:1665`), verb (`activity.rs:1108-1114`), elapsed (`fmt_compact_tight` `activity.rs:229-236`), `⇣12k` gated to ≥30 s (`activity.rs:1681`, `:1738-1744`), `↑ N in` (`:1751`), `⚡ N cached` (`:1755`), `N queued` (`:1775-1778`), `Cancelling…` red (`:1815-1823`), pulsing `◆` wait (`:1824-1831`) | **Mostly keep** — see §12. Changes: add the **right-aligned group** (today everything is one left-flowing parenthesised list), add the separate **phase timer** on the left, add the `[stop]` / `[↓]` mouse affordances, and change the spinner cadence to `tick/4` frames. Keep OSA's `esc to interrupt` text hint. |
| queued rows | **already exist** — `components/input/mod.rs:2686-2718`, prefix `⧖` (U+29D6), max 4 then `+N more queued`, backed by `queued_items` (`input/mod.rs:86`), set via `set_queued_items` (`input/mod.rs:388`), height via `queued_lines()` (`input/mod.rs:686`) | **Keep the placement.** Change prefix to `#{n} ` per §5, cap at 3, add the `(+N lines)` suffix and the kind styling. |
| keybind hint bar | no dedicated bar; a right-aligned width-tiered hint sits on the composer divider — `input/mod.rs:2773-2803` (`/ commands · @ files · # memory · shift+⏎ newline` at w≥88, degrading at 68/50), vim label at `input/mod.rs:2807-2825` | **Add** the dedicated bottom bar per §6, with `Enter:queue` while running as the headline item. The existing composer-divider hints move into it. |
| composer marker | **already `❯ `** — `components/input/mod.rs:2855-2862`, with `◈ ❯ ` while processing and two blanks when unfocused; styles at `input/mod.rs:2865-2871` | **Keep.** OSA already has the correct glyph. Optionally keep the `◈ ❯ ` processing variant as the "Enter will queue" signal called for in §7.2. |
| model/approval footer | model on status row 0 (`status_bar.rs:999`); permission mode on status row 1 as `⏵⏵ bypass permissions on` (`status_bar.rs:1372-1386`), separator `" · "` | **Move both onto the composer's bottom divider, right-aligned**, per §7.4. Note the dedup comment at `status_bar.rs:1029-1033` — the row-0 duplicate was already removed once; do not reintroduce it. |
| scroll markers | effectively none: the only `▼` is the table-clipped marker (`render/markdown.rs:627`, token `style/mod.rs:604`, tested at `layout_invariants.rs:2305-2335`); there is **no `▲`** anywhere; chat scrolling is delegated to the host terminal (`app/update.rs:994-996`, `:1162`) | **Add** §8 to the queue pane and any dialog list. Do **not** add them to the chat transcript — that stays terminal-native (see §12). |

### 11.2 Input/queue port plan — the real bug

OSA's current behaviour is **the opposite of §10.1**, at one site:

`src/app/handle_actions.rs:458-466`

```rust
if self.state == AppState::Processing {
    if text.starts_with('/') || text.starts_with('!') {
        self.enqueue_message(text);
    } else {
        self.chat.add_user_message(text);
        self.steer_message(text);
    }
    return;
}
```

A plain message typed mid-turn is **never queued** — it becomes a live mid-turn steer
(`steer_message`, `handle_actions.rs:495-523`, POSTing `client.steer_session()` at
`handle_actions.rs:512` and toasting "steering — folding into the current turn" at `:516-519`).
Only `/…` and `!…` reach `enqueue_message` (`handle_actions.rs:480-487`). That is the reported
"sometimes interrupts".

There are two further staleness holes that make it *inconsistent* rather than merely wrong:

**Hole 1 — parked turns read as idle.** The correct predicate already exists:
`turn_active(state, return_stack)` at `app/mod.rs:1258-1263`, exposed as `self.turn_is_active()`
at `app/mod.rs:845`, and already used correctly by the streaming gate (see the hazard note at
`app/handle_backend.rs:278-286`). But `submit_input` still compares
`self.state == AppState::Processing` (`handle_actions.rs:458`), as does `steer_message`
(`handle_actions.rs:504`) and the interrupt action dispatch (`app/keymap_dispatch.rs:237-246`).
About twenty overlays open *from* `Processing` and park the live turn on the return stack,
flipping `is_processing()` false — so with such an overlay up, Enter falls through to
`submit_prompt` (`handle_actions.rs:473`) and fires a **second concurrent `orchestrate` POST on
the same session** (`handle_actions.rs:704-722`).

**Hole 2 — early Idle inside a multi-generation turn.** `handle_agent_response` transitions to
Idle unconditionally at `handle_actions.rs:349-352`. `app/handle_backend.rs:352-359` assumes this
only fires at true completion, but `app/mod.rs:909-916` documents that one turn can contain
several assistant generations (ReAct re-entry, auto-continue nudge, coding nudge, verification
gate, goal verifier), and there is no `transition(AppState::Processing)` anywhere in
`handle_backend.rs` to re-arm the flag. Any non-terminal `agent_response` therefore leaves the
composer looking idle for the rest of a live turn. Worse, `maybe_dequeue_message`
(`handle_actions.rs:528-545`) guards only on `self.state != AppState::Idle`
(`handle_actions.rs:533`), so a premature Idle **auto-fires a queued message into a running
turn**.

**Ordered fixes:**

1. `handle_actions.rs:458` — route the `else` branch to `enqueue_message`. Steering becomes an
   explicit gesture only (`/steer`, registered at `app/commands.rs:25` — its description
   "queues if idle" is already stale and must be rewritten), plus the send-now chord in §10.4.
2. `handle_actions.rs:458`, `handle_actions.rs:504`, `app/keymap_dispatch.rs:237-246` — replace
   `self.state == AppState::Processing` / `is_processing()` with `self.turn_is_active()`
   (`app/mod.rs:845`).
3. `handle_actions.rs:349-352` — make the `Processing → Idle` transition conditional on a
   terminal response, and add the missing re-arm on continuation. Then tighten
   `maybe_dequeue_message`'s guard (`handle_actions.rs:533`) to `!self.turn_is_active()`.
4. Add the send-now path: bare Enter on an empty composer while a turn runs with a non-empty
   queue → cancel-and-send the top row (§10.3 step 4), plus the seen-capped
   `Queued · Enter to send now` hint. Cancel machinery already exists —
   `cancel_processing()` at `handle_actions.rs:725-762`, and it already preserves the queue
   across an interrupt (see the comment at `handle_actions.rs:737-739`).
5. Add `Ctrl+;` → toggle-queue-pane. There is no queue action in `config/keybindings.rs` today —
   the `Action` enum (`keybindings.rs:159-196`), its string map (`keybindings.rs:198-238`) and
   the defaults table (`keybindings.rs:351-377`) all need a `chat:queue` entry. Note Esc is
   deliberately non-rebindable (`app/update.rs:900-907`, `:1100-1106`, reserved list
   `config/keybindings.rs:292-316`) — keep it that way.
6. Change the composer submit hint to read `queue` (not `send`) whenever `turn_is_active()`.
   This is the cheapest possible fix for the *perceived* bug and should ship with fix 1.

### 11.3 Queue data model changes

Today: `pub message_queue: Vec<String>` (`app/mod.rs:409-413`, init `app/mod.rs:745`) — a flat
list of strings, flushed one at a time FIFO by `maybe_dequeue_message`
(`handle_actions.rs:539` `remove(0)` → re-enter `submit_input` at `:544`), called from three
sites (`handle_actions.rs:366`, `:420`, `app/handle_backend.rs:1248`).

Required additions to support §5 and §10:

- Per-entry `{id, version, kind, text, images, owner}` instead of a bare `String`.
- `kind` ∈ `{prompt, command, bash, cron}` to drive the row styling in §5.
- `version` for edit-vs-stale conflict detection.
- Stable ids so the pane's selection survives a reorder.

Keep the existing one-at-a-time FIFO drain; combining (§10.6) is a later, off-by-default
addition.

---

## 12. What OSA already does better — keep these

These are places where OSA's current design is the right one and this port must **not**
regress them.

1. **Terminal-native scrollback for the transcript.** OSA delegates chat scrolling to the host
   terminal (`app/update.rs:994-996`, `:1162`). This is strictly better than an in-app scroll
   region: it survives resize without re-wrapping frozen content, it keeps the terminal's own
   search and copy working, and it costs nothing to render. Do not add an in-app chat scrollbar
   or `▲`/`▼` markers to the transcript. Scroll markers belong only to bounded panes (queue,
   dialogs).

2. **`esc to interrupt` written out in words** (`activity.rs:114-120`), bound into the same
   width-budget group as the timer (`activity.rs:1716-1720`) so it survives narrowing. A literal
   `[stop]` button is a mouse affordance; the words are the discoverable keyboard affordance.
   Ship **both**, and never let the width budget drop the words in favour of the button.

3. **Double-Esc to interrupt with an 800 ms arm window** (`app/update.rs:1114-1135`,
   `EscTracker` at `app/keys.rs:7-11`, arm at `:1128`, toast at `:1130`, reset on any non-Esc key
   at `app/update.rs:1079-1082`), with **Ctrl+C as the single-press hard interrupt**
   (`app/update.rs:1136-1142`). This is safer than a single-press Esc cancel and the toast makes
   it discoverable. Keep it.

4. **The queue survives an interrupt** — `cancel_processing` explicitly preserves it
   (`handle_actions.rs:737-739`). Correct: interrupting the current turn is not a statement about
   the messages you lined up behind it.

5. **`↑` on an empty composer mid-turn pulls the whole queue back into the composer**
   (`pop_queue_to_composer`, `handle_actions.rs:551-565`, joined oldest-first with the current
   draft appended last via `join_queued_for_composer` at `:556`; bound at `app/update.rs:1146-1151`
   and from idle-Esc at `app/update.rs:936-940`). This is a genuinely better "undo my queueing"
   gesture than deleting rows one at a time. Keep it, and keep it distinct from the destructive
   `x` in the queue pane.

6. **Backslash line continuation** (`input/mod.rs:2369-2385`) as a universal newline escape,
   independent of whether the terminal reports Shift+Enter. Keep — and keep the §10.3 guard that
   a backslash continuation must not be mistaken for an empty composer.

7. **Paste-burst newline suppression** (`input/mod.rs:2339-2354`) — a pasted multi-line block
   does not fire N submits. Keep.

8. **Large-draft collapse pill** `[… N chars …]` (`input/mod.rs:2912+`) — keeps a pasted wall of
   text from eating the screen. Keep.

9. **a11y plain-text status line** (`activity.rs:1614-1627`, e.g.
   `OSA: running (bash) (12s, 1.5k tokens)`) — a screen-reader-safe rendering of the animated
   row. None of the chrome in this document may exist *only* as glyphs; every animated or
   glyph-encoded state needs a text equivalent here.

10. **Rotating example placeholders** (`input/mod.rs:466-470`, `:729-732`, list at
    `input/mod.rs:3200+`) re-rolled on each submit. Richer than a single fixed string. If a fixed
    placeholder is adopted for brand reasons, keep the rotation as an option — and keep the
    existing behaviour of switching the placeholder to a queue hint when the queue is non-empty
    (`input/mod.rs:466-470`).

11. **The verb is held stable for the whole turn** (`activity.rs:1108-1114`) rather than flapping
    per token. Keep.

12. **Token counter gated to ≥30 s** (`activity.rs:1681-1682`) and eased rather than jumping
    (`ease_tokens`, `activity.rs:266`). Keep both — an instantly-appearing, jittering counter
    reads as noise.

---

## 13. Implementation order

1. **Fix 6 then fix 1** from §11.2 — the submit hint plus real queueing. Highest
   perceived-quality gain per line changed, and it removes a data-loss class (a steered message
   that derails a turn is unrecoverable).
2. Fixes 2 and 3 — the two staleness holes. These are correctness, not cosmetics.
3. Header row: full path + context fraction + `+N` badge (§1).
4. Queue rows `#N` + the dedicated keybind hint bar (§5, §6).
5. Unified 1-column accent rail + `◆` bullet moved into the block wrapper (§2.1, §2.2).
6. Turn-status right-aligned group, phase timer, `[stop]` (§4).
7. Composer bottom-divider model/approval footer (§7.4).
8. Hook counters (§3.1) — gated on the SSE payload carrying per-tool hook outcomes.
9. Scroll markers on bounded panes (§8).

Each step gates on `cargo build` + `cargo test` for the TUI crate and a **visual** check against
the layout-invariant tests (`priv/rust/tui/src/layout_invariants.rs`) — layout tests staying green
has previously coexisted with a visibly broken screen, so green tests are necessary and not
sufficient.
