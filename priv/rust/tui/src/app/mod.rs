pub mod alt_screen;
pub mod assistant_stream;
pub mod attachment;
pub mod commands;
pub mod event_loop;
pub mod focus;
pub mod frame_size;
pub mod inline_backend;
mod handle_actions;
mod handle_backend;
mod handle_dialogs;
pub mod key_normalize;
mod keymap_dispatch;
pub mod permission_queue;
pub mod resume;
pub mod self_update;
pub mod settle_guard;
pub mod keys;
pub mod layout;
pub mod state;
pub mod stream_pace;
pub mod stream_probe;
pub mod terminal_probe;
pub mod update;

use anyhow::Result;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use tracing::info;

use crate::client::http::ApiClient;
use crate::components::activity::Activity;
use crate::components::agents::Agents;
use crate::components::chat::thinking_box::ThinkingBox;
use crate::components::chat::Chat;
use crate::components::header::Header;
use crate::components::input::InputComponent;
use crate::components::sidebar::Sidebar;
use crate::components::status_bar::StatusBar;
use crate::components::task_checklist::TaskChecklist;
use crate::components::tasks::Tasks;
use crate::components::toast::Toasts;
use crate::config::cli::Cli;
use crate::config::Config;
use crate::dialogs::command_palette::CommandPalette;
use crate::dialogs::config_editor::ConfigEditor;
use crate::dialogs::file_picker::FilePicker;
use crate::dialogs::model_picker::ModelPicker;
use crate::dialogs::onboarding::OnboardingWizard;
use crate::dialogs::plan_review::PlanReview;
use crate::dialogs::quit_confirm::QuitConfirm;
use crate::dialogs::reasoning::ReasoningSelector;
use crate::dialogs::rewind::RewindDialog;
use crate::dialogs::sessions::SessionBrowser;
use crate::event::Event;

use self::focus::FocusStack;
use self::keys::EscTracker;
use self::keys::KeyMap;
use self::layout::Layout;
use self::state::AppState;
use crate::voice::VoiceState;

/// Constants
pub const HEALTH_RETRY_DELAY: Duration = Duration::from_secs(5);
pub const MAX_MESSAGE_SIZE: usize = 100_000;

/// A foreground turn the user pushed to the background with Ctrl+B.
///
/// Backgrounding is not a dead-end: the turn keeps running on the backend (the
/// session SSE stream stays connected and the final answer still lands in
/// scrollback), and this handle is the real return path — `/bg` lists these,
/// `/fg` brings the most recent running one back to the live activity view.
#[derive(Debug, Clone)]
pub struct BackgroundTask {
    /// Stable 1-based label for this session, shown as "[N]".
    pub id: usize,
    /// Short human summary — the prompt that started the turn, truncated.
    pub summary: String,
    /// When the underlying turn started. Restored into `processing_start` on
    /// bring-back so the live elapsed timer stays accurate.
    pub started_at: Instant,
    /// Flipped true once the backgrounded turn's answer arrives.
    pub done: bool,
}

// Some fields initialized but not yet read directly (accessed via render pipeline or Phase 3+)
#[allow(dead_code)]
pub struct App {
    // Components
    pub header: Header,
    pub chat: Chat,
    pub input: InputComponent,
    pub status: StatusBar,
    pub activity: Activity,
    pub sidebar: Sidebar,
    pub thinking_box: ThinkingBox,
    pub tasks: Tasks,
    pub task_checklist: TaskChecklist,
    pub agents: Agents,
    pub toasts: Toasts,

    // Dialogs
    pub quit_dialog: QuitConfirm,
    pub palette: CommandPalette,
    pub model_picker: Option<ModelPicker>,
    pub session_browser: Option<SessionBrowser>,
    pub onboarding: Option<OnboardingWizard>,
    pub plan_review: Option<PlanReview>,
    /// Tool-permission asks. One displayed, the rest queued behind it — tool
    /// calls run in parallel, and a bare slot let a later ask silently replace
    /// the one the user was reading (approving B while looking at A).
    pub permissions: self::permission_queue::PermissionQueue,
    pub reasoning_selector: Option<ReasoningSelector>,
    pub rewind_dialog: Option<RewindDialog>,
    pub config_editor: Option<ConfigEditor>,
    pub file_picker: Option<FilePicker>,
    pub survey: Option<crate::dialogs::survey::SurveyDialog>,
    /// `/theme` — palette picker with a live swatch (AppState::ThemePicker).
    pub theme_picker: Option<crate::dialogs::theme_picker::ThemePicker>,
    /// `/keybindings` — scrollable key→action viewer (AppState::Keybindings).
    pub keybindings_viewer: Option<crate::dialogs::keybindings_viewer::KeybindingsViewer>,
    /// `/tools` — searchable, module-grouped tool browser (AppState::Tools).
    pub tools_browser: Option<crate::dialogs::tools_browser::ToolsBrowser>,
    /// `/context` — token-window breakdown; the last fetched stats snapshot
    /// rendered by the stateless overlay (AppState::ContextBreakdown).
    pub context_stats: Option<crate::dialogs::context_breakdown::ContextStats>,
    /// True between a `/tools` invocation and its `ToolsLoaded` reply, so the
    /// shared tool-list fetch knows to open the browser (vs. the startup load
    /// that only updates the tool count / welcome).
    pub tools_browser_pending: bool,
    /// `/trust` — workspace-trust dialog (AppState::Trust), populated from
    /// GET /workspace/trust and confirmed via POST /workspace/trust/accept.
    pub trust_dialog: Option<crate::dialogs::trust::TrustDialog>,
    /// `/permissions` — rules manager (AppState::PermissionsManager), from
    /// GET /api/v1/permission-rules.
    pub permissions_manager: Option<crate::dialogs::permissions_manager::PermissionsManager>,
    /// `/hooks` — registered-hooks viewer (AppState::Hooks), from GET /api/v1/hooks.
    pub hooks_viewer: Option<crate::dialogs::hooks_viewer::HooksViewer>,
    /// `/mcp` — MCP server list (AppState::Mcp), from GET /api/v1/mcp.
    pub mcp_servers: Option<crate::dialogs::mcp_servers::McpServers>,
    /// `/cost` — cost dashboard (AppState::Cost), from GET /api/v1/cost.
    pub cost_dashboard: Option<crate::dialogs::cost_dashboard::CostDashboard>,
    /// `/skill` `/skills` — skills browser (AppState::Skills), from GET /api/v1/skills.
    pub skills_browser: Option<crate::dialogs::skills_browser::SkillsBrowser>,
    /// `/channels` — channel connectivity panel (AppState::Channels).
    pub channels_panel: Option<crate::dialogs::channels_panel::ChannelsPanel>,
    /// `/memory` — memory browser (AppState::Memory).
    pub memory_browser: Option<crate::dialogs::memory_browser::MemoryBrowser>,
    /// `/persona` — persona picker (AppState::Persona).
    pub persona_picker: Option<crate::dialogs::persona_picker::PersonaPicker>,
    /// `/sandbox` — sandbox-backend picker (AppState::Sandbox).
    pub sandbox_picker: Option<crate::dialogs::sandbox_picker::SandboxPicker>,
    /// `/metrics` — telemetry dashboard (AppState::Metrics).
    pub metrics_dashboard: Option<crate::dialogs::metrics_dashboard::MetricsDashboard>,
    /// `/tasks` — task panel (AppState::Tasks).
    pub tasks_panel: Option<crate::dialogs::tasks_panel::TasksPanel>,
    /// One-shot overdrive (full-auto) entry confirmation overlay. When Some, it
    /// takes key priority; `overdrive_prev_mode` is the mode to revert to on
    /// cancel.
    pub overdrive_confirm: Option<crate::dialogs::overdrive_confirm::OverdriveConfirm>,
    pub overdrive_prev_mode: crate::components::status_bar::PermissionMode,
    /// `-c`/`--continue`: resume this folder's newest session on launch.
    pub startup_continue: bool,
    /// `--resume [id]`: Some(Some(id)) load that id; Some(None) open the session
    /// browser at startup; None = not requested. Consumed once at resolution.
    pub startup_resume: Option<Option<String>>,
    /// The mode flags this process was launched with, replayed verbatim into the
    /// `Resume this session with: …` line printed on exit so copy-pasting it
    /// returns the user to the SAME mode (notably overdrive) rather than
    /// silently dropping them back to prompting.
    pub launch_mode: self::resume::LaunchMode,
    /// Set when a launch-time resume could not be honoured (unknown / ambiguous
    /// session id). The event loop quits on it and `main` prints it to stderr
    /// with exit code 2. Failing loudly here is the whole point: the old path
    /// switched to the bad id, got an empty transcript back, and looked like a
    /// perfectly normal fresh session.
    pub fatal_exit: Option<String>,
    /// `--model <name>` / `--provider <name>`: a one-shot, SESSION-SCOPED model
    /// override applied the moment the launch session id is known.
    ///
    /// Session-scoped on purpose. The boot-time chain (`config.toml` outranking
    /// `OLLAMA_MODEL`, `Settings.put_env`, the launcher sourcing `~/.osa/.env`)
    /// means an env-based override loses on any machine where a model has ever
    /// been picked in the TUI. `POST /sessions/:id/provider` swaps the LIVE
    /// loop, so it beats on-disk config for this run without touching it.
    /// `.take()`n on first use so a later /new or /resume keeps the choice
    /// applied by the user, not by a stale launch flag.
    pub startup_model: Option<(Option<String>, String)>,

