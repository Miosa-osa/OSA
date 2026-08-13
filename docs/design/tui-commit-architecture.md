# TUI commit-to-scrollback architecture

Status: design specification. Describes the intended architecture for OSA's
inline TUI (`priv/rust/tui`), and the migration path from what is there today.

**The change in one sentence:** delete the live activity band — the growing and
shrinking stack of `┊ $ executing <cmd> 1.2s...` rows above the composer — and
replace it with committed one-line tool summaries in native scrollback
(`◆ Read 1 skill, Searched 8 patterns, Listed 4 dirs, Read 2 files`), leaving the
pinned live region holding only the task panel, the running-turn status row, the
composer, and the tail of whatever is still streaming.

All file:line citations are OSA's, relative to `priv/rust/tui/src` unless
otherwise noted. Where this document describes a mechanism OSA does not have
yet, it specifies the mechanism directly; a reference harness that already
implements this shape was studied while writing it, and its reasoning is folded
in below in our own words.

**Contents**

- Part 1 — the commit architecture (§1.1–§1.8)
- Part 2 — **the aggregated tool summary line**, in full detail
- Part 3 — **the hook counter**
- Part 4 — **the task panel and plan commit**
- Part 5 — where OSA stands today
- Part 6 — migration plan
- Part 7 — ordering constraints and risks

---

# Part 1 — The commit architecture

## 1.1 Two surfaces, one frontier

The TUI has exactly two surfaces, and they have opposite mutability:

| Surface | Owner | Mutability |
|---|---|---|
| Native terminal scrollback | the terminal | **print-once, frozen forever** |
| Pinned inline viewport ("live region") | ratatui | repainted every frame |

The conversation is one ordered list of entries. A monotonic **committed
frontier** divides it:

```
entries: [ e0 e1 e2 e3 | e4 e5 ]
           \_ committed _/  \_ live tail _/
             (printed once      (repainted
              via insert_before)  every frame)
```

Everything left of the frontier has been `insert_before`'d into the terminal's
scrollback and can never change. Everything right of it is re-rendered into the
pinned viewport each frame. The frontier only moves right.

The property that makes this not jump on screen: **a block is rendered by the
same renderer, at the same width, with the same display mode, on both sides of
the frontier.** The only permitted difference is the animation tick — and the
tick must never change a block's height. That is a testable invariant and it
must be pinned by a test, not by discipline.

## 1.2 Committability: what holds a block back

The frontier is computed by a single classification step applied to entry `i`:

- entry missing → **stop**
- already committed → **skip** (the committed-id set is authoritative; a scan
  cursor is only a lower-bound hint to avoid rescanning from zero)
- not committable → **stop** (the live tail starts here)
- otherwise → **commit**

The committability predicate takes the entry, whether a turn is currently
running, and whether the entry is the last one:

1. **Awaiting user input → never committable, in any turn state.** A tool blocked
   on a permission prompt or an `ask_user` question pins the frontier *before*
   itself, so it and everything after it stay live and visible underneath the
   modal. This is the whole mid-stream permission hold, and it falls out for
   free from the frontier rather than needing its own machinery. It must apply
   when idle too: a pending mark must never be committed out from under its
   modal, because the rendered "waiting" form would freeze on the terminal.
2. **Turn not running → committable.** Once the turn is idle every remaining
   entry is stable. A stale "still running" flag left behind at a phase
   transition must not permanently wedge the frontier; the commit pass finalizes
   such entries before rendering so they print in finished form.
3. **Not running → committable.**
4. **Running, mid-turn → held**, with two exceptions:
   - A **background-task lifecycle** block. Its running flag drives bullet
     animation only; the block's content never changes, because task completion
     pushes a *separate* block. An async task can outlive its turn, so gating on
     the flag would wedge the frontier for the rest of the turn and the task
     would be invisible until it finished.
   - A **non-last assistant message**. The tracker moves past a message without
     finishing it when a tool follows, leaving a stale running flag; but a
     message with a later block after it is provably complete and will never be
     appended to again. A running **tool** keeps the strict gate (its result may
     still update), and the **last** entry always stays live.

Two hard consequences of print-once:

- **A failed terminal write must not mark the entry committed.** The commit walk
  stops on failure with the entry still uncommitted and the cursor before it, so
  the next frame retries. Marking a never-printed block committed loses it
  permanently — a print-once surface can never re-emit it.
- **In-place mutation of a committed entry never reaches the screen.** Any
  handler that fills a placeholder must check whether the entry is already
  committed and *append a fresh block* instead of editing.

## 1.3 One walk, four consumers

The frontier walk exists twice: a **read-only projection** returning
`{ tail_start, will_commit }`, and a **mutating pass** that drives the actual
`insert_before`. Both share one classification function.

This sharing is load-bearing, not tidiness. Four things must agree on where the
frontier stops:

1. the commit pass,
2. the `will_commit` gate that selects the viewport resize strategy,
3. the viewport sizing (which measures the *post-commit* tail),
4. the tail renderer (which renders from the same start index).

If any two disagree, a block's height flips between the live region and native
scrollback and the composer jumps on every commit.

## 1.4 Display policy — folded on commit, folded in the tail too

Blocks stream expanded and commit folded. The display mode a block commits in:

| Block | Committed as |
|---|---|
| Edit / diff | **Expanded** — diffs always print in full |
| Successful read / search / list / memory-search | **Collapsed** — the one-line summary |
| Any other tool call, including shell execute | **Truncated** — header + capped output |
| Reasoning | **Collapsed** when the collapse-reasoning setting is on, else Expanded |
| Everything else | Expanded |

The non-obvious half: **after committing, the same display mode is stamped onto
every still-uncommitted tail entry.** Without this the live region is tall while
a block streams and snaps short the instant it finalizes, jerking the composer
upward. Matching the tail height to the committed height keeps the composer put
across a commit. The stamp is idempotent.

Two further rules that protect height parity:

- **Inter-block gap is a single constant applied identically on both sides of the
  frontier.** It is `0` today (adjacent blocks abut and rely on their own bullet
  chrome to read the boundary — a blank row per block made short collapsed
  blocks too airy), but it stays a named constant so the spacing is tunable in
  one place, and so it cannot be applied on one side only.
- **Timestamps are forced off in committed appearance.** The height calculation
  subtracts the timestamp column while the renderer treats it as an overlay, so
  leaving them on makes the reserved `insert_before` height disagree with the
  painted rows. Block horizontal padding is zeroed at the same time so committed
  content is flush-left with the welcome banner, and the live region's task
  panel, status, info, and prompt rows share that left edge — one column-0
  gutter, so the `◆` bullets, the task glyphs, and the `❯` prompt all line up.

## 1.5 The pinned live region

Layout, top to bottom:

```
live tail        (bottom of the uncommitted run — streaming reply / running tool)
task panel       (optional, auto-hiding, capped — Part 4)
side panel       (optional)
status row       (exactly 1 row)
composer         (grows as you type)
overlay OR info  (dropdown, else the 1-row model · mode · context · hint bar)
```

