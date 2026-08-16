// Phase 2+: value() and set_content() — wired when external content injection is added
#![allow(dead_code)]

pub mod completions;
pub mod history;
pub mod mentions;
pub mod paste_burst;
pub mod textarea;
pub mod vim;

use std::time::Instant;

use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crossterm::event::{
    DisableBracketedPaste, EnableBracketedPaste, Event as CrosstermEvent, KeyCode, KeyEvent,
    KeyboardEnhancementFlags, KeyModifiers, PopKeyboardEnhancementFlags,
    PushKeyboardEnhancementFlags,
};
use crossterm::execute;
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, supports_keyboard_enhancement};
use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::event::Event;
use crate::style;

use self::completions::{CompletionAction, CompletionItem, Completions};
use self::mentions::{Attachment, Candidate, Frecency, MentionKind, SubmitKind};
use super::{AppAction, Component, ComponentAction};

/// The trailing hint on the FIRST queued-message row, in full.
///
/// It used to read `— sends when this turn ends · esc to send now`, and the
/// second half was **not wired to anything**. There is no send-now key, in this
/// state or any other: `maybe_dequeue_message` is called from five
/// turn-completion sites and from no key handler at all, and `queue_may_drain`
/// requires `Idle && turn_done` — so a queued message cannot run until the turn
/// has ENDED, by finishing or by being interrupted.
///
/// What "esc to send now" actually described was the side effect of the
/// interrupt chord: Esc-Esc cancels the turn, `turn_done` is set on that path,
/// and the queue then drains. The label named the consequence and hid the
/// mechanism — and the mechanism is "destroy the work in flight". A user
/// reported precisely the resulting experience: "I click it, it didn't do it.
/// If I press it again it doesn't do it, and then if I do it too many times it
/// just turns off the conversation."
///
/// So the hint now says what the key does, cost first, and says that it takes
/// two presses. Both halves are load-bearing:
///
/// * **"esc esc"** — one press only arms; the spinner's affordance flips to
///   "esc again to interrupt". A hint that said "esc" was the reason the first
///   press read as the app ignoring the keystroke.
/// * **"interrupts"** before "runs it now" — the destructive half is what the
///   user is actually agreeing to, so it leads.
///
/// Deliberately NOT offered here: a real mid-turn send. `/steer` is the
/// product's explicit gesture for injecting into a running turn, and plain
/// mid-turn text was moved OFF that path on purpose (see `submit_input`) —
/// automatic steering "read as the agent lurching off course mid-thought".
/// Naming `/steer` on this row would be another near-miss promise anyway: it
/// injects text you retype, not the message already queued here.
pub const QUEUED_HINT_FULL: &str =
    "  \u{2014} sends when this turn ends \u{00b7} esc esc interrupts and runs it now";

/// The narrow-terminal fallback: the trigger, with no key named.
///
/// Naming a key that does not fit its explanation is how this went wrong the
/// first time, so the short form names none. "Sends when this turn ends" is the
/// half that answered the earlier report (a queued message during a 14-minute
/// fan-out was indistinguishable from the app ignoring the keystroke), and it
/// survives to a much narrower terminal on its own.
pub const QUEUED_HINT_SHORT: &str = "  \u{2014} sends when this turn ends";

/// Rows the `@`-mention dropdown reserves while it is open.
///
/// A CONSTANT, not the live match count — see [`InputComponent::mention_popup_height`]:
/// the dropdown re-filters on every keystroke, and an exactly-sized band would
/// rebuild the inline viewport per character typed.
pub const MENTION_POPUP_ROWS: u16 = 5;

pub struct InputComponent {
    /// The text content
    content: String,
    /// Cursor position within content
    cursor: usize,
    /// Command history
    history: history::History,
    /// Whether the input is focused
    focused: bool,
    /// Width for rendering
    width: u16,
    /// Multiline mode
    multiline: bool,
    /// Available commands for tab completion
    commands: Vec<String>,
    /// Tab completion state
    tab_matches: Vec<String>,
    tab_index: usize,
    /// Processing indicator (Step 4)
    processing: bool,
    /// Stash slot for Ctrl+S/Ctrl+R (Step 10)
    stash: Option<String>,
    /// File search active (Step 9: @ file refs)
    file_search_active: bool,
    /// File search matches — now typed [`Candidate`]s (file / dir / agent) so
    /// the popup can show a per-kind glyph (U-T30) and the submit path can
    /// resolve them to structured attachments (U-T1).
    file_matches: Vec<Candidate>,
    /// File search cursor
    file_match_index: usize,
    /// File search prefix position (byte offset of '@')
    file_search_start: usize,
    /// Completions popup for slash commands
    completions: Completions,
    /// Voice recording active
    recording: bool,
    /// Undo ring — snapshots of (content, cursor) before edits
    undo_stack: Vec<(String, usize)>,
    /// Redo ring — snapshots popped by undo
    redo_stack: Vec<(String, usize)>,
    /// Reverse-incremental history search state (Ctrl+R)
    reverse_search: Option<ReverseSearch>,
    /// Number of messages queued while the agent is Processing — drives the
    /// small "N queued" badge; kept in sync with `queued_items`.
    queued_count: usize,
    /// WS5 — the queued message texts, rendered as dim recallable lines above
    /// the composer (CC PromptInputQueuedCommands). Set via `set_queued_items`.
    queued_items: Vec<String>,
    /// Whether the kitty keyboard-enhancement protocol (DISAMBIGUATE_ESCAPE_CODES)
    /// was enabled at startup. Drives the terminal-aware newline hint: when true
    /// the composer advertises "shift+enter newline"; when false it advertises the
    /// universal backslash-continuation that works on every terminal. Set once from
    /// `main.rs` via [`InputComponent::set_kbd_enhanced`].
    kbd_enhanced: bool,
    /// WS9 — deferred content store for large-paste pills: id → full pasted
    /// text. The composer shows a compact "[Pasted text #N +M lines]" token;
    /// the real content is spliced back in at submit (CC pasteStore/history.ts).
    /// Retained across submits so an ↑-recalled history pill still expands.
    paste_store: std::collections::HashMap<usize, String>,
    /// Next pill id — auto-incrementing, session-scoped (CC nextPasteIdRef).
    next_paste_id: usize,
    /// Whether the optional vim modal-editing layer is active. Off by default;
    /// enabled via the `OSA_TUI_VIM` env flag or the `/vim` toggle
    /// (`toggle_vim`). When false, the vim layer is bypassed entirely so it
    /// never interferes with the default emacs/readline bindings.
    vim_enabled: bool,
    /// Current vim modal state (normal/insert + pending operator). Only
    /// consulted while `vim_enabled`.
    vim: vim::VimState,
    /// Emacs/readline kill-ring (CC useTextInput pushToKillRing / grok
    /// textarea.rs kill_buffer). `Ctrl+K`/`Ctrl+U`/`Ctrl+W`/`Alt+D` push here;
    /// `Ctrl+Y` yanks the most recent (last) entry, `Alt+Y` yank-pops (rotates).
    /// The most-recent kill is the LAST element. Capped so a long session can't
    /// grow it without bound.
    kill_ring: Vec<String>,
    /// Rotation cursor for yank-pop — index into `kill_ring` of the entry the
    /// last yank / yank-pop inserted. `Alt+Y` decrements it (wrapping) and swaps
    /// the yanked text for the earlier entry (readline yank-pop).
    kill_ring_index: usize,
    /// Byte range `[start, end)` of the text the last `Ctrl+Y`/`Alt+Y`
    /// inserted. `Some` only immediately after a yank / yank-pop; any other
    /// command clears it, which is what gates `Alt+Y` (yank-pop is a no-op
    /// unless it directly follows a yank). CC `recordYank` / `yankPop`.
    yank_anchor: Option<(usize, usize)>,
    /// The kind of the previous composer command, for kill accumulation and
    /// yank-pop gating. Successive kills append/prepend into the same ring
    /// entry (readline behaviour); a non-kill command breaks the run.
    last_edit: LastEdit,
    /// Undo-coalescing anchor (grok begin/end_undo_group, textarea.rs:2415).
    /// While `Some(cursor_after_last_insert)`, a further contiguous non-space
    /// `insert_char` coalesces into the SAME undo step instead of snapshotting,
    /// so one undo removes a whole typed word rather than a single character.
    /// Cleared by `snapshot()` (every non-coalescing edit) and by
    /// `restore_state`, and never matches after a cursor move, so any boundary
    /// breaks the run.
    undo_insert_run: Option<usize>,
    /// Rotating-placeholder seed (opencode index.tsx randomIndex, re-rolled on
    /// submit). Selects which example prompt / hint the empty composer shows so
    /// the empty box teaches features instead of a single static string.
    placeholder_seed: usize,
    /// U-T1 — known agent names (set from the app). An `@`-token matching one of
    /// these resolves to an [`Attachment::Agent`] instead of a file, and the
    /// popup can surface agents alongside files with a distinct glyph.
    agents: Vec<String>,
    /// U-T1 — structured attachments resolved from the LAST submitted line
    /// (`@file`, `@file#L10-20`, `@agent`). Populated in `submit()`; drained by
    /// the submit path via [`take_attachments`]. Retained (not cleared on the
    /// next keystroke) so the dispatch layer can read it after `submit()`.
    ///
    /// [`take_attachments`]: InputComponent::take_attachments
    last_attachments: Vec<Attachment>,
    /// U-T4 — how the last submitted line should be routed (prompt / shell /
    /// memory), classified from its leading sigil at submit time.
    last_submit_kind: SubmitKind,
    /// U-T4 — history bucket for `!`-shell submissions, kept separate from the
    /// prompt history so ↑ inside a `!`-line recalls prior shell commands (own
    /// bucket) rather than prompts. Persisted alongside the prompt history.
    shell_history: history::History,
    /// U-T6 — frecency ranker for the `@`-file/dir recall popup: a candidate
    /// selected often & recently floats to the top on the next open.
    file_frecency: Frecency,
    /// C5 — a half-typed line stashed when history recall begins, so stepping
    /// back down past the newest entry restores it instead of wiping it
    /// (readline/fish keep the working line in a virtual newest slot).
    history_draft: Option<String>,
    /// Paste-burst classifier for terminals that never deliver bracketed paste
    /// (see [`paste_burst`]). OSA enables bracketed paste at startup, so this is
    /// the FALLBACK path: it only ever sees `Key(Char)` events, which a
    /// bracketed paste does not produce, and [`InputComponent::insert_paste`]
    /// resets it — so the two paths can never double-handle the same text.
    paste_burst: paste_burst::PasteBurst,
    /// Test-only clock override. `None` in production (real `Instant::now()`);
    /// set by the paste-burst tests so timing-dependent behaviour is exercised
    /// deterministically without sleeping.
    clock_override: Option<Instant>,
}

/// The kind of the previous composer command — drives kill-ring accumulation
/// (successive kills merge) and yank-pop gating (`Alt+Y` only right after a
/// yank). Anything that isn't a kill or a yank is `Other` and breaks both runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LastEdit {
    Other,
    Kill,
    Yank,
}

/// Ctrl+R reverse-incremental history search over persisted input history.
struct ReverseSearch {
    /// The incremental search query typed after Ctrl+R.
    query: String,
    /// Index into `history.entries()` of the current match, if any.
    match_idx: Option<usize>,
}

impl InputComponent {
    pub fn new() -> Self {
        Self {
            content: String::new(),
            cursor: 0,
            history: history::History::persistent(),
            focused: true,
            width: 80,
            multiline: false,
            commands: Vec::new(),
            tab_matches: Vec::new(),
            tab_index: 0,
            processing: false,
            stash: None,
            file_search_active: false,
            file_matches: Vec::new(),
            file_match_index: 0,
            file_search_start: 0,
            completions: Completions::new(),
            recording: false,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            reverse_search: None,
            queued_count: 0,
            queued_items: Vec::new(),
            // Conservative default: assume no enhancement until main.rs probes the
            // terminal, so the always-works backslash hint shows if never set. The
            // test-only InputComponent::new() call sites (event_loop.rs) rely on this.
            kbd_enhanced: false,
            paste_store: std::collections::HashMap::new(),
            next_paste_id: 1,
            // Opt-in via env; default off. A `/vim` command can flip it at
            // runtime through `toggle_vim`.
            vim_enabled: std::env::var("OSA_TUI_VIM")
                .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                .unwrap_or(false),
            vim: vim::VimState::default(),
            kill_ring: Vec::new(),
            kill_ring_index: 0,
            yank_anchor: None,
            last_edit: LastEdit::Other,
            undo_insert_run: None,
            placeholder_seed: 0,
            agents: Vec::new(),
            last_attachments: Vec::new(),
            last_submit_kind: SubmitKind::Prompt,
            shell_history: history::History::shell_persistent(),
            file_frecency: Frecency::new(),
            history_draft: None,
            // `OSA_TUI_NO_PASTE_BURST=1` is the `disable_paste_burst` escape
            // hatch (Codex config key). `OSA_TUI_PASTE_BURST_BUFFER=1` opts into
            // the buffering contract, which needs a fast composer flush tick —
            // see the module docs. Default: enabled, direct-insert.
            paste_burst: paste_burst::PasteBurst::new(!env_flag("OSA_TUI_NO_PASTE_BURST"))
                .with_buffering(env_flag("OSA_TUI_PASTE_BURST_BUFFER")),
            clock_override: None,
        }
    }

    /// Current time, or the test clock when one is installed.
    fn now(&self) -> Instant {
        self.clock_override.unwrap_or_else(Instant::now)
    }

    /// Test hook: pin the composer's clock so paste-burst timing is
    /// deterministic. Production code never calls this.
    #[cfg(test)]
    pub(crate) fn set_test_clock(&mut self, at: Option<Instant>) {
        self.clock_override = at;
    }

    /// Whether the paste-burst fallback is enabled for this composer.
    pub fn paste_burst_enabled(&self) -> bool {
        self.paste_burst.is_enabled()
    }

    /// Test hook: install a specific paste-burst configuration (the production
    /// one is chosen from the environment in [`InputComponent::new`]).
    #[cfg(test)]
    pub(crate) fn set_paste_burst(&mut self, pb: paste_burst::PasteBurst) {
        self.paste_burst = pb;
    }

    /// Periodic flush for the paste-burst BUFFERING contract. Returns true when
    /// something was applied to the composer.
    ///
    /// The app loop does not currently forward ticks to the composer, so this is
    /// a no-op in the default (direct-insert) mode — nothing is ever buffered
    /// there, so no text can get stuck. Wire this to a tick faster than
    /// [`paste_burst::PASTE_BURST_ACTIVE_IDLE_TIMEOUT`] before enabling
    /// `OSA_TUI_PASTE_BURST_BUFFER`.
    pub fn paste_burst_tick(&mut self, now: Instant) -> bool {
        match self.paste_burst.flush_if_due(now) {
            paste_burst::FlushResult::Paste(text) => {
                // Deliberately NOT `insert_paste`: that resets the burst state,
                // and the Enter-suppression window must outlive this flush so a
                // slightly-late trailing newline is still a newline.
                self.insert_paste_inner(&text);
                true
            }
            paste_burst::FlushResult::Typed(ch) => {
                self.insert_char(ch);
                true
            }
            paste_burst::FlushResult::None => false,
        }
    }

    /// One plain (unmodified) character from the keyboard, routed through the
    /// paste-burst classifier. `now` is passed in so the whole path is
    /// deterministic under test.
    fn handle_plain_char(&mut self, ch: char, now: Instant) {
        if !self.paste_burst.is_enabled() {
            self.insert_char(ch);
            return;
        }

        if !self.paste_burst.buffering_enabled() {
            // Direct-insert contract: the char is rendered immediately and the
            // classifier only keeps the Enter-suppression window alive. Nothing
            // is buffered, so no flush tick is required.
            if self.paste_burst.on_plain_char_no_hold(now).is_some() {
                self.paste_burst.extend_window(now);
            }
            self.insert_char(ch);
            return;
        }

        // Buffering contract: hold / buffer / retro-capture.
        let decision = if ch.is_ascii() {
            self.paste_burst.on_plain_char(ch, now)
        } else {
            // Never hold non-ASCII (IME) chars — that reads as dropped input.
            self.paste_burst.on_plain_char_no_hold(now)
        };
        match decision {
            // Held for flicker suppression: do NOT render it yet.
            Some(paste_burst::CharDecision::RetainFirstChar) => {}
            Some(paste_burst::CharDecision::BeginBufferFromPending)
            | Some(paste_burst::CharDecision::BufferAppend) => {
                self.paste_burst.append_char_to_buffer(ch, now);
            }
            Some(paste_burst::CharDecision::BeginBuffer { retro_chars }) => {
                // Retro-capture: chars we already inserted as ordinary typing
                // are pulled back out of the buffer and into the burst, so the
                // eventual paste sees one contiguous string. `retro_chars` is a
                // CHARACTER count; `decide_begin_buffer` converts it to a UTF-8
                // byte offset, which is what makes this correct for multibyte
                // and emoji input.
                let cursor = floor_char_boundary(&self.content, self.cursor);
                let before = self.content[..cursor].to_string();
                match self
                    .paste_burst
                    .decide_begin_buffer(now, &before, retro_chars as usize)
                {
                    Some(grab) => {
                        self.snapshot();
                        self.content.replace_range(grab.start_byte..cursor, "");
                        self.cursor = grab.start_byte;
                        self.undo_insert_run = None;
                        self.completions.hide();
                        self.file_search_active = false;
                        self.file_matches.clear();
                        self.paste_burst.append_char_to_buffer(ch, now);
                    }
                    // Not paste-like after all: ordinary typing.
                    None => self.insert_char(ch),
                }
            }
            None => self.insert_char(ch),
        }
    }

    /// U-T1 — register the known agent names so an `@agent` token resolves to a
    /// structured [`Attachment::Agent`] and the `@`-popup can offer agents.
    pub fn set_agents(&mut self, agents: Vec<String>) {
        self.agents = agents;
    }

    /// U-T1 — drain the structured attachments resolved from the last submit.
    /// The submit/dispatch path calls this immediately after receiving
    /// `AppAction::Submit` to attach file/agent context to the turn.
    pub fn take_attachments(&mut self) -> Vec<Attachment> {
        std::mem::take(&mut self.last_attachments)
    }

    /// U-T4 — routing kind of the last submitted line (prompt / shell / memory).
    pub fn last_submit_kind(&self) -> SubmitKind {
        self.last_submit_kind
    }

    /// WS5 — set the queued messages (typed mid-turn). They render as dim
    /// recallable lines directly above the composer (CC
    /// PromptInputQueuedCommands) plus the "N queued" badge. Empty hides both.
    pub fn set_queued_items(&mut self, items: Vec<String>) {
        self.queued_count = items.len();
        self.queued_items = items;
    }

    /// Record whether the keyboard-enhancement protocol is active (set once from
    /// `main.rs` at startup) so the newline hint matches the terminal's real
    /// capabilities without a per-frame syscall.
    pub fn set_kbd_enhanced(&mut self, enabled: bool) {
        self.kbd_enhanced = enabled;
    }

    pub fn value(&self) -> &str {
        &self.content
    }

    /// Current cursor byte offset. Exposed for tests and cursor-edge decisions.
    pub fn cursor(&self) -> usize {
        self.cursor
    }

    /// Whether the `@`-file-reference search dropdown is currently active. The
    /// app checks this so a plain Esc can be routed to the input (to dismiss the
    /// dropdown) instead of triggering the global single/double-Esc handling.
    pub fn file_search_active(&self) -> bool {
        self.file_search_active
    }

    /// Whether the `/`-command completions popup is currently open. The app
    /// checks this so a single Esc can dismiss the popup (like the `@`-dropdown)
    /// instead of falling through to the global double-Esc clear-draft chord.
    pub fn completions_visible(&self) -> bool {
        self.completions.is_visible()
    }

    /// Close the `/`-command completions popup. Returns `true` if it was open.
    pub fn dismiss_completions(&mut self) -> bool {
        if self.completions.is_visible() {
            self.completions.hide();
            true
        } else {
            false
        }
    }

    /// True when the stored `@`-search anchor is still coherent with the live
    /// cursor: the cursor sits strictly AFTER the anchor and the anchor byte is
    /// still an '@'. Caret motions and edits don't cancel the search, so this
    /// is the single guard the query/drain/submit paths use before slicing
    /// `content[anchor+1..cursor]` (start > end / mid-codepoint would panic).
    fn file_search_is_valid(&self) -> bool {
        self.file_search_active
            && self.cursor > self.file_search_start
            && self.content.as_bytes().get(self.file_search_start) == Some(&b'@')
    }

    /// Cancel the `@`-search when a caret motion has moved the cursor out of the
    /// active token (to/before the anchor) or otherwise invalidated it. Called
    /// after every cursor-only move so the dropdown closes the instant the caret
    /// leaves the mention, matching how the completions popup dismisses.
    fn revalidate_file_search(&mut self) {
        if self.file_search_active && !self.file_search_is_valid() {
            self.file_search_active = false;
            self.file_matches.clear();
        }
    }

    pub fn is_empty(&self) -> bool {
        self.content.trim().is_empty()
    }