    // State
    pub state: AppState,
    /// Overlay caller stack. Each `enter_overlay` pushes the state that was
    /// active when the overlay opened, so closing it (`exit_overlay`) returns to
    /// the exact caller — including a live `Processing` turn — instead of a
    /// hardcoded `Idle`. Base-lifecycle transitions never touch this. Replaces
    /// the old single-slot `prev_state`, which could not survive nesting and
    /// dumped every overlay close into `Idle`, tearing down live turns.
    pub return_stack: Vec<AppState>,
    pub focus: FocusStack,
    pub keys: KeyMap,
    pub layout: Layout,

    // Network
    pub client: Arc<ApiClient>,
    pub sse_cancel: Option<CancellationToken>,

    // Session
    pub session_id: String,
    pub working_dir: String,
    /// Backend's git-root-aware workspace name (from /workspace/identity). None
    /// until it arrives; the status bar/title fall back to the launch-dir
    /// basename in the meantime.
    pub workspace_name: Option<String>,
    /// Human-readable title of the active session, mirrored into the status bar.
    /// None until the first prompt is titled (or a titled session is resumed).
    pub session_title: Option<String>,

    // Dimensions
    pub width: u16,
    pub height: u16,

    // Config
    pub config: Config,

    // Event channel
    pub event_tx: mpsc::UnboundedSender<Event>,
    pub event_rx: mpsc::UnboundedReceiver<Event>,

    // Processing state
    /// Owner of the assistant text for the turn: which message the streamed
    /// deltas belong to, and whether that message has already been finalized.
    /// See `app::assistant_stream` — a bare `String` here could not tell one
    /// generation from the next, so a nudged/re-generated answer rendered
    /// concatenated onto the answer it replaced.
    pub assistant_stream: assistant_stream::AssistantStream,
    /// De-jitter buffer in front of `assistant_stream`. Provider deltas arrive
    /// clumped (the cloud endpoint flushes 4-6 tokens at a time); this spreads a
    /// clump over the frames it has room for instead of painting it in one.
    /// Adaptive — a stream that already arrives smoothly passes straight
    /// through. See `app::stream_pace`.
    pub stream_pacer: stream_pace::StreamPacer,
    /// Which assistant message the pacer's held text belongs to. A delta for a
    /// different message must flush first, or held text would be committed
    /// under the wrong generation's identity.
    pub pace_msg_id: Option<String>,
    pub thinking_buf: String,
    pub processing_start: Option<Instant>,
    /// Spinner-clock elapsed captured at the agent_response turn-end edge (just
    /// before `activity.stop()`), consumed by the trailing turn_recap event so
    /// "✻ Worked for Ns" prints the same number the live spinner last showed —
    /// never the server's later-starting clock (which can appear to jump
    /// backwards). `.take()`n on use; None falls back to server elapsed_ms.
    pub last_turn_client_elapsed_secs: Option<u64>,
    /// WS5 — the last prompt submitted to the backend; restored into the
    /// composer when an interrupt lands before the turn produced any output
    /// (CC auto-restore on user-cancel).
    pub last_submitted_prompt: Option<String>,
    pub cancelled: bool,
    /// Whether the turn in flight has reached a genuine end.
    ///
    /// `AppState::Idle` cannot answer this: `handle_agent_response` runs full
    /// turn teardown on every agent_response, and one turn emits several. This
    /// is cleared when a prompt is submitted and set only by the backend's
    /// `done` event or by `finalize_turn_state` (cancel / disconnect / error),
    /// so nothing keyed on it can fire into a live turn.
    pub turn_done: bool,
    pub sse_reconnecting: bool,

    // Pending tool call args, used to pair with ToolCallEnd.
    /// Keyed by the backend's per-call `tool_call_id` when it sends one, else by
    /// tool name (legacy fallback) — see `handle_backend::pending_key`. With an
    /// id the queue holds exactly the one call's args, so concurrent same-name
    /// calls can never take each other's. Without one it degrades to the old
    /// per-name FIFO: a Vec (not a single String) so several concurrent calls of
    /// the SAME tool don't overwrite each other's args — which showed up as tool
    /// lines with no path.
    pub pending_tool_args: HashMap<String, Vec<String>>,

    /// U-B6 — queue of tool results that arrived BEFORE their
    /// `ToolCallEnd` (out-of-order stream). `ToolCallEnd` creates the scrollback
    /// message, so a `ToolResult` seen first has nothing to attach to and the
    /// output was silently dropped. Stashed here while the call is still pending
    /// (its args are still in `pending_tool_args`), then drained onto the message
    /// the instant `ToolCallEnd` builds it.
    ///
    /// Keyed identically to `pending_tool_args` (`handle_backend::pending_key`):
    /// per-call id when available, tool name otherwise. The drain is positional
    /// (`results.remove(0)`), which is only sound when the key identifies ONE
    /// call — hence the id.
    pub pending_tool_results: HashMap<String, Vec<(String, bool)>>,

    /// U-B6 — signatures of background shell calls already counted in
    /// `bg_shell_count`, so a `ToolCallStart` re-emitted on an SSE reconnect/replay
    /// does not double-count the same live background job. Cleared whenever
    /// `bg_shell_count` returns to zero (no live jobs ⇒ safe to forget), which
    /// also lets a genuinely new identical command count again later.
    pub counted_bg_shells: std::collections::HashSet<String>,

    /// Accumulator for collapsing consecutive same-kind tool calls into one
    /// scrollback summary line ("Read N files", "Ran N shell commands", …).
    pub collapse: crate::tools::collapse::Accumulator,

    /// True once we have flushed at least one agent text chunk for the current
    /// turn (so subsequent mid-turn flushes use the header-less continuation
    /// message type instead of repeating the "◈ OSA" header).
    pub agent_header_sent: bool,