- **Tail.** Starts at the shared frontier stop index and renders every entry from
  there to the end, **bottom-anchored**, clipping the topmost visible entry by a
  skip-rows offset when the run is taller than the area. When idle the tail is
  empty and only the task panel, status, and composer show.
- **Status row — exactly one row, always.** It carries the rich turn state: the
  concrete activity (`Run …`, `Thinking…`, `Waiting on subagent…`,
  `Retrying (attempt N)…`, `Cancelling…`), the timers, and the "N still running"
  cue for background work. It is the *only* in-turn progress surface besides the
  task panel. When there is nothing to show it degrades to a short idle hint.
- **Info bar — one row below the composer.** Model (+ reasoning effort) · mode
  flag · context usage absolute and percent · `N queued` · transcript hint.

**Height policy: content-sized, not bottom-pinned.** The viewport height is the
exact sum of its content — `tail + task panel + side panel + 1 (status) +
overlay + composer` — clamped between a small floor and `terminal_rows - 1`.

Two deliberate non-choices:

- **Not bottom-pinned.** When the conversation is short the composer sits right
  below the last block with blank space beneath it. Once the conversation fills
  the screen, "right after the content" *is* the bottom. Forcing the viewport to
  the bottom edge leaves a large blank gap under a short conversation.
- **Modals do not grow to the ceiling.** A centered modal grows to a moderate
  capped height, and its inner content scrolls. Growing to the full ceiling and
  shrinking on close leaves a screen-tall blank band, because rows already
  scrolled into native scrollback cannot be pulled back.

One special case: a **prompt-replacing modal** (permission / question / rewind)
sizes to fit the live tail *above* it plus the status row between them. The tool
the ask concerns is held in the tail by the pending-input rule, and the tail is
exactly where its diff or command preview lives. Without reserving those rows the
viewport collapses to just the modal and "Allow Edit to …?" appears with no
visible diff.

## 1.6 Reasoning and the expand toggle

Reasoning renders as `Thinking…` while running and `Thought for 14.5s` when
finished — sub-minute durations to one decimal, longer ones as `{m}m{s}s`.
Collapsed, it is the header line only, truncated to width, with an expand hint
appended.

Reasoning is the **only** block that keeps the left accent column, as the marker
separating it from the answer — and only while expanded. Collapsed reasoning
drops the accent, because reserving a gutter column nothing paints would indent
the header over blank space, and a folded `Thought for Xs` header cannot be
mistaken for the answer anyway. The rule to enforce by test: **reserved equals
painted.**

**Expanding a committed block is an honest re-print, not a toggle.** Committed
terminal text is immutable, so:

1. On commit, if the stamped mode was collapsed or truncated, record the entry id
   in a "foldable, committed" set — **only after the print actually succeeded**.
2. The expand keybinding pushes that id onto a pending-expand queue.
3. Each frame, drain the queue: flip the entry to expanded and `insert_before` it
   **again**, below the committed conversation.

The re-print is **uncapped**. The initial commit truncated the block under the
row cap, and this is the explicit "show me the whole thing" action — capping it
again just reprints the same footer. A one-shot, user-initiated tall insert is
acceptable.

Guards are not optional. A zero-width probe frame, a missing view, or an open
modal must leave the ids **queued** for a later frame, never silently dropped;
and a failed write must requeue the current id and everything after it. Since the
entry is already past the frontier, flipping its display mode has no effect on
the live tail.

## 1.7 Per-frame draw order, and why it is that order

```
0.  open synchronized update; adopt the current terminal size
1.  sync pending user-input marks
2.  commit any pending banner / plan block
3.  SIZE the viewport to its POST-COMMIT height
4.  COMMIT finalized blocks into native scrollback
5.  re-print any queued expands
6.  DRAW the live region (tail · task panel · status · overlay · composer)
7.  close synchronized update
```

**Why size before commit.** The viewport must already be at its post-commit
height when `insert_before` runs, so that `insert_before` can print the finalized
block, scroll the overflow into native scrollback, and reposition the
correctly-sized viewport to sit directly after it. If the viewport is still at
its tall streaming height at commit time, the shrink that follows strands the
composer at the top of the screen — the "input snaps to the top" failure.

**Why adopt the terminal size up front.** The frame's own autoresize is the
*last* step, but the commit pass reads the viewport width *first*. On the frame
that processes a resize, a block finalizing in that same frame would be laid out
and printed at the **stale** width; a subsequent shrink then hard-wraps every
over-wide row on the real terminal, permanently garbling the print-once copy.
Adopting the new size up front closes that window and is a no-op on every
non-resize frame.

**Why the synchronized update wraps the commits, not just the draw.** Each
`insert_before` scrolls, repaints, and flushes. Without a synchronized update
around them, a multi-block commit (reasoning + tool + message finalizing
together) presents as several visible scroll-and-paint bursts before the live
region repaints. Opening the update *before* the first commit batches the whole
frame — commits, viewport reposition, and live redraw — into one atomic present.
A redundant inner `Begin` is harmless: the synchronized-update DEC mode is a
mode, not a counter, so the first `End` closes it.

**Why pending marks sync once, up front.** The viewport sizing, the `will_commit`
gate, and the commit pass must judge committability against the *same* marks.
Syncing inside the commit pass lets a just-arrived permission's tool look
committable to the sizing walk for exactly one frame — which is one frame of
visible jump.

**Two resize paths, selected by `will_commit`:**

- **A commit follows** → pre-set only the viewport *height*, keeping the current
  top, using the raw area setter. `insert_before` then performs its own clear,
  scroll, and reposition; doing a clear-and-scroll immediately beforehand is
  redundant work that fights it.
- **No commit this frame** (overlay open/close, idle composer edits) → use the
  top-fixed height setter, which keeps the viewport anchored right after the
  content, scrolls committed rows up into native scrollback on a grow (preserving
  them), and clears the vacated rows on a shrink (wiping stale dropdown content).

**Commits are held while a centered full-region modal is open.** The modal owns
the whole live region, so an `insert_before` underneath it would scroll the
popup. Deferred commits flush on the first frame after it closes.

## 1.8 Commit height cap

Each committed block is capped at a configurable row limit (order of 2000 rows).
When a block exceeds it, only the top `cap - 1` content rows are committed and the
final row becomes:

```
… N more lines — /transcript to view
```

**The technique matters:** the block is laid out at its **full** height so
wrapping is byte-identical to an uncapped commit, but the `insert_before` buffer
is only `cap` rows tall, so overflow is *clipped* rather than re-wrapped. This is
what bounds the allocation and the writer burst for a multi-thousand-line diff
without changing where any surviving line wraps. The footer row is styled first
(clearing any clipped content that landed on it), then the text is written.

---

# Part 2 — The aggregated tool summary line

This is the headline surface. A run of consecutive foldable tool calls collapses
to a **single committed row**:

```
◆ Read 1 skill, Searched 8 patterns, Listed 4 dirs, Read 2 files
◆ Searched 7 patterns, Read 6 files
◆ Read 3 files, Listed 1 dir  [hooks: 12 ok]
```

## 2.1 The vocabulary — every tool type

Two functions live on the **kind**, never in the formatter. Putting tense and
plural on the kind is what stops a newly-added tool from silently rendering as
`Ran 1 tools`.