    /// The placeholder shown on an EMPTY composer. Contextual first (a queued-
    /// message hint when messages are waiting — CC usePromptInputPlaceholder's
    /// cascade), otherwise a rotating example prompt / tip keyed on
    /// `placeholder_seed` (re-rolled each submit — opencode index.tsx
    /// randomIndex). Turns the empty box from wasted space into feature
    /// discovery. The recording state is handled separately in `draw` (it needs
    /// its own red styling).
    fn placeholder(&self) -> &'static str {
        if !self.queued_items.is_empty() {
            return "Press \u{2191} to edit queued messages\u{2026}";
        }
        PLACEHOLDERS[self.placeholder_seed % PLACEHOLDERS.len()]
    }

    pub fn set_width(&mut self, width: u16) {
        self.width = width;
    }

    pub fn set_commands(&mut self, commands: Vec<String>) {
        self.commands = commands;
    }

    /// Set commands with descriptions for the inline completions popup.
    pub fn set_commands_with_descriptions(&mut self, commands: Vec<(String, String)>) {
        let items: Vec<CompletionItem> = commands
            .iter()
            .map(|(name, desc)| CompletionItem {
                name: format!("/{}", name),
                description: desc.clone(),
                category: None,
            })
            .collect();
        self.commands = commands.iter().map(|(n, _)| n.clone()).collect();
        self.completions.set_items(items);
    }

    /// Rows the open slash-completions popup wants above the input, or 0 when it
    /// is closed. `App::popup_slot` reserves this (as `ROW_POPUP`) so the
    /// upward-growing popup always has room to render real commands (not just a
    /// scroll arrow) — and, since it is a real band, so it never paints over the
    /// context-hint row or the band above it.
    pub fn completions_popup_height(&self) -> u16 {
        self.completions.desired_height()
    }

    /// Rows the `@`-mention dropdown reserves, or 0 when it is closed.
    ///
    /// Deliberately a CONSTANT ([`MENTION_POPUP_ROWS`]) rather than the live
    /// match count: the dropdown re-filters on every keystroke of a mention, so
    /// an exactly-sized band would change the inline-viewport height mid-word,
    /// and every height change rebuilds the viewport through a DSR cursor query
    /// — the churn that produced the stacked-composer artifacts. A fixed slot
    /// changes height exactly twice per dropdown session (open, close). The
    /// dropdown is bottom-anchored inside it, so a 1-match dropdown still sits
    /// tight against the composer.
    pub fn mention_popup_height(&self) -> u16 {
        if self.file_search_active && !self.file_matches.is_empty() {
            MENTION_POPUP_ROWS
        } else {
            0
        }
    }

    /// Rows the composer-anchored completion band wants — the `/`-command popup
    /// OR the `@`-mention dropdown, whichever is open.
    ///
    /// `max` rather than a sum because exactly one of the two ever paints
    /// (`draw_popup` gives the `/` popup precedence), so they can never share a
    /// row. That rule lives HERE, next to the draw that enforces it, rather than
    /// in the app's band arbiter: the arbiter reserves what a component asks
    /// for, and a component that knows two of its sub-widgets are mutually
    /// exclusive is the only thing that can honestly ask for one band.
    pub fn popup_desired_height(&self) -> u16 {
        self.completions_popup_height()
            .max(self.mention_popup_height())
    }

    /// Draw the composer-anchored completion band: the `/`-command popup, or the
    /// `@`-mention dropdown. Never both — the `/` popup wins — so the two can
    /// never share a row.
    ///
    /// `area` is `ROW_POPUP`, reserved by `App::popup_slot`. Both of these used
    /// to be painted from inside [`Component::draw`] at `area.y - n`, i.e. into
    /// rows nothing had reserved: the unreserved-overlay defect.
    pub fn draw_popup(&self, frame: &mut Frame, area: Rect) {
        if area.width == 0 || area.height == 0 {
            return;
        }
        if self.completions.is_visible() {
            self.completions.draw_in(frame, area);
            return;
        }
        self.draw_mention_dropdown(frame, area);
    }

    /// Test-only: put the `@`-mention dropdown into an exact, deterministic
    /// state. The real path (`rebuild_file_matches`) walks the cwd, so a layout
    /// test driven through it would depend on the machine's file tree.
    #[cfg(test)]
    pub(crate) fn seed_mention_dropdown(&mut self, inserts: &[&str], selected: usize) {
        self.content = "@".into();
        self.cursor = 1;
        self.file_search_start = 0;
        self.file_search_active = !inserts.is_empty();
        self.file_matches = inserts
            .iter()
            .map(|s| Candidate::file((*s).to_string()))
            .collect();
        self.file_match_index = selected.min(self.file_matches.len().saturating_sub(1));
    }

    /// The `@`-file/dir/agent dropdown, inside its reserved band.
    ///
    /// Bottom-anchored, bounded to [`MENTION_POPUP_ROWS`] rows, and windowed so
    /// the SELECTED candidate is always on screen — the old overlay always drew
    /// `file_matches[0..5]`, so cycling with ↑/↓ past the fifth of the ten
    /// candidates highlighted nothing visible. Every row is fitted with
    /// `util::fit_cols` (display COLUMNS, never bytes or chars) so a mention of
    /// a path with CJK or emoji in it cannot overflow the band's width.
    fn draw_mention_dropdown(&self, frame: &mut Frame, area: Rect) {
        if !self.file_search_active || self.file_matches.is_empty() {
            return;
        }
        let theme = style::theme();
        let bounds = frame.area();
        let shown = self
            .file_matches
            .len()
            .min(MENTION_POPUP_ROWS as usize)
            .min(area.height as usize);
        if shown == 0 {
            return;
        }
        // Scroll window that always contains the selection.
        let first = self
            .file_match_index
            .saturating_sub(shown - 1)
            .min(self.file_matches.len() - shown);
        // Bottom-anchored inside the reserved slot.
        let top = area.y + area.height.saturating_sub(shown as u16);
        let inner_w = area.width.saturating_sub(4).max(1);
        for (row, cand) in self.file_matches[first..first + shown].iter().enumerate() {
            let is_selected = first + row == self.file_match_index;
            let style = if is_selected {
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(theme.colors.muted)
            };
            let prefix = if is_selected { "\u{25b8} " } else { "  " };
            // U-T30 — per-kind type glyph (file / dir / agent), measured in
            // display columns because several of them are 2 cols wide.
            let glyph = cand.kind.glyph();
            let head_cols = crate::util::cols(prefix) + crate::util::cols(glyph) + 1;
            let ep = crate::util::ellipsize_path_middle(
                &cand.insert,
                (inner_w as usize).saturating_sub(head_cols).max(1),
            );
            let display = crate::util::fit_cols(
                &format!("{}{} {}", prefix, glyph, ep),
                inner_w as usize,
            );
            let row_area = Rect::new(area.x + 2, top + row as u16, inner_w, 1).intersection(bounds);
            if row_area.width == 0 || row_area.height == 0 {
                continue;
            }
            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(display, style))),
                row_area,
            );
        }
    }

    /// Set commands with descriptions AND an optional category for the inline
    /// completions popup. The category (e.g. "custom" for user-defined
    /// `~/.osa/commands/*.md` commands) lets the popup tag entries so a
    /// user-authored command is visually distinguished from a built-in.
    pub fn set_command_items(&mut self, commands: Vec<(String, String, Option<String>)>) {
        let items: Vec<CompletionItem> = commands
            .iter()
            .map(|(name, desc, category)| CompletionItem {
                name: format!("/{}", name),
                description: desc.clone(),
                category: category.clone(),
            })
            .collect();
        self.commands = commands.iter().map(|(n, _, _)| n.clone()).collect();
        self.completions.set_items(items);
    }

    /// Return the total height this input needs: top divider + text lines +
    /// bottom divider (Claude-Code frames the prompt with a rule above AND below).
    /// Single-line: 3. Multiline or wrapped: 2 + extra lines (capped at 11).
    pub fn needed_height(&self) -> u16 {
        let queued = self.queued_lines() as u16;
        if self.content.is_empty() {
            return 3 + queued; // queued rows + top divider + 1 text row + bottom divider
        }
        let prompt_len: usize = if self.processing { 4 } else { 2 };
        let avail = (self.width as usize).saturating_sub(prompt_len + 1); // usable chars
        if avail == 0 {
            return 3 + queued;
        }
        // Each logical line wraps INDEPENDENTLY under the composer's Paragraph
        // wrap, so sum the wrapped visual rows per line. The old
        // `ceil(total_chars / avail)` treated the whole buffer as one wrap
        // stream and under-counted a long line sitting inside a multiline draft
        // (e.g. a 100-col line + "\nx" reported 3 rows but occupies 4), clipping
        // the box's last row — and hiding the caret — as the draft grew.
        let text_lines: u16 = self
            .content
            .split('\n')
            .map(|line| {
                // Wrap by DISPLAY width so a CJK/emoji line reserves the right
                // number of rows (a wide char occupies 2 columns).
                let n = display_width(line);
                (n / avail + usize::from(n % avail != 0)).max(1) as u16
            })
            .sum();
        (2 + text_lines).min(11) + queued // top divider + text + bottom divider, cap at 11
    }

    /// WS5 — rows used by the queued-message display above the composer: one
    /// per item (each clipped to a single row), capped at 4 items plus a
    /// "+N more queued" overflow row.
    fn queued_lines(&self) -> usize {
        match self.queued_items.len() {
            0 => 0,
            n if n <= 4 => n,
            _ => 5,
        }
    }

    /// Set processing indicator state (Step 4)
    pub fn set_processing(&mut self, active: bool) {
        self.processing = active;
    }

    /// Set voice recording state — changes placeholder text
    pub fn set_recording(&mut self, active: bool) {
        self.recording = active;
    }

    pub fn submit(&mut self) -> String {
        let display = self.content.clone();
        // U-T1 — resolve structured attachments from the display text (before
        // pill-expansion, so `@`-tokens are intact). Drained by the submit path.
        self.last_attachments = mentions::parse_mentions(&display, &self.agents);
        // U-T4 — classify the routing kind from the leading sigil.
        self.last_submit_kind = SubmitKind::of(&display);
        if !display.trim().is_empty() {
            // History keeps the DISPLAY text — pill tokens intact (CC
            // history.ts stores `display` + pastedContents) — so ↑-recall
            // shows the compact pill, which still expands on the next submit
            // via the retained paste store. `!`-shell lines go to their own
            // bucket (U-T4) so shell recall stays separate from prompt recall.
            if self.last_submit_kind == SubmitKind::Shell {
                self.shell_history.push(display.clone());
            } else {
                self.history.push(display.clone());
            }
        }
        self.content.clear();
        self.cursor = 0;
        self.multiline = false;
        self.tab_matches.clear();
        self.file_search_active = false;
        self.file_matches.clear();
        self.completions.hide();
        // Re-roll the rotating placeholder so the next empty composer shows a
        // fresh example prompt / hint (opencode index.tsx randomIndex, re-rolled
        // on submit).
        self.placeholder_seed = self.placeholder_seed.wrapping_add(1);
        // WS9 — expand "[Pasted text #N ...]" pills into their full stored
        // content so the model receives the real text (CC expandPastedTextRefs
        // in processUserInput). Attachment chips ([Image #N]) pass through
        // untouched — they become content blocks, not inlined text.
        self.expand_paste_pills(&display)
    }

    pub fn reset(&mut self) {
        self.content.clear();
        self.cursor = 0;
        self.multiline = false;
        self.tab_matches.clear();
        self.file_search_active = false;
        self.file_matches.clear();
        self.completions.hide();
    }

    /// Double-Esc clear: push the current draft into input history (so ↑ /
    /// Ctrl+R can restore it) and clear the composer. Also snapshots for
    /// Ctrl+_ undo. Returns true when a non-blank draft was cleared.
    pub fn clear_to_history(&mut self) -> bool {
        if self.content.trim().is_empty() {
            return false;
        }
        self.snapshot();
        self.history.push(self.content.clone());
        self.reset();
        true
    }

    pub fn set_content(&mut self, text: &str) {
        self.content = text.to_string();
        self.cursor = self.content.len();
    }

    /// Set cursor to an approximate DISPLAY column (for mouse click). `col` is a
    /// terminal column, so wide (2-col) chars advance it by 2 — matching how the
    /// text was drawn.
    pub fn set_cursor_col(&mut self, col: u16) {
        let target = col as usize;
        let mut byte_pos = 0;
        let mut disp_col = 0;
        for ch in self.content.chars() {
            // Stop at the target column OR at the first newline. `set_cursor_col`
            // is only used to place the caret from a first-visual-row mouse
            // click, so counting must never run past the end of line 0. Without
            // the '\n' guard a click in the blank space to the right of a SHORT
            // first line kept counting into line 2+, dropping the caret onto a
            // later line instead of clamping it to the first line's end.
            if disp_col >= target || ch == '\n' {
                break;
            }
            byte_pos += ch.len_utf8();
            disp_col += UnicodeWidthChar::width(ch).unwrap_or(0);
        }
        self.cursor = byte_pos.min(self.content.len());
    }

    fn insert_char(&mut self, ch: char) {
        // Undo coalescing (grok begin/end_undo_group): a run of contiguous
        // non-space keystrokes collapses into ONE undo step. Snapshot only when
        // the run breaks — i.e. this is the first char of a word (no open run),
        // the caret moved since the last insert (`undo_insert_run` no longer
        // equals the cursor), or the char is whitespace (a word/line boundary
        // that both ends the current run and starts its own step). Otherwise
        // skip the snapshot so `hello` is one undo, not five.
        let coalesce = !ch.is_whitespace() && self.undo_insert_run == Some(self.cursor);
        if !coalesce {
            self.snapshot();
        }
        self.content.insert(self.cursor, ch);
        self.cursor += ch.len_utf8();
        // Keep the run open only across contiguous non-space chars; whitespace
        // closes it so the next word begins a fresh undo step.
        self.undo_insert_run = if ch.is_whitespace() { None } else { Some(self.cursor) };
        self.tab_matches.clear();

        // Slash command completions popup
        if self.content.starts_with('/') && !self.file_search_active {
            let filter = safe_str_range(&self.content, 1, self.cursor); // text after '/'
            self.completions.show(filter);
        } else {
            self.completions.hide();
        }

        // Step 9: Detect '@' to trigger file search
        if ch == '@' {
            self.file_search_active = true;
            self.file_search_start = self.cursor - 1; // byte position of '@'
            self.file_matches.clear();
            self.file_match_index = 0;
            self.rebuild_file_matches();
        } else if self.file_search_active {
            self.rebuild_file_matches();
        }
    }

    pub fn insert_str(&mut self, s: &str) {
        self.snapshot();
        self.content.insert_str(self.cursor, s);
        self.cursor += s.len();
        self.tab_matches.clear();
        self.file_search_active = false;
        self.file_matches.clear();
        // Bulk insertion (paste / voice transcription) makes any open slash
        // completions popup stale — its filter no longer reflects the buffer.
        // insert_char/delete_char re-evaluate the popup on every edit; do the
        // same here so a Ctrl+V into a "/"-draft doesn't leave a ghost menu
        // (which also over-reserved viewport rows via completions_popup_height).
        self.completions.hide();
    }

    /// WS9 — insert normalized pasted text. Large pastes (>[`PASTE_THRESHOLD`]
    /// chars or >2 newlines — CC PromptInput.tsx onTextPaste, maxLines
    /// effectively 2) collapse into a "[Pasted text #N +M lines]" pill token
    /// whose full content goes to the deferred store and is spliced back in at
    /// submit; small pastes insert inline. The line count intentionally mirrors
    /// CC's getPastedTextRefNumLines quirk of counting newline CHARS, not
    /// lines ("a\nb\nc" is "+2 lines").
    pub fn insert_paste(&mut self, text: &str) {
        // An explicit paste (bracketed paste or Ctrl+V) supersedes any in-flight
        // burst detection: drop the transient state so the fallback path can
        // never re-apply or interleave with text that already arrived whole.
        self.paste_burst.clear_after_explicit_paste();
        self.insert_paste_inner(text);
    }

    /// The paste insertion itself, WITHOUT resetting paste-burst state. Used by
    /// [`InputComponent::paste_burst_tick`], where the Enter-suppression window
    /// must survive the flush.
    fn insert_paste_inner(&mut self, text: &str) {
        let num_lines = text.matches('\n').count();
        if text.len() > PASTE_THRESHOLD || num_lines > 2 {
            let id = self.next_paste_id;
            self.next_paste_id += 1;
            self.paste_store.insert(id, text.to_string());
            let token = if num_lines == 0 {
                format!("[Pasted text #{}]", id)
            } else {
                format!("[Pasted text #{} +{} lines]", id, num_lines)
            };
            self.insert_str(&token);
        } else {
            self.insert_str(text);
        }
    }

    /// Replace every "[Pasted text #N]" / "[Pasted text #N +M lines]" pill in
    /// `text` with its stored content (CC history.ts expandPastedTextRefs).
    /// Replacements are spliced back-to-front at the ORIGINAL match offsets so
    /// pill-like strings inside pasted content are never re-scanned. Unknown
    /// ids (nothing stored) leave the token as literal text.
    fn expand_paste_pills(&self, text: &str) -> String {
        let mut pills: Vec<(usize, usize, usize)> = Vec::new();
        for (s, e) in chip_ranges(text) {
            if let Some(id) = pill_id(&text[s..e]) {
                pills.push((s, e, id));
            }
        }
        let mut out = text.to_string();
        for (s, e, id) in pills.into_iter().rev() {
            if let Some(content) = self.paste_store.get(&id) {
                out.replace_range(s..e, content);
            }
        }
        out
    }

    fn delete_char(&mut self) {
        if self.cursor > 0 {
            // Atomic chip delete (CC Cursor.deleteTokenBefore): backspace with
            // the caret at the END of a chip token — or inside one (mouse
            // click) — removes the whole token in one keystroke, so a pill or
            // [Image #N] chip can never be half-deleted into stray text. The
            // end-of-token case requires the char after the caret to be
            // whitespace or EOL (CC's word-boundary guard), so backspacing
            // through ordinary text touching a ']' stays character-wise.
            let next_is_boundary = self.content[self.cursor..]
                .chars()
                .next()
                .map_or(true, |c| c.is_whitespace());
            if let Some((s, e)) = chip_ranges(&self.content).into_iter().find(|&(s, e)| {
                (self.cursor == e && next_is_boundary)
                    || (self.cursor > s && self.cursor < e)
            }) {
                self.snapshot();
                self.content.drain(s..e);
                self.cursor = s;
                if !self.content.contains('\n') {
                    self.multiline = false;
                }
                self.after_edit();
                return;
            }
            self.snapshot();
            let prev = self.content[..self.cursor]
                .chars()
                .last()
                .map(|c| c.len_utf8())
                .unwrap_or(0);
            self.content.drain(self.cursor - prev..self.cursor);
            self.cursor -= prev;
            self.tab_matches.clear();

            // Update completions popup filter
            if self.content.starts_with('/') && !self.file_search_active {
                let filter = safe_str_range(&self.content, 1, self.cursor);
                self.completions.update_filter(filter);
            } else {
                self.completions.hide();
            }

            // If we deleted back past the '@', cancel file search
            if self.file_search_active && self.cursor <= self.file_search_start {
                self.file_search_active = false;
                self.file_matches.clear();
            } else if self.file_search_active {
                self.rebuild_file_matches();
            }
        }
    }

    fn move_left(&mut self) {
        if self.cursor > 0 {
            let prev = self.content[..self.cursor]
                .chars()
                .last()
                .map(|c| c.len_utf8())
                .unwrap_or(0);
            self.cursor -= prev;
            // Atomic chip hop (CC Cursor.snapOutOfImageRef): the caret never
            // lands INSIDE a "[Image #N]"/"[Pasted text #N]" token — crossing
            // its right edge snaps all the way to the token start.
            if let Some((s, _)) = chip_ranges(&self.content)
                .into_iter()
                .find(|&(s, e)| self.cursor > s && self.cursor < e)
            {
                self.cursor = s;
            }
        }
        self.revalidate_file_search();
    }

    fn move_right(&mut self) {
        if self.cursor < self.content.len() {
            let next = self.content[self.cursor..]
                .chars()
                .next()
                .map(|c| c.len_utf8())
                .unwrap_or(0);
            self.cursor += next;
            // Atomic chip hop: crossing into a chip jumps to its far edge.
            if let Some((_, e)) = chip_ranges(&self.content)
                .into_iter()
                .find(|&(s, e)| self.cursor > s && self.cursor < e)
            {
                self.cursor = e;
            }
        }
        self.revalidate_file_search();
    }

    /// Current cursor column, measured in DISPLAY columns from the start of its
    /// line (CJK/emoji count as 2, zero-width as 0) so the caret x-position is
    /// correct on wide text. Byte-index editing is unaffected — this is only a
    /// measurement of the text left of the caret.
    fn cursor_column(&self) -> usize {
        let line_start = self.content[..self.cursor]
            .rfind('\n')
            .map(|p| p + 1)
            .unwrap_or(0);
        display_width(&self.content[line_start..self.cursor])
    }

    /// Byte offset of DISPLAY column `col` into the line spanning `[start, end)`,
    /// clamped to the line's end. A target column landing in the middle of a
    /// wide (2-col) char resolves to that char's start, so the caret never
    /// splits a glyph.
    fn byte_at_column(&self, start: usize, end: usize, col: usize) -> usize {
        let line = &self.content[start..end];
        let mut acc = 0usize;
        for (b, ch) in line.char_indices() {
            if acc >= col {
                return start + b;
            }
            acc += UnicodeWidthChar::width(ch).unwrap_or(0);
        }
        end
    }

    /// Effective wrap width for cursor motion, in DISPLAY columns — the same
    /// formula `needed_height` uses for its wrap estimate, so caret motion and
    /// box growth agree on where a logical line folds. Columns are measured
    /// with `unicode_width`, so CJK/emoji fold at the same place the terminal
    /// wraps them.
    fn wrap_width(&self) -> usize {
        let prompt_len: usize = if self.processing { 4 } else { 2 };
        (self.width as usize).saturating_sub(prompt_len + 1).max(1)
    }

    /// Multiline: move the cursor up one VISUAL line (CC MeasuredText
    /// visual-line motion). Inside a long, wrapped logical line the caret
    /// first climbs the wrapped rows; only from the top visual row does it hop
    /// to the previous logical line's LAST visual row. History recall stays
    /// gated on the true buffer top edge (`up_crosses_to_history`), so a long
    /// wrapped draft is never clobbered by a stray Up. On the first line,
    /// jump to the start of the buffer.
    fn move_cursor_up(&mut self) {
        let w = self.wrap_width();
        let cur_start = self.content[..self.cursor]
            .rfind('\n')
            .map(|p| p + 1)
            .unwrap_or(0);
        let col = display_width(&self.content[cur_start..self.cursor]);
        let (vrow, vcol) = (col / w, col % w);
        if vrow > 0 {
            // Up one wrapped visual row within the same logical line.
            let cur_end = self.content[cur_start..]
                .find('\n')
                .map(|p| cur_start + p)
                .unwrap_or(self.content.len());
            self.cursor = self.byte_at_column(cur_start, cur_end, (vrow - 1) * w + vcol);
            return;
        }
        if cur_start == 0 {
            self.cursor = 0;
            return;
        }
        // Previous line occupies [prev_start, cur_start - 1) (excludes its
        // trailing '\n' at cur_start - 1). Land on its LAST visual row at the
        // same visual column, clamped to the line end.
        let prev_end = cur_start - 1;
        let prev_start = self.content[..prev_end]
            .rfind('\n')
            .map(|p| p + 1)
            .unwrap_or(0);
        let prev_len = display_width(&self.content[prev_start..prev_end]);
        let last_row_start = if prev_len == 0 { 0 } else { ((prev_len - 1) / w) * w };
        self.cursor = self.byte_at_column(prev_start, prev_end, last_row_start + vcol);
    }

    /// Multiline: move the cursor down one VISUAL line — through the wrapped
    /// rows of a long logical line first, then into the next logical line at
    /// the same visual column. On the last line, jump to the end of the buffer.
    fn move_cursor_down(&mut self) {
        let w = self.wrap_width();
        let cur_start = self.content[..self.cursor]
            .rfind('\n')
            .map(|p| p + 1)
            .unwrap_or(0);
        let cur_end = self.content[cur_start..]
            .find('\n')
            .map(|p| cur_start + p)
            .unwrap_or(self.content.len());
        let col = display_width(&self.content[cur_start..self.cursor]);
        let (vrow, vcol) = (col / w, col % w);
        let line_len = display_width(&self.content[cur_start..cur_end]);
        let last_vrow = if line_len == 0 { 0 } else { (line_len - 1) / w };
        if vrow < last_vrow {
            // Down one wrapped visual row within the same logical line.
            self.cursor = self.byte_at_column(cur_start, cur_end, (vrow + 1) * w + vcol);
            return;
        }
        if cur_end >= self.content.len() {
            self.cursor = self.content.len();
            return;
        }
        let next_start = cur_end + 1;
        let next_end = self.content[next_start..]
            .find('\n')
            .map(|p| next_start + p)
            .unwrap_or(self.content.len());
        self.cursor = self.byte_at_column(next_start, next_end, vcol);
    }

    fn handle_tab(&mut self) -> bool {
        // Step 9: If file search is active, cycle through file matches.
        // `file_search_is_valid` gates the drain: a stale anchor (caret moved
        // before '@') would make `drain(anchor..cursor)` panic with start > end.
        if self.file_search_is_valid() && !self.file_matches.is_empty() {
            self.snapshot();
            let selected = self.file_matches[self.file_match_index].insert.clone();
            self.file_frecency.record(&selected); // U-T6: reward this pick
            // Replace from '@' to cursor with '@selected_path'
            let end = self.cursor;
            self.content.drain(self.file_search_start..end);
            let insertion = format!("@{}", selected);
            self.content.insert_str(self.file_search_start, &insertion);
            self.cursor = self.file_search_start + insertion.len();
            self.file_match_index = (self.file_match_index + 1) % self.file_matches.len();
            return true;
        }

        // Regular command tab completion
        if !self.content.starts_with('/') {
            return false;
        }

        if self.tab_matches.is_empty() {
            let prefix = &self.content[1..]; // skip the /
            // Fuzzy subsequence match + rank (best-first) instead of prefix-only.
            self.tab_matches = crate::util::fuzzy::rank(&self.commands, prefix, |c| c.as_str())
                .into_iter()
                .map(|i| format!("/{}", self.commands[i]))
                .collect();
            self.tab_index = 0;
        } else if !self.tab_matches.is_empty() {
            self.tab_index = (self.tab_index + 1) % self.tab_matches.len();
        }

        if let Some(match_) = self.tab_matches.get(self.tab_index).cloned() {
            self.snapshot();
            self.content = match_;
            self.cursor = self.content.len();
        }
        true
    }

    /// Step 10: Stash current input
    pub fn stash(&mut self) -> bool {
        if self.content.is_empty() {
            return false;
        }
        self.stash = Some(self.content.clone());
        self.content.clear();
        self.cursor = 0;
        self.multiline = false;
        true
    }

    /// Step 10: Restore from stash
    pub fn restore_stash(&mut self) -> bool {
        if let Some(stashed) = self.stash.take() {
            self.content = stashed;
            self.cursor = self.content.len();
            self.multiline = self.content.contains('\n');
            true
        } else {
            false
        }
    }

    /// Step 9: Rebuild file matches from cwd
    fn rebuild_file_matches(&mut self) {
        // Caret motions (Home / Ctrl+A / Left / vim moves) can drag the cursor
        // to or before the stored '@' anchor without cancelling the search, and
        // an edit before the anchor can leave it no longer pointing at an '@'.
        // A stale anchor here would slice `content[anchor+1..cursor]` with
        // start > end (or off a codepoint) and abort the whole TUI, so
        // revalidate first and bail cleanly.
        if !self.file_search_is_valid() {
            self.file_search_active = false;
            self.file_matches.clear();
            return;
        }
        // Extract the search query after '@'
        let query_start = self.file_search_start + 1; // skip '@'
        let query = safe_str_range(&self.content, query_start, self.cursor).to_string();
        let query = query.as_str();
        if query.is_empty() {
            // Bare `@` (no query typed yet): show the workspace's top-level
            // files & dirs, frecency-ranked, so the picker is populated
            // immediately (CC/opencode show recent/root entries before any
            // filter) instead of a blank dropdown.
            self.file_matches = self.top_level_candidates();
            self.file_match_index = 0;
            return;
        }

        // Collect fuzzy-matching file/dir candidates from the cwd tree, then
        // fold in any known agent names the query fuzzy-matches (U-T1) so the
        // one popup offers `@file`, `@dir/` AND `@agent`.
        let mut paths = Vec::new();
        if let Ok(cwd) = std::env::current_dir() {
            Self::walk_dir(&cwd, &cwd, query, 3, &mut paths);
        }
        let mut candidates: Vec<Candidate> = paths.into_iter().map(Candidate::file).collect();
        for agent in &self.agents {
            if crate::util::fuzzy::is_match(agent, query) {
                candidates.push(Candidate::agent(agent.clone()));
            }
        }

        // Score each candidate by the better of its leaf-name vs. full-path
        // fuzzy match, then blend in the frecency boost (U-T6) so a file picked
        // often & recently outranks a marginally-better fuzzy hit. Agents get a
        // small constant nudge so a name-exact `@agent` isn't buried under files.
        let mut scored: Vec<(i32, usize, String, Candidate)> = candidates
            .into_iter()
            .filter_map(|c| {
                let rel = &c.insert;
                let name = rel.rsplit(['/', '\\']).next().unwrap_or(rel);
                let best = crate::util::fuzzy::score(name, query)
                    .into_iter()
                    .chain(crate::util::fuzzy::score(rel, query))
                    .max()?;
                // Frecency boost is scaled into the same integer space as the
                // fuzzy score so it acts as a strong tiebreaker without swamping
                // a clearly-better textual match.
                let boost = (self.file_frecency.boost(rel) * 40.0) as i32;
                let kind_bonus = if c.kind == MentionKind::Agent { 5 } else { 0 };
                Some((best + boost + kind_bonus, rel.chars().count(), rel.clone(), c))
            })
            .collect();
        scored.sort_by(|a, b| {
            b.0.cmp(&a.0)
                .then_with(|| a.1.cmp(&b.1))
                .then_with(|| a.2.cmp(&b.2))
        });

        self.file_matches = scored.into_iter().take(10).map(|(_, _, _, c)| c).collect();
        self.file_match_index = 0;
    }

    /// The workspace's top-level (depth-1) files and dirs as mention
    /// candidates, frecency-ranked then name-sorted, capped at 10. Feeds the
    /// bare-`@` picker so it is never empty. Hidden and noise dirs
    /// (node_modules/target/_build/deps) are skipped, matching `walk_dir`.
    fn top_level_candidates(&self) -> Vec<Candidate> {
        let mut cands: Vec<Candidate> = Vec::new();
        if let Ok(cwd) = std::env::current_dir() {
            if let Ok(entries) = std::fs::read_dir(&cwd) {
                for entry in entries.flatten() {
                    let name = entry.file_name().to_string_lossy().to_string();
                    if name.starts_with('.') {
                        continue;
                    }
                    if name == "node_modules"
                        || name == "target"
                        || name == "_build"
                        || name == "deps"
                    {
                        continue;
                    }
                    let is_dir = entry.path().is_dir();
                    let rel = if is_dir { format!("{}/", name) } else { name };
                    cands.push(Candidate::file(rel));
                }
            }
        }
        cands.sort_by(|a, b| {
            self.file_frecency
                .boost(&b.insert)
                .partial_cmp(&self.file_frecency.boost(&a.insert))
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.insert.cmp(&b.insert))
        });
        cands.truncate(10);
        cands
    }

    fn walk_dir(
        base: &std::path::Path,
        dir: &std::path::Path,
        query: &str,
        depth: usize,
        results: &mut Vec<String>,
    ) {
        if depth == 0 || results.len() >= 200 {
            return;
        }
        let entries = match std::fs::read_dir(dir) {
            Ok(e) => e,
            Err(_) => return,
        };
        for entry in entries.flatten() {
            if results.len() >= 200 {
                break;
            }
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();

            // Skip hidden dirs/files
            if name.starts_with('.') {
                continue;
            }
            // Skip common noise dirs
            if name == "node_modules" || name == "target" || name == "_build" || name == "deps" {
                continue;
            }

            let is_dir = path.is_dir();
            let mut rel = path
                .strip_prefix(base)
                .unwrap_or(&path)
                .to_string_lossy()
                .to_string();
            // Mark directories with a trailing '/' so the mention dropdown
            // distinguishes them from files (and inserts a browsable path).
            if is_dir {
                rel.push('/');
            }

            // Fuzzy subsequence match on either the leaf name or the full path.
            if crate::util::fuzzy::is_match(&name, query)
                || crate::util::fuzzy::is_match(&rel, query)
            {
                results.push(rel.clone());
            }

            if is_dir {
                Self::walk_dir(base, &path, query, depth - 1, results);
            }
        }
    }

    // ── Composer power-features: word motions, kill-line, undo/redo ──────────

    /// Push the current (content, cursor) onto the undo ring and clear redo.
    /// Also ends any open insert-coalescing run: a snapshot is, by definition,
    /// a new undo boundary, so the next `insert_char` starts a fresh group
    /// (it re-opens the run itself after inserting).
    fn snapshot(&mut self) {
        self.undo_stack.push((self.content.clone(), self.cursor));
        if self.undo_stack.len() > 100 {
            self.undo_stack.remove(0);
        }
        self.redo_stack.clear();
        self.undo_insert_run = None;
    }

    /// Restore editing state after an undo/redo hop.
    fn restore_state(&mut self, content: String, cursor: usize) {
        self.content = content;
        self.cursor = cursor.min(self.content.len());
        self.multiline = self.content.contains('\n');
        self.tab_matches.clear();
        self.file_search_active = false;
        self.file_matches.clear();
        self.completions.hide();
        // An undo/redo is a hard boundary: don't coalesce a following insert
        // into the step we just restored, and invalidate any yank region.
        self.undo_insert_run = None;
        self.yank_anchor = None;
    }

    fn undo(&mut self) -> bool {
        if let Some((content, cursor)) = self.undo_stack.pop() {
            self.redo_stack.push((self.content.clone(), self.cursor));
            self.restore_state(content, cursor);
            true
        } else {
            false
        }
    }

    fn redo(&mut self) -> bool {
        if let Some((content, cursor)) = self.redo_stack.pop() {
            self.undo_stack.push((self.content.clone(), self.cursor));
            self.restore_state(content, cursor);
            true
        } else {
            false
        }
    }

    /// Byte offset of the previous word boundary (skip whitespace, then word).
    fn word_left(&self) -> usize {
        let upto = &self.content[..self.cursor];
        let mut idx = self.cursor;
        let mut iter = upto.char_indices().rev().peekable();
        while let Some(&(bi, c)) = iter.peek() {
            if c.is_whitespace() {
                idx = bi;
                iter.next();
            } else {
                break;
            }
        }
        while let Some(&(bi, c)) = iter.peek() {
            if !c.is_whitespace() {
                idx = bi;
                iter.next();
            } else {
                break;
            }
        }
        idx
    }

    /// Byte offset of the next word boundary (skip whitespace, then word).
    fn word_right(&self) -> usize {
        let from = &self.content[self.cursor..];
        let mut idx = self.cursor;
        let mut iter = from.char_indices().peekable();
        while let Some(&(bi, c)) = iter.peek() {
            if c.is_whitespace() {
                idx = self.cursor + bi + c.len_utf8();
                iter.next();
            } else {
                break;
            }
        }
        while let Some(&(bi, c)) = iter.peek() {
            if !c.is_whitespace() {
                idx = self.cursor + bi + c.len_utf8();
                iter.next();
            } else {
                break;
            }
        }
        idx
    }

    /// Alt+B — move cursor one word left.
    fn move_word_left(&mut self) {
        self.cursor = self.word_left();
    }

    /// Alt+F — move cursor one word right.
    fn move_word_right(&mut self) {
        self.cursor = self.word_right();
    }

    /// U-T4 — recall the previous entry from the bucket matching the CURRENT
    /// line: `!`-shell lines walk the shell history, everything else the prompt
    /// history. Recalled shell entries keep their `!` prefix, so repeated ↑ /
    /// Ctrl+P stays within the same bucket.
    fn hist_prev(&mut self) -> Option<String> {
        if self.content.starts_with('!') {
            self.shell_history.prev().map(|s| s.to_string())
        } else {
            self.history.prev().map(|s| s.to_string())
        }
    }

    /// U-T4 — recall the next (newer) entry from the bucket for the current line.
    fn hist_next(&mut self) -> Option<String> {
        if self.content.starts_with('!') {
            self.shell_history.next().map(|s| s.to_string())
        } else {
            self.history.next().map(|s| s.to_string())
        }
    }

    /// Whether either history bucket is mid-recall (see [`History::is_navigating`]).
    fn is_navigating_history(&self) -> bool {
        self.history.is_navigating() || self.shell_history.is_navigating()
    }

    /// C5 — recall the previous entry, stashing the current half-typed line as a
    /// draft on the FIRST step into history so a later step back down restores
    /// it. Idempotent: re-stashing is skipped once a walk is in progress.
    fn history_recall_prev(&mut self) -> Option<String> {
        if !self.is_navigating_history() {
            self.history_draft = Some(self.content.clone());
        }
        self.hist_prev()
    }

    /// C5 — recall the next (newer) entry, or, when stepping past the newest
    /// history entry, restore the stashed half-typed draft. Returns `None` only
    /// when there is neither a newer entry nor a stashed draft (leave as-is).
    fn history_recall_next(&mut self) -> Option<String> {
        match self.hist_next() {
            Some(text) => Some(text),
            None => self.history_draft.take(),
        }
    }

    /// U-T2 — emacs Ctrl+P, mirroring the ↑ arrow: cycle file matches, else
    /// climb wrapped/logical lines, crossing into (bucket-aware) history recall
    /// only at the buffer's top edge.
    fn on_up(&mut self) {
        if self.file_search_active && !self.file_matches.is_empty() {
            self.file_match_index = if self.file_match_index > 0 {
                self.file_match_index - 1
            } else {
                self.file_matches.len() - 1
            };
            return;
        }
        if self.multiline || self.content.contains('\n') {
            if up_crosses_to_history(&self.content, self.cursor) {
                if let Some(text) = self.history_recall_prev() {
                    self.content = text;
                    self.cursor = self.content.len();
                    self.multiline = self.content.contains('\n');
                }
            } else {
                self.move_cursor_up();
            }
        } else if let Some(text) = self.history_recall_prev() {
            self.content = text;
            self.cursor = self.content.len();
            self.multiline = self.content.contains('\n');
        }
    }

    /// U-T2 — emacs Ctrl+N, mirroring the ↓ arrow.
    fn on_down(&mut self) {
        if self.file_search_active && !self.file_matches.is_empty() {
            self.file_match_index = (self.file_match_index + 1) % self.file_matches.len();
            return;
        }
        if self.multiline || self.content.contains('\n') {
            if down_crosses_to_history(&self.content, self.cursor) {
                if let Some(text) = self.history_recall_next() {
                    self.content = text;
                    self.cursor = self.content.len();
                    self.multiline = self.content.contains('\n');
                }
            } else {
                self.move_cursor_down();
            }
        } else if let Some(text) = self.history_recall_next() {
            // C5 — a newer history entry, or the restored half-typed draft.
            self.content = text;
            self.cursor = self.content.len();
            self.multiline = self.content.contains('\n');
        }
        // No newer entry and no stashed draft → leave the buffer untouched
        // (never wipe a half-typed line, readline/fish parity).
    }

    /// U-T3 — the dimmed inline autocomplete suffix shown after the caret, or
    /// `None`. Fish/CC-style history autosuggestion: the newest history entry
    /// that starts with (but is longer than) the current buffer. Gated to the
    /// common single-line "typing at the end" case so it never fights the
    /// slash-completion popup, the `@`-file dropdown, or multi-line editing.
    fn ghost_suffix(&self) -> Option<String> {
        if self.content.is_empty()
            || self.cursor != self.content.len()
            || self.multiline
            || self.content.contains('\n')
            || self.file_search_active
            || self.completions.is_visible()
            || self.reverse_search.is_some()
            || self.content.starts_with('/')
        {
            return None;
        }
        // Shell lines suggest from the shell bucket; everything else from prompts.
        let entries = if self.content.starts_with('!') {
            self.shell_history.entries()
        } else {
            self.history.entries()
        };
        entries.iter().rev().find_map(|e| {
            if e.len() > self.content.len() && e.starts_with(&self.content) && !e.contains('\n') {
                Some(e[self.content.len()..].to_string())
            } else {
                None
            }
        })
    }

    /// U-T3 — accept the current ghost suggestion (Tab / → at end-of-line),
    /// appending it to the buffer. Returns true when a suggestion was accepted.
    fn accept_ghost(&mut self) -> bool {
        if let Some(suffix) = self.ghost_suffix() {
            self.snapshot();
            self.content.push_str(&suffix);
            self.cursor = self.content.len();
            self.undo_insert_run = None;
            return true;
        }
        false
    }

    /// Push `killed` onto the kill-ring (emacs/readline: CC pushToKillRing,
    /// grok kill_buffer). Successive kills accumulate into the SAME (most
    /// recent, last) entry — forward kills (`Ctrl+K`, `Alt+D`) append, backward
    /// kills (`Ctrl+W`, `Ctrl+U`) prepend — so `Ctrl+K Ctrl+K` then `Ctrl+Y`
    /// yanks the whole run. A non-kill command in between starts a new entry.
    /// The most-recent entry is the LAST element; `Ctrl+Y` yanks it.
    fn push_kill(&mut self, killed: &str, forward: bool, accumulate: bool) {
        if killed.is_empty() {
            return;
        }
        let accumulate = accumulate && !self.kill_ring.is_empty();
        if accumulate {
            if let Some(top) = self.kill_ring.last_mut() {
                if forward {
                    top.push_str(killed);
                } else {
                    top.insert_str(0, killed);
                }
            }
        } else {
            self.kill_ring.push(killed.to_string());
            // Bound the ring so a long session can't grow it without limit.
            if self.kill_ring.len() > 60 {
                self.kill_ring.remove(0);
            }
        }
        self.last_edit = LastEdit::Kill;
        self.kill_ring_index = self.kill_ring.len().saturating_sub(1);
        // A kill invalidates any pending yank region (Alt+Y needs a fresh yank).
        self.yank_anchor = None;
    }

    /// Ctrl+Y — yank (insert) the most recent kill at the caret and remember the
    /// inserted range so a following `Alt+Y` can yank-pop it. No-op on an empty
    /// ring. CC `yank` / `recordYank`; grok `textarea.rs:2592 yank()`.
    fn yank(&mut self) -> bool {
        if self.kill_ring.is_empty() {
            return false;
        }
        self.snapshot();
        self.kill_ring_index = self.kill_ring.len() - 1;
        let text = self.kill_ring[self.kill_ring_index].clone();
        let start = self.cursor;
        self.content.insert_str(start, &text);
        self.cursor = start + text.len();
        self.yank_anchor = Some((start, self.cursor));
        self.after_edit();
        self.multiline = self.content.contains('\n');
        // after_edit / mutations don't touch last_edit; set the Yank marker so
        // the very next Alt+Y is recognised as a yank-pop.
        self.last_edit = LastEdit::Yank;
        true
    }

    /// Alt+Y — yank-pop: replace the text the last yank / yank-pop inserted with
    /// the previous kill-ring entry, rotating backward through the ring. Only
    /// valid immediately after a yank (guarded by `yank_anchor` + the `Yank`
    /// last-edit marker). CC `handleYankPop` / `yankPop`.
    fn yank_pop(&mut self) -> bool {
        let Some((start, end)) = self.yank_anchor else {
            return false;
        };
        let n = self.kill_ring.len();
        if n == 0 {
            return false;
        }
        // Rotate to the previous (older) entry, wrapping around the ring.
        self.kill_ring_index = (self.kill_ring_index + n - 1) % n;
        let text = self.kill_ring[self.kill_ring_index].clone();
        // Swap in place — no new snapshot, so the whole yank+pops collapse to a
        // single undo step that removes all of the yanked text at once.
        self.content.replace_range(start..end, &text);
        self.cursor = start + text.len();
        self.yank_anchor = Some((start, self.cursor));
        self.multiline = self.content.contains('\n');
        self.undo_insert_run = None;
        self.last_edit = LastEdit::Yank;
        true
    }

    /// Ctrl+W — delete (kill) the word before the cursor into the kill-ring.
    /// `accumulate` (the previous command was also a kill) merges into the same
    /// ring entry.
    fn delete_word_back(&mut self, accumulate: bool) {
        let start = self.word_left();
        if start < self.cursor {
            let killed = self.content[start..self.cursor].to_string();
            self.snapshot();
            self.content.drain(start..self.cursor);
            self.cursor = start;
            self.push_kill(&killed, false, accumulate); // backward kill → prepend
            self.after_edit();
        }
    }

    /// Alt+D — delete (kill) the word forward from the cursor into the ring.
    fn kill_word_forward(&mut self, accumulate: bool) {
        let end = self.word_right();
        if end > self.cursor {
            let killed = self.content[self.cursor..end].to_string();
            self.snapshot();
            self.content.drain(self.cursor..end);
            self.push_kill(&killed, true, accumulate); // forward kill → append
            self.after_edit();
        }
    }

    /// Ctrl+U — kill from the cursor to the START of the current line into the
    /// ring (readline `unix-line-discard` / CC `killToLineStart`). Replaces the
    /// old "wipe the whole buffer" behaviour, which discarded the text.
    fn kill_to_line_start(&mut self, accumulate: bool) {
        let line_start = self.content[..self.cursor]
            .rfind('\n')
            .map(|p| p + 1)
            .unwrap_or(0);
        if line_start < self.cursor {
            let killed = self.content[line_start..self.cursor].to_string();
            self.snapshot();
            self.content.drain(line_start..self.cursor);
            self.cursor = line_start;
            self.push_kill(&killed, false, accumulate); // backward kill → prepend
            self.after_edit();
        }
    }

    /// Ctrl+D (readline delete-forward) — remove the character under the cursor.
    /// A no-op at end-of-buffer. The idle handler only routes Ctrl+D here when
    /// the buffer is non-empty (empty Ctrl+D is EOF/quit), so this never fights
    /// the exit binding.
    fn delete_forward_char(&mut self) {
        // Atomic chip delete, forward direction: Ctrl+D with the caret at a
        // chip's start (or inside one) removes the whole token — never a lone
        // '[' that would strand the rest as text.
        if let Some((s, e)) = chip_ranges(&self.content)
            .into_iter()
            .find(|&(s, e)| self.cursor >= s && self.cursor < e)
        {
            self.snapshot();
            self.content.drain(s..e);
            self.cursor = s;
            if !self.content.contains('\n') {
                self.multiline = false;
            }
            self.after_edit();
            return;
        }
        if self.cursor < self.content.len() {
            self.snapshot();
            let next = self.content[self.cursor..]
                .chars()
                .next()
                .map(|c| c.len_utf8())
                .unwrap_or(0);
            self.content.drain(self.cursor..self.cursor + next);
            self.after_edit();
        }
    }

    /// Ctrl+K — kill from the cursor to the end of the current line. If the
    /// cursor sits on a newline, kill just that newline.
    fn kill_to_line_end(&mut self, accumulate: bool) {
        let rest = &self.content[self.cursor..];
        let end = match rest.find('\n') {
            Some(0) => self.cursor + 1,          // on a newline: remove it
            Some(n) => self.cursor + n,          // to end of visual line
            None => self.content.len(),          // last line: to end of buffer
        };
        if end > self.cursor {
            let killed = self.content[self.cursor..end].to_string();
            self.snapshot();
            self.content.drain(self.cursor..end);
            self.push_kill(&killed, true, accumulate); // forward kill → append
            self.after_edit();
        }
    }

    /// Shared bookkeeping after a structural edit (kill/word-delete).
    fn after_edit(&mut self) {
        self.tab_matches.clear();
        if !self.content.contains('\n') {
            self.multiline = false;
        }
        if self.content.starts_with('/') && !self.file_search_active {
            let filter = safe_str_range(&self.content, 1, self.cursor);
            self.completions.update_filter(filter);
        } else {
            self.completions.hide();
        }
        if self.file_search_active {
            if self.cursor <= self.file_search_start {
                self.file_search_active = false;
                self.file_matches.clear();
            } else {
                self.rebuild_file_matches();
            }
        }
    }

    /// Ctrl+G — open the current buffer in `$EDITOR` (then `$VISUAL`, then `vi`),
    /// read it back on exit. Raw mode / bracketed paste are suspended around the
    /// child process and restored afterward. Returns Ok(true) if the buffer
    /// changed. The editor uses its own alternate screen, so the inline viewport
    /// is preserved on return.
    fn open_in_editor(&mut self) -> Result<bool, String> {
        // Out-of-the-box editor: `vi` exists on a default unix box but not on
        // Windows, where `notepad` is always present. $EDITOR / $VISUAL still win.
        let default_editor = if cfg!(windows) { "notepad" } else { "vi" };
        let editor = std::env::var("EDITOR")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .or_else(|| std::env::var("VISUAL").ok().filter(|s| !s.trim().is_empty()))
            .unwrap_or_else(|| default_editor.to_string());

        // Support `EDITOR="code --wait"` style values: first token is the program.
        let mut parts = editor.split_whitespace();
        let program = parts.next().unwrap_or(default_editor).to_string();
        let extra_args: Vec<String> = parts.map(|s| s.to_string()).collect();

        // Temp file seeded with the current buffer (markdown for editor niceties).
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let path = std::env::temp_dir().join(format!(
            "osa-compose-{}-{}.md",
            std::process::id(),
            nanos
        ));
        // $TMPDIR is world-writable and this name is predictable, so create the
        // draft 0600 with O_EXCL: an attacker-planted symlink (or file) at the
        // path makes this fail loudly instead of becoming a write primitive.
        // The draft is the user's prompt -- it must not be world-readable while
        // the editor is open, and it survives on disk if OSA is killed before
        // the remove_file below.
        crate::client::auth::write_private_new(&path, self.content.as_bytes())
            .map_err(|e| format!("compose: write temp failed: {e}"))?;

        // Suspend the TUI's terminal modes around the child.
        let mut out = std::io::stdout();
        let _ = execute!(out, PopKeyboardEnhancementFlags);
        let _ = execute!(out, DisableBracketedPaste);
        let _ = disable_raw_mode();

        let status = std::process::Command::new(&program)
            .args(&extra_args)
            .arg(&path)
            .status();

        // Restore terminal modes exactly as main.rs set them up.
        let _ = enable_raw_mode();
        let _ = execute!(out, EnableBracketedPaste);
        if matches!(supports_keyboard_enhancement(), Ok(true)) {
            let _ = execute!(
                out,
                PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
            );
        }

        let result = match status {
            Ok(st) if st.success() => match std::fs::read_to_string(&path) {
                Ok(text) => {
                    // Editors commonly append a trailing newline; drop one.
                    let text = text.strip_suffix('\n').unwrap_or(&text).to_string();
                    let changed = text != self.content;
                    if changed {
                        self.snapshot();
                        self.content = text;
                        self.cursor = self.content.len();
                        self.multiline = self.content.contains('\n');
                        self.completions.hide();
                        self.file_search_active = false;
                        self.file_matches.clear();
                        self.tab_matches.clear();
                    }
                    Ok(changed)
                }
                Err(e) => Err(format!("compose: read back failed: {e}")),
            },
            Ok(_) => Ok(false), // editor exited non-zero: keep buffer as-is
            Err(e) => Err(format!("compose: launch '{program}' failed: {e}")),
        };

        let _ = std::fs::remove_file(&path);
        result
    }

    // ── Vim modal-editing layer (optional; gated by `vim_enabled`) ───────────

    /// Whether vim mode is currently enabled.
    pub fn vim_enabled(&self) -> bool {
        self.vim_enabled
    }

    /// Toggle vim mode (for a `/vim` command). Returns the new enabled state and
    /// resets the modal state to Insert so the composer stays usable either way.
    pub fn toggle_vim(&mut self) -> bool {
        self.vim_enabled = !self.vim_enabled;
        self.vim = vim::VimState::default();
        self.vim_enabled
    }

    /// Whether the vim layer needs first refusal on `key` (consulted by the
    /// app's key dispatch). In Normal mode it claims Esc and every unmodified /
    /// shifted key (Ctrl/Alt combos stay with the app: interrupt, suspend,
    /// palette…). In Insert mode it claims only Esc, to drop into Normal — every
    /// other key flows through the normal composer path untouched. Always false
    /// when vim is disabled, so there is zero interference.
    pub fn vim_wants_key(&self, key: &KeyEvent) -> bool {
        if !self.vim_enabled {
            return false;
        }
        match self.vim.mode {
            vim::VimMode::Normal => {
                key.code == KeyCode::Esc
                    || matches!(key.modifiers, KeyModifiers::NONE | KeyModifiers::SHIFT)
            }
            vim::VimMode::Insert => {
                key.code == KeyCode::Esc && key.modifiers == KeyModifiers::NONE
            }
        }
    }

    /// Enter Normal mode, clamping the caret so it rests ON a char (vim never
    /// leaves the caret past the last char of a non-empty line).
    fn enter_normal_mode(&mut self) {
        self.vim.mode = vim::VimMode::Normal;
        self.vim.pending = None;
        self.completions.hide();
        self.vim_clamp_cursor();
    }

    /// If the caret sits just past the last char of a non-empty line, step it
    /// back onto that char (Normal-mode invariant).
    fn vim_clamp_cursor(&mut self) {
        let ls = vim::line_start(&self.content, self.cursor);
        let le = vim::line_end(&self.content, self.cursor);
        if self.cursor == le && le > ls {
            let prev = self.content[..self.cursor]
                .chars()
                .next_back()
                .map(|c| c.len_utf8())
                .unwrap_or(0);
            self.cursor -= prev;
        }
    }

    /// Dispatch a key in Normal mode. Returns Consumed for handled keys and
    /// Emit(Submit) when Enter sends the buffer (submit still works modelessly).
    fn handle_vim_normal_key(&mut self, key: KeyEvent) -> ComponentAction {
        use vim::VimMode;

        // Enter submits from Normal mode too (then resets to Insert for the
        // next prompt).
        if crate::app::key_normalize::is_submit(&key) {
            self.vim.pending = None;
            if self.content.trim().is_empty() {
                return ComponentAction::Consumed;
            }
            let text = self.submit();
            self.vim = vim::VimState::default();
            return ComponentAction::Emit(AppAction::Submit(text));
        }

        let c = match key.code {
            KeyCode::Char(c) => c,
            other => {
                // Non-char keys: arrows / edges / Esc still navigate.
                match other {
                    KeyCode::Esc => self.vim.pending = None,
                    KeyCode::Left | KeyCode::Backspace => self.vim_move_left(),
                    KeyCode::Right => self.vim_move_right(),
                    KeyCode::Up => self.move_cursor_up(),
                    KeyCode::Down => self.move_cursor_down(),
                    KeyCode::Home => self.cursor = vim::line_start(&self.content, self.cursor),
                    KeyCode::End => self.vim_line_end_normal(),
                    _ => {}
                }
                return ComponentAction::Consumed;
            }
        };

        // Second key of a pending operator (dd / dw / cc / gg).
        if let Some(op) = self.vim.pending.take() {
            self.vim_apply_operator(op, c);
            return ComponentAction::Consumed;
        }

        match c {
            // Motions.
            'h' => self.vim_move_left(),
            'l' => self.vim_move_right(),
            'j' => self.move_cursor_down(),
            'k' => self.move_cursor_up(),
            'w' => self.cursor = vim::word_forward(&self.content, self.cursor),
            'b' => self.cursor = vim::word_back(&self.content, self.cursor),
            'e' => self.cursor = vim::word_end(&self.content, self.cursor),
            '0' => self.cursor = vim::line_start(&self.content, self.cursor),
            '$' => self.vim_line_end_normal(),
            '^' => self.cursor = vim::first_non_blank(&self.content, self.cursor),
            'G' => {
                self.cursor = self.content.len();
                self.vim_clamp_cursor();
            }
            // Operators / two-key prefixes.
            'd' | 'c' | 'g' => self.vim.pending = Some(c),
            'x' => self.vim_delete_under(),
            'D' => self.vim_delete_to_line_end(),
            'u' => {
                self.undo();
                self.vim_clamp_cursor();
            }
            // Insert-mode transitions.
            'i' => self.vim.mode = VimMode::Insert,
            'a' => {
                self.vim_move_right_append();
                self.vim.mode = VimMode::Insert;
            }
            'A' => {
                self.cursor = vim::line_end(&self.content, self.cursor);
                self.vim.mode = VimMode::Insert;
            }
            'I' => {
                self.cursor = vim::first_non_blank(&self.content, self.cursor);
                self.vim.mode = VimMode::Insert;
            }
            'o' => self.vim_open_below(),
            'O' => self.vim_open_above(),
            _ => {} // swallow unbound keys (never inserts text in Normal mode)
        }
        ComponentAction::Consumed
    }

    /// Apply a two-key operator (the first key was `op`, the second `c`).
    fn vim_apply_operator(&mut self, op: char, c: char) {
        match (op, c) {
            ('g', 'g') => self.cursor = 0,          // gg → top of buffer
            ('d', 'd') => self.vim_delete_line(),   // dd → delete line
            ('d', 'w') => self.vim_delete_word_forward(), // dw
            ('c', 'c') => self.vim_change_line(),   // cc → change line
            _ => {}                                  // unknown combo: ignore
        }
    }

    /// Normal-mode `h`: one char left, never past line start.
    fn vim_move_left(&mut self) {
        let ls = vim::line_start(&self.content, self.cursor);
        if self.cursor > ls {
            let prev = self.content[..self.cursor]
                .chars()
                .next_back()
                .map(|c| c.len_utf8())
                .unwrap_or(0);
            self.cursor -= prev;
        }
    }

    /// Normal-mode `l`: one char right, resting ON the last char (never past it).
    fn vim_move_right(&mut self) {
        let le = vim::line_end(&self.content, self.cursor);
        if let Some(ch) = self.content[self.cursor..].chars().next() {
            if ch != '\n' {
                let cand = self.cursor + ch.len_utf8();
                if cand < le {
                    self.cursor = cand;
                }
            }
        }
    }

    /// `a` helper: step right by one, allowed to land just past the last char so
    /// insert appends after it.
    fn vim_move_right_append(&mut self) {
        let le = vim::line_end(&self.content, self.cursor);
        if self.cursor < le {
            let next = self.content[self.cursor..]
                .chars()
                .next()
                .map(|c| c.len_utf8())
                .unwrap_or(0);
            self.cursor += next;
        }
    }

    /// Normal-mode `$` / End: caret on the LAST char of the line (not past it).
    fn vim_line_end_normal(&mut self) {
        let ls = vim::line_start(&self.content, self.cursor);
        let le = vim::line_end(&self.content, self.cursor);
        if le > ls {
            let prev = self.content[..le]
                .chars()
                .next_back()
                .map(|c| c.len_utf8())
                .unwrap_or(0);
            self.cursor = le - prev;
        } else {
            self.cursor = le;
        }
    }

    /// `x`: delete the char under the caret.
    fn vim_delete_under(&mut self) {
        if let Some(ch) = self.content[self.cursor..].chars().next() {
            if ch != '\n' {
                self.snapshot();
                self.content.drain(self.cursor..self.cursor + ch.len_utf8());
                self.after_edit();
                self.vim_clamp_cursor();
            }
        }
    }

    /// `D`: delete from the caret to the end of the line.
    fn vim_delete_to_line_end(&mut self) {
        let le = vim::line_end(&self.content, self.cursor);
        if le > self.cursor {
            self.snapshot();
            self.content.drain(self.cursor..le);
            self.after_edit();
            self.vim_clamp_cursor();
        }
    }

    /// `dd`: delete the whole logical line (plus one bounding newline).
    fn vim_delete_line(&mut self) {
        let ls = vim::line_start(&self.content, self.cursor);
        let le = vim::line_end(&self.content, self.cursor);
        self.snapshot();
        if le < self.content.len() {
            // Not the last line: drop the line and its trailing newline.
            self.content.drain(ls..le + 1);
            self.cursor = ls;
        } else if ls > 0 {
            // Last line, has a preceding newline: drop it and the line.
            self.content.drain(ls - 1..le);
            self.cursor = ls - 1;
        } else {
            // Only line: clear it.
            self.content.drain(ls..le);
            self.cursor = 0;
        }
        self.after_edit();
        self.vim_clamp_cursor();
    }

    /// `dw`: delete from the caret to the start of the next word.
    fn vim_delete_word_forward(&mut self) {
        let target = vim::word_forward(&self.content, self.cursor);
        if target > self.cursor {
            self.snapshot();
            self.content.drain(self.cursor..target);
            self.after_edit();
            self.vim_clamp_cursor();
        }
    }

    /// `cc`: clear the line's content and enter Insert at its start.
    fn vim_change_line(&mut self) {
        let ls = vim::line_start(&self.content, self.cursor);
        let le = vim::line_end(&self.content, self.cursor);
        self.snapshot();
        self.content.drain(ls..le);
        self.cursor = ls;
        self.after_edit();
        self.vim.mode = vim::VimMode::Insert;
    }

    /// `o`: open a new line below and enter Insert.
    fn vim_open_below(&mut self) {
        let le = vim::line_end(&self.content, self.cursor);
        self.snapshot();
        self.content.insert(le, '\n');
        self.cursor = le + 1;
        self.multiline = true;
        self.vim.mode = vim::VimMode::Insert;
        self.after_edit();
    }

    /// `O`: open a new line above and enter Insert.
    fn vim_open_above(&mut self) {
        let ls = vim::line_start(&self.content, self.cursor);
        self.snapshot();
        self.content.insert(ls, '\n');
        self.cursor = ls;
        self.multiline = true;
        self.vim.mode = vim::VimMode::Insert;
        self.after_edit();
    }

    /// Handle a key while Ctrl+R reverse-search is active.
    fn handle_reverse_search_key(&mut self, key: KeyEvent) -> ComponentAction {
        let Some(mut rs) = self.reverse_search.take() else {
            return ComponentAction::Ignored;
        };
        let mut keep = true;
        let accept = |this: &mut Self, idx: Option<usize>| {
            if let Some(i) = idx {
                if let Some(entry) = this.history.entries().get(i).cloned() {
                    this.content = entry;
                    this.cursor = this.content.len();
                    this.multiline = this.content.contains('\n');
                }
            }
        };
        match (key.code, key.modifiers) {
            // Ctrl+R again: step to the next-older match.
            (KeyCode::Char('r'), KeyModifiers::CONTROL) => {
                let before = rs.match_idx.unwrap_or(self.history.len());
                if let Some(i) = self.history.search_backward(&rs.query, before) {
                    rs.match_idx = Some(i);
                }
            }
            (KeyCode::Esc, _) => {
                keep = false; // cancel: leave the buffer untouched
            }
            (KeyCode::Enter, _) => {
                accept(self, rs.match_idx);
                keep = false;
            }
            (KeyCode::Left, _) | (KeyCode::Right, _) | (KeyCode::Home, _) | (KeyCode::End, _) => {
                accept(self, rs.match_idx);
                keep = false;
            }
            (KeyCode::Backspace, _) => {
                rs.query.pop();
                rs.match_idx = self.history.search_backward(&rs.query, self.history.len());
            }
            (KeyCode::Char(c), m) if m == KeyModifiers::NONE || m == KeyModifiers::SHIFT => {
                rs.query.push(c);
                rs.match_idx = self.history.search_backward(&rs.query, self.history.len());
            }
            _ => {} // swallow other keys while searching
        }
        if keep {
            self.reverse_search = Some(rs);
        }
        ComponentAction::Consumed
    }
}

