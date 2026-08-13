# TUI Design Spec: Slash-Command Surface and Streaming Render Pipeline

Status: design specification. Two independent parts.

- **Part 1** — the target slash-command inventory for OSA, with every command
  we should support, whether we have it today, and what it should do.
- **Part 2** — the streaming/render architecture OSA should converge on, what
  OSA does today (with file:line), and a ranked change list.

Comparative material is drawn from a reference harness studied for this spec.
Only OSA's own code is cited by path; the reference side is described by
mechanism so it can be implemented from this document alone.

---

# Part 1 — Slash-command inventory

## 1.1 Where OSA's commands live today

OSA has **three** registries that must stay in sync. This is itself a defect:
there is no single source of truth, and the three lists have already drifted.

| Registry | Path | Role |
|---|---|---|
| TUI seed list | `priv/rust/tui/src/app/commands.rs:14` (`BUILTIN_SLASH_COMMANDS`) | Seeds the `/` popup and Ctrl+K palette before the backend answers |
| TUI dispatch | `priv/rust/tui/src/app/commands.rs:105` (`handle_command` match) | The commands the TUI actually handles locally |
| Backend registry | `lib/optimal_system_agent/channels/cli/commands.ex:32` (`@commands`) | CLI dispatch + `GET /commands` |
| API-only extras | `lib/optimal_system_agent/channels/http/api/tool_routes.ex:530` | Commands advertised over HTTP with no CLI handler |
| User commands | `lib/optimal_system_agent/tools/registry/command_loader.ex` | `~/.osa/commands/*.md`, `$ARGUMENTS`/`{{args}}` substitution |

Observed drift: `/steer`, `/add-dir`, `/provider`, `/update`, `/keybindings`
appear in the TUI seed list; `/customize`, `/init`, `/map`, `/files`, `/tag`,
`/fast`, `/effort`, `/release-notes`, `/export`, `/plan` appear only in the
Elixir map; `/desktop` and `/reasoning` exist only as API-only entries. A user
who types `/init` in the TUI and `/keybindings` in the CLI gets different
answers about what exists.

**Recommendation R0 (prerequisite):** collapse to one declarative registry with
per-command metadata — canonical name, aliases, one-line description, usage
string, argument hint, capability gate, and whether the command opens a UI
surface or runs inline. The reference harness models each command as a trait
object with exactly those methods plus a `visible(ctx)` predicate and a
`required_tools()` gate, and builds the registry from one ordered `Vec`. That
shape is worth copying wholesale: it makes the completion popup, the help
palette, and the dispatcher read from the same list by construction.

Two further reference-harness ideas that OSA lacks and should adopt:

- **Capability gating.** A command declares the backend tool it needs
  (e.g. a scheduler tool for a recurring-prompt command). If the session does
  not advertise that tool, the command is neither listed nor resolvable. OSA
  half-does this in `tool_routes.ex:87` but only on the HTTP path — the TUI
  popup still offers dead commands.
- **Provenance badges.** Each entry in the dropdown carries a right-aligned
  badge: `built-in` versus `skill · <source>`. OSA merges skills and commands
  into one list with no visual distinction.

## 1.2 The full inventory

Columns: **Command** (canonical, with aliases) · **OSA has it?** (`yes`,
`partial`, `no`) · **Proposed behaviour** · **Notes** (surface = opens a UI
overlay/picker/modal; inline = runs and returns text/toast).

### Session lifecycle

| Command | OSA has it? | Proposed behaviour | Notes |
|---|---|---|---|
| `/new` (`clear`) | yes | Start a fresh session | inline; OSA `commands.rs:129` also resets backend context |
| `/delete` | **no** | Delete the current session, with confirm | inline; needs a session id guard. Slots into the Elixir sessions module + a TUI confirm dialog |
| `/home` (`welcome`) | **no** | Leave the session and return to the welcome/home screen without quitting | surface. OSA has no "session-less" home state — this is the largest structural gap in the list |
| `/resume` | yes | Session picker | surface |
| `/continue` | yes (OSA-only) | Resume this folder's last session | inline |
| `/session` | yes (OSA-only) | Show or switch session | inline |
| `/fork` | yes | Branch the session into a peer agent. Should accept `--worktree` / `--no-worktree` and an optional directive | OSA lacks the worktree flags |
| `/rename` (`title`) | yes | Rename the session; `--auto` resets to the generated title | inline. OSA lacks `--auto` |
| `/tag` | yes (OSA-only) | Tag the session for search | inline |
| `/share` | **no** | Publish the session to a URL | inline. Needs a hosted endpoint — defer |
| `/quit` (`exit`) | yes | Quit | inline |

### Conversation content

