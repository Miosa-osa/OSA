# TUI — Composer, Rendering, and Status

OSA's primary interface is a Rust TUI built on `ratatui`/`crossterm`
(`priv/rust/tui/`). It talks to the Elixir engine over a local HTTP + SSE API
and never reaches the internet directly. This doc covers the interface-layer
capabilities added this cycle; see `docs/BACKLOG.md` (`TUI — composer` /
`TUI — render` / `TUI — notifications...` / `TUI — status / activity` rows)
for the item-by-item scoreboard.

---

## Composer

**Module:** `priv/rust/tui/src/components/input/`

- **Structured `@`-mentions** — typing `@` opens a fuzzy picker over files,
  directories, and agents (`Candidate`/`MentionKind` in `mentions.rs`), with
  a per-kind glyph in the popup so you can tell a file mention from an agent
  mention at a glance. Selecting one inserts a structured attachment, not
  just a plain path string.
- **Frecency-ranked recall** (`Frecency` in `mentions.rs`) — mentions you use
  often and recently rank higher in the picker, the same frequency+recency
  scoring pattern used elsewhere in OSA (e.g. memory relevance).
- **Ghost-text completion** — an inline, dimmed suggestion for the likely
  rest of a command/mention, accepted with a single keystroke.
- **Bash submit-mode** — prefix a line with `!` to submit it as a shell
  command without leaving the chat (`SubmitKind` in `mentions.rs`).
- **Huge-input pill** — pasting a very large block collapses to a compact
  "N lines pasted" pill instead of flooding the composer, expandable on
  demand.
- **History navigation** — Ctrl+N/P walk composer history; Alt+D deletes a
  word forward, matching common readline bindings.

Image mentions carry through to the backend as structured data today;
non-image structured `@file`/`@agent` references still reach the model as
inline prompt text (nothing is lost — it's just not a distinct wire field
yet). A fully structured carry needs a new `OrchestrateRequest` field plus
backend handling; tracked as a small deferred backend feature, not TUI glue.

---

## Rendering

**Module:** `priv/rust/tui/src/render/`

- **LaTeX → Unicode** (`latex.rs`) — inline and block LaTeX math is
  converted to readable Unicode math characters for terminal display instead
  of showing raw `\(...\)`/`\[...\]` source.
- **Table-cell markdown** — nested block-quotes, tabs, and soft line breaks
  inside table cells now render correctly instead of breaking the table
  layout.
- **Bold-italic and setext headings** — `***bold italic***` and
  underline-style (`===`/`---`) headings render correctly.
- **Raw-source toggle** (`Alt+R`) — flips a message between rendered and raw
  markdown source, useful when the rendered form obscures something (a code
  block that looks like a table, for instance). A live-preview swap while
  streaming is deliberately not implemented — it's in tension with the
  fixed-height streaming viewport invariant below.

---

## Fixed-Height Streaming Viewport

The inline chat viewport now holds a **constant height** while a response
streams in, instead of reflowing/resizing the terminal on every chunk. This
removes the flicker and scroll-position jumpiness that comes from a growing
viewport competing with terminal auto-scroll during a long streamed
response. `PlanReview` was also removed from the overlay-classification path
that used to interact with this invariant.

---

## Notifications, Focus, Clipboard, Sleep Inhibitor

**Module:** `priv/rust/tui/src/notification/`

- **Focus tracking** (`focus.rs`, DECSET 1004) — the TUI knows whether the
  terminal window currently has focus, used to decide whether a completion
  notification is worth firing (no point notifying if you're already
  looking at it).
- **OSC 9;4 progress** (`progress.rs`) — reports turn progress to
  terminal-emulator-level progress indicators (e.g. taskbar/dock progress on
  supporting terminals).
- **Sleep inhibitor** (`inhibit.rs`) — prevents the machine from sleeping
  during a long-running turn.
- **Audio completion cue** (`sound.rs`) — an optional sound on turn
  completion.
- **Kitty click-to-focus / re-push** (`kitty.rs`) — kitty-protocol-specific
  focus and keyboard-enhancement re-push handling.
- **Layered clipboard** — copy operations layer correctly instead of
  clobbering each other across nested contexts (e.g. copying a tool result
  vs copying selected text).
- **Notification channel selection** — `NotificationConfig::from_env`
  chooses the channel and honors an opt-out. See env vars below.

### Environment Variables

| Env Var | Default | Effect |
|---|---|---|
| `OSA_NOTIFY_CHANNEL` | terminal-detected | Selects the desktop-notification channel. Unknown/unset falls back to auto-detection. |
| `OSA_NO_NOTIFY` | unset (on) | Set to any value to disable completion notifications entirely (checked via `var_os`, so an empty value still disables). Also gates `notify_on_complete` in `app/mod.rs`. |
| `OSA_COLOR_LEVEL` | auto-detected | Overrides terminal color-capability detection (`render/colors.rs`). Takes precedence over `NO_COLOR` and a `TERM=dumb` check. |

---

## Status and Activity Cues

- **Esc-again-to-interrupt** — pressing Esc once clears the composer; a
  second Esc while a turn is running interrupts it (distinct from the
  Esc-Esc rewind gesture, which triggers from an empty composer).
- **Watcher/background cue** — a visible indicator when a background task or
  watcher is active.
- **Queued-message hint** — shows when a message you sent will be queued
  behind an in-flight turn rather than sent immediately.
- **Usage-percent + low-balance indicator** — context/budget usage shown as
  a percentage with a low-balance warning state.
- **MCP status chip** — shows connected MCP server status inline. (An
  equivalent LSP status half was scoped but not built — OSA has no backend
  LSP concept to surface.)
- **Width-gated spinner** — the busy spinner adapts its rendering to
  available terminal width instead of overflowing on narrow terminals.
- **Subagent footer** — a footer line summarizing active sub-agent activity
  (tool count, token usage) while delegation is running.
- **Categorical `/context`** — `/context` breaks down context usage by
  category rather than a single aggregate number.

---

## See Also

- [Desktop (Tauri Command Center)](../desktop/README.md) — the separate
  Tauri/SvelteKit desktop app, not this terminal TUI
- [CLI Command Reference](../reference/cli-reference.md)
- [Agent Loop](../backend/agent-loop/loop.md)