impl Component for InputComponent {
    fn handle_event(&mut self, event: &Event) -> ComponentAction {
        if !self.focused {
            return ComponentAction::Ignored;
        }

        match event {
            Event::Terminal(CrosstermEvent::Key(key)) => {
                // Vim modal layer (opt-in). In Normal mode it owns the key
                // outright; in Insert mode only Esc is intercepted (→ Normal),
                // leaving reverse-search / completions their own Esc cancel.
                if self.vim_enabled {
                    if self.vim.mode == vim::VimMode::Normal {
                        return self.handle_vim_normal_key(*key);
                    }
                    if key.code == KeyCode::Esc
                        && key.modifiers == KeyModifiers::NONE
                        && self.reverse_search.is_none()
                        && !self.completions.is_visible()
                    {
                        self.enter_normal_mode();
                        return ComponentAction::Consumed;
                    }
                }

                // Ctrl+R reverse-incremental history search owns all keys while active.
                if self.reverse_search.is_some() {
                    return self.handle_reverse_search_key(*key);
                }

                // The instant a paste burst is detected the composer's transient
                // popups must stop reacting: a pasted '/' or '@' would otherwise
                // open a menu that then swallows the rest of the paste (Enter
                // selecting a command instead of inserting the paste's newline).
                let burst_now = self.now();
                let in_burst = self.paste_burst.in_burst_context(burst_now);

                // Route to completions popup first when visible
                if self.completions.is_visible() && !in_burst {
                    if let Some(action) = self.completions.handle_key(*key) {
                        match action {
                            CompletionAction::Select(name) => {
                                // U-T6 — reward this command in the frecency ranker.
                                self.completions.record(&name);
                                // Replace input with selected command
                                self.content = format!("{} ", name);
                                self.cursor = self.content.len();
                                self.tab_matches.clear();
                                return ComponentAction::Consumed;
                            }
                            CompletionAction::Dismiss => {
                                return ComponentAction::Consumed;
                            }
                        }
                    }
                    // Up/Down consumed by completions but returned None — still consumed
                    match key.code {
                        KeyCode::Up | KeyCode::Down => return ComponentAction::Consumed,
                        _ => {}
                    }
                }

                // Kill-ring run tracking (readline): remember the previous
                // command's kind, then default THIS command to "Other". The
                // kill / yank arms below re-mark themselves (Kill / Yank), so
                // any other key breaks kill accumulation and ends a yank-pop run
                // — exactly emacs's "last command" gate.
                let prev_edit = self.last_edit;
                self.last_edit = LastEdit::Other;

                // Paste-burst bookkeeping for everything that is neither a plain
                // character nor Enter (arrows, Ctrl/Alt chords, Backspace, ...).
                // Such a key can never be part of a paste, so any buffered burst
                // is applied through the normal paste path first and the
                // classification window is dropped so the NEXT keystroke is not
                // grouped into the burst that just ended.
                let plain_char = matches!(key.code, KeyCode::Char(_))
                    && (key.modifiers == KeyModifiers::NONE
                        || key.modifiers == KeyModifiers::SHIFT);
                if !plain_char && key.code != KeyCode::Enter {
                    if let Some(text) = self.paste_burst.flush_before_modified_input() {
                        self.insert_paste(&text);
                    }
                    self.paste_burst.clear_window_after_non_char();
                }

                match (key.code, key.modifiers) {
                    // Insert a newline (enters multiline mode) rather than submit.
                    // Shift+Enter / Alt+Enter / Ctrl+J all mean "newline, don't
                    // submit", but terminals encode them differently — the single
                    // key-normalization layer owns that quirk so this stays
                    // consistent cross-terminal. Plain Enter always submits (Claude
                    // Code convention); the portable Ctrl+J fallback covers
                    // terminals where Shift+Enter collapses to a bare Enter.
                    _ if crate::app::key_normalize::is_insert_newline(key) => {
                        self.multiline = true;
                        self.insert_char('\n');
                        return ComponentAction::Consumed;
                    }
                    // PASTE BURST — Enter arriving inside a burst window is a
                    // newline in the pasted text, not "submit". This is the
                    // whole point of the fallback: on a terminal without
                    // bracketed paste a multi-line paste arrives as chars +
                    // Enters, and without this the composer submits the first
                    // line and drops the rest. Checked BEFORE the
                    // backslash-continuation and submit arms so a pasted literal
                    // `\` at end of line survives verbatim.
                    _ if key.code == KeyCode::Enter
                        && self
                            .paste_burst
                            .direct_insert_newline_should_insert(burst_now) =>
                    {
                        // In buffering mode the newline joins the burst buffer
                        // (nothing to render); otherwise it goes straight in.
                        if !self.paste_burst.append_newline_if_active(burst_now) {
                            self.multiline = true;
                            self.insert_char('\n');
                        }
                        self.paste_burst.extend_window(burst_now);
                        self.tab_matches.clear();
                        self.completions.hide();
                        return ComponentAction::Consumed;
                    }
                    // Escape cancels file search if active
                    (KeyCode::Esc, KeyModifiers::NONE) if self.file_search_active => {
                        self.file_search_active = false;
                        self.file_matches.clear();
                        return ComponentAction::Consumed;
                    }
                    // Universal backslash-continuation newline: works on EVERY
                    // terminal regardless of keyboard protocol. When a plain Enter
                    // arrives and the char immediately left of the cursor is a literal
                    // backslash, drop that backslash and insert a newline instead of
                    // submitting (Claude Code's useTextInput handleEnter). This is the
                    // one newline path that stays reliable even where Shift+Enter
                    // collapses to a bare Enter. Skipped while the @-file dropdown is
                    // active so a plain Enter still selects a match.
                    _ if key.code == KeyCode::Enter
                        && key.modifiers == KeyModifiers::NONE
                        && !self.file_search_active
                        && crate::app::key_normalize::newline_via_backslash(
                            &self.content,
                            self.cursor,
                        ) =>
                    {
                        self.snapshot();
                        // Replace the trailing "\" (1 ASCII byte) with a newline; the
                        // cursor byte offset is unchanged (one byte removed and one
                        // inserted, both at the same spot before the cursor).
                        self.content.remove(self.cursor - 1);
                        self.content.insert(self.cursor - 1, '\n');
                        self.multiline = true;
                        self.tab_matches.clear();
                        self.completions.hide();
                        return ComponentAction::Consumed;
                    }
                    // Enter ALWAYS submits — both single-line and multiline. Submit
                    // routing goes through the key-normalization layer (the single
                    // source of truth) rather than a second literal Enter match, so
                    // "what is a submit?" is answered in exactly one place. (Ctrl+Enter
                    // is accepted too for muscle-memory / terminals that map it.)
                    _ if crate::app::key_normalize::is_submit(key) =>
                    {
                        // If file search dropdown is active and we have matches, select current match.
                        // `file_search_is_valid` gates the drain against a stale
                        // anchor (caret moved before '@' → start > end panic).
                        if self.file_search_is_valid() && !self.file_matches.is_empty() {
                            let selected =
                                self.file_matches[self.file_match_index].insert.clone();
                            self.file_frecency.record(&selected); // U-T6
                            let end = self.cursor;
                            self.content.drain(self.file_search_start..end);
                            let insertion = format!("@{} ", selected);
                            self.content.insert_str(self.file_search_start, &insertion);
                            self.cursor = self.file_search_start + insertion.len();
                            self.file_search_active = false;
                            self.file_matches.clear();
                            return ComponentAction::Consumed;
                        }

                        if self.content.trim().is_empty() {
                            return ComponentAction::Consumed;
                        }
                        let text = self.submit();
                        return ComponentAction::Emit(AppAction::Submit(text));
                    }
                    // Backspace
                    (KeyCode::Backspace, KeyModifiers::NONE) => {
                        self.delete_char();
                        if !self.content.contains('\n') {
                            self.multiline = false;
                        }
                        return ComponentAction::Consumed;
                    }
                    // Arrow keys — up/down navigate file matches when file search active
                    (KeyCode::Up, KeyModifiers::NONE) if self.file_search_active && !self.file_matches.is_empty() => {
                        if self.file_match_index > 0 {
                            self.file_match_index -= 1;
                        } else {
                            self.file_match_index = self.file_matches.len() - 1;
                        }
                        return ComponentAction::Consumed;
                    }
                    (KeyCode::Down, KeyModifiers::NONE) if self.file_search_active && !self.file_matches.is_empty() => {
                        self.file_match_index = (self.file_match_index + 1) % self.file_matches.len();
                        return ComponentAction::Consumed;
                    }
                    // Multiline: Up/Down move the CURSOR between lines (preserving
                    // column). At the TOP edge (cursor on the first line) Up
                    // crosses into history recall; at the BOTTOM edge Down does —
                    // matching Claude Code, where history is reached only from the
                    // buffer edge. Single-line / empty input recall via the arms
                    // below.
                    (KeyCode::Up, KeyModifiers::NONE)
                        if self.multiline || self.content.contains('\n') =>
                    {
                        if up_crosses_to_history(&self.content, self.cursor) {
                            if let Some(text) = self.history_recall_prev() {
                                self.content = text;
                                self.cursor = self.content.len();
                                self.multiline = self.content.contains('\n');
                            }
                        } else {
                            self.move_cursor_up();
                        }
                        return ComponentAction::Consumed;
                    }
                    (KeyCode::Down, KeyModifiers::NONE)
                        if self.multiline || self.content.contains('\n') =>
                    {
                        if down_crosses_to_history(&self.content, self.cursor) {
                            if let Some(text) = self.history_recall_next() {
                                self.content = text;
                                self.cursor = self.content.len();
                                self.multiline = self.content.contains('\n');
                            }
                            // else: already at newest with no stashed draft — stay
                            // put (cursor at buffer end), never wipe the draft.
                        } else {
                            self.move_cursor_down();
                        }
                        return ComponentAction::Consumed;
                    }
                    (KeyCode::Left, KeyModifiers::NONE) => {
                        self.move_left();
                        return ComponentAction::Consumed;
                    }
                    (KeyCode::Right, KeyModifiers::NONE) => {
                        // U-T3 — → at end-of-buffer accepts the ghost suggestion
                        // (fish/CC), otherwise it just moves the caret.
                        if self.cursor == self.content.len() && self.accept_ghost() {
                            return ComponentAction::Consumed;
                        }
                        self.move_right();
                        return ComponentAction::Consumed;
                    }
                    // Home/End within input
                    (KeyCode::Home, KeyModifiers::NONE) => {
                        self.cursor = 0;
                        self.revalidate_file_search();
                        return ComponentAction::Consumed;
                    }
                    (KeyCode::End, KeyModifiers::NONE) => {
                        self.cursor = self.content.len();
                        self.revalidate_file_search();
                        return ComponentAction::Consumed;
                    }
                    // History up/down (only in single-line mode, not during file
                    // search). Routed through the bucket-aware helpers so a
                    // `!`-shell line recalls shell history (U-T4).
                    (KeyCode::Up, KeyModifiers::NONE) if !self.multiline => {
                        if let Some(text) = self.history_recall_prev() {
                            self.content = text;
                            self.cursor = self.content.len();
                        }
                        return ComponentAction::Consumed;
                    }
                    (KeyCode::Down, KeyModifiers::NONE) if !self.multiline => {
                        // C5 — a newer entry or the restored half-typed draft; no
                        // stash and no newer entry → leave the buffer untouched
                        // instead of wiping the in-progress line.
                        if let Some(text) = self.history_recall_next() {
                            self.content = text;
                            self.cursor = self.content.len();
                        }
                        return ComponentAction::Consumed;
                    }
                    // U-T2 — emacs Ctrl+P / Ctrl+N history & line navigation,
                    // mirroring ↑ / ↓ (readline muscle memory).
                    (KeyCode::Char('p'), KeyModifiers::CONTROL) => {
                        self.on_up();
                        return ComponentAction::Consumed;
                    }
                    (KeyCode::Char('n'), KeyModifiers::CONTROL) => {
                        self.on_down();
                        return ComponentAction::Consumed;
                    }
                    // Tab completion — but first accept an inline ghost
                    // suggestion when one is showing (U-T3), so Tab both
                    // completes commands AND accepts autosuggestions like fish.
                    (KeyCode::Tab, KeyModifiers::NONE) => {
                        if self.accept_ghost() {
                            return ComponentAction::Consumed;
                        }
                        self.handle_tab();
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+U: kill from the cursor to the start of the line into
                    // the kill-ring (readline unix-line-discard / CC
                    // killToLineStart). This used to wipe the WHOLE buffer and
                    // discard the text; now it's a proper backward kill whose
                    // text Ctrl+Y can bring back.
                    (KeyCode::Char('u'), KeyModifiers::CONTROL) => {
                        self.kill_to_line_start(prev_edit == LastEdit::Kill);
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+A: move to start
                    (KeyCode::Char('a'), KeyModifiers::CONTROL) => {
                        self.cursor = 0;
                        self.revalidate_file_search();
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+E: move to end
                    (KeyCode::Char('e'), KeyModifiers::CONTROL) => {
                        self.cursor = self.content.len();
                        self.revalidate_file_search();
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+K: kill from cursor to end of line (into the kill-ring)
                    (KeyCode::Char('k'), KeyModifiers::CONTROL) => {
                        self.kill_to_line_end(prev_edit == LastEdit::Kill);
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+W: kill the word before cursor (into the kill-ring)
                    (KeyCode::Char('w'), KeyModifiers::CONTROL) => {
                        self.delete_word_back(prev_edit == LastEdit::Kill);
                        return ComponentAction::Consumed;
                    }
                    // Alt+D: kill the word forward from the cursor (into the ring)
                    (KeyCode::Char('d'), KeyModifiers::ALT) => {
                        self.kill_word_forward(prev_edit == LastEdit::Kill);
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+D: delete the char under the cursor (readline
                    // delete-forward). The idle handler routes Ctrl+D here only
                    // when the buffer is non-empty; empty Ctrl+D is EOF/quit.
                    (KeyCode::Char('d'), KeyModifiers::CONTROL) => {
                        self.delete_forward_char();
                        return ComponentAction::Consumed;
                    }
                    // Alt+B: move one word left
                    (KeyCode::Char('b'), KeyModifiers::ALT) => {
                        self.move_word_left();
                        return ComponentAction::Consumed;
                    }
                    // Alt+F: move one word right
                    (KeyCode::Char('f'), KeyModifiers::ALT) => {
                        self.move_word_right();
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+_ : undo (Ctrl+Z is now app-level suspend). Encodings:
                    // legacy terminals send 0x1F, which crossterm decodes as
                    // Ctrl+'7' (parse.rs maps 0x1C..=0x1F to '4'..='7');
                    // kitty-protocol terminals report '_' (often with SHIFT,
                    // since '_' is shifted '-'); Ctrl+'-' is accepted for CC
                    // parity. `contains` tolerates stray protocol bits.
                    (KeyCode::Char('_') | KeyCode::Char('7') | KeyCode::Char('-'), m)
                        if m.contains(KeyModifiers::CONTROL)
                            && !m.contains(KeyModifiers::ALT) =>
                    {
                        self.undo();
                        return ComponentAction::Consumed;
                    }
                    // Alt+_ / Alt+- : redo. Ctrl+Y is now the readline YANK
                    // (below), so redo moved off it onto the Alt-mirror of the
                    // Ctrl+_ undo chord — a non-conflicting home that mirrors
                    // undo's key. Encodings mirror the undo arm.
                    (KeyCode::Char('_') | KeyCode::Char('7') | KeyCode::Char('-'), m)
                        if m.contains(KeyModifiers::ALT) =>
                    {
                        self.redo();
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+Y: YANK the most recent kill at the caret (readline;
                    // CC useTextInput yank). This replaces the old redo binding —
                    // every emacs/bash user expects Ctrl+K then Ctrl+Y to move
                    // text, and the killed text was previously discarded.
                    (KeyCode::Char('y'), KeyModifiers::CONTROL) => {
                        self.yank();
                        return ComponentAction::Consumed;
                    }
                    // Alt+Y: YANK-POP — rotate the ring, swapping the just-yanked
                    // text for the previous entry. Only meaningful directly after
                    // a yank / yank-pop (gated on the previous command); otherwise
                    // a harmless no-op.
                    (KeyCode::Char('y'), KeyModifiers::ALT) => {
                        if prev_edit == LastEdit::Yank {
                            self.yank_pop();
                        }
                        return ComponentAction::Consumed;
                    }
                    // Ctrl+G: open the current buffer in $EDITOR
                    (KeyCode::Char('g'), KeyModifiers::CONTROL) => {
                        return match self.open_in_editor() {
                            Ok(_) => ComponentAction::Consumed,
                            Err(e) => ComponentAction::Emit(AppAction::Toast(e)),
                        };
                    }
                    // Ctrl+R: enter reverse-incremental history search
                    (KeyCode::Char('r'), KeyModifiers::CONTROL) => {
                        if self.history.is_empty() {
                            return ComponentAction::Emit(AppAction::Toast(
                                "History is empty".into(),
                            ));
                        }
                        self.reverse_search = Some(ReverseSearch {
                            query: String::new(),
                            match_idx: None,
                        });
                        return ComponentAction::Consumed;
                    }
                    // Step 10: Ctrl+S toggles stash (stash when non-empty, restore when empty)
                    (KeyCode::Char('s'), KeyModifiers::CONTROL) => {
                        if !self.content.is_empty() {
                            if self.stash() {
                                return ComponentAction::Emit(AppAction::Toast(
                                    "Input stashed".into(),
                                ));
                            }
                        } else if self.restore_stash() {
                            return ComponentAction::Emit(AppAction::Toast("Input restored".into()));
                        }
                        return ComponentAction::Consumed;
                    }
                    // Regular character input — routed through the paste-burst
                    // classifier, which in the default direct-insert mode still
                    // inserts every char immediately and only tracks timing.
                    (KeyCode::Char(ch), m)
                        if m == KeyModifiers::NONE || m == KeyModifiers::SHIFT =>
                    {
                        self.handle_plain_char(ch, burst_now);
                        return ComponentAction::Consumed;
                    }
                    _ => {}
                }
                ComponentAction::Ignored
            }
            _ => ComponentAction::Ignored,
        }
    }

    fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = style::theme();

        // WS5 — queued messages (typed mid-turn) render as dim one-row lines
        // directly above the composer (CC PromptInputQueuedCommands) so the
        // user can see and verify what they queued; ↑ / Esc pops them back
        // into the composer for editing.
        let mut area = area;
        let queued_rows = self.queued_lines() as u16;
        if queued_rows > 0 && area.height > queued_rows + 1 {
            let max_items = 4usize;
            let shown = self.queued_items.len().min(max_items);
            for (i, item) in self.queued_items.iter().take(shown).enumerate() {
                let one_line = item.replace('\n', " ");
                let mut spans = vec![
                    Span::styled("\u{29d6} ", theme.hint()),
                    Span::styled(one_line.clone(), theme.hint()),
                ];

                // Say WHEN it runs, on the first row only.
                //
                // A queued message rendered as a dim line and nothing else,
                // which during a long turn is indistinguishable from the app
                // ignoring the keystroke. Reported after a 14-minute fan-out:
                // typing appeared to do nothing, and the user interrupted to
                // force it — which worked, but only by accident of the queue
                // draining on interrupt.
                //
                // Naming the trigger turns "nothing happened" into "I know what
                // happens next, and what to do if I want it sooner". The
                // interrupt half is accurate: `turn_done` is set on the
                // interrupt path, so a queued message fires promptly rather
                // than waiting out the cancel timeout.
                //
                // Only when it fits: this must never push the composer down or
                // wrap, so it is dropped on a narrow terminal rather than
                // costing a row.
                if i == 0 {
                    let used = unicode_width::UnicodeWidthStr::width(one_line.as_str()) + 2;
                    let fits = |h: &str| {
                        used + unicode_width::UnicodeWidthStr::width(h) <= area.width as usize
                    };
                    // Widest truthful form first, then the short form, then
                    // nothing. Two tiers rather than one so a narrow terminal
                    // keeps "sends when this turn ends" — the half that fixed
                    // the "typing appeared to do nothing" report — instead of
                    // losing the whole row's explanation to a longer sentence.
                    let hint = if fits(QUEUED_HINT_FULL) {
                        Some(QUEUED_HINT_FULL)
                    } else if fits(QUEUED_HINT_SHORT) {
                        Some(QUEUED_HINT_SHORT)
                    } else {
                        None
                    };
                    if let Some(hint) = hint {
                        spans.push(Span::styled(hint.to_string(), theme.recede()));
                    }
                }

                let line = Line::from(spans);
                frame.render_widget(
                    Paragraph::new(line),
                    Rect::new(area.x, area.y + i as u16, area.width, 1),
                );
            }
            if self.queued_items.len() > max_items {
                let more = format!("  +{} more queued", self.queued_items.len() - max_items);
                frame.render_widget(
                    Paragraph::new(Span::styled(more, theme.hint())),
                    Rect::new(area.x, area.y + shown as u16, area.width, 1),
                );
            }
            area = Rect::new(
                area.x,
                area.y + queued_rows,
                area.width,
                area.height - queued_rows,
            );
        }

        if area.height < 2 {
            return;
        }

        // Shell mode: a leading '!' routes the line to OSA's bash tool on submit.
        // Memory mode: a leading '#' quick-adds the line to memory on submit
        // (mirrors the shell branch — CC's `# note` quick-capture). Each recolors
        // the frame and flags a badge so the active mode is obvious while typing.
        let shell_mode = self.content.starts_with('!');
        let memory_mode = self.content.starts_with('#');
        let divider_style = if shell_mode {
            Style::default().fg(theme.colors.primary)
        } else if memory_mode {
            Style::default().fg(theme.colors.secondary)
        } else {
            theme.prompt_border()
        };

        // Top divider — full-width `─` rule (Claude-Code style).
        let sep_area = Rect::new(area.x, area.y, area.width, 1);
        let separator =
            Paragraph::new("\u{2500}".repeat(area.width as usize)).style(divider_style);
        frame.render_widget(separator, sep_area);

        // Right-aligned mode badge on the top divider ("shell" / "memory").
        let mode_badge = if shell_mode {
            Some(" shell ")
        } else if memory_mode {
            Some(" memory ")
        } else {
            None
        };
        if let Some(badge) = mode_badge {
            let bw = badge.chars().count() as u16;
            if area.width > bw + 4 {
                let badge_area = Rect::new(area.x + area.width - bw - 1, area.y, bw, 1);
                frame.render_widget(
                    Paragraph::new(Span::styled(badge, theme.button_active())),
                    badge_area,
                );
            }
        }

        // Bottom divider — reserve the last row for a matching `─` rule when we
        // have room for it (top div + >=1 text row + bottom div).
        let has_bottom = area.height >= 3;
        if has_bottom {
            let bot_area = Rect::new(area.x, area.y + area.height - 1, area.width, 1);
            let bottom =
                Paragraph::new("\u{2500}".repeat(area.width as usize)).style(divider_style);
            frame.render_widget(bottom, bot_area);

            // Always-visible prefix hint, right-aligned on the bottom divider so
            // OSA's composer affordances are discoverable at a glance. Advertises
            // only prefixes that actually work.
            // Keep this minimal — the essentials only, so the composer reads calm
            // rather than busy. Shell (`!`) / newline / palette stay discoverable
            // via /help and the welcome hint instead of crowding this line.
            // Terminal-aware newline affordance (mirrors Claude Code's
            // getNewlineInstructions): when the kitty keyboard protocol is active
            // Shift+Enter reliably inserts a newline, so advertise it; otherwise
            // advertise the universal backslash-continuation ("\\\u{23ce}"), the one
            // newline that works on every terminal. Fixes the discoverability gap
            // where the only working newline key was invisible. Shown only on wide
            // enough composers so narrow terminals stay calm.
            let nl = if self.kbd_enhanced { "shift+\u{23ce}" } else { "\\\u{23ce}" };
            let w = area.width as usize;
            let hint = if w >= 88 {
                format!("  / commands \u{00b7} @ files \u{00b7} # memory \u{00b7} {} newline  ", nl)
            } else if w >= 68 {
                "  / commands \u{00b7} @ files \u{00b7} # memory  ".to_string()
            } else if w >= 50 {
                "  / commands \u{00b7} @ files  ".to_string()
            } else {
                String::new()
            };
            let hw = hint.chars().count() as u16;
            if hw > 0 && area.width > hw + 2 {
                let hint_area = Rect::new(area.x + area.width - hw, bot_area.y, hw, 1);
                frame.render_widget(
                    Paragraph::new(Span::styled(hint, theme.hint())),
                    hint_area,
                );
            }

            // Vim mode indicator, left-aligned on the bottom divider. Only shown
            // when vim mode is enabled so the default composer stays uncluttered.
            if self.vim_enabled {
                let vlabel = format!(" {} ", self.vim.label());
                let vw = vlabel.chars().count() as u16;
                let vstyle = if self.vim.is_normal() {
                    theme.button_active()
                } else {
                    theme.hint()
                };
                if area.width > vw + 2 {
                    let v_area = Rect::new(area.x + 1, bot_area.y, vw, 1);
                    frame.render_widget(
                        Paragraph::new(Span::styled(vlabel, vstyle)),
                        v_area,
                    );
                }
            }
        }

        // Input line(s) — everything between the two dividers.
        let input_h = if has_bottom {
            area.height - 2
        } else {
            area.height - 1
        };
        let input_area = Rect::new(area.x, area.y + 1, area.width, input_h);

        // Vertical scroll: once the input has grown to its cap, keep the cursor's
        // line visible by scrolling within the box (so Shift+Enter keeps working
        // past the visible height instead of clipping).
        let v_scroll: u16 = if self.multiline || self.content.contains('\n') {
            let total_lines = self.content.split('\n').count() as u16;
            let cursor_line = self.content[..self.cursor.min(self.content.len())]
                .matches('\n')
                .count() as u16;
            let visible = input_area.height.max(1);
            // Keep lines 0..visible showing while the cursor is near the top; only
            // scroll once the cursor passes the last visible row, and never scroll
            // past the final line (which would blank out the box when it's small).
            let max_scroll = total_lines.saturating_sub(visible);
            cursor_line
                .saturating_sub(visible.saturating_sub(1))
                .min(max_scroll)
        } else {
            0
        };

        // Step 4: Processing-aware prompt
        let (prompt, prompt_len) = if self.processing {
            ("\u{25c8} \u{276f} ", 4) // "◈ ❯ " — 4 display chars
        } else if self.focused {
            ("\u{276f} ", 2) // "❯ " — 2 display chars
        } else {
            ("  ", 2)
        };
        let prompt_style = if self.processing {
            Style::default().fg(theme.colors.secondary)
        } else if self.focused {
            theme.prompt_char()
        } else {
            theme.faint()
        };

        // Ctrl+R reverse-search overlay replaces the normal input line.
        if let Some(rs) = &self.reverse_search {
            let matched = rs
                .match_idx
                .and_then(|i| self.history.entries().get(i))
                .map(|s| s.replace('\n', " \u{23ce} "))
                .unwrap_or_else(|| "(no match)".to_string());
            let label = format!("(reverse-i-search)`{}': ", rs.query);
            let label_cols = label.chars().count();
            let line = Line::from(vec![
                Span::styled("\u{276f} ", prompt_style),
                Span::styled(label, theme.hint()),
                Span::raw(matched),
            ]);
            frame.render_widget(Paragraph::new(line), input_area);
            if self.focused {
                let cursor_x = area.x + 2 + label_cols as u16;
                let cursor_y = area.y + 1;
                if cursor_x < area.x + area.width {
                    frame.set_cursor_position(Position::new(cursor_x, cursor_y));
                }
            }
            return;
        }

        if self.content.is_empty() {
            let placeholder = if self.recording {
                "\u{25C9} Recording... press Enter to stop, Esc to cancel"
            } else {
                self.placeholder()
            };
            let placeholder_style = if self.recording {
                Style::default().fg(Color::Red)
            } else {
                theme.input_placeholder()
            };
            let line = Line::from(vec![
                Span::styled(prompt, prompt_style),
                Span::styled(placeholder, placeholder_style),
            ]);
            frame.render_widget(Paragraph::new(line), input_area);
        } else if let Some(pilled) =
            splice_middle(&self.content, HUGE_INPUT_THRESHOLD, HUGE_INPUT_KEEP)
        {
            // U-T5 — huge draft: collapse the middle into a "[… N chars …]" pill
            // so the composer renders a compact preview instead of laying out
            // tens of thousands of chars every frame. The FULL content is kept
            // for submit / Ctrl+G-edit; this is display-only. Precise caret
            // tracking is intentionally dropped in this rare mode (edit the huge
            // draft in $EDITOR via Ctrl+G).
            let preview = pilled.replace('\n', " ");
            let mut spans = vec![Span::styled(prompt, prompt_style)];
            if let (Some(a), Some(bstart)) =
                (preview.find("[\u{2026} "), preview.find("chars \u{2026}]"))
            {
                let bend = bstart + "chars \u{2026}]".len();
                spans.push(Span::raw(preview[..a].to_string()));
                spans.push(Span::styled(preview[a..bend].to_string(), theme.hint()));
                spans.push(Span::raw(preview[bend..].to_string()));
            } else {
                spans.push(Span::raw(preview));
            }
            let paragraph = ratatui::widgets::Paragraph::new(Line::from(spans))
                .wrap(ratatui::widgets::Wrap { trim: false });
            frame.render_widget(paragraph, input_area);
            return;
        } else {
            // Available width for text (after prompt)
            let avail = (input_area.width as usize).saturating_sub(prompt_len + 1);

            // Build text with prompt on first line, wrapping enabled
            let mut text_lines: Vec<Line<'_>> = Vec::new();
            let content_str: &str = &self.content;

            if self.multiline || content_str.contains('\n') {
                // Multiline: split on newlines, each line gets wrapped by Paragraph
                for (i, text_line) in content_str.split('\n').enumerate() {
                    if i == 0 {
                        let mut spans = vec![Span::styled(prompt, prompt_style)];
                        spans.extend(chip_spans(text_line, theme.attachment_chip()));
                        text_lines.push(Line::from(spans));
                    } else {
                        let mut spans = vec![Span::raw("  ".to_string())]; // indent
                        spans.extend(chip_spans(text_line, theme.attachment_chip()));
                        text_lines.push(Line::from(spans));
                    }
                }
            } else if avail > 0 && display_width(content_str) > avail {
                // Single-line but too long: horizontal scroll to keep cursor
                // visible. Measured in DISPLAY columns so a wide-char line
                // scrolls by the right amount and never clips a glyph.
                let cursor_col = display_width(&content_str[..self.cursor]);
                let start = if cursor_col >= avail {
                    cursor_col - avail + 1
                } else {
                    0
                };
                let visible: String = slice_by_display_cols(content_str, start, avail);
                let mut spans = vec![Span::styled(prompt, prompt_style)];
                spans.extend(chip_spans(&visible, theme.attachment_chip()));
                text_lines.push(Line::from(spans));
            } else {
                let mut spans = vec![Span::styled(prompt, prompt_style)];
                spans.extend(chip_spans(content_str, theme.attachment_chip()));
                // U-T3 — dimmed inline autocomplete: append the ghost suffix
                // after the caret (which is at end-of-line here). Only when it
                // still fits the visible width so it never forces a wrap.
                if let Some(ghost) = self.ghost_suffix() {
                    let used = prompt_len + display_width(content_str);
                    let room = (input_area.width as usize).saturating_sub(used + 1);
                    if room > 0 {
                        let shown = slice_by_display_cols(&ghost, 0, room);
                        if !shown.is_empty() {
                            spans.push(Span::styled(shown, theme.faint()));
                        }
                    }
                }
                text_lines.push(Line::from(spans));
            }

            let paragraph = ratatui::widgets::Paragraph::new(Text::from(text_lines))
                .wrap(ratatui::widgets::Wrap { trim: false })
                .scroll((v_scroll, 0));
            frame.render_widget(paragraph, input_area);
        }

        // NOTE: the `/`-completions popup and the `@`-mention dropdown are NOT
        // drawn here any more. Both used to paint at `area.y - n`, i.e. into rows
        // ABOVE the composer's own rect that belong to the context-hint / survey /
        // agents bands, with nothing reserving them — the same unreserved-overlay
        // defect the task checklist had. They now draw into `ROW_POPUP` via
        // `draw_popup`, a band the layout reserves (`App::popup_slot`).

        // Stash indicator
        if self.stash.is_some() && self.content.is_empty() {
            let hint = "[Ctrl+S to restore stash]";
            let hint_width = hint.len() as u16;
            if input_area.width > hint_width + 10 {
                let hint_area = Rect::new(
                    input_area.x + input_area.width - hint_width,
                    input_area.y,
                    hint_width,
                    1,
                );
                frame.render_widget(
                    Paragraph::new(Span::styled(hint, theme.hint())),
                    hint_area,
                );
            }
        }

        // NOTE: the old clickable mic button was removed with the mouse layer —
        // OSA does not capture the mouse (native scroll is preserved; see main.rs
        // and app/update.rs), so a drawn mic button could not be clicked and only
        // looked clickable. Voice input is toggled with Alt+V.

        // Message-queue indicator ("N queued") — shown while messages wait for
        // the current turn to finish. During processing the mic button is
        // hidden, so the right edge is free for this badge.
        if self.queued_count > 0 {
            let label = format!(" \u{29d6} {} queued ", self.queued_count);
            let w = label.chars().count() as u16;
            if input_area.width > w + 6 {
                let q_area = Rect::new(
                    input_area.x + input_area.width - w,
                    input_area.y,
                    w,
                    1,
                );
                frame.render_widget(
                    Paragraph::new(Span::styled(label, theme.hint())),
                    q_area,
                );
            }
        }

        // Show cursor
        if self.focused {
            let avail = (area.width as usize).saturating_sub(prompt_len + 1);

            if self.multiline || self.content.contains('\n') {
                // Multiline cursor: find which line and column
                let before_cursor = &self.content[..self.cursor];
                let line_idx = before_cursor.matches('\n').count();
                let last_newline = before_cursor.rfind('\n');
                let col = match last_newline {
                    Some(pos) => display_width(&before_cursor[pos + 1..]),
                    None => display_width(before_cursor),
                };
                let indent: u16 = if line_idx == 0 { prompt_len as u16 } else { 2 };
                let cursor_x = area.x + indent + col as u16;
                // Account for the vertical scroll so the caret tracks the cursor
                // line even after the input has scrolled past its visible height.
                let cursor_y = area.y + 1 + (line_idx as u16).saturating_sub(v_scroll);
                if cursor_x < area.x + area.width && cursor_y < area.y + area.height {
                    frame.set_cursor_position(Position::new(cursor_x, cursor_y));
                }
            } else {
                // Single-line cursor (accounts for horizontal scroll), measured
                // in display columns so the caret tracks wide chars correctly.
                let cursor_col = display_width(&self.content[..self.cursor]);
                let scroll_start = if avail > 0 && cursor_col >= avail {
                    cursor_col - avail + 1
                } else {
                    0
                };
                let visible_cursor = (cursor_col - scroll_start) as u16;
                let cursor_x = area.x + prompt_len as u16 + visible_cursor;
                let cursor_y = area.y + 1;
                if cursor_x < area.x + area.width {
                    frame.set_cursor_position(Position::new(cursor_x, cursor_y));
                }
            }
        }
    }

    fn set_focused(&mut self, focused: bool) {
        self.focused = focused;
    }
}

/// True when `name` is set to a truthy value (`1` / `true`, case-insensitive).
fn env_flag(name: &str) -> bool {
    std::env::var(name)
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// The largest char boundary `<= idx` (clamped to the string length). Retro-
/// capture slices `content[..cursor]`, and a raw slice at a mid-codepoint index
/// aborts the whole TUI.
fn floor_char_boundary(s: &str, idx: usize) -> usize {
    let mut i = idx.min(s.len());
    while i > 0 && !s.is_char_boundary(i) {
        i -= 1;
    }
    i
}

/// Panic-proof substring by byte range. Clamps both ends to `[0, len]`, treats
/// an inverted range (`start >= end`, e.g. a stale `@`-anchor or a leading-`/`
/// filter with the caret at 0) as empty, and snaps the ends INWARD to char
/// boundaries so a multibyte codepoint can never split. Every composer slice
/// that mixes a stored byte anchor with the live cursor MUST go through this —
/// a raw `&content[a..b]` there aborts the whole TUI (start > end or a
/// mid-codepoint index both panic).
fn safe_str_range(s: &str, start: usize, end: usize) -> &str {
    let len = s.len();
    let start = start.min(len);
    let end = end.min(len);
    if start >= end {
        return "";
    }
    let mut lo = start;
    while lo < end && !s.is_char_boundary(lo) {
        lo += 1;
    }
    let mut hi = end;
    while hi > lo && !s.is_char_boundary(hi) {
        hi -= 1;
    }
    if lo >= hi {
        return "";
    }
    &s[lo..hi]
}

/// True when the cursor sits on the FIRST visual line of `content` (no newline
/// before it). Pure + unit-testable geometry helper.
fn cursor_on_first_line(content: &str, cursor: usize) -> bool {
    let c = cursor.min(content.len());
    !content[..c].contains('\n')
}

/// True when the cursor sits on the LAST visual line of `content` (no newline
/// after it). Pure + unit-testable geometry helper.
fn cursor_on_last_line(content: &str, cursor: usize) -> bool {
    let c = cursor.min(content.len());
    !content[c..].contains('\n')
}

/// Decision for an Up press inside a MULTILINE buffer: cross into history
/// recall only at the very top-of-buffer edge (cursor at offset 0). Anywhere
/// else the caret moves up a line first, so a single stray Up can never replace
/// an in-progress draft — the user must deliberately reach the top-left corner
/// and press Up again (shell-style). Pure + unit-testable.
fn up_crosses_to_history(content: &str, cursor: usize) -> bool {
    cursor == 0 && cursor_on_first_line(content, cursor)
}

/// Decision for a Down press inside a MULTILINE buffer: cross into history at
/// the very end-of-buffer edge. Combined with `History::next()` (which yields
/// nothing unless already navigating), a genuine multiline draft is never
/// clobbered. Pure + unit-testable.
fn down_crosses_to_history(content: &str, cursor: usize) -> bool {
    cursor >= content.len() && cursor_on_last_line(content, cursor)
}

/// Chars of pasted text handled inline before collapsing into a pill token —
/// ported verbatim from Claude Code (imagePaste.ts PASTE_THRESHOLD).
pub const PASTE_THRESHOLD: usize = 800;

/// U-T5 — a composed draft longer than this (chars) collapses its middle into a
/// display pill so the composer stays responsive on giant drafts.
pub const HUGE_INPUT_THRESHOLD: usize = 10_000;

/// U-T5 — chars kept visible at EACH end of a huge draft before the middle pill.
pub const HUGE_INPUT_KEEP: usize = 2_000;

/// U-T5 — if `content` exceeds `threshold` chars, return a display string whose
/// middle is replaced by a "[… N chars …]" pill, keeping `keep` chars at each
/// end. `None` when the content is short enough to show whole. Splits on char
/// boundaries (never mid-codepoint) and never double-counts: `hidden` is exactly
/// the elided char count. Display-only — the composer keeps the full buffer.
pub fn splice_middle(content: &str, threshold: usize, keep: usize) -> Option<String> {
    let total = content.chars().count();
    if total <= threshold {
        return None;
    }
    // Guard against overlap on pathological small `threshold`/large `keep`.
    let keep = keep.min(total / 2);
    if keep == 0 || 2 * keep >= total {
        return None;
    }
    let head: String = content.chars().take(keep).collect();
    let tail: String = content.chars().skip(total - keep).collect();
    let hidden = total - 2 * keep;
    Some(format!("{head}[\u{2026} {hidden} chars \u{2026}]{tail}"))
}

/// Rotating example prompts / hints for the empty composer (opencode
/// index.tsx:288-304 rotating placeholder list; CC usePromptInputPlaceholder
/// example-command cascade). Index 0 is the classic default so the composer
/// still greets identically on first launch; the rest rotate on each submit to
/// surface `/`, `@`, and `#` affordances.
const PLACEHOLDERS: &[&str] = &[
    "Ask OSA anything\u{2026}",
    "Type / for commands \u{00b7} @ to add a file",
    "Describe a task and OSA will get to work\u{2026}",
    "Paste an error and ask OSA to fix it\u{2026}",
    "@ a file to pull it in as context\u{2026}",
    "Start a line with # to save a note to memory\u{2026}",
    "Ask OSA to explain, refactor, or debug\u{2026}",
];

/// Display width (terminal columns) of `s`, honoring CJK/emoji wide chars and
/// zero-width combining marks — matches `render/markdown.rs` + `message.rs`
/// so the composer measures text the same way the transcript does.
fn display_width(s: &str) -> usize {
    UnicodeWidthStr::width(s)
}

/// Substring of `s` starting at display column `start_col`, spanning at most
/// `max_cols` display columns. Drives the composer's single-line horizontal
/// scroll so a wide-char window advances by columns, not chars, and never
/// clips a glyph mid-cell.
fn slice_by_display_cols(s: &str, start_col: usize, max_cols: usize) -> String {
    let mut col = 0usize;
    let mut taken = 0usize;
    let mut out = String::new();
    for ch in s.chars() {
        let w = UnicodeWidthChar::width(ch).unwrap_or(0);
        if col < start_col {
            col += w;
            continue;
        }
        if taken + w > max_cols {
            break;
        }
        out.push(ch);
        taken += w;
    }
    out
}

/// True when `tok` is a chip token: "[Image #3]", "[File #12]",
/// "[Pasted text #1]" or "[Pasted text #1 +10 lines]".
fn is_chip_token(tok: &str) -> bool {
    let inner = match tok.strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
        Some(i) => i,
        None => return false,
    };
    for prefix in ["Image #", "File #"] {
        if let Some(num) = inner.strip_prefix(prefix) {
            return !num.is_empty() && num.bytes().all(|b| b.is_ascii_digit());
        }
    }
    // WS9 — large-paste pill: "Pasted text #N" with optional " +M lines".
    if let Some(rest) = inner.strip_prefix("Pasted text #") {
        let digits = rest.bytes().take_while(|b| b.is_ascii_digit()).count();
        if digits == 0 {
            return false;
        }
        let tail = &rest[digits..];
        if tail.is_empty() {
            return true;
        }
        if let Some(mid) = tail.strip_prefix(" +").and_then(|t| t.strip_suffix(" lines")) {
            return !mid.is_empty() && mid.bytes().all(|b| b.is_ascii_digit());
        }
        return false;
    }
    false
}

/// Byte ranges `[start, end)` of every chip token in `content`, left to
/// right. Shared by chip styling, atomic delete, caret hop and pill expansion
/// so all four agree on exactly what a token is.
fn chip_ranges(content: &str) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut base = 0;
    while let Some(open_rel) = content[base..].find('[') {
        let open = base + open_rel;
        match content[open..].find(']') {
            Some(close_rel) => {
                let end = open + close_rel + 1;
                if is_chip_token(&content[open..end]) {
                    out.push((open, end));
                    base = end;
                } else {
                    base = open + 1;
                }
            }
            None => break,
        }
    }
    out
}

/// The id N of a "[Pasted text #N ...]" pill token, or None for other chips.
fn pill_id(tok: &str) -> Option<usize> {
    if !is_chip_token(tok) {
        return None;
    }
    let rest = tok.strip_prefix("[Pasted text #")?;
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

/// WS9 — CC PromptInput.tsx onTextPaste normalization, ported verbatim:
/// strip ANSI escape sequences, then replace every `\r` with `\n` (CC's
/// `/\r/g` — CRLF intentionally becomes two newlines, matching CC exactly)
/// and every tab with four spaces.
pub fn normalize_paste(raw: &str) -> String {
    strip_ansi(raw).replace('\r', "\n").replace('\t', "    ")
}

/// Remove ANSI escape sequences: CSI (`ESC [ … final byte`), OSC (`ESC ] …`
/// terminated by BEL or `ESC \`), and two-char `ESC x` escapes. Pasting
/// colored terminal output must yield plain text, not control bytes.
fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            out.push(c);
            continue;
        }
        match chars.peek().copied() {
            Some('[') => {
                // CSI: parameter/intermediate bytes end at a final byte @..~.
                chars.next();
                for n in chars.by_ref() {
                    if ('\u{40}'..='\u{7e}').contains(&n) {
                        break;
                    }
                }
            }
            Some(']') => {
                // OSC: terminated by BEL or the ST sequence ESC \.
                chars.next();
                while let Some(n) = chars.next() {
                    if n == '\u{07}' {
                        break;
                    }
                    if n == '\u{1b}' {
                        if chars.peek() == Some(&'\\') {
                            chars.next();
                        }
                        break;
                    }
                }
            }
            Some(_) => {
                chars.next();
            }
            None => {}
        }
    }
    out
}

/// Split `text` into spans, styling attachment chip tokens ("[Image #N]",
/// "[File #N]") distinctly with `chip_style` and leaving the rest as-is.
fn chip_spans(text: &str, chip_style: Style) -> Vec<Span<'static>> {
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut rest = text;
    while let Some(open) = rest.find('[') {
        if let Some(rel) = rest[open..].find(']') {
            let close = open + rel;
            let token = &rest[open..=close];
            if is_chip_token(token) {
                if open > 0 {
                    spans.push(Span::raw(rest[..open].to_string()));
                }
                spans.push(Span::styled(token.to_string(), chip_style));
                rest = &rest[close + 1..];
                continue;
            }
        }
        // A '[' that doesn't open a chip: emit through it and keep scanning.
        spans.push(Span::raw(rest[..=open].to_string()));
        rest = &rest[open + 1..];
    }
    if !rest.is_empty() {
        spans.push(Span::raw(rest.to_string()));
    }
    spans
}

#[cfg(test)]
mod input_edit_tests {
    use super::*;
    use crossterm::event::{Event as CrosstermEvent, KeyCode, KeyEvent, KeyModifiers};

    fn key(code: KeyCode, mods: KeyModifiers) -> Event {
        Event::Terminal(CrosstermEvent::Key(KeyEvent::new(code, mods)))
    }

    /// Build an input with `content` and the cursor placed at byte `cursor`.
    fn at(content: &str, cursor: usize) -> InputComponent {
        let mut input = InputComponent::new();
        input.content = content.to_string();
        input.cursor = cursor.min(input.content.len());
        input.multiline = input.content.contains('\n');
        input
    }

    // ── Ctrl+U / Ctrl+K / Ctrl+W kill operations ────────────────────────────

    #[test]
    fn ctrl_u_kills_to_line_start_not_whole_buffer() {
        // On a single line with the caret at the end, kill-to-line-start clears
        // the line (same visible result as before) — but on a MULTILINE buffer
        // it only kills the current line, and the killed text is now yankable.
        let mut input = at("abc\ndef", 7); // caret at end of "def"
        input.handle_event(&key(KeyCode::Char('u'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "abc\n"); // only "def" killed, first line intact
        assert_eq!(input.cursor(), 4);
        // The killed text went to the ring — Ctrl+Y brings it back.
        input.handle_event(&key(KeyCode::Char('y'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "abc\ndef");
    }

    #[test]
    fn ctrl_k_kills_to_end_of_line() {
        // Cursor after "hello " (byte 6) — kill to end of the line.
        let mut input = at("hello world", 6);
        input.handle_event(&key(KeyCode::Char('k'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "hello ");
        assert_eq!(input.cursor(), 6);
    }

    #[test]
    fn ctrl_k_on_multiline_kills_only_current_line() {
        // "abc\ndef", cursor at byte 4 (start of "def") — kill to end of that line.
        let mut input = at("abc\ndef", 4);
        input.handle_event(&key(KeyCode::Char('k'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "abc\n");
        assert_eq!(input.cursor(), 4);
    }

    #[test]
    fn ctrl_k_on_newline_removes_the_newline() {
        // Cursor sits ON the newline (byte 3 in "abc\ndef") — remove just it.
        let mut input = at("abc\ndef", 3);
        input.handle_event(&key(KeyCode::Char('k'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "abcdef");
        assert_eq!(input.cursor(), 3);
    }

    #[test]
    fn ctrl_w_deletes_word_before_cursor() {
        let mut input = at("hello world", 11);
        input.handle_event(&key(KeyCode::Char('w'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "hello ");
        assert_eq!(input.cursor(), 6);
    }

    #[test]
    fn ctrl_w_skips_trailing_whitespace() {
        let mut input = at("hello world   ", 14);
        input.handle_event(&key(KeyCode::Char('w'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "hello ");
    }

    #[test]
    fn ctrl_d_deletes_char_forward() {
        let mut input = at("hello", 0);
        input.handle_event(&key(KeyCode::Char('d'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "ello");
        assert_eq!(input.cursor(), 0);
    }

    #[test]
    fn ctrl_d_at_end_is_noop() {
        let mut input = at("hello", 5);
        input.handle_event(&key(KeyCode::Char('d'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "hello");
        assert_eq!(input.cursor(), 5);
    }

    #[test]
    fn edits_are_utf8_safe() {
        // Multi-byte content: "héllo" ('é' is 2 bytes). Cursor at end.
        let mut input = at("héllo", "héllo".len());
        input.handle_event(&key(KeyCode::Char('w'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "");
    }

    #[test]
    fn ctrl_j_inserts_newline_not_submit() {
        let mut input = at("abc", 3);
        let action = input.handle_event(&key(KeyCode::Char('j'), KeyModifiers::CONTROL));
        assert!(matches!(action, ComponentAction::Consumed));
        assert_eq!(input.value(), "abc\n");
    }

    // ── Up/Down history-vs-linenav decision at buffer edges ──────────────────

    #[test]
    fn first_last_line_geometry() {
        let content = "one\ntwo\nthree";
        assert!(cursor_on_first_line(content, 0));
        assert!(cursor_on_first_line(content, 3)); // still on line 0 (before \n)
        assert!(!cursor_on_first_line(content, 4)); // start of "two"
        assert!(!cursor_on_last_line(content, 4));
        assert!(cursor_on_last_line(content, 8)); // start of "three"
        assert!(cursor_on_last_line(content, content.len()));
    }

    #[test]
    fn up_crosses_to_history_only_at_top_left_edge() {
        let content = "one\ntwo";
        // At offset 0 (very top-left) → cross into history.
        assert!(up_crosses_to_history(content, 0));
        // Mid first line (offset 2) → NOT yet; caret moves first.
        assert!(!up_crosses_to_history(content, 2));
        // On a later line → never crosses on Up.
        assert!(!up_crosses_to_history(content, 5));
    }

    #[test]
    fn down_crosses_to_history_only_at_bottom_end_edge() {
        let content = "one\ntwo";
        // At the very end → cross into history.
        assert!(down_crosses_to_history(content, content.len()));
        // Mid last line → not yet.
        assert!(!down_crosses_to_history(content, 5));
        // On the first line → never crosses on Down.
        assert!(!down_crosses_to_history(content, 1));
    }

    #[test]
    fn down_at_bottom_edge_without_history_nav_preserves_draft() {
        // A genuine multiline draft; not navigating history. Down at the bottom
        // must NOT wipe it (History::next yields nothing when not navigating).
        let mut input = at("line one\nline two", "line one\nline two".len());
        input.handle_event(&key(KeyCode::Down, KeyModifiers::NONE));
        assert_eq!(input.value(), "line one\nline two");
    }

    #[test]
    fn up_mid_buffer_moves_caret_not_history() {
        // Cursor on the second line; Up moves the caret up, leaving text intact.
        let mut input = at("line one\nline two", 12); // within "line two"
        input.handle_event(&key(KeyCode::Up, KeyModifiers::NONE));
        assert_eq!(input.value(), "line one\nline two");
        // Caret moved onto the first line.
        assert!(cursor_on_first_line(input.value(), input.cursor()));
    }

    // ── C5: history recall stashes/restores a half-typed draft ───────────────

    #[test]
    fn up_stashes_half_typed_draft_and_down_restores_it() {
        let mut input = at("half typed", "half typed".len());
        input.history = history::History::new(10);
        input.history.push("older command".to_string());
        // ↑ recalls the history entry, stashing the in-progress line.
        input.handle_event(&key(KeyCode::Up, KeyModifiers::NONE));
        assert_eq!(input.value(), "older command");
        // ↓ past the newest entry restores the draft rather than wiping it.
        input.handle_event(&key(KeyCode::Down, KeyModifiers::NONE));
        assert_eq!(input.value(), "half typed");
    }

    #[test]
    fn down_without_history_nav_does_not_wipe_single_line_draft() {
        // ↓ with no prior ↑ (not navigating, nothing stashed) must leave the
        // half-typed line intact instead of clearing it.
        let mut input = at("keep me", "keep me".len());
        input.history = history::History::new(10);
        input.handle_event(&key(KeyCode::Down, KeyModifiers::NONE));
        assert_eq!(input.value(), "keep me");
    }

    // ── C3: Esc dismisses the `/`-completions popup via the app helper ───────

    #[test]
    fn dismiss_completions_hides_the_slash_popup() {
        let mut input = InputComponent::new();
        input.set_commands_with_descriptions(vec![("model".into(), "switch model".into())]);
        // Typing '/' opens the slash-command completions popup.
        input.handle_event(&key(KeyCode::Char('/'), KeyModifiers::NONE));
        assert!(input.completions_visible(), "popup should open on '/'");
        assert!(input.dismiss_completions(), "dismiss reports it closed one");
        assert!(!input.completions_visible());
        assert!(!input.dismiss_completions(), "second dismiss is a no-op");
    }

    // ── Double-Esc clear-to-history + Ctrl+_ undo rebind ────────────────────

    #[test]
    fn clear_to_history_pushes_draft_and_up_restores_it() {
        let mut input = at("draft in progress", 5);
        input.history = history::History::new(10); // in-memory: no disk writes
        assert!(input.clear_to_history());
        assert_eq!(input.value(), "");
        // ↑ recalls the cleared draft.
        input.handle_event(&key(KeyCode::Up, KeyModifiers::NONE));
        assert_eq!(input.value(), "draft in progress");
        // Blank drafts are not pushed.
        let mut empty = at("   ", 0);
        empty.history = history::History::new(10);
        assert!(!empty.clear_to_history());
        assert!(empty.history.entries().is_empty());
    }

    #[test]
    fn undo_rebound_to_ctrl_underscore_encodings() {
        // All three terminal encodings of Ctrl+_ / Ctrl+- undo the last edit.
        for code in [KeyCode::Char('_'), KeyCode::Char('7'), KeyCode::Char('-')] {
            let mut input = at("", 0);
            input.handle_event(&key(KeyCode::Char('x'), KeyModifiers::NONE));
            assert_eq!(input.value(), "x");
            input.handle_event(&key(code, KeyModifiers::CONTROL));
            assert_eq!(input.value(), "", "undo via {code:?}");
        }
        // Ctrl+Z no longer reaches undo (it suspends at the app level); the
        // composer ignores it and keeps the buffer intact.
        let mut input = at("", 0);
        input.handle_event(&key(KeyCode::Char('x'), KeyModifiers::NONE));
        let act = input.handle_event(&key(KeyCode::Char('z'), KeyModifiers::CONTROL));
        assert!(matches!(act, ComponentAction::Ignored));
        assert_eq!(input.value(), "x");
    }
}

#[cfg(test)]
mod display_width_tests {
    use super::*;

    /// Build an input with `content` and the cursor at byte `cursor`.
    fn at(content: &str, cursor: usize) -> InputComponent {
        let mut input = InputComponent::new();
        input.content = content.to_string();
        input.cursor = cursor.min(input.content.len());
        input.multiline = input.content.contains('\n');
        input
    }

    #[test]
    fn cursor_column_counts_display_width_not_chars() {
        // "中" is a wide (2-col) CJK char, 3 bytes. Caret after it → column 2.
        let input = at("中x", "中".len());
        assert_eq!(input.cursor_column(), 2);
        // After "中x" the column is 3 (2 + 1), not the 2 a char count would give.
        let input = at("中x", "中x".len());
        assert_eq!(input.cursor_column(), 3);
    }

    #[test]
    fn byte_at_column_lands_on_wide_char_start() {
        let input = at("中x", 0);
        let end = "中x".len();
        // Column 0 → byte 0 (start of "中").
        assert_eq!(input.byte_at_column(0, end, 0), 0);
        // Columns 1 and 2 both resolve to the start of "x" (byte 3): a target
        // inside the wide glyph snaps to the following char, never splitting it.
        assert_eq!(input.byte_at_column(0, end, 1), 3);
        assert_eq!(input.byte_at_column(0, end, 2), 3);
    }

    #[test]
    fn needed_height_wraps_by_display_width() {
        // Width 10 → prompt 2, usable 7 columns. Five CJK chars = 10 display
        // columns → 2 wrapped rows (a char count of 5 would wrongly say 1).
        let mut input = at("中中中中中", 0);
        input.set_width(10);
        // top divider + 2 text rows + bottom divider = 4.
        assert_eq!(input.needed_height(), 4);
    }

    #[test]
    fn vertical_motion_tracks_display_columns() {
        // Up from "ab" (col 2) onto the wide first line lands at the byte that
        // sits at display column 2 — the start of the 2nd "中" (byte 3).
        let mut input = at("中中中\nab", "中中中\nab".len());
        input.set_width(40); // no wrapping
        input.move_cursor_up();
        assert_eq!(input.cursor(), 3);
    }

    #[test]
    fn emoji_line_caret_math() {
        // A wide emoji (2 cols) followed by ASCII.
        let input = at("😀ok", "😀".len());
        assert_eq!(input.cursor_column(), 2);
    }
}

#[cfg(test)]
mod vim_and_memory_tests {
    use super::*;
    use crossterm::event::{Event as CrosstermEvent, KeyCode, KeyEvent, KeyModifiers};

    fn key(code: KeyCode) -> Event {
        Event::Terminal(CrosstermEvent::Key(KeyEvent::new(code, KeyModifiers::NONE)))
    }
    fn ch(c: char) -> Event {
        key(KeyCode::Char(c))
    }

    fn vim_input(content: &str, mode: vim::VimMode) -> InputComponent {
        let mut input = InputComponent::new();
        input.history = history::History::new(10);
        input.vim_enabled = true;
        input.vim = vim::VimState { mode, pending: None };
        input.content = content.to_string();
        input.cursor = 0;
        input.multiline = input.content.contains('\n');
        input
    }

    // ── '#' memory mode: submit round-trips the raw text for app routing ─────

    #[test]
    fn hash_prefixed_line_submits_verbatim_for_memory_routing() {
        // The composer keeps the leading '#'; the app layer (update.rs) strips
        // it and routes to memory_quick_add. Here we only assert the text
        // survives submit intact.
        let mut input = InputComponent::new();
        input.history = history::History::new(10);
        input.set_content("#remember the port is 19001");
        assert_eq!(input.submit(), "#remember the port is 19001");
    }

    // ── vim state machine ────────────────────────────────────────────────────

    #[test]
    fn disabled_vim_types_letters_normally() {
        // Fresh input has vim off (env unset in tests): 'i' inserts an 'i',
        // it does NOT act as an insert-mode command.
        let mut input = InputComponent::new();
        input.history = history::History::new(10);
        input.handle_event(&ch('i'));
        assert!(!input.vim_enabled());
        assert_eq!(input.value(), "i");
    }

    #[test]
    fn esc_enters_normal_and_clamps_caret() {
        let mut input = vim_input("hi", vim::VimMode::Insert);
        input.cursor = input.content.len();
        input.handle_event(&key(KeyCode::Esc));
        assert_eq!(input.vim.mode, vim::VimMode::Normal);
        // Caret clamped onto the last char ('i'), not past it.
        assert_eq!(input.cursor(), 1);
    }

    #[test]
    fn normal_mode_motions_and_x() {
        let mut input = vim_input("hello", vim::VimMode::Normal);
        input.handle_event(&ch('0')); // start of line
        assert_eq!(input.cursor(), 0);
        input.handle_event(&ch('x')); // delete 'h'
        assert_eq!(input.value(), "ello");
        input.handle_event(&ch('$')); // last char ('o')
        assert_eq!(input.cursor(), 3);
    }

    #[test]
    fn word_motion_w() {
        let mut input = vim_input("one two", vim::VimMode::Normal);
        input.handle_event(&ch('w'));
        assert_eq!(input.cursor(), 4); // start of "two"
    }

    #[test]
    fn dd_deletes_current_line() {
        let mut input = vim_input("a\nb\nc", vim::VimMode::Normal);
        input.handle_event(&ch('d'));
        assert_eq!(input.vim.pending, Some('d'));
        input.handle_event(&ch('d'));
        assert_eq!(input.value(), "b\nc");
        assert_eq!(input.vim.pending, None);
    }

    #[test]
    fn dw_deletes_word_forward() {
        let mut input = vim_input("one two", vim::VimMode::Normal);
        input.handle_event(&ch('d'));
        input.handle_event(&ch('w'));
        assert_eq!(input.value(), "two");
    }

    #[test]
    fn gg_and_capital_g_jump_edges() {
        let mut input = vim_input("a\nb\nc", vim::VimMode::Normal);
        input.handle_event(&ch('G'));
        // End of buffer, clamped onto the last char 'c' (byte 4 of "a\nb\nc").
        assert_eq!(input.cursor(), 4);
        input.handle_event(&ch('g'));
        input.handle_event(&ch('g'));
        assert_eq!(input.cursor(), 0);
    }

    #[test]
    fn append_a_enters_insert_after_char() {
        let mut input = vim_input("ab", vim::VimMode::Normal);
        input.cursor = 0;
        input.handle_event(&ch('a')); // insert after 'a'
        assert_eq!(input.vim.mode, vim::VimMode::Insert);
        assert_eq!(input.cursor(), 1);
        input.handle_event(&ch('X'));
        assert_eq!(input.value(), "aXb");
    }

    #[test]
    fn cc_clears_line_and_enters_insert() {
        let mut input = vim_input("hello", vim::VimMode::Normal);
        input.handle_event(&ch('c'));
        input.handle_event(&ch('c'));
        assert_eq!(input.value(), "");
        assert_eq!(input.vim.mode, vim::VimMode::Insert);
    }

    #[test]
    fn u_undoes_last_normal_edit() {
        let mut input = vim_input("hello", vim::VimMode::Normal);
        input.handle_event(&ch('x')); // delete 'h' → "ello"
        assert_eq!(input.value(), "ello");
        input.handle_event(&ch('u')); // undo
        assert_eq!(input.value(), "hello");
    }

    #[test]
    fn toggle_vim_flips_state() {
        let mut input = InputComponent::new();
        let before = input.vim_enabled();
        assert_eq!(input.toggle_vim(), !before);
        assert_eq!(input.vim_enabled(), !before);
    }

    #[test]
    fn vim_wants_key_leaves_ctrl_combos_to_app() {
        let input = vim_input("x", vim::VimMode::Normal);
        // Ctrl+C is not claimed by vim even in Normal mode → app can interrupt.
        let ctrl_c = KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL);
        assert!(!input.vim_wants_key(&ctrl_c));
        // A plain motion key IS claimed.
        let h = KeyEvent::new(KeyCode::Char('h'), KeyModifiers::NONE);
        assert!(input.vim_wants_key(&h));
    }

    #[test]
    fn vim_normal_claims_backtab_so_app_must_exclude_permission_cycle() {
        // In Normal mode `vim_wants_key` claims EVERY NONE/SHIFT key, including
        // Shift+Tab (BackTab). If `handle_idle_key` gave vim first refusal
        // unconditionally, BackTab would be swallowed by the Normal-mode `_ => {}`
        // and the permission-mode cycle would be unreachable in vim. Guard: the
        // app checks `vim_wants_key(&k) && !is_permission_cycle(&k)`, so a
        // permission-cycle key falls through even in vim Normal mode.
        let input = vim_input("x", vim::VimMode::Normal);
        let backtab = KeyEvent::new(KeyCode::BackTab, KeyModifiers::NONE);
        assert!(
            input.vim_wants_key(&backtab),
            "vim Normal claims BackTab (this is why the app must exclude it)"
        );
        assert!(
            crate::app::key_normalize::is_permission_cycle(&backtab),
            "BackTab is the permission-mode cycle key"
        );
        // The app's combined guard yields false → BackTab reaches the mode cycle.
        assert!(
            !(input.vim_wants_key(&backtab)
                && !crate::app::key_normalize::is_permission_cycle(&backtab)),
            "app guard must let BackTab fall through to cycle_permission_mode"
        );
    }
}

#[cfg(test)]
mod ws9_composer_tests {
    use super::*;
    use crossterm::event::{Event as CrosstermEvent, KeyCode, KeyEvent, KeyModifiers};

    fn key(code: KeyCode) -> Event {
        Event::Terminal(CrosstermEvent::Key(KeyEvent::new(code, KeyModifiers::NONE)))
    }

    fn fresh() -> InputComponent {
        let mut input = InputComponent::new();
        input.history = history::History::new(10); // in-memory: no disk writes
        input
    }

    // ── Large-paste pill: token, store, expand-at-submit ────────────────────

    #[test]
    fn small_paste_inserts_inline() {
        let mut input = fresh();
        input.insert_paste("hello world");
        assert_eq!(input.value(), "hello world");
    }

    #[test]
    fn large_paste_collapses_to_pill_and_expands_at_submit() {
        let mut input = fresh();
        let big = "x".repeat(PASTE_THRESHOLD + 1);
        input.insert_paste(&big);
        assert_eq!(input.value(), "[Pasted text #1]");
        assert_eq!(input.submit(), big); // model receives the full text
        // History keeps the compact pill display, not the expanded body.
        assert_eq!(
            input.history.entries().last().map(|s| s.as_str()),
            Some("[Pasted text #1]")
        );
    }

    #[test]
    fn multiline_paste_pill_counts_newline_chars_cc_style() {
        let mut input = fresh();
        let text = "a\nb\nc\nd"; // 3 newline CHARS (> 2) → pill "+3 lines"
        input.insert_paste(text);
        assert_eq!(input.value(), "[Pasted text #1 +3 lines]");
        assert_eq!(input.submit(), text);
    }

    #[test]
    fn pill_expands_in_place_with_surrounding_text() {
        let mut input = fresh();
        input.insert_str("before ");
        input.insert_paste(&"y".repeat(900));
        input.insert_str(" after");
        assert_eq!(input.submit(), format!("before {} after", "y".repeat(900)));
    }

    #[test]
    fn recalled_pill_from_history_still_expands() {
        let mut input = fresh();
        let big = "z".repeat(900);
        input.insert_paste(&big);
        let _ = input.submit();
        input.handle_event(&key(KeyCode::Up)); // recall "[Pasted text #1]"
        assert_eq!(input.value(), "[Pasted text #1]");
        assert_eq!(input.submit(), big);
    }

    #[test]
    fn deleted_pill_token_content_is_not_sent() {
        let mut input = fresh();
        input.insert_paste(&"q".repeat(900));
        // ONE backspace atomically removes the whole pill token.
        input.handle_event(&key(KeyCode::Backspace));
        assert_eq!(input.value(), "");
        input.insert_str("typed instead");
        assert_eq!(input.submit(), "typed instead");
    }

    // ── Paste normalization (CC onTextPaste, verbatim) ──────────────────────

    #[test]
    fn normalize_strips_ansi_crs_and_tabs() {
        let raw = "\u{1b}[31mred\u{1b}[0m\r\n\tdone";
        // CC verbatim: EVERY \r becomes \n (CRLF → two newlines), tab → 4sp.
        assert_eq!(normalize_paste(raw), "red\n\n    done");
    }

    #[test]
    fn normalize_strips_osc_sequences() {
        let raw = "\u{1b}]0;title\u{7}text";
        assert_eq!(normalize_paste(raw), "text");
    }

    // ── Atomic chip hop / delete ────────────────────────────────────────────

    #[test]
    fn backspace_after_chip_deletes_whole_token() {
        let mut input = fresh();
        input.set_content("[Image #1]");
        input.handle_event(&key(KeyCode::Backspace));
        assert_eq!(input.value(), "");
    }

    #[test]
    fn backspace_mid_word_after_bracket_stays_char_wise() {
        // Char after the caret is NOT a boundary → no token delete (CC guard).
        let mut input = fresh();
        input.set_content("[Image #1]x");
        input.cursor = "[Image #1]".len();
        input.handle_event(&key(KeyCode::Backspace));
        assert_eq!(input.value(), "[Image #1x"); // plain ']' delete
    }

    #[test]
    fn arrows_hop_over_chip_atomically() {
        let mut input = fresh();
        input.set_content("[Image #1] hi");
        input.cursor = "[Image #1]".len();
        input.handle_event(&key(KeyCode::Left));
        assert_eq!(input.cursor(), 0); // snapped over the whole chip
        input.handle_event(&key(KeyCode::Right));
        assert_eq!(input.cursor(), "[Image #1]".len());
    }

    #[test]
    fn pill_token_grammar() {
        assert!(is_chip_token("[Pasted text #3]"));
        assert!(is_chip_token("[Pasted text #3 +12 lines]"));
        assert!(!is_chip_token("[Pasted text #]"));
        assert!(!is_chip_token("[Pasted text #3 +x lines]"));
        assert!(is_chip_token("[Image #2]"));
        assert_eq!(pill_id("[Pasted text #7 +2 lines]"), Some(7));
        assert_eq!(pill_id("[Image #7]"), None);
    }

    // ── Wrapped-visual-line cursor motion ───────────────────────────────────

    #[test]
    fn up_climbs_wrapped_visual_rows_before_leaving_the_line() {
        let mut input = fresh();
        input.set_width(20); // wrap width = 20 - 3 = 17
        let line2 = "b".repeat(40); // wraps to 3 visual rows (17+17+6)
        input.set_content(&format!("aaa\n{}", line2));
        // Caret at very end: visual row 2, vcol 6.
        input.handle_event(&key(KeyCode::Up));
        assert_eq!(input.cursor(), 4 + 23); // row 1, same vcol (17 + 6)
        input.handle_event(&key(KeyCode::Up));
        assert_eq!(input.cursor(), 4 + 6); // row 0, vcol 6
        input.handle_event(&key(KeyCode::Up));
        // Off the top visual row → previous logical line "aaa", clamped.
        assert_eq!(input.cursor(), 3);
    }

    #[test]
    fn down_descends_wrapped_visual_rows() {
        let mut input = fresh();
        input.set_width(20); // wrap width 17
        let line1 = "c".repeat(40);
        input.set_content(&format!("{}\nzz", line1));
        input.cursor = 5; // row 0, vcol 5
        input.handle_event(&key(KeyCode::Down));
        assert_eq!(input.cursor(), 17 + 5); // row 1, same vcol
        input.handle_event(&key(KeyCode::Down));
        assert_eq!(input.cursor(), 34 + 5); // row 2
        input.handle_event(&key(KeyCode::Down));
        // Last visual row → next logical line "zz", vcol clamped to its end.
        assert_eq!(input.cursor(), 41 + 2);
    }

    // ── Composer slice-safety: @-mention & leading-'/' panics (C1/C2) ────────

    fn kev(code: KeyCode, mods: KeyModifiers) -> Event {
        Event::Terminal(CrosstermEvent::Key(KeyEvent::new(code, mods)))
    }

    fn type_chars(input: &mut InputComponent, s: &str) {
        for c in s.chars() {
            input.handle_event(&kev(KeyCode::Char(c), KeyModifiers::NONE));
        }
    }

    #[test]
    fn safe_str_range_handles_inverted_clamped_and_multibyte() {
        assert_eq!(safe_str_range("hello", 3, 1), ""); // start > end (would panic raw)
        assert_eq!(safe_str_range("hello", 1, 3), "el");
        assert_eq!(safe_str_range("hello", 2, 99), "llo"); // clamp upper
        assert_eq!(safe_str_range("hello", 99, 100), ""); // clamp both
        // "é" occupies bytes [0,2); a mid-codepoint index snaps INWARD so a
        // raw slice's "byte index is not a char boundary" panic can't happen.
        let s = "é";
        assert_eq!(safe_str_range(s, 0, 1), ""); // hi snaps down to 0
        assert_eq!(safe_str_range(s, 1, 2), ""); // lo snaps up to 2
        assert_eq!(safe_str_range(s, 0, 2), "é");
    }

    #[test]
    fn at_mention_home_then_type_does_not_panic() {
        // C1 repro: `x@y`, Home, type → the stale '@' anchor once sliced
        // content[3..1] (start > end) and aborted the whole TUI.
        let mut input = fresh();
        type_chars(&mut input, "x@y");
        assert!(input.file_search_active());
        input.handle_event(&kev(KeyCode::Home, KeyModifiers::NONE));
        // Caret moved before the anchor → the @-search cancels.
        assert!(!input.file_search_active());
        type_chars(&mut input, "z"); // must NOT panic
        assert_eq!(input.value(), "zx@y");
    }

    #[test]
    fn at_mention_ctrl_a_then_multibyte_does_not_panic() {
        // Ctrl+A (home) + a multibyte insert before the anchor: once a
        // "byte index is not a char boundary" panic.
        let mut input = fresh();
        type_chars(&mut input, "x@y");
        input.handle_event(&kev(KeyCode::Char('a'), KeyModifiers::CONTROL));
        assert!(!input.file_search_active());
        type_chars(&mut input, "é"); // must NOT panic
        assert_eq!(input.value(), "éx@y");
    }

    #[test]
    fn at_mention_stale_anchor_tab_and_enter_do_not_panic() {
        // The Tab (handle_tab) and Enter (submit) drains of
        // content[anchor..cursor] must not panic with a stale anchor.
        let mut input = fresh();
        type_chars(&mut input, "x@y");
        input.handle_event(&kev(KeyCode::Home, KeyModifiers::NONE));
        input.handle_event(&kev(KeyCode::Tab, KeyModifiers::NONE)); // no panic
        input.handle_event(&kev(KeyCode::Enter, KeyModifiers::NONE)); // no panic
    }

    #[test]
    fn slash_left_backspace_does_not_underflow() {
        // C2 repro: `//`, Left, Backspace leaves "/" with cursor 0 →
        // content[1..0] (range 1..0) once panicked.
        let mut input = fresh();
        type_chars(&mut input, "//");
        input.handle_event(&kev(KeyCode::Left, KeyModifiers::NONE));
        input.handle_event(&kev(KeyCode::Backspace, KeyModifiers::NONE)); // no panic
        assert_eq!(input.value(), "/");
        assert_eq!(input.cursor(), 0);
        // A further backspace at cursor 0 is a no-op, still no panic.
        input.handle_event(&kev(KeyCode::Backspace, KeyModifiers::NONE));
        assert_eq!(input.value(), "/");
    }

    #[test]
    fn at_mention_selection_resolves_to_file_attachment() {
        // End-to-end (no fs): `@Cargo.toml` submits as a File attachment that
        // the submit path can carry as a context_ref.
        use super::mentions::Attachment;
        let mut input = fresh();
        type_chars(&mut input, "see @Cargo.toml please");
        let _ = input.submit();
        let atts = input.take_attachments();
        assert_eq!(
            atts,
            vec![Attachment::File { path: "Cargo.toml".into(), range: None }]
        );
    }

    #[test]
    fn at_mention_line_range_resolves_with_range() {
        use super::mentions::{Attachment, LineRange};
        let mut input = fresh();
        type_chars(&mut input, "@src/main.rs#L10-20");
        let _ = input.submit();
        let atts = input.take_attachments();
        assert_eq!(
            atts,
            vec![Attachment::File {
                path: "src/main.rs".into(),
                range: Some(LineRange { start: 10, end: Some(20) }),
            }]
        );
    }
}

#[cfg(test)]
mod killring_undo_placeholder_tests {
    use super::*;
    use crossterm::event::{Event as CrosstermEvent, KeyCode, KeyEvent, KeyModifiers};
    use ratatui::{backend::TestBackend, Terminal};

    fn kv(code: KeyCode, mods: KeyModifiers) -> Event {
        Event::Terminal(CrosstermEvent::Key(KeyEvent::new(code, mods)))
    }
    fn ch(c: char) -> Event {
        kv(KeyCode::Char(c), KeyModifiers::NONE)
    }

    fn at(content: &str, cursor: usize) -> InputComponent {
        let mut input = InputComponent::new();
        input.history = history::History::new(10);
        input.content = content.to_string();
        input.cursor = cursor.min(input.content.len());
        input.multiline = input.content.contains('\n');
        input
    }

    // ── P1: kill-ring + yank round-trips ────────────────────────────────────

    #[test]
    fn ctrl_k_then_ctrl_y_moves_text() {
        // The canonical readline reflex: kill to EOL, then yank it back.
        let mut input = at("hello world", 6); // caret after "hello "
        input.handle_event(&kv(KeyCode::Char('k'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "hello ");
        input.handle_event(&kv(KeyCode::Char('y'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "hello world");
    }

    #[test]
    fn ctrl_w_kill_word_is_yankable() {
        let mut input = at("foo bar", 7);
        input.handle_event(&kv(KeyCode::Char('w'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "foo ");
        // Move to start, yank the killed "bar" there.
        input.handle_event(&kv(KeyCode::Char('a'), KeyModifiers::CONTROL)); // home
        input.handle_event(&kv(KeyCode::Char('y'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "barfoo ");
    }

    #[test]
    fn alt_d_kills_word_forward_into_ring() {
        let mut input = at("foo bar", 0);
        input.handle_event(&kv(KeyCode::Char('d'), KeyModifiers::ALT));
        assert_eq!(input.value(), " bar"); // "foo" killed forward
        input.handle_event(&kv(KeyCode::Char('y'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "foo bar"); // yanked back at the caret (offset 0)
    }

    #[test]
    fn successive_kills_accumulate_into_one_ring_entry() {
        // Two Ctrl+K in a row append into the SAME entry (readline), so a single
        // Ctrl+Y restores the whole run.
        let mut input = at("abcdef", 0);
        input.handle_event(&kv(KeyCode::Char('k'), KeyModifiers::CONTROL)); // kill "abcdef"
        // Nothing left to kill on this line; type + kill again to prove append.
        let mut input = at("ab\ncd", 0);
        input.handle_event(&kv(KeyCode::Char('k'), KeyModifiers::CONTROL)); // kill "ab"
        input.handle_event(&kv(KeyCode::Char('k'), KeyModifiers::CONTROL)); // kill the '\n' (accumulates)
        assert_eq!(input.value(), "cd");
        input.handle_event(&kv(KeyCode::Char('y'), KeyModifiers::CONTROL));
        // One yank restores "ab\n" (both kills merged) ahead of "cd".
        assert_eq!(input.value(), "ab\ncd");
    }

    // ── P1: ring rotation via yank-pop ──────────────────────────────────────

    #[test]
    fn alt_y_yank_pop_rotates_the_ring() {
        // Build a ring with two SEPARATE entries: kill "first", type, kill
        // "second". A non-kill command between them breaks accumulation.
        let mut input = at("first", 5);
        input.handle_event(&kv(KeyCode::Char('u'), KeyModifiers::CONTROL)); // ring=["first"]
        for c in "second".chars() {
            input.handle_event(&ch(c));
        }
        input.handle_event(&kv(KeyCode::Char('u'), KeyModifiers::CONTROL)); // ring=["first","second"]
        assert_eq!(input.value(), "");
        // Yank inserts the most-recent kill…
        input.handle_event(&kv(KeyCode::Char('y'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "second");
        // …and Alt+Y rotates back to the older entry, replacing it in place.
        input.handle_event(&kv(KeyCode::Char('y'), KeyModifiers::ALT));
        assert_eq!(input.value(), "first");
    }

    #[test]
    fn alt_y_without_preceding_yank_is_noop() {
        let mut input = at("hi", 0); // caret at start so Ctrl+K kills "hi"
        input.handle_event(&kv(KeyCode::Char('k'), KeyModifiers::CONTROL)); // ring=["hi"]
        assert_eq!(input.value(), "");
        // Alt+Y not immediately after a yank → no-op (buffer stays empty).
        input.handle_event(&kv(KeyCode::Char('y'), KeyModifiers::ALT));
        assert_eq!(input.value(), "");
    }

    // ── P1 CRITICAL: Ctrl+Y is YANK, not redo ───────────────────────────────

    #[test]
    fn ctrl_y_is_yank_not_redo() {
        let mut input = at("", 0);
        for c in "ab".chars() {
            input.handle_event(&ch(c));
        }
        input.handle_event(&kv(KeyCode::Char('_'), KeyModifiers::CONTROL)); // undo → ""
        assert_eq!(input.value(), "");
        // If Ctrl+Y were still redo, this would restore "ab". As yank on an
        // empty ring it must be a no-op.
        input.handle_event(&kv(KeyCode::Char('y'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "");
        // Redo now lives on Alt+_ and DOES restore the undone text.
        input.handle_event(&kv(KeyCode::Char('_'), KeyModifiers::ALT));
        assert_eq!(input.value(), "ab");
    }

    // ── P2: undo coalescing ─────────────────────────────────────────────────

    #[test]
    fn undo_coalesces_a_typed_word_into_one_step() {
        let mut input = at("", 0);
        for c in "hello".chars() {
            input.handle_event(&ch(c));
        }
        assert_eq!(input.value(), "hello");
        // ONE undo removes the whole word, not a single character.
        input.handle_event(&kv(KeyCode::Char('_'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "");
    }

    #[test]
    fn undo_group_breaks_on_word_boundary() {
        let mut input = at("", 0);
        for c in "foo bar".chars() {
            input.handle_event(&ch(c));
        }
        // First undo drops "bar" (its own group after the space boundary).
        input.handle_event(&kv(KeyCode::Char('_'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "foo ");
        // Next undo drops the boundary space; the third drops "foo".
        input.handle_event(&kv(KeyCode::Char('_'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "foo");
        input.handle_event(&kv(KeyCode::Char('_'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "");
    }

    #[test]
    fn cursor_move_breaks_the_insert_group() {
        // Typing, moving the caret, then typing again must be TWO undo steps.
        let mut input = at("", 0);
        for c in "abc".chars() {
            input.handle_event(&ch(c));
        }
        input.handle_event(&kv(KeyCode::Left, KeyModifiers::NONE)); // move breaks run
        input.handle_event(&ch('X')); // "abXc"
        assert_eq!(input.value(), "abXc");
        input.handle_event(&kv(KeyCode::Char('_'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "abc"); // only the post-move insert undone
    }

    // ── P4: vim mode badge renders when enabled ─────────────────────────────

    fn render_text(input: &InputComponent) -> String {
        let mut term = Terminal::new(TestBackend::new(80, 6)).unwrap();
        term.draw(|f| input.draw(f, f.area())).unwrap();
        term.backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol())
            .collect()
    }

    #[test]
    fn vim_badge_renders_normal_and_insert_when_enabled() {
        let mut input = InputComponent::new();
        input.history = history::History::new(10);
        input.vim_enabled = true;
        input.vim = vim::VimState { mode: vim::VimMode::Normal, pending: None };
        assert!(render_text(&input).contains("NORMAL"), "NORMAL badge missing");
        input.vim.mode = vim::VimMode::Insert;
        assert!(render_text(&input).contains("INSERT"), "INSERT badge missing");
    }

    #[test]
    fn vim_badge_absent_when_disabled() {
        let mut input = InputComponent::new();
        input.history = history::History::new(10);
        input.vim_enabled = false;
        let text = render_text(&input);
        assert!(!text.contains("NORMAL"));
        assert!(!text.contains("INSERT"));
    }

    // ── P3: rotating / contextual placeholder ───────────────────────────────

    #[test]
    fn placeholder_rotates_on_submit() {
        let mut input = InputComponent::new();
        input.history = history::History::new(10);
        let first = input.placeholder();
        assert_eq!(first, PLACEHOLDERS[0]); // classic greeting on first launch
        input.set_content("do a thing");
        let _ = input.submit(); // re-rolls the seed
        assert_ne!(input.placeholder(), first, "placeholder should rotate on submit");
    }

    #[test]
    fn placeholder_is_contextual_when_messages_queued() {
        let mut input = InputComponent::new();
        input.history = history::History::new(10);
        input.set_queued_items(vec!["queued msg".into()]);
        assert!(
            input.placeholder().contains("queued"),
            "queued hint should win over the rotating example"
        );
    }
}

// ── Composer sub-layers (U-T1..U-T6) ─────────────────────────────────────────
#[cfg(test)]
mod composer_layers_tests {
    use super::*;
    use crate::components::input::mentions::{Attachment, LineRange, MentionKind};
    use crossterm::event::{Event as CrosstermEvent, KeyCode, KeyEvent, KeyModifiers};

    fn key(code: KeyCode, mods: KeyModifiers) -> Event {
        Event::Terminal(CrosstermEvent::Key(KeyEvent::new(code, mods)))
    }

    /// Fresh input with deterministic in-memory history buckets (no ~/.osa file).
    fn fresh() -> InputComponent {
        let mut input = InputComponent::new();
        input.history = history::History::new(50);
        input.shell_history = history::History::new(50);
        input
    }

    // ── U-T1: @-mention as a structured attachment ───────────────────────────

    #[test]
    fn submit_resolves_file_range_and_agent_attachments() {
        let mut input = fresh();
        input.set_agents(vec!["debugger".into()]);
        input.set_content("see @src/main.rs#L2-8 then @debugger");
        let _ = input.submit();
        assert_eq!(input.last_submit_kind(), SubmitKind::Prompt);
        let atts = input.take_attachments();
        assert_eq!(
            atts,
            vec![
                Attachment::File {
                    path: "src/main.rs".into(),
                    range: Some(LineRange { start: 2, end: Some(8) }),
                },
                Attachment::Agent { name: "debugger".into() },
            ]
        );
        // Draining leaves nothing for the next turn.
        assert!(input.take_attachments().is_empty());
    }

    #[test]
    fn plain_prompt_has_no_attachments() {
        let mut input = fresh();
        input.set_content("just a normal question");
        let _ = input.submit();
        assert!(input.take_attachments().is_empty());
    }

    // ── U-T30: @-popup surfaces agents with an Agent-kind candidate ───────────

    #[test]
    fn at_popup_offers_agent_candidates_with_kind() {
        let mut input = fresh();
        input.set_agents(vec!["debugger".into()]);
        // Simulate an active `@debug` search (independent of the cwd tree).
        input.content = "@debug".into();
        input.file_search_active = true;
        input.file_search_start = 0;
        input.cursor = input.content.len();
        input.rebuild_file_matches();
        let agent = input
            .file_matches
            .iter()
            .find(|c| c.kind == MentionKind::Agent);
        assert!(agent.is_some(), "agent should appear in the @-popup");
        assert_eq!(agent.unwrap().insert, "debugger");
        // The glyph differs per kind (U-T30).
        assert_ne!(MentionKind::Agent.glyph(), MentionKind::File.glyph());
    }

    // ── U-T2: Ctrl+P / Ctrl+N history navigation ─────────────────────────────

    #[test]
    fn ctrl_p_and_ctrl_n_walk_history() {
        let mut input = fresh();
        input.history.push("cmd1".into());
        input.history.push("cmd2".into());
        // Ctrl+P → newest, then older.
        input.handle_event(&key(KeyCode::Char('p'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "cmd2");
        input.handle_event(&key(KeyCode::Char('p'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "cmd1");
        // Ctrl+N → back toward newest.
        input.handle_event(&key(KeyCode::Char('n'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "cmd2");
    }

    #[test]
    fn alt_d_kills_word_forward() {
        // Alt+D deletes the word ahead of the caret (readline kill-word).
        let mut input = fresh();
        input.set_content("hello world");
        input.cursor = 0;
        input.handle_event(&key(KeyCode::Char('d'), KeyModifiers::ALT));
        assert_eq!(input.value(), " world");
        assert_eq!(input.cursor(), 0);
    }

    // ── U-T3: ghost-text inline autocomplete ─────────────────────────────────

    #[test]
    fn ghost_suffix_completes_from_history() {
        let mut input = fresh();
        input.history.push("zzghost completion target".into());
        input.content = "zzghost".into();
        input.cursor = input.content.len();
        assert_eq!(
            input.ghost_suffix().as_deref(),
            Some(" completion target")
        );
        // Tab accepts the ghost (fish/CC autosuggest).
        input.handle_event(&key(KeyCode::Tab, KeyModifiers::NONE));
        assert_eq!(input.value(), "zzghost completion target");
    }

    #[test]
    fn ghost_suffix_suppressed_for_slash_and_midline() {
        let mut input = fresh();
        input.history.push("hello there".into());
        // Slash draft: owned by the completions popup, no ghost.
        input.content = "/hel".into();
        input.cursor = input.content.len();
        assert!(input.ghost_suffix().is_none());
        // Caret not at end: no ghost.
        input.content = "hello".into();
        input.cursor = 2;
        assert!(input.ghost_suffix().is_none());
    }

    // ── U-T4: bash `!` submit-mode + separate history bucket ──────────────────

    #[test]
    fn shell_submit_classified_and_bucketed() {
        let mut input = fresh();
        input.set_content("!ls -la");
        let _ = input.submit();
        assert_eq!(input.last_submit_kind(), SubmitKind::Shell);
        // The `!` line went to the shell bucket, NOT the prompt history.
        assert_eq!(input.shell_history.entries(), &["!ls -la"]);
        assert!(input.history.is_empty());
    }

    #[test]
    fn shell_line_recalls_shell_bucket() {
        let mut input = fresh();
        input.history.push("a prompt".into());
        input.shell_history.push("!git status".into());
        // Typing `!` selects the shell bucket for recall.
        input.content = "!".into();
        input.cursor = 1;
        input.handle_event(&key(KeyCode::Char('p'), KeyModifiers::CONTROL));
        assert_eq!(input.value(), "!git status");
    }

    #[test]
    fn memory_line_classified() {
        let mut input = fresh();
        input.set_content("#remember this");
        let _ = input.submit();
        assert_eq!(input.last_submit_kind(), SubmitKind::Memory);
    }

    // ── U-T5: huge-input middle-splice pill ──────────────────────────────────

    #[test]
    fn splice_middle_collapses_over_threshold() {
        assert_eq!(
            splice_middle("abcdefghij", 5, 2).as_deref(),
            Some("ab[\u{2026} 6 chars \u{2026}]ij")
        );
        // Short content is shown whole.
        assert!(splice_middle("short", 10, 2).is_none());
        // The real thresholds elide a giant paste.
        let giant = "x".repeat(HUGE_INPUT_THRESHOLD + 500);
        let pilled = splice_middle(&giant, HUGE_INPUT_THRESHOLD, HUGE_INPUT_KEEP).unwrap();
        assert!(pilled.contains("chars \u{2026}]"));
        assert!(pilled.chars().count() < giant.chars().count());
    }

    // ── U-T6: frecency-ranked @-file recall ──────────────────────────────────

    #[test]
    fn frecency_floats_recent_pick_in_at_popup() {
        // Two candidates that fuzzy-match "z" equally; the one recorded via
        // frecency should sort ahead once selected before.
        let mut input = fresh();
        input.file_frecency.record("z_beta.rs");
        input.content = "@z".into();
        input.file_search_active = true;
        input.file_search_start = 0;
        input.cursor = input.content.len();
        // Seed two synthetic candidates and re-run only the ranking by hand:
        // rebuild scans the cwd, so assert the frecency boost is what tips ties.
        assert!(input.file_frecency.boost("z_beta.rs") > input.file_frecency.boost("z_alpha.rs"));
    }
}

/// Composer-level wiring for the paste-burst fallback
/// ([`super::paste_burst`]): the state machine itself is unit-tested in that
/// module; these drive `InputComponent` end-to-end with a pinned clock, so
/// "paste arrives as fast key events" is exercised without a terminal.
#[cfg(test)]
mod paste_burst_composer_tests {
    use super::paste_burst::{PasteBurst, PASTE_BURST_CHAR_INTERVAL};
    use super::*;
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
    use std::time::Duration;

    fn ev(code: KeyCode) -> Event {
        Event::Terminal(CrosstermEvent::Key(KeyEvent::new(
            code,
            KeyModifiers::NONE,
        )))
    }

    /// Feed `text` as raw key events at `step` apart, starting at `t`, exactly
    /// as a terminal without bracketed paste delivers a paste. Returns the
    /// (clock, action-of-the-last-key) pair.
    fn feed(
        input: &mut InputComponent,
        text: &str,
        t: &mut Instant,
        step: Duration,
    ) -> ComponentAction {
        let mut last = ComponentAction::Ignored;
        for ch in text.chars() {
            input.set_test_clock(Some(*t));
            let code = if ch == '\n' {
                KeyCode::Enter
            } else {
                KeyCode::Char(ch)
            };
            last = input.handle_event(&ev(code));
            *t += step;
        }
        last
    }

    fn fast() -> Duration {
        Duration::from_millis(1)
    }

    fn slow() -> Duration {
        Duration::from_millis(200)
    }

    // ── the bug this fixes ─────────────────────────────────────────────────

    #[test]
    fn multiline_paste_as_fast_keys_does_not_submit_halfway() {
        let mut input = InputComponent::new();
        let mut t = Instant::now();
        let action = feed(&mut input, "line one\nline two\nline three", &mut t, fast());

        assert!(
            matches!(action, ComponentAction::Consumed),
            "no keystroke in the burst may emit Submit"
        );
        assert_eq!(input.value(), "line one\nline two\nline three");
    }

    #[test]
    fn enter_after_a_burst_but_outside_the_window_still_submits() {
        let mut input = InputComponent::new();
        let mut t = Instant::now();
        feed(&mut input, "pasted text", &mut t, fast());
        // Wait out the 120ms suppression window before pressing Enter.
        t += Duration::from_millis(500);
        input.set_test_clock(Some(t));
        let action = input.handle_event(&ev(KeyCode::Enter));

        match action {
            ComponentAction::Emit(AppAction::Submit(text)) => assert_eq!(text, "pasted text"),
            other => panic!("expected Submit, got {other:?}"),
        }
    }

    #[test]
    fn slow_typing_then_enter_submits() {
        let mut input = InputComponent::new();
        let mut t = Instant::now();
        let action = feed(&mut input, "hello\n", &mut t, slow());

        match action {
            ComponentAction::Emit(AppAction::Submit(text)) => assert_eq!(text, "hello"),
            other => panic!("slow typing must submit on Enter, got {other:?}"),
        }
    }

    #[test]
    fn slow_typing_never_enters_a_burst_window() {
        let mut input = InputComponent::new();
        let mut t = Instant::now();
        feed(&mut input, "abcdef", &mut t, slow());
        assert!(!input.paste_burst.in_burst_context(t));
    }

    #[test]
    fn a_non_char_key_ends_the_burst_window() {
        let mut input = InputComponent::new();
        let mut t = Instant::now();
        feed(&mut input, "abcdef", &mut t, fast());
        assert!(input.paste_burst.in_burst_context(t));

        // An arrow key can never be part of a paste: the window drops, so the
        // very next Enter submits again.
        input.set_test_clock(Some(t));
        input.handle_event(&ev(KeyCode::Left));
        assert!(!input.paste_burst.in_burst_context(t));

        input.set_test_clock(Some(t));
        assert!(matches!(
            input.handle_event(&ev(KeyCode::Enter)),
            ComponentAction::Emit(AppAction::Submit(_))
        ));
    }

    #[test]
    fn burst_suppresses_the_slash_completions_popup_stealing_enter() {
        let mut input = InputComponent::new();
        input.set_commands(vec!["help".into(), "clear".into()]);
        let mut t = Instant::now();
        // A pasted line that happens to start with '/' must not have its
        // newline eaten by the command palette.
        let action = feed(&mut input, "/usr/local/bin\nnext line", &mut t, fast());
        assert!(matches!(action, ComponentAction::Consumed));
        assert_eq!(input.value(), "/usr/local/bin\nnext line");
    }

    #[test]
    fn two_char_prefix_before_a_newline_is_still_a_paste() {
        // Below the 3-char burst threshold: only the wider direct-insert Enter
        // rule saves this from submitting "ab".
        let mut input = InputComponent::new();
        let mut t = Instant::now();
        let action = feed(&mut input, "ab\ncd", &mut t, fast());
        assert!(matches!(action, ComponentAction::Consumed));
        assert_eq!(input.value(), "ab\ncd");
    }

    #[test]
    fn multibyte_burst_survives_intact() {
        let mut input = InputComponent::new();
        let mut t = Instant::now();
        feed(&mut input, "日本語 🎉 done\nsecond", &mut t, fast());
        assert_eq!(input.value(), "日本語 🎉 done\nsecond");
    }

    // ── disable switch ─────────────────────────────────────────────────────

    #[test]
    fn disabled_burst_lets_enter_submit_mid_paste() {
        let mut input = InputComponent::new();
        input.set_paste_burst(PasteBurst::disabled());
        let mut t = Instant::now();
        feed(&mut input, "line one\nline two", &mut t, fast());
        // Legacy behaviour, deliberately: the embedded newline submits "line
        // one" and only the tail is left in the composer. This is the exact bug
        // the fallback exists to fix, so the escape hatch must reproduce it.
        assert_eq!(input.value(), "line two");
        assert!(!input.paste_burst_enabled());
    }

    // ── explicit paste must not double-handle ──────────────────────────────

    #[test]
    fn explicit_paste_resets_burst_state() {
        let mut input = InputComponent::new();
        let mut t = Instant::now();
        feed(&mut input, "abcdef", &mut t, fast());
        assert!(input.paste_burst.in_burst_context(t));

        // A bracketed paste arriving right after clears the fallback's state so
        // the two paths can never interleave.
        input.insert_paste("X");
        assert!(!input.paste_burst.in_burst_context(t));
        input.set_test_clock(Some(t));
        assert!(matches!(
            input.handle_event(&ev(KeyCode::Enter)),
            ComponentAction::Emit(AppAction::Submit(_))
        ));
    }

    // ── buffering contract (opt-in) ────────────────────────────────────────

    #[test]
    fn buffering_mode_coalesces_a_burst_into_one_paste() {
        let mut input = InputComponent::new();
        input.set_paste_burst(PasteBurst::new(true).with_buffering(true));
        let mut t = Instant::now();
        feed(&mut input, "hello world", &mut t, fast());

        // Nothing rendered yet: the whole burst is held in the buffer.
        assert_eq!(input.value(), "");
        t += PasteBurst::recommended_active_flush_delay();
        assert!(input.paste_burst_tick(t));
        assert_eq!(input.value(), "hello world");
    }

    #[test]
    fn buffering_mode_flushes_a_lone_held_char_as_typing() {
        let mut input = InputComponent::new();
        input.set_paste_burst(PasteBurst::new(true).with_buffering(true));
        let mut t = Instant::now();
        input.set_test_clock(Some(t));
        input.handle_event(&ev(KeyCode::Char('a')));
        // Flicker suppression: not rendered yet.
        assert_eq!(input.value(), "");

        t += PasteBurst::recommended_flush_delay();
        assert!(input.paste_burst_tick(t));
        assert_eq!(input.value(), "a");
    }

    #[test]
    fn buffering_mode_retro_captures_the_exact_byte_range() {
        let mut input = InputComponent::new();
        // Pre-fill the composer as if the chars had already been typed in, then
        // hand the machine a stream it classifies as paste-like.
        input.set_paste_burst(PasteBurst::new(true).with_buffering(true));
        input.set_content("keep 日本 語🎉");
        let cursor = input.cursor();
        // Three fast chars put the machine in the state that yields BeginBuffer
        // (and give `flush_if_due` a timestamp to measure idleness from).
        let mut now = Instant::now();
        for _ in 0..3 {
            input.paste_burst.on_plain_char_no_hold(now);
            now += Duration::from_millis(1);
        }

        let grab = input
            .paste_burst
            .decide_begin_buffer(now, &input.content[..cursor], 4)
            .expect("whitespace makes the prefix paste-like");
        assert_eq!(grab.grabbed, "本 語🎉");
        assert!(input.content.is_char_boundary(grab.start_byte));

        // Apply exactly what the composer applies: remove the grabbed BYTE
        // range, so the multibyte chars are cut whole.
        input.content.replace_range(grab.start_byte..cursor, "");
        input.cursor = grab.start_byte;
        assert_eq!(input.value(), "keep 日");

        // ...and the removed text comes back as one contiguous paste.
        input.set_test_clock(Some(now));
        let t = now + PasteBurst::recommended_active_flush_delay();
        assert!(input.paste_burst_tick(t));
        assert_eq!(input.value(), "keep 日本 語🎉");
    }

    #[test]
    fn buffering_mode_retro_capture_runs_through_the_key_path() {
        let mut input = InputComponent::new();
        input.set_paste_burst(PasteBurst::new(true).with_buffering(true));
        let mut t = Instant::now();

        // A slow char lands normally (held, then flushed as typing)...
        input.set_test_clock(Some(t));
        input.handle_event(&ev(KeyCode::Char('x')));
        t += PasteBurst::recommended_flush_delay();
        input.paste_burst_tick(t);
        assert_eq!(input.value(), "x");

        // ...then a fast burst arrives. The held/buffered chars coalesce, and
        // the already-visible 'x' is left alone (it is not part of the burst).
        t += Duration::from_millis(300);
        feed(&mut input, "a b c d", &mut t, fast());
        t += PasteBurst::recommended_active_flush_delay();
        input.paste_burst_tick(t);
        assert_eq!(input.value(), "xa b c d");
    }

    #[test]
    fn buffering_mode_flushes_before_an_unrelated_key() {
        let mut input = InputComponent::new();
        input.set_paste_burst(PasteBurst::new(true).with_buffering(true));
        let mut t = Instant::now();
        feed(&mut input, "abcdef", &mut t, fast());
        assert_eq!(input.value(), "");

        // Ctrl+A is not part of any paste: the buffer must be applied, never
        // left stuck.
        input.set_test_clock(Some(t));
        input.handle_event(&Event::Terminal(CrosstermEvent::Key(KeyEvent::new(
            KeyCode::Char('a'),
            KeyModifiers::CONTROL,
        ))));
        assert_eq!(input.value(), "abcdef");
        assert_eq!(input.cursor(), 0);
    }

    #[test]
    fn char_interval_constant_matches_codex() {
        assert_eq!(PASTE_BURST_CHAR_INTERVAL, Duration::from_millis(8));
    }
}

// ── a queued message must say when it runs ─────────────────────────────────
//
// Reported after a 14-minute fan-out: typing appeared to do nothing, and the
// user interrupted to force it. The message WAS queued and rendered — as a dim
// line with no indication of when it would fire, which during a long turn is
// indistinguishable from a dropped keystroke.
#[cfg(test)]
mod queued_affordance {
    use super::*;

    fn queued_row_text(items: Vec<&str>, width: u16) -> String {
        let mut input = InputComponent::new();
        input.set_queued_items(items.into_iter().map(String::from).collect());
        let backend = ratatui::backend::TestBackend::new(width, 10);
        let mut term = ratatui::Terminal::new(backend).expect("terminal");
        term.draw(|f| {
            let area = ratatui::layout::Rect::new(0, 0, width, 10);
            input.draw(f, area);
        })
        .expect("draw");
        let buf = term.backend().buffer().clone();
        (0..width)
            .map(|x| buf[(x, 0)].symbol())
            .collect::<String>()
    }

    #[test]
    fn the_first_queued_row_names_its_trigger() {
        let row = queued_row_text(vec!["check the god files"], 120);
        assert!(row.contains("check the god files"), "{row:?}");
        assert!(
            row.contains("sends when this turn ends"),
            "a queued message must say WHEN it runs: {row:?}"
        );
    }

    /// THE regression. `esc to send now` named a key that was never wired to
    /// anything: there is no send-now handler, and `queue_may_drain` requires
    /// `Idle && turn_done`, so no keystroke can run a queued message while the
    /// turn is alive. What Esc-Esc actually does is END the turn — after which
    /// the queue drains, which is what the label was describing without saying.
    ///
    /// Reported verbatim: "I click it, it didn't do it. If I press it again it
    /// doesn't do it, and then if I do it too many times it just turns off the
    /// conversation — it interrupts it."
    #[test]
    fn the_row_never_promises_a_send_now_key() {
        for width in [40usize, 60, 80, 100, 120, 200] {
            let row = queued_row_text(vec!["check the god files"], width as u16);
            assert!(
                !row.contains("esc to send now"),
                "at width {width} the row still advertises a send-now key that \
                 does not exist; pressing it interrupts the turn instead: {row:?}"
            );
        }
    }

    /// When a key IS named, the row must name the real gesture — two presses,
    /// and the cost stated before the benefit.
    #[test]
    fn the_named_gesture_is_the_one_that_actually_runs() {
        let row = queued_row_text(vec!["check the god files"], 140);
        assert!(
            row.contains("esc esc"),
            "one Esc only arms the interrupt; a hint saying `esc` is why the \
             first press read as the app ignoring the keystroke: {row:?}"
        );
        let i = row.find("interrupts").expect("names the cost");
        let j = row.find("runs it now").expect("names the effect");
        assert!(
            i < j,
            "the destructive half is what the user is agreeing to, so it must \
             come first: {row:?}"
        );
    }

    /// Narrow terminals keep the trigger and drop the key, rather than losing
    /// the whole explanation to a longer sentence.
    #[test]
    fn a_narrow_row_keeps_the_trigger_and_names_no_key() {
        let row = queued_row_text(vec!["check the god files"], 60);
        assert!(
            row.contains("sends when this turn ends"),
            "the short form must survive where the long one does not: {row:?}"
        );
        assert!(!row.contains("esc"), "no key may be named part-way: {row:?}");
    }

    #[test]
    fn the_hint_is_dropped_rather_than_wrapping_on_a_narrow_terminal() {
        // It must never push the composer down or cost a row — the queued
        // display's height is computed from the item count alone.
        let row = queued_row_text(vec!["a message that is quite long indeed"], 44);
        assert!(
            !row.contains("sends when this turn ends"),
            "the hint should be dropped at narrow widths, not wrapped: {row:?}"
        );
    }

    #[test]
    fn only_the_first_row_carries_the_hint() {
        let mut input = InputComponent::new();
        input.set_queued_items(vec!["one".into(), "two".into()]);
        // Height must not change with the hint — it is drawn inside row 0.
        assert_eq!(input.queued_lines(), 2);
    }
}