    // Background tasks (Ctrl+B). See `BackgroundTask` — each is a real handle
    // with a bring-back (`/fg`) path, not a one-way dead-end.
    pub bg_tasks: Vec<BackgroundTask>,
    /// Monotonic id source so each backgrounded turn gets a stable "[N]" label.
    pub bg_task_seq: usize,
    /// Count of running background shell commands (`bash` with run_in_background).
    /// Incremented on the tool-call start, decremented on the backend's
    /// `background_command_completed` event. Feeds the status-bar shell chip and
    /// the "N background terminals" summary.
    pub bg_shell_count: usize,
    /// Number of FOREGROUND shell commands currently running in this turn (a
    /// `bash`/`shell_execute` tool call in flight WITHOUT run_in_background).
    /// When > 0, Ctrl+B detaches the running command to the background instead
    /// of backgrounding the whole turn. Incremented on the tool-call start,
    /// decremented on its end.
    pub active_fg_shell_count: usize,

    // Backend auto-start
    pub backend_spawn_attempted: bool,
    pub health_retry_count: u32,

    // Whether the one-time "update available" transcript notice has been shown
    // this session. /health is polled repeatedly (startup + config changes), so
    // this guard keeps the notice to exactly once — quiet, never nagging.
    pub update_notice_shown: bool,

    // Commands from backend
    pub command_entries: Vec<crate::client::types::CommandEntry>,

    // Names of the tools currently available in this session (from GET /tools).
    // Drives capability-gating: a command whose `required_tools` are not all
    // present here is hidden from the `/` palette and `/help`. Empty until the
    // first ToolsLoaded arrives, during which nothing is gated (fail-open).
    pub available_tools: HashSet<String>,

    // Voice input
    pub voice: VoiceState,

    // Active /goal auto-continue loop (cross-turn keep-going). When Some, each
    // assistant turn-completion auto-submits a "continue toward the goal" prompt
    // until the reply says DONE, the user cancels, /goal off, or the cycle cap.
    pub goal: Option<String>,
    pub goal_cycle: u32,
    pub goal_max_cycles: u32,
    /// Instant the active goal became live, so the status-line goal indicator can
    /// count up "Working on: <goal> · 3m 40s" from activation (Codex
    /// `thread_goal_actions` + `status_indicator_widget` elapsed). Stamped the
    /// first frame a goal is present and reset the moment it clears, so the timer
    /// freezes/resets instead of leaking across goals. Reconciled every frame in
    /// `sync_goal_indicator` (called from `sync_chrome`) — additive, so the
    /// existing `set_goal`/`clear_goal` paths need no change.
    pub goal_activated_at: Option<Instant>,

    // Pasted / drag-dropped image & file attachments, shown as [Image #N] chips.
    pub attachments: Vec<crate::app::attachment::Attachment>,

    // Welcome message injected flag
    pub welcome_injected: bool,
    // Set once we've resolved this folder's session on launch (resume-or-create).
    pub dir_session_resolved: bool,
    // Welcome banner (tool_count, provider, model) waiting to be pushed into the
    // terminal scrollback by the event loop via insert_before.
    pub pending_welcome_banner: Option<(usize, Option<String>, Option<String>)>,

    // Transcript viewer (Ctrl+O) — additive full-screen reader over the in-memory
    // conversation. `transcript_log` retains finalized messages as they drain into
    // native scrollback; `transcript` is the open overlay state (None = closed).
    pub transcript_log: Vec<crate::dialogs::transcript_viewer::TranscriptEntry>,
    pub transcript: Option<crate::dialogs::transcript_viewer::TranscriptViewer>,
    /// When set, the transcript overlay renders THESE entries instead of
    /// `transcript_log` — used for nested subagent transcripts fetched from the
    /// backend (dashboard "view"). Cleared when the overlay closes.
    pub transcript_override: Option<Vec<crate::dialogs::transcript_viewer::TranscriptEntry>>,

    // Completion notification: bell / OSC 9 when a turn ends while the user is
    // likely away. `notify_on_complete` toggles it (off via OSA_NO_NOTIFY);
    // `last_user_input` tracks the last keypress for the idle heuristic.
    pub notify_on_complete: bool,
    pub last_user_input: Option<Instant>,
    /// U-T18 — notification channel + user hooks, built once from env/config.
    /// Consumed by the focus-gated turn-complete notifier.
    pub notify_cfg: crate::notification::NotificationConfig,

    // U-T12/T15 — turn-activity side effects reconciled once per tick from
    // `turn_is_active()` (robust across overlays parking a live turn, cancels
    // and disconnects). `turn_effects_active` tracks whether the effects are
    // currently engaged so start/stop fire exactly on the turn edges.
    /// U-T15 — OS sleep inhibitor held for the duration of a turn (Drop releases).
    pub inhibitor: Option<crate::notification::SleepInhibitor>,
    /// True while the taskbar-progress bar + sleep inhibitor are engaged.
    pub turn_effects_active: bool,
    /// Throttle for the OSC 9;4 progress keepalive re-emit (~3s cadence).
    pub last_progress_keepalive: Option<Instant>,

    // WS12 chrome — deduping terminal-title writer (OSC 0, tmux-wrapped) and
    // the unanswered-permission ping state: when the permission dialog opened
    // and whether its 6s desktop ping already fired (CC useNotifyAfterTimeout).
    pub chrome_title: crate::components::title::TitleState,
    pub permission_wait_since: Option<Instant>,
    pub permission_pinged: bool,

    // Background-agent dashboard (AppState::AgentsDashboard): index of the
    // currently-selected agent row, for cancel targeting.
    pub agents_dashboard_selected: usize,

    // Message queue: prompts typed while the agent is Processing are enqueued
    // (FIFO) instead of interrupting, then auto-submitted one at a time on each
    // turn completion. /steer inserts at the front (priority). Parity with
    // Claude Code / Hermes "keep typing while busy".
    pub message_queue: Vec<String>,

    // Esc-vs-Esc-Esc detector. A single Esc never destroys state; double-Esc
    // clears the draft (pushed to input history) or, on an empty composer,
    // opens the rewind picker (Claude Code double-Esc).
    pub esc_tracker: EscTracker,

    // One-shot hard-repaint request (Ctrl+L, or resume after a Ctrl+Z
    // suspend). The event loop clears the terminal's diff state before the
    // next draw so every cell repaints.
    pub force_redraw: bool,

    // One-shot "the terminal was resized" request (pane split / drag). Set in
    // the Resize handler, consumed by the event loop, which then rebuilds the
    // inline viewport FRESH at the new size and clears the old-width rows.
    // Unlike the transient height dips handled by the shrink debounce, a resize
    // is a deliberate size change and is committed immediately — but a burst of
    // Resize events from a pane-drag is coalesced into ONE rebuild because the
    // whole event backlog is drained before the loop reads this flag, so it
    // always reflects the FINAL size.
    pub resize_dirty: bool,

    // Reserved height of the streaming preview slot for the CURRENT turn, in
    // rows (0 when no reply is streaming), plus the pending-shrink timer that
    // damps it. See `DampedSlot`.
    //
    // This used to be a bare high-water mark, which made the slot MONOTONIC for
    // the turn: a reply whose rendered height dipped could not shrink it back,
    // so a grow/shrink oscillation could not churn the inline viewport. It also
    // meant the slot never released a row until the turn ended — the turn that
    // needed twelve rows early reserved twelve for its one-row closing reply and
    // drew a blank band above it. The slot now sizes to what is drawn and damps
    // only the shrink direction, on a time bound.
    //
    // A `Cell` because `desired_inline_height` is `&self`: keeping the state
    // inside the one function that computes the slot means the sizing and the
    // memory of it cannot drift, and every turn-ending path releases it for free
    // (the "nothing is streaming" branch resets it).
    pub(crate) stream_preview_slot: std::cell::Cell<crate::app::event_loop::DampedSlot>,