| Semantic kind | Source tools | `verb(past)` | `verb(running)` | `noun(1)` | `noun(n)` | Folds eagerly? |
|---|---|---|---|---|---|---|
| **File** | file read (`read`, `read_file`, `cat`, `head`, `tail`, and read-only shell pipelines) | `Read` | `Reading` | `file` | `files` | yes |
| **Skill** | a read whose path is a skill definition, and skill/slash-command invocations | `Read` | `Reading` | `skill` | `skills` | yes |
| **Search** | pattern search — grep / glob / rg / `search` | `Searched` | `Searching` | `pattern` | `patterns` | yes |
| **Dir** | directory listing — `ls`, `list_dir`, `tree` | `Listed` | `Listing` | `dir` | `dirs` | yes |
| **WebFetch** | URL content retrieval | `Fetched` | `Fetching` | `website` | `websites` | yes |
| **WebSearch** | web search, incl. social search | `Searched` | `Searching` | `website` | `websites` | yes |
| **MemorySearch** | memory search | `Searched` | `Searching` | `memory` | `memories` | yes |
| **IntegrationSearch** | MCP tool *discovery* (`search_tool`) | `Searched` | `Searching` | `MCP tool` | `MCP tools` | yes |
| **Subagent** | subagent lifecycle rows | `Ran` | `Running` | `subagent` | `subagents` | yes |
| **Command** | shell execute | `Ran` | `Running` | `command` | `commands` | **label-only** |
| **EditFile** | file edit **and file write** | `Edited` | `Editing` | `file` | `files` | **label-only** |
| **McpCall** | MCP tool *dispatch* (`use_tool`) | `Called` | `Calling` | `MCP tool` | `MCP tools` | **label-only** |
| **OtherTool** | anything unclassified | `Ran` | `Running` | `tool` | `tools` | **label-only** |
| *(lifecycle chrome)* | `session_start`, `user_prompt_submit`, … | — | — | — | — | never labelled |

Notes on the table:

- **There is no separate "write" kind.** A write is an edit block, so it labels as
  `Edited N files`. This is deliberate: the reader cares that files changed, not
  which syscall did it.
- **A read of a skill file counts as a skill, not a file.** That is why
  `Read 1 skill, … , Read 2 files` legitimately shows the verb `Read` **twice** in
  one line: they are two different buckets with two different nouns, and merging
  them would hide that a skill was loaded.
- **"Label-only" kinds** never fold eagerly — a shell command or a diff is usually
  the most interesting thing on screen and gets its own block. Their vocabulary
  still exists because a *truncation* header (§2.6) must be able to say
  `Ran 6 commands` about rows it is hiding.
- **Pluralization is strictly `count == 1 ? singular : plural`.** No special
  cases, no zero form (a bucket with zero calls does not exist).
- **`dir` / `dirs` is abbreviated on purpose.** The line is a single row competing
  for width with three or four other clauses; `directories` costs 8 columns for
  no information. Same reasoning for `MCP tool`. **This conflicts with OSA's
  current wording** (`Listed N directories`, `Searched for N patterns`,
  `Ran N shell commands` — `tools/collapse.rs:228-257`, asserted at
  `tools/collapse.rs:665-703`). Adopt the terse forms; they are what the target
  line looks like.

## 2.2 Clause ordering, separator, spacing

- **Ordering is call order, not category order.** Buckets are held in a `Vec` and
  looked up linearly by kind; a kind seen for the first time is **appended**. So
  the clauses appear in the order their first call happened. `Read 1 skill,
  Searched 8 patterns, Listed 4 dirs, Read 2 files` is a literal trace: a skill
  was loaded, then searching started, then listing, then more file reads.
  A fixed category order would destroy that reading.
- **Separator is `", "`** — comma, one space. Built as: for bucket index `i`,
  emit `if i == 0 { "" } else { ", " }` then `verb SP count SP noun`. There is no
  trailing separator and no Oxford-comma special case.
- **The whole label is one styled span run** on a single row, in a bright-gray
  bold text style, preceded by the tool bullet and one space.

## 2.3 The aggregation window — what collapses into one line

A run is a **maximal consecutive sequence** of entries, classified one at a time:

| Classification | Meaning | Counts? | Breaks the run? |
|---|---|---|---|
| **Member(kind)** | a *collapsed*, eagerly-foldable tool call or subagent row | yes | no |
| **ThoughtMember** | a *finished, collapsed* reasoning entry | **no** | **no** — reasoning never breaks a run; it folds to height 0 and is invisible in the label |
| **Transparent** | hidden or still-streaming reasoning, **or a manually expanded member** | no | **no** — it renders its own rows without splitting the group |
| **Break** | anything else | — | **yes** |

So the run ends at the first of:

1. **assistant prose** — text between tool calls closes the group and starts a new
   one on the next call. This is the common case and it is what makes each line
   correspond to "what the agent did before it next spoke".
2. **a non-foldable tool** — a shell command, an edit/write, an MCP dispatch. It
   gets its own block; the pending group is emitted *before* it so the transcript
   stays chronological.
3. **a tool awaiting user input** — a permission or question prompt. It is not a
   member (members require *not* pending), so it breaks. Its own row stays live
   and standalone under the modal.
4. **end of the entry list.**
5. **turn end** — flushes whatever is open.

**One member is enough to fold.** There is no minimum of two. A compact label
beats the member's own row even at N=1, and emitting the header with the *first*
call avoids a visible fold-in jump when the second arrives.

A run consisting only of reasoning never folds — thought members do not count, so
the label would be empty.

## 2.4 Deduplication of counts

Default: **counts are per call, not deduplicated.** Reading the same file twice
is `Read 2 files`. The line reports work done, not distinct objects touched.

Two kinds override this with a **distinct-source set**, whose size replaces the
call count when non-empty:

- **WebSearch** dedupes by **citation URL**, so `Searched 12 websites` means
  twelve distinct sites, not twelve requests. A search returning overlapping
  citations does not inflate the number.
- **Subagent** dedupes by **child session id**, so a subagent's "started" row and
  its terminal row count once, while a burst of terminal rows from several
  workers counts each distinct worker.

OSA additionally dedupes read *paths* today (`tools/collapse.rs:210-212`) — but
for a different purpose: to **name** the files (`Read main.rs, lib.rs +3 more`)
rather than to count them. Keep that; see §2.7.

## 2.5 Prefix glyph, and the running form

- **Finished group:** the tool bullet `◆`, then a space, then the label.
- **Still-running group:** the *same* row. There is no second row shape. The
  header is rebuilt from the same walk every frame; the only difference is a
  `running` flag set when **any** member is still running, which flips
  `verb(running)` to the present participle.

So the row reads `◆ Reading 2 files` mid-flight and becomes `◆ Read 3 files` the
instant its last member closes. **The running line still shows counts** — the
count so far — it does not degrade to a spinner or a generic "working". Nothing
else churns beside the label while the run executes; per-call detail never
appears next to it.

The header row's chrome also carries state: a running group wears the animated
accent, a group with any failure wears the error accent. Failure is additionally
carried in **words** (`· 2 failed`) and, where OSA already does it, in the
**glyph** (`✗` instead of `◆`) — colour alone is unreadable under `NO_COLOR` and
to colour-blind readers.