| Command | OSA has it? | Proposed behaviour | Notes |
|---|---|---|---|
| `/compact` | yes | Compact history; free-text arg = what to preserve | inline; queue behind the running turn rather than executing immediately |
| `/recap` (`summarize`) | yes | Summarize the session so far | inline |
| `/context` | yes | Context-window usage + session stats | surface |
| `/copy` | yes | Copy last response to clipboard **or file**; `[N]` selects the Nth-from-last | OSA copies only the last reply, no `N`, no file target |
| `/export` | yes | Export the conversation to a file or clipboard | inline |
| `/transcript` (`log`) | **no** | Open the full transcript in `$PAGER` | inline (spawns child). Cheap and high value given OSA has no in-app scrollback |
| `/find` | **no** | Incremental search over the conversation scrollback | surface. Medium effort: needs a search overlay over the chat widget |
| `/history` | **no** | Search prompt history | surface. Small: OSA already persists prompt history for up-arrow |
| `/jump` | **no** | Jump to a turn in the conversation | surface. Depends on a turn index; pairs with `/rewind`'s picker |
| `/rewind` (`undo`) | yes | Restore code/conversation from a checkpoint | surface |
| `/expand` | **no** | Re-print the last collapsed block, fully expanded | inline. Directly relevant to OSA's inline mode where collapsed tool output is unrecoverable |
| `/queue` | **no** | List prompts queued behind the running turn | surface. OSA queues prompts but never shows the queue |
| `/btw` | **no** | Ask a side question that does not interrupt the running turn; answered in a small overlay | surface. Distinct from `/steer` — `/steer` redirects, `/btw` asks without redirecting |
| `/steer` | yes (OSA-only) | Inject a directive into the running turn | inline |
| `/retry` | yes (OSA-only) | Re-send the last prompt | inline |
| `/undo` | yes (alias of rewind) | Drop the last exchange | inline |

### Model, effort, and mode

| Command | OSA has it? | Proposed behaviour | Notes |
|---|---|---|---|
| `/model` (`m`) | yes | Switch active model. Bare name = switch **and persist**; `name + effort` = session-scoped switch only | OSA does not distinguish persist-vs-session |
| `/models` | yes (OSA-only) | Browse and pick a model | surface |
| `/provider` (`providers`) | yes (OSA-only) | Connect an account or paste a key | surface |
| `/effort` | yes | Set reasoning effort. Levels must be **model-specific**, read from the model's advertised option ids, not a hardcoded low/medium/high/max | OSA hardcodes the four levels (`commands.ex:60`) |
| `/reasoning` | yes (OSA-only) | Effort selector (TUI) | Should be folded into `/effort` as an alias |
| `/fast` | yes (OSA-only) | Toggle low effort | Keep |
| `/plan` | yes | Enter plan mode; optional description | inline |
| `/view-plan` (`show-plan`, `plan-view`) | **no** | View the current plan | surface. Small — OSA has plan state, no viewer |
| `/auto` | yes | Classifier auto-approves safe tools | inline |
| `/always-approve` (`yolo`) | yes (as `/overdrive`, `/yolo`, `/dangerous`) | Skip all permission prompts; accept `on|off` args | OSA's toggles have no explicit on/off arg |
| `/coordinator` | yes (OSA-only) | Delegation-only mode | inline |
| `/goal` | yes | Set/manage an autonomous goal. Should accept `status`, `pause`, `resume`, `clear`, and `--budget <tokens>` | OSA's `/goal` has no subcommands or budget |

### Tools, extensions, agents

| Command | OSA has it? | Proposed behaviour | Notes |
|---|---|---|---|
| `/tools` | yes (OSA-only) | Tool count / list | inline |
| `/skills` (`skill`) | yes | Browse, run, enable, disable, create skills | surface |
| `/mcps` | yes (as `/mcp`) | MCP server status | Should open the same extensions surface as `/plugins` |
| `/plugins` (`plugin`) | **no** | Manage plugins: `list`, `reload`, `trust <path>`, `add <path>`, `remove <path>` | surface + inline subcommands |
| `/reload-plugins` | **no** | Alias for `/plugins reload` | inline |
| `/marketplace` | **no** | Browse installable extensions | surface. Defer until a registry exists |
| `/hooks` | yes | View hooks | OSA lacks the management verbs below |
| `/hooks-list` | partial | List hooks loaded in this session | inline |
| `/hooks-add <path>` | **no** | Add a custom hook file or directory | inline |
| `/hooks-remove <path>` | **no** | Remove a custom hook path | inline |
| `/hooks-trust` | **no** | Trust this project for hook execution | inline. **Security-relevant**: OSA currently loads project hooks without an explicit per-project trust gate |
| `/hooks-untrust` | **no** | Revoke project hook trust | inline |
| `/config-agents` (`agents`) | partial | Manage agent *definitions* (create/edit/delete) | surface. OSA's `/agents` shows the runtime dashboard, not definitions — these are two different commands and both are needed |
| `/dashboard` (`agents-dashboard`, `sessions`) | partial | Fullscreen overview of every running session | surface. OSA's `/agents` is closest |
| `/personas` | partial | Manage personas: create, edit, delete | surface. OSA's `/persona` only shows/switches |
| `/tasks` | yes | Background tasks, subagents, scheduled tasks | surface |
| `/bg`, `/fg` | yes (OSA-only) | List / foreground background turns | inline |
| `/workflows` | **no** | Show workflow runs (phases, agents, progress) | surface |
| `/workflow <name> [args] \| pause\|resume\|stop\|save` | **no** | Launch a saved workflow or manage a run | inline. Pairs with `/workflows` |
| `/deep-research <query>` | **no** | Bounded parallel research agents, cross-checked evidence, cited report | inline (expands to a structured prompt). Implementable today on OSA's fleet primitives |
| `/loop [interval] <prompt>` | **no** | Run a prompt on a recurring interval | inline. Implementation note below |
| `/imagine <description>` | **no** | Generate an image | inline. Gate on an image tool |
| `/imagine-video <description>` | **no** | Generate a video | inline. Gate on a video tool |