    // The same damped reservation for the other two bands that reserved a
    // ceiling and painted less than it. `Activity` reserved `max_height()` (its
    // verbosity ceiling) while drawing `height()`; `Agents` reserved a flat
    // `AGENTS_INLINE_CAP` while drawing its live roster. Both bands are
    // bottom-anchored, so both surpluses painted as blank rows above their
    // content — the same defect as the preview's, in a different band.
    pub(crate) activity_slot: std::cell::Cell<crate::app::event_loop::DampedSlot>,
    pub(crate) agents_slot: std::cell::Cell<crate::app::event_loop::DampedSlot>,

    // One clock per frame, latched by `desired_inline_height` and read by
    // `measure_bands`. Both run during a single frame, and a band's pending
    // shrink must not be allowed to mature BETWEEN the reservation and the
    // draw — that would reserve one height and paint another, which is the
    // anchor-orphaning class of bug. `DampedSlot::resolve` is idempotent for a
    // fixed instant, so sharing one makes the two calls agree by construction.
    pub(crate) frame_now: std::cell::Cell<Instant>,

    // One-shot "/clear was run" request. The terminal (and thus the real
    // scrollback the finalized transcript lives in when inline) is owned by
    // the event loop, not `App`, so `/clear` can only clear the in-memory
    // state (`self.chat`, `self.transcript_log`, ...) and must signal the
    // loop to purge the real scrollback + re-prime the inline viewport.
    // Consumed (set back to false) once per event-loop iteration.
    pub pending_clear: bool,

    // WS10 — user-configurable keybindings: compiled defaults overlaid by
    // ~/.osa/keybindings.json, consulted by update.rs before hardcoded arms.
    pub keymap: crate::config::keybindings::Keybindings,
    // Pending multi-step chord prefix (e.g. ctrl+x awaiting ctrl+k) plus when
    // it was pressed; expires after 3s (keymap_dispatch::CHORD_TIMEOUT).
    pub chord_pending: Option<(Vec<crossterm::event::KeyEvent>, Instant)>,
    // Armed timestamp for the ctrl+x ctrl+k kill-all-agents press-twice confirm.
    pub kill_agents_armed: Option<Instant>,
    // Ctrl+T (chat:todosToggle) — hide/show the floating task checklist.
    pub task_checklist_hidden: bool,
}

impl App {
    /// Write the active provider/model to EVERY surface that displays it, in one
    /// call.
    ///
    /// The header, the status bar, the sidebar and the chat welcome each kept
    /// their own copy, updated by three separate call sites that all had to
    /// remember all four. Backend-side this is already solved —
    /// `Runtime.Identity` is the one resolver behind `GET /health`, `osa doctor`
    /// and `/status` — so the TUI gets the same guarantee here: one writer, one
    /// value, no surface can drift.
    pub fn set_identity(&mut self, provider: &str, model: &str) {
        self.header.set_provider_info(provider, model);
        self.status.set_provider_info(provider, model);
        self.sidebar.set_provider_info(provider, model);
        let tool_count = self.header.tool_count();
        self.chat.set_welcome_info(provider, model, tool_count);
    }

    /// The active `(provider, model)` as currently displayed — read straight off
    /// the status bar, so anything built from this (notably the startup banner)
    /// is showing the exact strings the bar is showing.
    pub fn identity(&self) -> (String, String) {
        (
            self.status.provider().to_string(),
            self.status.model_name().to_string(),
        )
    }

    pub async fn new(config: Config, cli: Cli, kbd_enhanced: bool) -> Result<Self> {
        let (event_tx, event_rx) = mpsc::unbounded_channel();

        // Create API client
        let client = Arc::new(ApiClient::new(
            config.base_url.clone(),
            config.profile_dir.clone(),
        )?);

        // Generate session ID
        let session_id = generate_session_id();

        // Capture the CWD at startup — this is the directory the user launched from,
        // not the backend's directory. Sent with every orchestrate request.
        let working_dir = std::env::current_dir()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default();

        // Initialize theme
        let theme = crate::style::themes::by_name(&config.theme)
            .unwrap_or_else(crate::style::themes::dark);
        crate::style::set_theme(theme);

        // Use actual terminal size instead of hardcoded 80x24
        let init = crate::app::frame_size::probe();
        let (init_w, init_h) = (init.cols, init.rows);

        info!(
            "App initialized: session={}, url={}, term={}x{}, cwd={}",
            session_id, config.base_url, init_w, init_h, working_dir
        );

        let goal_max_cycles = config.goal_max_cycles.max(1);

        let mut sidebar = Sidebar::new();
        sidebar.set_yolo_mode(config.skip_permissions);

        // Seed the status-line permission mode from launch flags. `--overdrive`
        // / `--dangerously-skip-permissions` (folded into config.skip_permissions)
        // wins and lands in overdrive; otherwise honour an explicit
        // `--permission-mode <mode>`. Mirrors the skip_permissions seeding.
        use crate::components::status_bar::PermissionMode;
        let mut status = StatusBar::new();
        let seeded_mode = if config.skip_permissions {
            PermissionMode::BypassPermissions
        } else {
            match cli.permission_mode.as_deref() {
                Some("plan") => PermissionMode::Plan,
                Some("accept-edits") | Some("auto-edit") | Some("acceptedits") => {
                    PermissionMode::AcceptEdits
                }
                Some("auto") => PermissionMode::Auto,
                Some("overdrive") | Some("bypass") | Some("bypasspermissions") => {
                    PermissionMode::BypassPermissions
                }
                _ => PermissionMode::Default,
            }
        };
        if !seeded_mode.is_default() {
            status.set_permission_mode(seeded_mode);
        }
        // An overdrive seed implies the bypass flag + sidebar indicator, exactly
        // like --dangerously-skip-permissions.
        let overdrive_seeded = seeded_mode.is_overdrive();
        if overdrive_seeded {
            sidebar.set_yolo_mode(true);
        }

        // Seed the inline `/` completions with the built-in command set so the
        // slash menu is populated and filterable immediately — before (or even
        // without) the backend `GET /commands` response. The backend registry
        // merges in / overrides this once it loads.
        let mut input = InputComponent::new();
        input.set_commands_with_descriptions(crate::app::commands::builtin_slash_commands());
        // Record whether the kitty keyboard-enhancement protocol is active (probed
        // once in main.rs) so the composer's newline hint matches the terminal's
        // real capabilities: "shift+enter" when enhanced, backslash+enter otherwise.
        input.set_kbd_enhanced(kbd_enhanced);

        // WS10: user keybindings (~/.osa/keybindings.json) over compiled
        // defaults. Load problems are warnings, never fatal.
        let keymap = crate::config::keybindings::Keybindings::load(
            &config.profile_dir.join("keybindings.json"),
        );
        for w in keymap.load_warnings() {
            tracing::warn!("keybindings: {}", w);
        }

        Ok(Self {
            header: Header::new(),
            chat: Chat::new(),
            input,
            status,
            activity: Activity::new(),
            sidebar,
            thinking_box: ThinkingBox::new(),
            tasks: Tasks::new(),
            task_checklist: TaskChecklist::new(),
            agents: {
                // Tell the roster where "here" is so its trail rows can print
                // paths workspace-relative instead of fully qualified. Purely a
                // display concern; borrowed before `working_dir` moves below.
                let mut a = Agents::new();
                a.set_workspace_root(&working_dir);
                a
            },
            toasts: Toasts::new(),

            quit_dialog: QuitConfirm::new(),
            palette: CommandPalette::new(),
            model_picker: None,
            session_browser: None,
            onboarding: None,
            plan_review: None,
            permissions: self::permission_queue::PermissionQueue::new(),
            reasoning_selector: None,
            rewind_dialog: None,
            config_editor: None,
            file_picker: None,
            survey: None,
            theme_picker: None,
            keybindings_viewer: None,
            tools_browser: None,
            context_stats: None,
            tools_browser_pending: false,
            trust_dialog: None,
            permissions_manager: None,
            hooks_viewer: None,
            mcp_servers: None,
            cost_dashboard: None,
            skills_browser: None,
            channels_panel: None,
            memory_browser: None,
            persona_picker: None,
            sandbox_picker: None,
            metrics_dashboard: None,
            tasks_panel: None,
            overdrive_confirm: None,
            overdrive_prev_mode: crate::components::status_bar::PermissionMode::Default,
            startup_continue: cli.continue_last,
            startup_resume: cli.resume.clone(),
            launch_mode: self::resume::LaunchMode::from_cli(&cli),
            fatal_exit: None,
            // `--provider` alone (no `--model`) still needs a model to swap to;
            // the backend resolves the provider's default when model is "".
            startup_model: match (cli.model.clone(), cli.provider.clone()) {
                (Some(m), p) => Some((p, m)),
                (None, Some(p)) => Some((Some(p), String::new())),
                (None, None) => None,
            },

            workspace_name: None,
            session_title: None,
            state: AppState::Connecting,
            return_stack: Vec::new(),
            focus: FocusStack::new(),
            keys: KeyMap::default(),
            layout: Layout::compute(init_w, init_h, config.sidebar_enabled, 0, 0),

            client,
            sse_cancel: None,

            session_id,
            working_dir,

            width: init_w,
            height: init_h,

            config,

            event_tx,
            event_rx,

            assistant_stream: assistant_stream::AssistantStream::new(),
            stream_pacer: stream_pace::StreamPacer::new(stream_pace::PaceMode::from_env()),
            pace_msg_id: None,
            thinking_buf: String::new(),
            processing_start: None,
            last_turn_client_elapsed_secs: None,
            last_submitted_prompt: None,
            cancelled: false,
            // No turn in flight yet, so nothing is waiting on a turn end.
            turn_done: true,
            sse_reconnecting: false,

            pending_tool_args: HashMap::new(),
            pending_tool_results: HashMap::new(),
            counted_bg_shells: std::collections::HashSet::new(),
            collapse: crate::tools::collapse::Accumulator::default(),
            agent_header_sent: false,

            bg_tasks: Vec::new(),
            bg_task_seq: 0,
            bg_shell_count: 0,
            active_fg_shell_count: 0,
            backend_spawn_attempted: false,
            health_retry_count: 0,
            update_notice_shown: false,
            // Seed the Ctrl+K palette / `/help` with the full built-in set at
            // construction, mirroring the inline `/` completions seed above, so
            // the palette is populated immediately — before (or entirely
            // without) the backend `GET /commands` response. `CommandsLoaded`
            // replaces this with the merged backend registry once it arrives.
            command_entries: crate::app::handle_backend::builtin_command_entries(),
            available_tools: HashSet::new(),

            voice: VoiceState::new(),
            goal: None,
            goal_cycle: 0,
            goal_max_cycles,
            goal_activated_at: None,
            attachments: Vec::new(),
            welcome_injected: false,
            dir_session_resolved: false,
            pending_welcome_banner: None,

            transcript_log: Vec::new(),
            transcript: None,
            transcript_override: None,
            notify_on_complete: std::env::var("OSA_NO_NOTIFY").is_err(),
            last_user_input: None,
            notify_cfg: crate::notification::NotificationConfig::from_env(),
            inhibitor: None,
            turn_effects_active: false,
            last_progress_keepalive: None,
            chrome_title: crate::components::title::TitleState::new(),
            permission_wait_since: None,
            permission_pinged: false,
            agents_dashboard_selected: 0,
            message_queue: Vec::new(),
            esc_tracker: EscTracker::default(),
            force_redraw: false,
            resize_dirty: false,
            stream_preview_slot: std::cell::Cell::new(Default::default()),
            activity_slot: std::cell::Cell::new(Default::default()),
            agents_slot: std::cell::Cell::new(Default::default()),
            frame_now: std::cell::Cell::new(Instant::now()),
            pending_clear: false,
            keymap,
            chord_pending: None,
            kill_agents_armed: None,
            task_checklist_hidden: false,
        })
    }