## 2.6 Overflow — many distinct kinds

There is **no cap on the number of clauses**. Every bucket gets a clause; the row
is not shortened by dropping buckets, because a dropped bucket is a lie about
what happened.

The row is a single line, so it is **truncated at the right edge by the content
width** like any other one-row block. On a narrow terminal the tail clauses are
cut. This is accepted: the leading clauses are the earliest work, and the full
detail is one `/transcript` away.

A separate, related label family handles a *different* overflow — a fold that
hides N rows entirely (`… +N more`). That family uses the **same** bucket
vocabulary so the two can't drift, but it has one extra rule: if **any** hidden
participant has no bucket (lifecycle chrome, a system row), it **declines** and
the caller renders the exact numeric `+N more` instead. Reasoning is the only
participant a label may silently omit. A label that under-describes what is
hidden is worse than a bare number.

## 2.7 OSA port plan for the summary line

**Target:** `tools/collapse.rs`, with drive points in `app/handle_backend.rs`.

OSA already has the right shape and one family too few.

1. **Add verb/noun to the kind.** `ToolKind` (`tools/collapse.rs:16-41`) currently
   has `Search / Read / List / Shell / Mcp(String) / NonCollapsible`. Extend to
   the §2.1 table — add `Skill`, `WebFetch`, `WebSearch`, `MemorySearch`,
   `Subagent`, `EditFile`, `McpCall`, `OtherTool`, and split `Mcp` into discovery
   vs dispatch — then:
   ```rust
   impl ToolKind {
       pub fn verb(&self, running: bool) -> &'static str;
       pub fn noun(&self, count: usize) -> &'static str;
       pub fn folds_eagerly(&self) -> bool;   // false for the label-only kinds
   }
   ```
   `classify()` (`tools/collapse.rs:44-67`) gains the new arms. The skill split is
   a path test on the read target, mirroring how `extract_read_path`
   (`tools/collapse.rs:136-138`) already recovers the path.

2. **Replace the per-kind counters with an ordered bucket list.** Delete
   `search_count / read_paths / read_ops / list_count / shell_count /
   mcp_server / mcp_count` (`tools/collapse.rs:177-185`):
   ```rust
   struct Bucket {
       kind: ToolKind,
       calls: usize,
       read_paths: Vec<String>,          // Read bucket only, for naming
       sources: std::collections::HashSet<String>, // distinct-count override
   }
   pub struct Accumulator {
       buckets: Vec<Bucket>,
       any_error: bool,
       failed: usize,
       running: bool,
   }
   ```
   `add()` (`tools/collapse.rs:199-226`) becomes: linear `position` lookup on the
   family key, **append on miss**. Append-on-miss *is* the ordering rule of §2.2.

3. **Delete `family_matches`** (`tools/collapse.rs:194-196`) and the
   flush-on-kind-change at `app/handle_backend.rs:577-579`. A different foldable
   kind now joins the same run in its own bucket instead of emitting a second
   line. This single change is what turns three lines into one.

4. **Rewrite `summary_text()`** (`tools/collapse.rs:228-257`) as the §2.2 join
   loop. Keep `named_read_summary` (`tools/collapse.rs:150-164`) as a **special
   case for a run whose only bucket is Read** — naming files is strictly more
   informative than counting them, and it is OSA's own improvement. With more
   than one bucket, fall back to the count form so the row stays one line.

5. **Add a running form.** `Accumulator::live_line()` beside `take_summary_line()`
   (`tools/collapse.rs:261-295`), rendering the same buckets with `running = true`
   and no reset. Both must be produced by **one** function returning a `Line` —
   two code paths will drift and the composer will jump.

6. **Keep and extend the failure treatment.** The `✗` glyph plus the word
   `(failed)` (`tools/collapse.rs:272-293`) already beats colour-only; add the
   `· N failed` count when more than one member failed.

7. **Audit every break site** (§2.3) in `app/handle_backend.rs:12-17`
   (`flush_collapse`), `:557-585`, and `app/handle_actions.rs:244`. The flush must
   run **before** the interrupting block is pushed — a missed site reorders the
   transcript permanently, and this is print-once.