**Implementation note for `/loop` and friends.** The reference harness does not
parse the interval itself. The command expands into a *structured prompt* that
instructs the model to call a `scheduler_create` tool, and the canonical wording
lives in one shared module so every front-end expands it identically. Two fire
modes are described in that wording — a detached background subagent that cannot
see the conversation (default), and an in-session fire that arrives as a new
turn — and the prompt text differs between them so the stored prompt is written
to survive the runtime it actually gets. The UI also inserts a *provisional*
scheduled-task row immediately on submit, replaced when the real
`ScheduledTaskCreated` notification arrives, so the task appears without waiting
for a model round-trip. Copy all three ideas.

### Memory

| Command | OSA has it? | Proposed behaviour | Notes |
|---|---|---|---|
| `/memory` (`mem`) | yes | Browse, view, manage memories; `on\|off` toggles the backend | OSA's is save/recall only, no browser, no toggle |
| `/remember [text]` | **no** | Save a memory note; bare form enters a capture mode | inline. Small |
| `/flush` | **no** | Flush conversation memory to disk now | inline. Gate on a memory backend |
| `/dream` | **no** | Memory consolidation — merge session logs into organized topics | inline. Gate on a memory backend |

### Diagnostics and status

| Command | OSA has it? | Proposed behaviour | Notes |
|---|---|---|---|
| `/doctor [fix [FIX]]` | partial | Check the session **and apply named fixes** | OSA reports only; the `fix` verb is the valuable half. Aliases worth adding: `terminal-setup`, `terminal-check`, `terminal-info` |
| `/session-info` (`status`, `info`) | yes (as `/status`) | Model, turns, context usage | surface |
| `/usage` (`cost`) | yes | Account quota + token usage; `show\|manage` subcommands | OSA lacks `manage` (billing) |
| `/metrics` | yes (OSA-only) | Telemetry metrics | inline |
| `/version` | yes (OSA-only) | Version + update check | inline |
| `/update` | yes (OSA-only) | Self-update | inline |
| `/release-notes` (`changelog`) | yes | Release notes for the current version | surface |
| `/announcements hide\|show` | **no** | Show or hide session announcements | inline. Only worth it if OSA ships an announcements channel |
| `/feedback [text]` | **no** | Send feedback about the session | surface + inline. Needs an endpoint |
| `/debug [scroll\|fps\|log]` | **no** | Toggle debug overlays: scroll HUD, FPS HUD, render log | inline. **Build this** — Part 2 argues OSA cannot currently measure its own frame behaviour, and an FPS/scroll HUD is the cheapest instrument |
| `/scroll-debug` | **no** | Hidden alias for the scroll HUD | hidden |

### Appearance, input, terminal

| Command | OSA has it? | Proposed behaviour | Notes |
|---|---|---|---|
| `/theme` (`t`) | yes | Switch theme; bare form opens a picker with live swatches | OSA already does the bare-form picker (`commands.rs:150`) |
| `/settings` (`config`, `preferences`, `prefs`) | yes (as `/config`) | Settings modal | surface. Add the three aliases |
| `/privacy` | **no** | Open the data-retention / training settings row | surface. Should exist the moment OSA sends any telemetry |
| `/keybindings` | yes (OSA-only) | Keybinding map + config path | surface |
| `/compact-mode` | **no** | Toggle compact UI — less padding, more content | inline. Cheap, high perceived value on small terminals |
| `/multiline` (`ml`) | **no** | Swap Enter and Shift+Enter | inline. Small; OSA's input widget already distinguishes them |
| `/vim-mode` | **no** | Vim-style scrollback keys (j/k, h/l, g/G, y/Y) | inline. Medium — needs a modal keymap layer in `keymap_dispatch.rs` |
| `/timestamps` | **no** | Toggle message timestamps | inline. Trivial |
| `/timeline` | **no** | Toggle a timeline sidebar | surface. Medium |
| `/toggle-mouse-reporting` | **no** | Toggle terminal mouse reporting so native click-drag copy/paste works | inline. **High value** — this is the standard escape hatch when the TUI eats selection |
| `/edit-prompt` | **no** | Open `$EDITOR` for the prompt | inline (spawns child). Small and frequently wanted |
| `/minimal` / `/fullscreen` (`full`) | **no** | Relaunch this session in the other screen mode | inline (relaunch). OSA has both inline and alt-screen backends (`inline_backend.rs`, `alt_screen.rs`) but no user-facing switch. Note the reference harness makes each switcher visible *only* in the opposite mode |
| `/a11y` (`screenreader`) | yes (OSA-only) | Screen-reader mode | inline |
| `/voice` | yes | Dictation toggle | The reference harness varies the description text depending on whether the terminal reports key releases (hold-to-talk only possible when it does) — worth mirroring |