    /// True when the app wants a full-height alternate-screen viewport (dialogs,
    /// connecting, onboarding, file picker) instead of the inline live region.
    pub fn wants_full_viewport(&self) -> bool {
        self.state.is_overlay()
            || self.state.is_fullscreen()
            || self.file_picker.is_some()
            || self.transcript.is_some()
            || self.config_editor.is_some()
            || self.overdrive_confirm.is_some()
            // Without this, /reasoning (no-arg) sets `reasoning_selector` but draw()
            // takes the inline branch, leaving the selector's draw arm unreachable —
            // an invisible modal that captures keystrokes. It must claim the full
            // viewport like every other Option-overlay.
            || self.reasoning_selector.is_some()
    }

    pub fn recompute_layout(&mut self) {
        let task_lines = self.tasks.height();
        let agent_lines = self.agents.height();
        let input_h = self.input.needed_height();
        self.layout = Layout::compute_with_input_height(
            self.width,
            self.height,
            self.config.sidebar_enabled,
            task_lines,
            agent_lines,
            input_h,
        );
        self.chat
            .set_size(self.layout.chat_width, self.layout.chat_height);
        self.input.set_width(self.layout.chat_width);
        self.status.set_width(self.width);
        // Live context-meter overlay: re-estimate the composer's uncommitted
        // input on every edit (typing/paste/backspace all route through here as
        // post-edit bookkeeping) so the meter reflects what the user is about to
        // send, CC-style. Recomputed on change, not on render ticks. On submit
        // the composer drains its buffer before this runs, so pending falls back
        // to 0 naturally; submit_prompt also resets it explicitly as a backstop.
        self.refresh_pending_input_tokens();
    }

    /// Re-estimate the composer's pending input and push it onto the context
    /// meter (status bar, mirrored to the sidebar so both surfaces agree). Cheap
    /// char/4 estimate; never mutates the committed context value.
    pub(crate) fn refresh_pending_input_tokens(&mut self) {
        let pending =
            crate::components::status_bar::estimate_tokens(self.input.value());
        self.status.set_pending_input_tokens(pending);
        // Mirror the combined (committed + pending) ratio into the sidebar meter.
        self.sidebar.set_context(self.status.display_context_ratio());
    }

    /// Transition to a new state with validation
    pub fn transition(&mut self, target: AppState) {
        debug_assert!(
            self.state.can_transition_to(target),
            "Invalid state transition: {} -> {}",
            self.state,
            target,
        );
        // Auto-manage processing indicator on state transitions
        if target == AppState::Processing && self.state != AppState::Processing {
            self.input.set_processing(true);
        } else if self.state == AppState::Processing && target != AppState::Processing {
            self.input.set_processing(false);
        }
        // Dismiss the file picker on any state transition — prevents the invisible
        // overlay from silently intercepting keystrokes when the app changes context.
        if self.file_picker.is_some() {
            self.file_picker = None;
        }
        self.state = target;
        // Reset quit dialog focus to Cancel (safe default) each time the dialog opens.
        if target == AppState::Quit {
            self.quit_dialog.reset();
        }
    }

    /// Whether a turn is currently in flight — either the app is directly in
    /// `Processing`, or an overlay was opened *from* `Processing` (so the live
    /// turn is parked on the return stack). Used to keep streaming/thinking
    /// buffers accumulating and the spinner accountable even while an overlay
    /// (e.g. `/context`) is drawn over an active turn.
    pub(crate) fn turn_is_active(&self) -> bool {
        turn_active(self.state, &self.return_stack)
    }

    /// Which floating `Option`-overlay currently owns the screen and keys, if
    /// any. The ONE place draw priority and key priority are decided, so they
    /// can never drift apart. Returns `None` when only the base state machine
    /// (Idle/Processing/overlay-states) is active.
    pub(crate) fn active_modal_overlay(&self) -> Option<ModalOverlay> {
        topmost_modal(
            self.overdrive_confirm.is_some(),
            self.config_editor.is_some(),
            self.file_picker.is_some(),
            self.reasoning_selector.is_some(),
        )
    }