**Tests** (extend `tools/collapse.rs`'s existing modules): `Skill, Search×8,
List×4, Read×2` yields exactly `Read 1 skill, Searched 8 patterns, Listed 4 dirs,
Read 2 files`; bucket order follows first appearance; `1 dir` vs `4 dirs`; a lone
read run still names its file; a run of one folds.

---

# Part 3 — The hook counter

The trailing bracket on a summary row:

```
◆ Read 3 files, Listed 1 dir  [hooks: 54 ok, 19 failed]
◆ Ran 2 commands              [hooks: 9/1]
```

## 3.1 What a hook is

A **hook** is a user-registered handler that runs around a tool call or a session
lifecycle event. Hook runs are **not standalone transcript entries** — they are
attached to the tool call they wrapped, so a hook never costs a row of its own.
The attachment has three lanes:

- `pre_tool_use` hooks — run before the tool,
- `post_tool_use` hooks — run after it,
- lifecycle hooks — `session_start`, `session_end`, `stop`, each carrying its own
  event name.

Each individual run has one of four outcomes:

| Outcome | Carries | Counted as |
|---|---|---|
| **Success** | elapsed | `ok` |
| **Blocked** | detail + elapsed | `blocked` — a stop-gate *decision*, not a failure |
| **Failed** | error + elapsed | `failed` |
| **Skipped** | — | **not counted at all** |

The Blocked/Failed distinction is the important one: a hook that deliberately
denies an action ran correctly. Only Failed means the hook itself broke.

## 3.2 Where the counts come from, and their scope

Counts are **per group, not cumulative for the session.** The tool block carries
its own hook data; the group accumulator sums across the members of the run it is
labelling, and resets with the run. A row that says `54 ok` means fifty-four hook
runs happened across the calls in *that* line.

Crucially, hook counts are summed **only for verb-run headers** — the aggregate
rows where no per-member detail is visible. A truncation header (`+N more`)
does *not* absorb them, because the members it hides will show their own.

## 3.3 The two bracket shapes

Both are a suffix appended to an existing row, opening with **two spaces** then
`[hooks: `, and closing with `]`.

**Labeled shape — used on aggregate/group rows.** Names every outcome, because no
member detail is visible to explain the numbers:

```
  [hooks: 54 ok, 19 failed]
  [hooks: 54 ok, 3 blocked, 19 failed]
  [hooks: 54]                            ← blocked == 0 AND failed == 0
```

- Fixed order: `ok`, `blocked`, `failed`. Zero-count outcomes are **omitted
  entirely**, never printed as `0 ok`.
- Segment separator is `", "`; each segment is `count SP label`.
- Special case: when both blocked and failed are zero, the label word is dropped
  and only the bare success number appears — `[hooks: 54]`. There is nothing to
  disambiguate, so the word is noise.

**Compact shape — used on individual rows.** A `completed/failed` ratio:

```
  [hooks: 9/1]
  [hooks: 9]      ← failed == 0
  [hooks: 1]      ← completed == 0 is impossible unless only failures; then "[hooks: 3]" in error colour
```

- `completed` = **success + blocked**. Blocked hooks completed normally, so they
  stay in the green numerator. This is the established contract for individual
  rows, where the member's own detail explains any block.
- The `/` separator is emitted **only when both sides are non-zero**.

**Colour roles** (all numbers additionally carry the DIM modifier so the bracket
recedes below the label it trails):

| Element | Role |
|---|---|
| `  [hooks: `, `]`, `, `, `/` | muted / chrome tier |
| the `ok` (or completed) number | success accent + DIM |
| the `blocked` number | running/warning accent + DIM |
| the `failed` number | error accent + DIM |
| the `ok` / `blocked` / `failed` words | same colour as their number |

## 3.4 Zero case

**When the total run count is zero, the entire suffix is omitted** — no brackets,
no `[hooks: 0]`, no trailing spaces. The function returns nothing and the row
renders exactly as it would with no hooks configured. A user with no hooks never
sees the word "hooks" in their transcript.

Note that Skipped runs do not contribute to the total, so a group where every
hook was skipped also renders no bracket.

## 3.5 OSA port plan for the hook counter

**OSA's honest equivalent** is the agent hooks subsystem at
`lib/optimal_system_agent/agent/hooks.ex`, with implementations in
`lib/optimal_system_agent/agent/hooks/shell_hook.ex` and `http_hook.ex`, and user
documentation at `docs/features/hooks.md`.

The outcome vocabulary maps **exactly**, which is the good news. From
`hooks.ex:36-37`, a handler returns:

| OSA return | Maps to |
|---|---|
| `{:ok, payload}` / `:allow` | **Success** |
| `:skip` | **Skipped** (uncounted) |
| `{:block, reason}` / `{:deny, reason}` | **Blocked** |
| a raised error / crash | **Failed** |
| `{:rewrite_input, input}` | **Success** (it continued) |

and `run/2` is specified as `{:ok, map()} | {:blocked, String.t()}`
(`hooks.ex:125`). Hooks are registered per event (`hooks.ex:64` `hook_event`,
`:114` `register/4`) with a priority ordering, and there is a fire-and-forget
`run_async/2` (`hooks.ex:132`) for post-events.

**The gap is the wire, not the model.** The TUI today knows almost nothing about
hook runs:

- `event/backend.rs:432` — `HookBlocked { hook_name, reason }` is the *only*
  per-run event, and it only covers the blocked case.
- `event/backend.rs:464` — `HooksLoaded(...)` delivers the static registry.
- `dialogs/hooks_viewer.rs` — renders that registry (`HookEntry` at `:33`,
  `EventHooks` at `:40`, rows at `:56-62`, `draw_hook` at `:272`). It answers
  "what is wired and in what order", never "what ran on this call".

Port steps, in order:

1. **Backend: emit per-run outcomes.** Add a `HookRun` event carrying
   `{ tool_call_id, phase (:pre | :post | lifecycle event name), hook_name,
   outcome (:ok | :skipped | :blocked | :failed), elapsed_ms, detail }`, emitted
   from `hooks.ex`'s dispatch path for both `run/2` and `run_async/2`. Without
   this, everything below is unimplementable — **this is the blocking step.**
   Extend `event/backend.rs` with the variant and keep `HookBlocked` as a
   deprecated alias until the new event lands, so nothing regresses.

2. **TUI: attach runs to the call.** Add to `ToolCallData`
   (`components/chat/message.rs`, constructed at `components/chat/mod.rs:342-345`
   and `:351-360`) a `hook_runs: Vec<HookRun>` field, keyed in by
   `tool_call_id` — the same id `update_last_tool_result`
   (`components/chat/mod.rs:390-420`) already uses for correct out-of-order
   pairing. Do **not** key by tool name; hooks land out of order for the same
   reason results do.

3. **Accumulate per group.** Add `HookRunCounts { ok, blocked, failed }` to
   `tools/collapse.rs`'s `Accumulator` (§2.7 step 2), summed in `add()` from the
   member's runs. Skipped increments nothing.

4. **Render the suffix.** One function in `tools/collapse.rs` returning
   `Option<Vec<Span<'static>>>`, `None` when the total is zero (§3.4). Called from
   `take_summary_line()` / `live_line()` and appended to the spans. Colours come
   from `crate::style::theme()` — `colors.success`, the warning/running accent,
   and `colors.error`, each with `Modifier::DIM`; brackets and separators use
   `theme.recede()` (the chrome tier OSA already reserves for gutters).

5. **Compact shape for individual rows.** The same function with a shape
   parameter, used by the full (non-collapsed) tool renderer in `tools/` so a
   `● Bash(cmd)` cell can carry `[hooks: 9/1]`.

6. **Cross-check the viewer.** `dialogs/hooks_viewer.rs` should gain a per-session
   run tally so the "what is wired" view and the "what ran" suffix agree; the
   footer that today tallies the registry count (`dialogs/hooks_viewer.rs:9`) is
   the natural home.

Until step 1 ships, the honest interim is to render **nothing**. Do not
approximate the counter from `HookBlocked` alone — a bracket that shows only
blocks and never shows `ok` would systematically misreport hooks as broken.

---

# Part 4 — The task panel and the plan commit

## 4.1 Anchoring and height

The task panel is **live, never committed**. It sits inside the pinned live
region, directly **above** the status row and composer and **below** the
streaming tail:

```
live tail
task panel      ← here
side panel
status row
composer
info bar
```

The viewport sizing measures the panel so the composer sits right after it — the
panel is part of the content-sized height of §1.5, not an overlay.

**Height policy:**

- `0` rows when the panel is hidden (§4.3) or there are no tasks.
- Otherwise **one row per task**, capped at **8 rows** by default. When there are
  more, the last visible row becomes an overflow marker and only `cap - 1` tasks
  are listed:
  ```
  … +7 more · ctrl+t to expand
  ```
- The force-show pin expands to the **full** list (the sizing caller still clamps
  it to the screen). When already forced open and still overflowing a tiny
  screen, the chord hint is dropped from the marker: `… +7 more`.
- Task text is truncated to **64 characters** with a trailing `…`, so one task is
  always exactly one row — which is what the one-row-per-task height contract
  assumes.
- No leading pad. The panel sits at the shared live-region left edge (column 0),
  so its glyph column lines up with the committed `◆` bullets and the `❯` prompt.
- The panel's background is reset so it inherits the terminal's own background,
  matching the rest of the live region.

## 4.2 Status glyphs and colours

| Status | Glyph | Style |
|---|---|---|
| **Pending** | `□` (U+25A1 white square) | primary text colour |
| **In progress** | `▶` (U+25B6 black right-pointing triangle) | **warning colour, BOLD** |
| **Completed** | `✓` check mark | muted |
| **Cancelled** | `✗` ballot X | muted + **CROSSED OUT** |

The running task is distinguished by **three** simultaneous signals — a different
glyph, a different hue, and bold weight — so it is findable at a glance and
survives both `NO_COLOR` and colour-blindness. Everything else in the panel is at
or below the primary tier; the in-progress row is the only thing in the band that
is actually news.

The overflow marker row is dim.

## 4.3 Auto-hide rules

The panel decides its own visibility every frame:

- **No tasks → hidden.**
- **Any task is Pending or InProgress → shown.**
- **Every task is finished (completed or cancelled) → hidden**, even while a turn
  is actively running. A finished list must not linger: without this rule, last
  turn's completed checklist sits at the top of the next turn saying nothing.
- **A new turn that creates fresh pending tasks re-shows it immediately** — the
  rule is stateless, so there is nothing to reset.
- **The force-show pin (Ctrl+T) overrides the auto-hide** and keeps the panel
  visible regardless, e.g. to review a list you just finished. It also expands
  past the row cap.

Note this is a **pin**, not a hide-toggle: the chord's job is to make the panel
appear when the auto-rule would hide it, and to expand it when the cap would
truncate it.

## 4.4 Interaction with the commit pass

**The task panel itself never commits.** It is live-only, for a good reason: it
is a *current state*, not an event. Committing it would print a stale snapshot on
every mutation and fill the scrollback with near-identical checklists.

What *does* commit is a **plan**, exactly once per plan and once per revision.

## 4.5 Committing a plan

When the agent parks for plan approval:

- **The whole plan body is committed into native scrollback** as an ordinary
  finalized assistant-message block. It then reads and scrolls exactly like the
  rest of the transcript, with no separate pane and no internal scroll.
- **Only the decision controls stay live** — a 2–3 row strip under the composer:
  ```
  Plan ready for review
  a approve · s revise · q keep planning
  <feedback input, only while revising>
  ```
  Nothing of the plan body is drawn under the prompt.
- **Deduplicated by the plan's tool-call id.** A revised plan arrives with a new
  id and commits as its own block.
- **The block is inserted *above* the still-running plan-exit tool row**, not
  appended after it. This matters: the frontier stops at the running tool, so an
  appended block would sit behind it and never commit while approval is parked —
  users lose the head of a long plan to the clipped live tail. Anchoring above
  the tool row lets the frontier reach the plan immediately. If the anchor row is
  gone, append and accept that the plan commits at turn end.
- **An empty or whitespace-only plan still commits a short notice**, explaining
  that approval is parked and what the options are. Otherwise only the controls
  strip appears and the session looks stuck.
- The header text is honest about state: `Plan ready for review` vs
  `No plan written yet`.

Two caveats worth writing down:

- Pushing into scrollback state from the render path is a **deliberate
  exception**, made so the plan enters the normal commit pipeline rather than
  needing a parallel one.
- The pushed block is client-render state, not a server event, so a **resumed
  session will not replay it**. Post-reload, the transcript shows the plan only
  through whatever the agent itself messaged. Accepted: the live session is the
  mode's whole surface.

## 4.6 Is the running task echoed elsewhere?

Yes — in the **status row**, and only as a verb. The in-progress task's
present-continuous form ("Wiring the checklist…") replaces the generic rotating
spinner word, so the status row states the concrete current step. The task panel
carries the *list*; the status row carries the *one thing happening now*. Neither
repeats the other's information, and neither shows a second timer.

## 4.7 OSA port plan for the task panel

**OSA is already close.** `components/task_checklist.rs` implements most of this.

Already correct, keep as-is:

- **Glyphs and styles** (`components/task_checklist.rs:136-152`): `✔` completed
  (dim + crossed out), `▸` in-progress (`theme.task_active()`), `□` pending
  (`theme.task_pending()`), `✗` failed (`theme.task_failed()`). Note OSA's fourth
  status is `Failed` where §4.2 has `Cancelled` — OSA's is the better distinction
  for an agent; keep it, and add `Cancelled` only if the backend ever emits it.
  The glyph table is shared by the live panel and the committed snapshot
  (`:134-135`), which is exactly the right factoring.
- **Header** `Plan  n/m` (`components/task_checklist.rs:161-177`) — one stable
  title with the count carrying progress. The comment at `:157-163` records why
  the title must not flip to `Updated plan` when a step starts; do not undo that.
- **The running task feeds the spinner**: `current_active_form()`
  (`components/task_checklist.rs:73-78`) → the activity's `active_verb`
  (`components/activity.rs:490-494`). §4.6 already holds.
- **Anchoring**: the checklist is a real band, measured at
  `app/event_loop.rs:2222-2229` and drawn at `app/event_loop.rs:2371-2373`, never
  an overlay into the stream band. The comment at `app/event_loop.rs:2219-2221`
  records the bug that caused — a plan interleaving with a streaming markdown
  table. Keep the band.
- **The plan snapshot commits**: `snapshot_if_changed(width)`
  (`components/task_checklist.rs:258-270`), deduped by an ordered `id:status` key
  (`:245-253`), pushed via `Chat::add_plan_snapshot`
  (`components/chat/mod.rs:326-328`) from `app/handle_actions.rs:344-345`.
  Fitting each item to one row at commit width (`:222-229`) is the height-parity
  discipline of §1.1 applied correctly.

Three real gaps:

1. **No auto-hide when everything is done.** `is_visible()`
   (`components/task_checklist.rs:115-117`) is `self.visible && !self.items.is_empty()`
   — a fully completed list lingers indefinitely, which is precisely the
   complaint §4.3 exists to fix. Change to:
   ```rust
   pub fn is_visible(&self) -> bool {
       if self.items.is_empty() { return false; }
       if self.pinned { return true; }
       self.items.iter().any(|i| matches!(
           i.status, ChecklistStatus::Pending | ChecklistStatus::InProgress))
   }
   ```

2. **No overflow row.** `height()` (`components/task_checklist.rs:125-127`) is
   `(items + 1).min(MAX_HEIGHT)` with `MAX_HEIGHT = 12`
   (`components/task_checklist.rs:4`), and `draw` (`:274+`) clamps to the area —
   so items past the cap are **silently dropped** with no indication. Add the
   `… +N more · ctrl+t to expand` marker as the last row when truncating, and
   drop the chord hint when already pinned. Note OSA's cap of 12 includes the
   header row; the reference cap of 8 is items-only. Either is defensible —
   choose one and state it in the constant's doc comment.

3. **The keybind is a hide-toggle, not a pin.** `app/keymap_dispatch.rs:207-209`
   flips `task_checklist_hidden` (`app/mod.rs:487`, initialised at `:757`), which
   is read as a suppressor at `app/event_loop.rs:2222`. Once gap 1 lands, a
   suppressor cannot *un*-hide an auto-hidden list. Replace the single boolean
   with a tri-state — `Auto | Pinned | Suppressed` — where the chord cycles
   `Auto → Pinned → Suppressed → Auto`, and `Pinned` additionally lifts the row
   cap of gap 2.

One more, lower priority:

4. **Truncation width.** `item_line` fits to columns via `fit_cols`
   (`components/task_checklist.rs:196-203`) — correct, and the comment there
   records the byte-vs-column bug it replaced. The reference additionally caps
   task text at a fixed 64 characters *before* width fitting, so a very wide
   terminal does not turn the panel into a wall of prose. Worth adopting.

---

# Part 5 — Where OSA stands today

## 5.1 What maps cleanly

| Architecture element | OSA today | Notes |
|---|---|---|
| Print-once commit via `insert_before` | `app/event_loop.rs:1371-1448` (step 2: drain + batched insert) | Already the model. OSA additionally **batches** a screenful of messages into one `insert_before` — strictly better than one call per block; keep it. |
| Commit precedes draw | commit at `app/event_loop.rs:1371`, draw at `app/event_loop.rs:1495` | Already correct. |
| Viewport sized before commit | `app/event_loop.rs:944` → rebuild at `:1308-1313`, commit at `:1385` | Right order; the *content* of that height is wrong (§5.2, item 3). |
| Run vocabulary + aggregation | `tools/collapse.rs:16-296` | A real counterpart, one family short (§2.7). |
| Committing a summary line | `components/chat/mod.rs:350-361` `add_collapsed_tool_summary` | Exists; carries a pre-rendered `Line` through the tool-call carrier, chosen because it is exactly height-1 with no orphan blank row (`app/handle_backend.rs:2086-2090`). |
| Driving the accumulator + break sites | `app/handle_backend.rs:12-17`, `:557-585`; `app/handle_actions.rs:244` | Already flushes on kind change, non-collapsible tool, and turn end. |
| Task panel as a real band | `components/task_checklist.rs`; measured `app/event_loop.rs:2222-2229`, drawn `:2371-2373` | Already right (§4.7). |
| Plan committed to scrollback | `components/task_checklist.rs:258-270` → `components/chat/mod.rs:326-328` | Already right. |
| Running task feeds the status verb | `components/task_checklist.rs:73-78` → `components/activity.rs:490-494` | Already right. |
| Reasoning duration | `components/activity.rs:479-484` | Computed — but rendered transiently *in the live status row*, never committed. |
| Hooks model | `lib/optimal_system_agent/agent/hooks.ex` | Outcome vocabulary maps exactly (§3.5); the per-run wire event is missing. |
| Terminal scrollback as the history | `components/chat/mod.rs:1-6` | Same philosophy, stated in the module doc. |
| Synchronized update | `app/event_loop.rs:1489-1496` | Exists, but opens **after** the commits. |
| One width per frame | `app/event_loop.rs:1386-1390` | OSA already learned this the hard way; the comment records that a third, lagging width source printed messages permanently at a width the terminal no longer had. |

## 5.2 What has no counterpart

1. **No committability predicate and no frontier.** OSA's commit queue
   (`Chat::scrollback`, `components/chat/mod.rs:53`) is push-driven: handlers
   decide at push time whether a block is live or queued. There is no per-entry
   predicate, no read-only projection of what the commit pass will do, and
   therefore nothing corresponding to `tail_start` or `will_commit`.

2. **No pending-user-input hold.** OSA draws a permission prompt into the stream
   band (`app/event_loop.rs:2329-2331`), but the tool cell it concerns has already
   been pushed or lives in `Chat::messages`. Nothing says "this entry must not
   commit while a modal owns it."

3. **The live activity band — the thing to delete.**
   - `components/activity.rs:379-395` — `ToolEntry`.
   - `components/activity.rs:427-562` — `Activity` fields `tool_feed`,
     `live_streams`, `live_command`.
   - `components/activity.rs:1254-1269` — push a row on tool start (with
     concurrent-identical folding at `:1239-1252`).
   - `components/activity.rs:1272-1330` — `tool_end_with_id`, closing a row by
     backend call id.
   - `components/activity.rs:1994-2085` — render the feed rows
     (`┊ <emoji> <verb:<10> <detail>  ×N  1.2s...`).
   - `components/activity.rs:2088-2105` — the live command-output tail.
   - Reserved as the `think` band at `app/event_loop.rs:2253-2264`, painted
     bottom-anchored at `app/event_loop.rs:2353`.

   Its height policy (`components/activity.rs:1524-1558` `height()`,
   `:1560-1597` `max_height()`) is a **verbosity ceiling** —
   `Off: 1+details`, `New: 2+details`, `All: 1+details+4`,
   `Verbose: 1+details+8` — deliberately decoupled from the live feed. The
   comment at `components/activity.rs:1552-1559` states exactly why: a slot that
   tracks the feed grows a row per tool, and every growth rebuilds the inline
   viewport (a DSR cursor re-anchor that stacks a fresh composer down the
   screen). This architecture removes the problem instead of capping it.

4. **Single-bucket summaries.** See §2.7. `family_matches`
   (`tools/collapse.rs:194-196`) plus the flush at `app/handle_backend.rs:577-579`
   means a `Read, Read, List, Read` run emits **three** lines.

5. **No present-tense label.** The summary is produced only on flush
   (`tools/collapse.rs:261-295`) and is always past tense.

6. **No hook run stream.** Only `BackendEvent::HookBlocked`
   (`event/backend.rs:432`) and the static registry `HooksLoaded`
   (`event/backend.rs:464`). See §3.5.

7. **No committed reasoning block.** `components/chat/thinking_box.rs` is a live
   band; `thought_for` is a transient status segment. Nothing commits
   `◆ Thought for 14.5s` into scrollback.

8. **No expand re-print.** `components/chat/mod.rs:424-447`
   `toggle_last_tool_expand` reaches only *live* cells, and `:449-461`
   `has_expandable_last_tool` documents that finalized cells are static.

9. **No commit height cap.** OSA commits whatever `Message::height(w)` reports
   (`components/chat/message.rs:384-420`).

10. **No distinct-source counts.** OSA dedupes read *paths*
    (`tools/collapse.rs:210-212`) to **name** files — a better idea for reads —
    but has no equivalent for web citations or subagent ids.

11. **Task panel gaps** — auto-hide, overflow row, pin semantics. See §4.7.

---

# Part 6 — Migration plan

Ordered so each step leaves the TUI shippable.

**Step 1 — Multi-bucket summary lines.** §2.7 steps 1–4, 6–7. No visible change
beyond fewer, richer lines.

**Step 2 — The running form.** §2.7 step 5. Render `Accumulator::live_line()` as
the **single** content row of the live activity slot. Fixed at one row; it can
never grow. This preserves the "something is happening" signal that deleting the
band otherwise costs.

**Step 3 — Delete the live activity band.**

1. Delete `tool_feed` and every reader (`components/activity.rs:379-395`,
   `:1239-1269`, `:1272-1330`, `:1994-2085`). `tool_start` / `tool_end_with_id`
   keep their other effects (`last_tool_name`, `last_output_at`, the
   foreground-shell counter) and stop pushing rows. The concurrent-identical fold
   and the call-id pairing die with them — with one committed row per run,
   neither has anything to do.
2. Delete the live command-output tail (`components/activity.rs:558-561`,
   `:1964-1984`, `:2088-2105`). Streamed shell output belongs in the committed
   truncated execute block, capped (Step 6).
3. Collapse the height policy to a constant:
   ```rust
   fn height(&self)     -> u16 { if !self.active { 0 } else { 1 + self.details_rows() } }
   fn max_height(&self) -> u16 { self.height() }
   ```
   With `height() == max_height()`, the damped slot at
   `app/event_loop.rs:2256-2260` becomes a no-op and can be simplified away —
   **and that is the point**: the band can no longer grow or shrink, so it can no
   longer rebuild the inline viewport mid-turn. Delete the now-obsolete rationale
   comment at `components/activity.rs:1552-1559`.
4. `Verbosity` (`components/activity.rs:397-424`) only ever selected feed depth.
   Delete it and the `/verbosity` command (`app/commands.rs:338-341`), or
   repurpose `Off` as "hide the status row". If kept, it must not reintroduce a
   variable-height band.
5. Keep the `└` details block (`components/activity.rs:526-535`). It is capped and
   its wrap width is recorded (`details_width`, `:535`) so reserved equals
   painted. It is where anything the feed showed and the status row does not
   should move.

**Step 4 — Task panel fixes.** §4.7 gaps 1–3 (auto-hide, overflow row, pin
tri-state), plus gap 4 if desired. Independent of Steps 1–3.

**Step 5 — Commit `Thought for Xs`.** On the Thinking→other transition, push a
committed one-row block through `Chat::add_collapsed_tool_summary` — the carrier
is already exactly one row with no orphan blank line
(`app/handle_backend.rs:2086-2090`). Format per §1.6; add a
`fmt_thought_duration` rather than changing `crate::util::fmt_elapsed`, which is
integer-second and used elsewhere. `components/chat/thinking_box.rs` stays as the
**live** reasoning preview — it is the tail, not the band. Independent.

**Step 6 — Cap committed block height.** §1.8, applied to `h` **before** it
enters the batch (`app/event_loop.rs:1436`), never inside `flush`
(`app/event_loop.rs:1396-1415`).

**Step 7 — Expand re-print.** §1.6, wired as:

1. `Chat::committed_foldable: Vec<CommitId>`, recorded in the drain loop
   (`app/event_loop.rs:1417-1446`) only after the write succeeded.
2. `Chat::pending_expand: Vec<CommitId>`, pushed by the Ctrl+O handler when
   nothing live is expandable (`components/chat/mod.rs:455-461` already gates
   this correctly).
3. Drain **after** the step-2 drain (`app/event_loop.rs:1447`) and **before** the
   `last_inline_top` resync (`:1459`), re-`insert_before` fully expanded and
   uncapped.
4. Guards per §1.6. Note step 2 propagates write failures with `?`
   (`app/event_loop.rs:1412`, `:1447`) — the expand pass must **not** propagate,
   it must requeue.

   This needs the committed `Message` to survive commit; today `drain_scrollback`
   (`components/chat/mod.rs:504-506`) moves them out and only a text copy survives
   into `transcript_log` (`app/event_loop.rs:1423-1427`). Add a small id-keyed
   ring of the last N *foldable* messages.

**Step 8 — Hook counter, backend half.** §3.5 step 1. Blocking for step 9.

**Step 9 — Hook counter, TUI half.** §3.5 steps 2–6.

**Step 10 — Move the synchronized update.** `BeginSynchronizedUpdate` is emitted
at `app/event_loop.rs:1489`, *after* the welcome banner (`:1360`) and the message
flush (`:1406`) have already scrolled and repainted. Move the `Begin` to just
before step 1b (before `app/event_loop.rs:1343`), leaving `End` at `:1496`.

---

# Part 7 — Ordering constraints and risks

## Ordering (hard)

1. **Step 1 before Step 3.** Deleting the band without multi-bucket summaries
   leaves a mixed run emitting three separate lines where the band used to show
   one coherent picture — a visible regression.
2. **Step 2 before Step 3.** The live label must exist before the feed is deleted,
   or there is a window with no in-turn tool signal at all.
3. **Step 3 before Step 10.** Moving the synchronized update while the band still
   resizes the viewport per tool just makes the churn atomic instead of removing
   it.
4. **Step 6 before Step 7.** Expansion is defined as the uncapped re-print of a
   block the initial commit capped. Without a cap there is nothing to expand to
   and the queue is dead code.
5. **Step 8 before Step 9.** The bracket cannot be approximated from
   `HookBlocked` alone; see §3.5.
6. **Steps 4 and 5 are independent** and can land at any point.

## Risks

- **R1 — height parity across the flush (highest).** The invariant: *the rows a
  block occupies in the live region must equal the rows it occupies once
  committed.* Enforce it structurally — one renderer used by both sides — not by
  discipline. OSA's shared path is `components/chat/message.rs:384-420`. Add a
  layout-invariant test asserting `live_rows == committed_rows == 1` for the
  summary line, and a test that the animation tick never changes a block's height.

- **R2 — one width per frame.** `app/event_loop.rs:1386-1390` records that a
  third, lagging width source printed finalized messages permanently into
  scrollback at a width the terminal no longer had. **Every new commit path in
  Steps 5–7 must take `size.cols` from the single `frame_size()`, never
  `get_frame()`.** The up-front size adoption of §1.7 is the general form.

- **R3 — print-once contract.** Editing a committed entry is a silent no-op on
  screen. OSA has one in-place mutator, `update_last_tool_result`
  (`components/chat/mod.rs:390-420`), which walks the *live* list and is currently
  safe. Step 7 introduces a post-commit id map; code that reaches into it to
  **edit** rather than **re-print** is a silent bug. Step 9 attaches hook runs by
  id — those must land *before* the tool commits, or they never render.

- **R4 — the reserve/paint agreement.** OSA collapsed five hand-maintained band
  sums into one `measure_bands` (`app/event_loop.rs:2190-2211`) after repeated
  drift bugs, and the rule at `app/event_loop.rs:2296-2303` is that `draw_inline`
  may compute no heights, only read rects. Steps 3, 4, and 5 touch band heights;
  every change goes through `measure_bands`.

- **R5 — losing the "still working" signal.** Deleting the band removes per-tool
  progress. The compensating surfaces are the one-row status
  (`components/activity.rs` `WaitingReason`, `RetryState`, `active_verb`, the `└`
  details block) and the task panel. **Audit before deleting:** anything the feed
  shows that neither surface does must move into `details` or into the committed
  summary first.

- **R6 — flush ordering.** Every break site (§2.3) must flush before the
  interrupting block is pushed. A missed site reorders the transcript
  permanently; this is print-once and there is no repaint to fix it.

- **R7 — no true pending-input hold.** OSA's push-driven queue cannot keep the
  asked-about tool live and unfrozen under a permission modal the way §1.2
  specifies. Flushing before the ask is strictly weaker. If it turns out to matter
  — an "Allow Edit to …?" prompt showing with no visible diff — the real fix is to
  give `Chat` a committability predicate and a real frontier, a substantially
  larger change than this migration. Defer, but record.

- **R8 — hook counts that mislead.** A bracket is a claim about what ran. Partial
  data (blocks only, or pre-hooks only) makes it a false claim, and a false claim
  about the safety layer is worse than no claim. Render nothing until §3.5 step 1
  ships end to end.

- **R9 — green tests over a broken screen.** OSA has already shipped layout tests
  that stayed green while the scrollback was visibly wrong. The band deletion and
  the task-panel changes must be verified **by eye** at several widths and across
  a live resize, not only by `layout_invariants.rs`.