### Workspace, auth, docs

| Command | OSA has it? | Proposed behaviour | Notes |
|---|---|---|---|
| `/cd [path]` | **no** | Change the working directory for new agents; bare form opens a picker | surface. OSA has `/add-dir` but no cwd switch |
| `/add-dir` | yes (OSA-only) | Allow file access in an additional directory | inline |
| `/trust` | yes (OSA-only) | Show or accept workspace trust | inline |
| `/sandbox` | yes (OSA-only) | Show or switch the sandbox backend | inline |
| `/permissions` | yes (OSA-only) | View and manage permission rules | surface |
| `/init` | yes (OSA-only) | Scan the project, write `AGENTS.md` | inline |
| `/map` | yes (OSA-only) | Map the workspace | inline |
| `/files` | yes (OSA-only) | Files currently in context | inline |
| `/channels` (`ch`) | yes (OSA-only) | Channel connectivity | inline |
| `/desktop` (`gui`) | yes (OSA-only) | Open the desktop GUI | inline |
| `/customize` | yes (OSA-only) | Identity, skills, schedules, channels | surface |
| `/setup` | yes (OSA-only) | Re-run the setup wizard | surface |
| `/login` | yes | Log in / re-authenticate | surface |
| `/logout` | yes | Log out, return to the login screen | inline |
| `/import-claude` | **no** | Import settings from a Claude Code install | surface. OSA's users overwhelmingly have one; this is a cheap onboarding win |
| `/docs [web\|title]` (`howto`, `guides`) | **no** | Open bundled how-to guides, or the online docs | surface |
| `/tutorial` (`tour`, `onboarding`) | **no** | Quick tips tour | surface |
| `/help` | yes | Browse commands and shortcuts | OSA already opens the palette rather than dumping text (`commands.rs:118`) — correct |

### Easter eggs

| Command | OSA has it? | Proposed behaviour | Notes |
|---|---|---|---|
| `/gboom` | n/a | Hidden game; never listed | Optional. The mechanism worth copying is the *tick-ceiling escalation*: an active view may request a faster tick than the configured animation fps |

## 1.3 Priority ranking for the missing commands

**P0 — cheap and immediately useful**
`/toggle-mouse-reporting`, `/edit-prompt`, `/transcript`, `/timestamps`,
`/compact-mode`, `/multiline`, `/remember`, `/queue`, `/view-plan`,
`/debug [scroll|fps|log]`, `/settings` aliases, `/doctor fix`.

**P1 — structural but self-contained**
`/find`, `/history`, `/expand`, `/delete`, `/cd`, `/plugins` + `/hooks-*`
(including the trust gate), `/personas` management, `/config-agents` split from
`/agents`, `/import-claude`, `/docs`, `/tutorial`, `/copy [N] [file]`,
`/model` persist-vs-session split, model-specific `/effort` levels.

**P2 — needs new subsystems**
`/home` (session-less home screen), `/minimal` + `/fullscreen` (screen-mode
relaunch), `/vim-mode`, `/timeline`, `/btw`, `/jump`, `/loop`, `/workflows` +
`/workflow`, `/deep-research`, `/flush` + `/dream`, `/imagine*`, `/share`,
`/feedback`, `/privacy`, `/announcements`, `/marketplace`.

---

# Part 2 — Streaming and render pipeline

The perceived-speed gap is not one bug. It is roughly six independent
mechanisms, of which OSA has two.

## 2.1 Target architecture (reference harness), mechanism by mechanism

### M1 — Draw cadence derived from the physical display refresh rate

A one-shot, process-cached probe reads the primary display's refresh rate from
the OS (CoreGraphics on macOS, `EnumDisplaySettings` on Windows). The probe is
fail-closed: it is skipped entirely over SSH, under WSL, and on Linux
(Wayland/X11 both return a skip reason), and any Hz outside `[30, 500]` is
rejected.

From the probe, the minimum inter-draw interval is
`clamp(round(1000 / hz), floor_ms, ceiling_ms)` with defaults `floor_ms = 8`,
`ceiling_ms = 16`, accepted Hz window `[55, 240]`, and a fallback cadence of
`16 ms` when the probe yields nothing. Two separate clocks come out of this: a
`min_draw_interval` for general repaints and a `scroll_cadence` for the scroll
clock. Both are overridable by env knobs, and the resolved values are reported
in telemetry.

Net effect: on a 120 Hz laptop the UI paints every **8 ms**; on a 60 Hz display
or over SSH it paints every 16 ms. It never paints faster than the panel can
show, and never slower than the panel can show.