    /// Shared per-turn teardown: commit completed-but-unflushed tool calls into
    /// scrollback, drop the partial streaming text, and reset every per-turn
    /// accumulator (stream/thinking buffers, header flag, collapse run, spinner,
    /// status, agents panel). Extracted so the CancelTimeout path and the
    /// disconnect path finalize identically and can never drift apart.
    pub(crate) fn finalize_turn_state(&mut self) {
        // This is where a turn ends WITHOUT a backend `done` — cancel, timeout,
        // disconnect. Marking it done here is what stops a lost `done` from
        // stranding the message queue for the rest of the session.
        self.turn_done = true;
        // The turn these asks belong to is over — answering them would resume
        // nothing, so drop the visible prompt AND everything queued behind it
        // rather than leaving orphan dialogs over the next turn.
        self.clear_permission_prompts();
        self.chat.clear_streaming();
        // Commit any completed-but-unflushed tool calls; drop the partial
        // streaming text deliberately.
        self.chat.flush_pending_tools();
        self.flush_collapse();
        // Hand over anything the de-jitter buffer was still holding BEFORE the
        // buffers are dropped. Nothing may be left waiting on a cadence tick at
        // a boundary the user can see, and a last completed block settling into
        // scrollback here is strictly better than losing it.
        self.flush_stream_pacer();
        // The turn is over — drop the partial text AND this turn's finalization
        // history, so the next turn is not mistaken for a repeat of this one.
        self.assistant_stream.reset();
        self.stream_pacer.reset();
        self.pace_msg_id = None;
        self.thinking_buf.clear();
        self.agent_header_sent = false;
        self.activity.stop();
        self.status.set_active(false);
        self.agents.task_completed();
    }

    /// Drop every outstanding permission ask (displayed + queued) and leave the
    /// overlay behind if one was open, keeping the return stack balanced —
    /// exactly one `exit_overlay` per `enter_overlay`, no matter how many asks
    /// were stacked inside it.
    pub(crate) fn clear_permission_prompts(&mut self) {
        if !self.permissions.is_active() {
            self.permissions.clear();
            return;
        }
        self.permissions.clear();
        self.activity.set_pending_user(false);
        if self.state == AppState::Permissions {
            self.exit_overlay();
        }
    }

    /// Settle the working chrome at the TURN-end edge, so what the user is left
    /// looking at is the OUTPUT rather than the remains of the machinery that
    /// produced it.
    ///
    /// Driven from the run loop's `Processing → Idle` edge, which is the single
    /// true turn boundary: one turn can contain SEVERAL assistant generations
    /// (the ReAct loop re-enters on the auto-continue nudge, the coding nudge,
    /// the verification gate, the goal verifier…), each finalizing its own
    /// message, so hanging teardown on `agent_response` would retire the chrome
    /// in the middle of a turn that is still running. Driving it off the state
    /// edge also covers the paths that never see an `agent_response` at all —
    /// interrupt, cancel-timeout, backend disconnect — with one implementation.
    ///
    /// Everything here is idempotent, and everything here is *transient*:
    ///
    /// * the live preview remnant (`clear_streaming`) — its content has already
    ///   been committed by `handle_agent_response`, so what is dropped is a
    ///   duplicate of the block the user is about to read;
    /// * completed-but-unflushed tool cells and the collapsed tool run, pushed
    ///   into scrollback so they are SETTLED history above the answer instead of
    ///   mid-flight rows beside it;
    /// * the spinner / tool-progress feed, the frozen reasoning box, and the
    ///   multi-agent roster ([`settle_working_chrome`]).
    ///
    /// The frozen plan snapshot and the background-terminals summary are
    /// deliberately NOT touched: the first is committed history the user may want
    /// to scroll back to, and the second reports jobs that really are still
    /// running.
    pub(crate) fn settle_turn_chrome(&mut self) {
        // Release the preview's per-turn growth. `desired_inline_height` also
        // releases it on its "nothing is streaming" branch, but that branch is
        // short-circuited by an open permission prompt or plan-review panel — so
        // a turn that ended under one of those would otherwise carry its
        // high-water mark into the next turn and start it pre-grown.
        self.stream_preview_slot.set(Default::default());
        self.activity_slot.set(Default::default());
        self.agents_slot.set(Default::default());
        self.chat.clear_streaming();
        self.chat.flush_pending_tools();
        self.flush_collapse();
        crate::app::event_loop::settle_working_chrome(
            &mut self.activity,
            &mut self.agents,
            &mut self.thinking_box,
        );
    }

    /// End the in-flight turn after a passive backend disconnect: finalize the
    /// half-rendered message and pending tools (mirroring the CancelTimeout
    /// path), then return to `Idle`. If the turn is parked under an open
    /// overlay, rewrite the parked `Processing` so closing the overlay lands on
    /// `Idle` instead of a dead, frozen spinner with a dangling bubble.
    pub(crate) fn end_active_turn_on_disconnect(&mut self) {
        self.finalize_turn_state();
        if self.state.is_processing() {
            self.transition(AppState::Idle);
        } else {
            for s in self.return_stack.iter_mut() {
                if *s == AppState::Processing {
                    *s = AppState::Idle;
                }
            }
        }
        self.recompute_layout();
    }

    /// Enter an overlay, remembering the caller on the return stack so closing
    /// the overlay lands back where it opened (including a live `Processing`
    /// turn). Entry reuses `transition()`, so its legality assert and side
    /// effects (spinner bookkeeping, stray file-picker dismissal, quit reset)
    /// are preserved unchanged.
    pub fn enter_overlay(&mut self, target: AppState) {
        self.return_stack.push(self.state);
        self.transition(target);
    }

    /// Close the current overlay, returning to whatever opened it (default
    /// `Idle` if the stack is somehow empty). Deliberately bypasses
    /// `can_transition_to`: returning to the caller — even `Processing` — is
    /// legal by construction, and several overlay→Processing edges are absent
    /// from the legacy transition table.
    pub fn exit_overlay(&mut self) {
        let from = self.state;
        let target = self.return_stack.pop().unwrap_or(AppState::Idle);
        self.sync_overlay_processing_indicator(from, target);
        if self.file_picker.is_some() {
            self.file_picker = None;
        }
        self.state = target;
    }

    /// Pop the caller recorded for the current overlay WITHOUT restoring it —
    /// for the few close paths that intentionally land somewhere other than the
    /// caller (plan approve → `Processing`, plan reject/edit and onboarding
    /// completion → `Idle`). Keeps the return stack balanced: exactly one pop
    /// per overlay open.
    pub fn discard_overlay_return(&mut self) {
        self.return_stack.pop();
    }

    /// Mirror of `transition()`'s processing-indicator bookkeeping for the
    /// assert-free `exit_overlay` path.
    fn sync_overlay_processing_indicator(&mut self, from: AppState, to: AppState) {
        if to == AppState::Processing && from != AppState::Processing {
            self.input.set_processing(true);
        } else if from == AppState::Processing && to != AppState::Processing {
            self.input.set_processing(false);
        }
    }

    /// Set the active session's human-readable title and mirror it into the
    /// status bar. Single entry point so the two never drift: every producer
    /// (SSE push, session create/resume, picker selection) goes through here.
    pub(crate) fn set_session_title(&mut self, title: Option<String>) {
        let normalized = title
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty());
        self.session_title = normalized.clone();
        self.status.set_session_title(normalized);
    }

    /// WS12 chrome sync — runs once per event-loop iteration, just before draw
    /// (the 200ms tick guarantees cadence even while idle).
    ///
    /// 1. Terminal tab title: "OSA — <dir>", with a ✳/✻ glyph animating at
    ///    960ms while a turn runs (CC `use-terminal-title`). The TitleState
    ///    writer dedups, so unchanged frames cost zero pty writes.
    /// 2. Unanswered-permission ping: when a permission dialog has been open
    ///    6s with no decision, fire one desktop notification + bell (CC
    ///    `useNotifyAfterTimeout`). Resets when the dialog closes; honours the
    ///    OSA_NO_NOTIFY opt-out via `notify_on_complete`.
    pub(crate) fn sync_chrome(&mut self) {
        let basename = self
            .workspace_name
            .clone()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| {
                std::path::Path::new(&self.working_dir)
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_else(|| "~".to_string())
            });
        let busy = self.state == AppState::Processing;
        let title = crate::components::title::compose(busy, &basename);
        // Sanitization happens inside the writer. If the (backend-supplied)
        // workspace name sanitizes away entirely we keep whatever title is
        // already on the tab rather than clearing it — caller policy.
        let _ = self.chrome_title.update(&title);

        // U-T24 — keep the spinner's "N queued" hint in sync with the live WS5
        // message queue every frame (cheap; the writer only re-renders on change).
        self.activity.set_queued(self.message_queue.len());

        // Effort tier: feed the live thinking segment ("thinking with <effort>
        // effort") from the same status-bar effort chip every frame. Cheap
        // clone; additive to the existing thinking timer/verb rotation.
        self.activity.set_current_effort(self.status.effort());

        // Goal + elapsed indicator: reconcile the status-line "Working on: <goal>
        // · <elapsed>" chip every frame from the live goal state (cheap; the
        // writer only re-renders on change).
        self.sync_goal_indicator();

        // Inline ask_user band header chip: `[turn: 7s, ↓53.6k]`. Read the live
        // turn clock / token counter FIRST so the borrow of `self.survey` below
        // does not overlap the shared borrows of `status`/`processing_start`.
        if self.survey.is_some() {
            let elapsed = self
                .processing_start
                .map(|t| t.elapsed().as_secs())
                .unwrap_or(0);
            let tokens = self.status.output_tokens();
            if let Some(ref mut s) = self.survey {
                s.set_turn_meta(elapsed, tokens);
            }
        }

        // U-T28 — feed the compact sub-agent footer cue (count + est. cost) from
        // the agents panel while sub-agents are active; clear it otherwise.
        if self.agents.is_active() {
            self.status
                // Two corrections, both "stop stating something false":
                //  * COUNT — `entry_count` includes rows that already finished
                //    (they linger for the retain window), so the cue read "4
                //    subagents" for one live worker plus three done ones.
                //    `running_count` counts only what has not reached a terminal
                //    state.
                //  * COST — the number passed here was `est_cost_usd`, the
                //    WHOLE-TASK appraisal, rendered inches from a per-agent
                //    count where it reads as per-agent spend. The backend
                //    reports no per-agent cost, so the cue now shows none; the
                //    task-level figure keeps its home on the roster header and
                //    the dashboard, where it is labelled as such.
                .set_subagents(self.agents.running_count(), None);
            // CC FleetView `main` root row: synthesize it from live session
            // state (top-level action, turn elapsed, session output tokens). No
            // backend event drives `main` — it is the home node the TUI owns.
            // The `main` row states the GOAL — something no other surface in the
            // live region carries. It used to fall back to a bare "Working…",
            // which merely restated the spinner line's verb and the roster
            // header's "Running N agents…", stacking three headers that all said
            // the same thing. With no goal there is nothing unique to add, so the
            // row stays quiet rather than echoing.
            let activity = match self.goal.as_deref() {
                Some(g) if !g.trim().is_empty() => g.trim().to_string(),
                _ if self.state == AppState::Processing => String::new(),
                _ => "Ready".to_string(),
            };
            let elapsed = if self.state == AppState::Processing {
                self.processing_start
                    .map(|t| t.elapsed().as_secs())
                    .unwrap_or(0)
            } else {
                0
            };
            let tokens = self.status.output_tokens().min(u32::MAX as u64) as u32;
            self.agents.set_main_row(activity, elapsed, tokens);
        } else {
            self.status.set_subagents(0, None);
        }

        // FleetSelect roster focus: mirror the shared selection cursor into the
        // Agents component (for the inline highlight) and flip the footer hint.
        let fleet_select = self.state == AppState::FleetSelect;
        self.status.set_fleet_select(fleet_select);
        self.agents.set_roster_selected(if fleet_select {
            Some(self.agents_dashboard_selected)
        } else {
            None
        });

        if self.permissions.is_active() {
            let since = *self.permission_wait_since.get_or_insert_with(Instant::now);
            if !self.permission_pinged
                && self.notify_on_complete
                && since.elapsed() >= Duration::from_secs(6)
            {
                crate::components::notify::notify("OSA", "Waiting for your permission");
                self.permission_pinged = true;
            }
        } else {
            self.permission_wait_since = None;
            self.permission_pinged = false;
        }
    }

    /// Reconcile the status-line active-goal indicator ("Working on: <goal> ·
    /// 3m 40s") with the live goal state, once per frame. Stamps the goal-active
    /// Instant the first frame a goal is present so the elapsed counts from
    /// activation, and clears it the moment the goal clears so the timer resets
    /// (never leaks across goals). Overrides the plain "goal N/max" label that the
    /// `/goal` command path seeds, so the richer indicator is the single winner.
    pub(crate) fn sync_goal_indicator(&mut self) {
        match self.goal.clone() {
            Some(goal) => {
                let since = *self.goal_activated_at.get_or_insert_with(Instant::now);
                let elapsed = since.elapsed().as_secs();
                self.status
                    .set_goal_label(Some(compose_goal_label(&goal, elapsed)));
            }
            None => {
                // Goal cleared: freeze/reset the timer and drop the chip.
                if self.goal_activated_at.is_some() {
                    self.goal_activated_at = None;
                    self.status.set_goal_label(None);
                }
            }
        }
    }

    /// U-T12 + U-T15 — reconcile the turn-lifecycle side effects (taskbar
    /// progress bar + OS sleep inhibitor) with whether a turn is in flight.
    /// Runs once per event-loop iteration (the 200ms tick guarantees cadence).
    ///
    /// Driving both effects off `turn_is_active()` — rather than hooking every
    /// individual Processing-enter / Idle-return site — keeps them correct across
    /// the ~20 overlays that park a live turn on the return stack, and across
    /// cancels, backend disconnects and errors that end a turn without a plain
    /// `transition(Idle)`. Engaged on the rising edge, released on the falling
    /// edge, and re-asserted (progress keepalive) on a slow cadence so terminals
    /// that time the bar out keep it lit.
    pub(crate) fn sync_turn_effects(&mut self) {
        let active = self.turn_is_active();
        if active {
            if !self.turn_effects_active {
                self.turn_effects_active = true;
                self.inhibitor = Some(crate::notification::SleepInhibitor::begin());
                crate::notification::progress::start();
                self.last_progress_keepalive = Some(Instant::now());
            } else {
                let due = self
                    .last_progress_keepalive
                    .map(|t| t.elapsed() >= Duration::from_secs(3))
                    .unwrap_or(true);
                if due {
                    crate::notification::progress::keepalive();
                    self.last_progress_keepalive = Some(Instant::now());
                }
            }
        } else if self.turn_effects_active {
            self.turn_effects_active = false;
            self.inhibitor = None; // Drop releases the OS inhibitor.
            crate::notification::progress::done();
            self.last_progress_keepalive = None;
        }
    }
}