### M2 — Frame back-pressure against a dedicated writer thread

Terminal bytes are not written from the event loop. A `spawn_writer_thread`
owns the tty and receives `WriterPayload { sequence, data }` over an mpsc
channel; a `WriterSync` tracks `queued` and `written` sequence numbers.

The presenter holds `in_flight_target: Option<u64>`. Before drawing it records
`queued_before`; after drawing it reads `queued_after`, and if the frame
enqueued new bytes it sets `in_flight_target = Some(queued_after)`. **While
`in_flight_target` is set, no new frame is drawn at all.** It is cleared only
when a `WriterEvent::Written(sequence >= target)` arrives.

This is the single most important anti-jank mechanism in the design. The render
loop can never run ahead of the terminal's ability to consume bytes, so a slow
terminal (tmux, SSH, a Wayland compositor under load) causes *fewer frames*
rather than a growing write backlog and visible lag.

### M3 — Coalescing presenter with a deferred-draw deadline

The presenter is a small state machine:

- `dirty: bool` — something changed.
- `force_full_repaint: bool` — OR-accumulated; consumed on the next draw and
  triggers a `terminal.clear()` first.
- `last_draw_at: Instant`, `draw_scheduled_at: Option<Instant>`.
- `request_throttled(now, min_draw_interval)` — if the cadence has not elapsed,
  it does **not** drop the request; it sets `draw_scheduled_at =
  last_draw_at + min_draw_interval` and returns false.
- The event loop's `select!` includes an arm that sleeps until
  `draw_scheduled_at`, so a suppressed repaint is guaranteed to land exactly one
  cadence tick later.

The critical property: throttling never loses a frame, it defers it. There is
one `present_if_dirty` call at the bottom of the loop body, so every iteration
has exactly one opportunity to paint.

### M4 — Priority-ordered biased `select!` with bounded stream batching

The event loop is a biased `select!` where arm order is deliberate and
documented. Cancellation, ACP stream, task completions, and keyboard input rank
above timers; voice STT (which can be ready on nearly every iteration at
5–20 Hz) is placed **last** so it can never starve anything.

Inside the ACP arm, incoming messages are drained in a bounded batch:

```
const ACP_DRAIN_BATCH_MAX: usize = 32;
while drained < ACP_DRAIN_BATCH_MAX && input_rx.is_empty() {
    let Ok(msg) = acp_rx.try_recv() else { break };
    ...
}
```

Two guards, both essential: the batch is capped at 32, **and** it is cut short
the moment any terminal input is pending. So a token flood collapses into one
repaint, but a keypress or wheel event waits at most one partial batch.

### M5 — Synchronized output around a zero-byte-idle frame

Every frame is wrapped in `BeginSynchronizedUpdate` / `EndSynchronizedUpdate`
(DEC 2026), queued into the same buffer as the cell data so the whole frame
reaches the terminal atomically. This matters most under tmux/zellij.

The draw path deliberately bypasses the framework's `Terminal::draw()` and
drives the lower-level primitives directly:

```
terminal.autoresize()
terminal.get_frame()          -> render into it
terminal.set_frame_links(...)  -> OSC-8 spans participate in the cell diff
terminal.flush_with_links()    -> returns bool: did any cell change?
terminal.swap_buffers()
```

Because `flush` reports whether anything changed, an unchanged frame writes
**zero bytes** — the payload is discarded before it reaches the writer. There is
a test asserting exactly that. This also solves a cosmetic bug worth noting: the
framework's `draw()` emits cursor `Show`/`MoveTo`/`Hide` unconditionally every
frame, which resets the terminal's 500 ms cursor-blink timer, so at 30+ fps the
cursor never blinks. Cursor commands are instead de-duplicated by a
`CursorState`: no cell changes and same position ⇒ zero cursor commands.

Hyperlink spans and post-flush escape sequences (e.g. inline image protocol
data) are written *inside* the synchronized block so images appear atomically
with the cells they belong to.

### M6 — Incremental markdown with a frozen prefix, plus resumable syntax state

Two layers.

**Checkpoint-based freezing.** The markdown renderer identifies *checkpoints* —
positions where output can never change no matter what is appended. Checkpoints
are created only at **top-level (depth 0) block boundaries**: after a heading,
after a paragraph followed by a blank line, after a closed fenced/indented code
block, after a blockquote/list/table that closed at depth 0, after a thematic
break, after an HTML block. Crucially, nothing inside a list, blockquote, or
table can be a checkpoint, because the outer container may continue. Each
checkpoint records `source_bytes` and `output_lines`. Content before the latest
checkpoint is rendered exactly once, ever.

**Word-wrap caching on top of freezing.** The wrap cache is keyed on
`(width, generation, theme)` where `generation` increments on every mutation.
It additionally tracks `frozen_pre_wrap_count` and `frozen_wrapped_count`, so a
re-wrap only processes newly-frozen lines plus the unfrozen tail; the frozen
wrapped output is preserved as-is. Stated explicitly in the source: this turns
streaming from O(N²) total wrapping into ~O(N). Width or theme change resets
both counters and forces a full re-wrap. There is a separate
`evict_wrap_cache()` for off-screen entries that drops only the post-wrap copy
(the largest per-block allocation) while keeping the ability to rebuild.