/// Compose the status-line active-goal chip: `Working on: <goal> · 3m 40s`. The
/// goal text is ellipsized to keep the chip terse on narrow status bars, and the
/// elapsed uses the Codex compact formatter so it counts up smoothly. Pure over
/// its inputs so the composition is unit-testable without an `App` clock.
fn compose_goal_label(goal: &str, elapsed_secs: u64) -> String {
    const MAX_GOAL_CHARS: usize = 40;
    let goal = goal.trim();
    // Head-preserving trim: the start of a goal statement carries the intent, so
    // keep the leading words and append an ellipsis when it overflows.
    // COLUMNS, not chars: a 40-char CJK goal is 80 columns wide and shoves the
    // elapsed-time suffix off the status bar, and a `.chars().take()` cut also
    // splits grapheme clusters (half a flag, a severed emoji ZWJ sequence).
    // `fit_cols` measures true display width and breaks on cluster boundaries.
    let shown = crate::util::fit_cols(goal, MAX_GOAL_CHARS);
    let shown = shown
        .strip_suffix('\u{2026}')
        .map(|h| format!("{}\u{2026}", h.trim_end()))
        .unwrap_or(shown);
    format!(
        "Working on: {} \u{00b7} {}",
        shown,
        crate::components::status_bar::fmt_elapsed_compact(elapsed_secs)
    )
}

pub(super) fn generate_session_id() -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    use std::time::{SystemTime, UNIX_EPOCH};

    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let mut hasher = DefaultHasher::new();
    SystemTime::now().hash(&mut hasher);
    std::process::id().hash(&mut hasher);
    let random = hasher.finish() as u32;
    format!("tui_{}_{:08x}", nanos, random)
}

/// Whether a turn is in flight: either the app is directly `Processing`, or a
/// turn was parked on the return stack when an overlay opened from `Processing`.
/// Pure over its inputs so the streaming/thinking buffer gate is unit-testable.
fn turn_active(state: AppState, return_stack: &[AppState]) -> bool {
    state.is_processing() || return_stack.contains(&AppState::Processing)
}

/// The mutually-exclusive `Option<_>`-backed modal overlays that float above the
/// state machine, in priority order (highest first). A single source of truth so
/// the draw layer (`event_loop::draw`) and the key router (`update::handle_key`)
/// can never disagree about which overlay is on top — the bug where one overlay
/// was DRAWN while a *different* one consumed keystrokes (e.g. a config-editor
/// drawn over an invisible file-picker that ate the keys).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ModalOverlay {
    /// One-time overdrive (full-auto) confirmation — the most modal thing there
    /// is; nothing may run while it awaits yes/no.
    Overdrive,
    ConfigEditor,
    FilePicker,
    Reasoning,
}

/// Pure priority resolver over the four Option-overlay presence flags. Extracted
/// so the draw/key ordering invariant is unit-testable without an `App`. The
/// order here is authoritative: both the draw match and the key match consume it.
pub(crate) fn topmost_modal(
    overdrive: bool,
    config_editor: bool,
    file_picker: bool,
    reasoning: bool,
) -> Option<ModalOverlay> {
    if overdrive {
        Some(ModalOverlay::Overdrive)
    } else if config_editor {
        Some(ModalOverlay::ConfigEditor)
    } else if file_picker {
        Some(ModalOverlay::FilePicker)
    } else if reasoning {
        Some(ModalOverlay::Reasoning)
    } else {
        None
    }
}

#[cfg(test)]
mod turn_active_tests {
    use super::turn_active;
    use crate::app::state::AppState;

    #[test]
    fn processing_is_active() {
        assert!(turn_active(AppState::Processing, &[]));
    }

    #[test]
    fn idle_is_not_active() {
        assert!(!turn_active(AppState::Idle, &[]));
    }

    #[test]
    fn overlay_parked_over_processing_is_active() {
        // /context (ContextBreakdown) opened mid-turn: state is the overlay, the
        // live turn is parked on the return stack. StreamingToken must still be
        // buffered here — this is the exact case the old `is_processing()` gate
        // dropped, losing streamed text while the overlay was up.
        assert!(turn_active(
            AppState::ContextBreakdown,
            &[AppState::Idle, AppState::Processing]
        ));
    }

    #[test]
    fn overlay_over_idle_is_not_active() {
        assert!(!turn_active(
            AppState::ContextBreakdown,
            &[AppState::Idle]
        ));
    }
}

#[cfg(test)]
mod goal_indicator_tests {
    use super::compose_goal_label;

    #[test]
    fn goal_label_shows_goal_and_nonzero_elapsed_once_activated() {
        // Once a goal has been active for a while, the chip names the goal AND a
        // non-zero, compact-formatted elapsed (Codex "Working on: <goal> · Nm Ss").
        let label = compose_goal_label("ship the release", 220);
        assert!(label.starts_with("Working on: ship the release"));
        assert!(label.contains("3m 40s"), "non-zero elapsed must show, got: {label:?}");
        assert!(!label.contains(" 0s "), "activated goal is not frozen at zero");
    }

    #[test]
    fn goal_label_at_activation_reads_zero() {
        // The instant a goal activates the elapsed is 0s — proving the timer
        // counts FROM activation, not some earlier clock.
        let label = compose_goal_label("do the thing", 0);
        assert_eq!(label, "Working on: do the thing \u{00b7} 0s");
    }

    #[test]
    fn goal_label_ellipsizes_long_goals() {
        // A long goal is head-trimmed with an ellipsis so the chip stays terse.
        let long = "a".repeat(80);
        let label = compose_goal_label(&long, 5);
        assert!(label.contains('\u{2026}'), "long goal must be ellipsized");
        assert!(label.ends_with("\u{00b7} 5s"));
    }
}

#[cfg(test)]
mod modal_overlay_tests {
    use super::{topmost_modal, ModalOverlay};

    #[test]
    fn none_when_no_overlay() {
        assert_eq!(topmost_modal(false, false, false, false), None);
    }

    #[test]
    fn overdrive_beats_everything() {
        // Even with all four present, overdrive is the topmost — it is the
        // hard modal that must win draw AND keys.
        assert_eq!(
            topmost_modal(true, true, true, true),
            Some(ModalOverlay::Overdrive)
        );
    }

    #[test]
    fn config_editor_beats_file_picker_and_reasoning() {
        // The regression this locks: draw drew config_editor above file_picker,
        // but the key router routed to file_picker — they must agree, and the
        // single resolver guarantees config_editor wins both.
        assert_eq!(
            topmost_modal(false, true, true, true),
            Some(ModalOverlay::ConfigEditor)
        );
    }

    #[test]
    fn file_picker_beats_reasoning() {
        assert_eq!(
            topmost_modal(false, false, true, true),
            Some(ModalOverlay::FilePicker)
        );
    }

    #[test]
    fn reasoning_alone() {
        assert_eq!(
            topmost_modal(false, false, false, true),
            Some(ModalOverlay::Reasoning)
        );
    }
}

/// Open a URL in the user's default browser, best-effort.
///
/// Deliberately dependency-free: this is three `Command`s, and the failure
/// mode of a browser that will not open is that the user reads the URL off
/// the screen, which they can already do. Errors are swallowed for the same
/// reason — a sign-in must not fail because `xdg-open` is missing, which is
/// the normal state of a container or a bare SSH session.
///
/// The URL is passed as a single argv element, never through a shell, so a
/// hostile verification URL cannot become a command.
pub fn open_in_browser(url: &str) {
    #[cfg(target_os = "macos")]
    let candidates: [&str; 1] = ["open"];
    #[cfg(target_os = "windows")]
    let candidates: [&str; 1] = ["explorer"];
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    let candidates: [&str; 3] = ["xdg-open", "gio", "wslview"];

    let url = url.to_string();
    std::thread::spawn(move || {
        for bin in candidates {
            let mut cmd = std::process::Command::new(bin);
            if bin == "gio" {
                cmd.arg("open");
            }
            let spawned = cmd
                .arg(&url)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn();
            if spawned.is_ok() {
                return;
            }
        }
    });
}