**Resumable syntax highlighting for the *open* code fence.** This is the piece
OSA is closest to and still behind on. Two complementary caches:

- *Still-open trailing fence* (closing ``` has not arrived): the syntax
  engine's resumable per-line `ParseState` and `HighlightState` are persisted
  across renders, so each committed line is highlighted exactly once. The source
  records the cost of not doing this: re-running the highlighter over the whole
  growing block cost ~35 ms per push near the end of a ~1000-line block.
- *Closed fences trapped in the unfrozen tail* — e.g. a fence inside an open
  list, which can never checkpoint: the batch highlight is memoized per
  `(fence_info, body)` under a **256 KiB body-byte budget**, cleared wholesale
  on overflow. The budget is sized in bytes rather than entries because a
  list-indented fence can be split into many per-line text events. Recorded
  cost of not doing this: 50–100 ms per re-run, and one observed 4.5 s UI
  freeze.

Invalidation for both is wholesale: the struct is dropped on any theme, style,
or width reset. Correctness is asserted byte-identical against a one-shot batch
render.

### M7 — Heavy work moved off the render thread, coalesced by key

Expensive per-block rendering runs on dedicated `std::thread` + mpsc workers,
not in the draw path: one for syntax-highlighting file edits, one for diagram
rendering (3 s render timeout). Both workers **coalesce queued jobs by key,
latest-wins**, so a burst of updates to the same block produces one render, and
older pending jobs for that key are dropped rather than pinning the fast tick.

### M8 — A scroll clock that paces wheel input over frames

Wheel deltas are not applied on arrival. A scroll stream accumulates pending
lines and flushes them on a cadence deadline (`scroll_cadence`, from M1), with
a per-flush cap and a "coast" budget that tapers motion after input stops:
`min(|pending|, max(lines_per_tick, |pending| / 2), coast_budget_left)`. The
deadline is only armed when a flush would actually apply lines, to avoid a
busy-spin. There is a PTY end-to-end test that fires a wheel burst and asserts
the number of synchronized-update pairs emitted — i.e. **frame amplification is
a tested invariant**, not a hope.

## 2.2 What OSA does today

### Present and correct

- **Synchronized output.** OSA does wrap its single draw in DEC 2026:
  `priv/rust/tui/src/app/event_loop.rs:1489` (`BeginSynchronizedUpdate`) and
  `:1496` (`EndSynchronizedUpdate`), with an unpair-recovery guard at
  `priv/rust/tui/src/main.rs:310-314`. Exactly one `terminal.draw()` call site,
  `event_loop.rs:1495`. This is fine.
- **Event coalescing.** The loop blocks on `event_rx.recv()`
  (`event_loop.rs:1510`) then drains the backlog with `try_recv()`
  (`event_loop.rs:1521-1529`), explicitly to collapse a burst into one redraw.
- **A frame-rate floor.** `MIN_DRAW_INTERVAL = 16ms` (`event_loop.rs:868`), with
  a deadline-absorb loop at `event_loop.rs:1537-1557` that keeps swallowing
  events until the deadline using `time::timeout_at`.
- **Incremental markdown.** `render/markdown_stream.rs` has a genuine frozen
  prefix (`:61-63`), incremental `advance()` (`:148-155`), and — importantly —
  an *incremental freeze scanner* that resumes from `self.scan.pos` rather than
  rescanning from byte 0 (`:76-83`, `:163-193`), which was the O(N²) fix.
- **Resumable syntax highlighting.** `render/syntax.rs:89-103` persists
  `ParseState`/`HighlightState` in a thread-local prefix memo, commits only
  complete lines (`:106-111`, `:162-168`), and highlights the trailing partial
  line from a clone that is never committed (`:170-181`). Measured payoff
  recorded at `:69-74`.
- **A reveal pacer.** `app/stream_pace.rs` is a real de-jitter buffer:
  `LAG_BUDGET = 120ms` (`:130`), `WARMUP_DELTAS = 6` (`:135`),
  `BURST_GAP_MS = 5.0` (`:149`), engage at `ENGAGE_CHUNK_CHARS = 12.0` /
  `ENGAGE_GAP_MS = 18.0` (`:154`, `:159`), release hysteresis at
  `RELEASE_CHUNK_CHARS = 8.0` / `RELEASE_GAP_MS = 11.0` (`:163-164`),
  `EWMA_ALPHA = 0.25` (`:168`). Release is deadline-proportional:
  `share = elapsed / (LAG_BUDGET - age)`, `want = ceil(total * share)` clamped
  to `[1, total]`, with a forced full release once `age >= LAG_BUDGET`
  (`:415-454`).

### The gaps, in order of likely contribution to the perceived speed difference

**G1 — No writer thread, no frame back-pressure.** OSA writes frames from the
event loop itself. `event_loop.rs:1495` draws and the bytes go straight out.
There is no `queued`/`written` sequence accounting and nothing equivalent to
`in_flight_target`. Under tmux, SSH, or any terminal that is slow to consume,
OSA's loop keeps producing frames the terminal has not finished displaying. This
is exactly the condition that reads as "laggy" rather than "slow": input
response degrades because the terminal is chewing through a backlog of stale
frames. **This is the single largest structural difference.** (M2)

**G2 — Fixed 16 ms cadence, no display probe.** `MIN_DRAW_INTERVAL` is a
hardcoded `Duration::from_millis(16)` at `event_loop.rs:868`. On a 120 Hz or
144 Hz display OSA paints at half or a third of the rate the panel can show,
which is directly perceptible as coarser motion during streaming and scrolling.
No probe, no env override, no telemetry on the effective cadence. (M1)

**G3 — The 16 ms cap only applies to a narrow case.** The deadline-absorb path
at `event_loop.rs:1537-1557` is gated on `batch_cadence_only &&
prev_batch_cadence_only`, where a cadence event is only a stream delta or an
`AnimationFrame` (`event_loop.rs:51-53`). Any mixed-event iteration bypasses the
cap entirely and draws immediately. There is no `draw_scheduled_at` equivalent:
when the cap *does* suppress a draw, nothing guarantees the deferred frame lands
one cadence later — it lands whenever the next event happens to arrive. (M3)

**G4 — No dirty flag; every iteration that reaches the draw call rebuilds the
whole viewport.** There is no general `needs_redraw`. The only dirty-ish state
is `resize_dirty` (`event_loop.rs:964`) and `force_redraw` (`:1466-1469`, which
does a `terminal.clear()`). All per-cell savings come from ratatui's buffer
diff, and — critically — OSA has no equivalent of "did the flush write any
cells?", so it cannot skip the frame entirely when nothing changed. An idle
animating frame still costs a full widget-tree rebuild. (M5)

**G5 — The markdown tail is re-rendered and the frozen prefix is *cloned* on
every call.** `render/markdown_stream.rs:203-215` re-runs `render_markdown` over
the tail on each render, and `body_with_cursor()` at `:221-225` does
`self.frozen_lines.clone()` — a full `Vec<Line>` clone of the entire frozen
prefix, every call. For a long reply that clone grows without bound. The chat
widget's second-layer cache
(`priv/rust/tui/src/components/chat/mod.rs:539-575`, keyed on
`(stream_gen, width)`) holds this to once per delta rather than once per frame,
but once per delta on an O(N) clone is still O(N²) over a reply. The reference
design avoids this by never materializing the frozen prefix as a fresh Vec —
frozen wrapped output is appended to and truncated in place. (M6)

**G6 — The syntax memo holds exactly one block, with no byte budget.**
`render/syntax.rs:100-103` is a single-slot thread-local. The reuse test at
`:134-140` requires the same language, same theme, and that `code` be a strict
prefix-extension of what was consumed — so **alternating between two fenced code
blocks thrashes the memo to zero hit rate**, falling back to full re-highlight
per delta. There is no closed-fence memo at all, so a closed fence stuck in the
unfrozen tail (inside an open list — precisely the common case in agent output)
is re-highlighted from scratch on every delta. There is also no size cap:
`:172` does `memo.lines.clone()` of the whole rendered block per call. The
reference design's two-cache split plus the 256 KiB budget exists specifically
because this case caused a multi-second freeze. (M6)

**G7 — No off-thread render workers.** OSA has no equivalent of the
coalesce-by-key background workers. All highlighting and layout happens inline
on the render path. (M7)

**G8 — No scroll clock.** Scroll input is applied as it arrives; there is no
cadence-paced flush, no per-flush cap, no coast taper, and no frame-amplification
test. OSA's debounces (`RESIZE_SETTLE = 50ms` at `event_loop.rs:837`,
`SHRINK_SETTLE_TICKS` at `:795`, `SLOT_SHRINK_HOLD = 200ms` at `:502`) are
settle timers, not pacers. (M8)

**G9 — The animation tick is coarse and single-rate.** `ANIMATION_FRAME = 32ms`
(~31 fps) at `event_loop.rs:62`, `TICK_INTERVAL = 200ms` at `:57`,
`ANIMATION_IDLE_POLL = 100ms` at `:67`. There is no slow/fast tick demand: the
reference design lets each view declare `None`/`Slow`(~83 ms)/`Fast`, and lets a
view raise a *ceiling* to request a faster tick than the configured fps. OSA
runs one rate for everything.

**G10 — The pacer's own doc contradicts itself.** `stream_pace.rs:3` says
"Default OFF" and the table at `:66-76` argues that pacing makes chunking worse,
but `from_env()` at `:202-213` defaults to `Auto` (`_ => PaceMode::Auto`, `:211`)
and the note at `:186-201` explains the reversal. Two contradictory rationales
live in one file header. Fix the header before anyone tunes these constants.

**G11 — No instrumentation.** No FPS HUD, no scroll HUD, no render-time
measurement, no frame-count assertions in tests. The reference harness has a PTY
harness that parses `CSI ? 2026 h/l` pairs out of the byte stream and records
wall-clock duration per frame, and uses it to assert that a wheel burst does not
amplify into extra frames. OSA cannot currently answer "how many frames did that
burst cost?" at all. Everything above is therefore unmeasurable until this
exists.

### Not a gap

OSA's reveal pacer (`stream_pace.rs`) is *more* sophisticated than what the
reference harness does for text reveal — the reference has no character-level
de-jitter buffer at all; it relies on M1–M5 to make paint-on-arrival look
smooth. So the perceived gap is **not** in reveal pacing. It is in frame
scheduling, back-pressure, and per-frame work. Do not spend effort tuning
`LAG_BUDGET`.

## 2.3 Ranked change list

Ranked by (impact on perceived speed) ÷ (implementation risk).

| # | Change | Impact | Risk | Ratio | Where |
|---|---|---|---|---|---|
| 1 | **Frame back-pressure + writer thread.** Move tty writes to a dedicated thread with sequence accounting; refuse to draw while a frame is in flight. | Very high — removes the dominant jank source under tmux/SSH | Medium — touches the terminal backend, needs careful shutdown/child-handoff ordering | **Highest** | `event_loop.rs` draw path, `inline_backend.rs`, `alt_screen.rs` |
| 2 | **Zero-byte idle frames.** Bypass `Terminal::draw()`; use `get_frame`/`flush`/`swap_buffers` and skip all output (including cursor commands) when the flush reports no cell changes. Fixes the non-blinking cursor as a side effect. | High | Low-medium — mechanical, well-specified | **Very high** | `event_loop.rs:1489-1496` |
| 3 | **Instrumentation first: `/debug fps\|scroll\|log` + a PTY frame-counting harness** that parses DEC 2026 pairs. | High (enabling) — nothing below is verifiable without it | Low | **Very high** | new; `app/commands.rs`, test harness |
| 4 | **Presenter state machine with `draw_scheduled_at`.** Replace the narrow `batch_cadence_only` gate with a general `dirty` + `force_full_repaint` + deferred-deadline presenter, and add a `select!` arm that sleeps until the scheduled draw. | High — makes the cadence cap actually universal and lossless | Low-medium | **High** | `event_loop.rs:1537-1557` |
| 5 | **Kill the frozen-prefix clone.** Stop returning `frozen_lines.clone()`; append/truncate wrapped output in place and hand out a borrowed slice. | High on long replies (removes an O(N²)) | Low — local to two functions | **High** | `render/markdown_stream.rs:221-225` |
| 6 | **Display-refresh probe → adaptive cadence.** `clamp(1000/hz, 8, 16)`, fail-closed on SSH/WSL/Linux, env override, report the effective value. | Medium-high on 120 Hz+ hardware; zero elsewhere | Low — pure function + one FFI probe, fully fail-closed | **High** | `event_loop.rs:868` |
| 7 | **Closed-fence syntax memo + byte budget.** Add a `(fence_info, body) -> lines` memo alongside the prefix memo, capped at 256 KiB of body bytes, cleared wholesale on overflow. | High whenever a code fence sits inside an open list (common) | Low-medium | **High** | `render/syntax.rs:89-181` |
| 8 | **Bound and interrupt the stream drain.** Cap the backlog drain at ~32 events **and** break the moment terminal input is pending. | Medium-high — input responsiveness during token floods | Low | **High** | `event_loop.rs:1521-1529` |
| 9 | **Multi-slot syntax memo** (small LRU keyed by language+theme+prefix) so alternating fences stop thrashing. | Medium | Low | Medium-high | `render/syntax.rs:100-103` |
| 10 | **Tick demand (None/Slow/Fast) + per-view tick ceiling.** | Medium — cuts idle work, allows genuinely smooth animations where wanted | Low-medium | Medium | `event_loop.rs:57-67`, `app/state.rs` |
| 11 | **Scroll clock** with cadence, per-flush cap, and coast taper. | Medium-high for scrolling specifically | Medium — easy to get wrong; needs the harness from #3 first | Medium | new, `app/event_loop.rs` + input handling |
| 12 | **Off-thread coalesce-by-key workers** for syntax/diagram/heavy block rendering. | Medium | Medium-high — threading + invalidation | Medium | new |
| 13 | **Priority-ordered biased select** with documented arm order; demote any high-frequency low-priority source to last. | Medium | Low | Medium | `event_loop.rs` select |
| 14 | **Fix the `stream_pace.rs` header contradiction.** | None on speed; prevents a future regression | Trivial | — | `render`/`app/stream_pace.rs:3,66-76,186-213` |

**Suggested sequencing:** #3 (instrument) → #2 and #5 (cheap, measurable wins)
→ #1 and #4 (the structural fix) → #6, #7, #8 → the rest. Do not start #11 or
#12 before #3 exists.
