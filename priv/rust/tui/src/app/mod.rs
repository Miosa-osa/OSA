pub mod attachment;
pub mod commands;
pub mod event_loop;
pub mod focus;
mod handle_actions;
mod handle_backend;
mod handle_dialogs;
pub mod key_normalize;
mod keymap_dispatch;
pub mod keys;
pub mod layout;
pub mod state;
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
use crate::dialogs::permissions::Permissions;
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
    pub permissions: Option<Permissions>,
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

    // Dimensions
    pub width: u16,
    pub height: u16,

    // Config
    pub config: Config,

    // Event channel
    pub event_tx: mpsc::UnboundedSender<Event>,
    pub event_rx: mpsc::UnboundedReceiver<Event>,

    // Processing state
    pub stream_buf: String,
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
    pub sse_reconnecting: bool,

    // Pending tool call args (tool_name -> args JSON), used to pair with ToolCallEnd
    /// Per-tool-name FIFO queue of pending args. A Vec (not a single String) so
    /// several concurrent calls of the SAME tool (e.g. many dir_list) don't
    /// overwrite each other's args — which showed up as tool lines with no path.
    pub pending_tool_args: HashMap<String, Vec<String>>,

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
    /// Consecutive mouse wheel-up ticks accumulated on the inline surface; the
    /// reader only opens once this crosses SCROLL_OPEN_THRESHOLD, so a single
    /// tick can never slam it open. Reset by any wheel-down / click / timeout.
    pub scroll_up_ticks: u8,
    /// Timestamp of the last wheel-up tick, used to time-gate the gesture so
    /// stray ticks spread across a session never accumulate into an open.
    pub last_scroll_up: Option<Instant>,

    // Completion notification: bell / OSC 9 when a turn ends while the user is
    // likely away. `notify_on_complete` toggles it (off via OSA_NO_NOTIFY);
    // `last_user_input` tracks the last keypress for the idle heuristic.
    pub notify_on_complete: bool,
    pub last_user_input: Option<Instant>,

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
        let (init_w, init_h) = crossterm::terminal::size().unwrap_or((80, 24));

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
            agents: Agents::new(),
            toasts: Toasts::new(),

            quit_dialog: QuitConfirm::new(),
            palette: CommandPalette::new(),
            model_picker: None,
            session_browser: None,
            onboarding: None,
            plan_review: None,
            permissions: None,
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

            workspace_name: None,
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

            stream_buf: String::new(),
            thinking_buf: String::new(),
            processing_start: None,
            last_turn_client_elapsed_secs: None,
            last_submitted_prompt: None,
            cancelled: false,
            sse_reconnecting: false,

            pending_tool_args: HashMap::new(),
            collapse: crate::tools::collapse::Accumulator::default(),
            agent_header_sent: false,

            bg_tasks: Vec::new(),
            bg_task_seq: 0,
            bg_shell_count: 0,
            active_fg_shell_count: 0,
            backend_spawn_attempted: false,
            health_retry_count: 0,
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
            attachments: Vec::new(),
            welcome_injected: false,
            dir_session_resolved: false,
            pending_welcome_banner: None,

            transcript_log: Vec::new(),
            transcript: None,
            transcript_override: None,
            scroll_up_ticks: 0,
            last_scroll_up: None,
            notify_on_complete: std::env::var("OSA_NO_NOTIFY").is_err(),
            last_user_input: None,
            chrome_title: crate::components::title::TitleState::new(),
            permission_wait_since: None,
            permission_pinged: false,
            agents_dashboard_selected: 0,
            message_queue: Vec::new(),
            esc_tracker: EscTracker::default(),
            force_redraw: false,
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
        self.input.set_voice_available(self.voice.available);
        self.status.set_width(self.width);
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
        self.chrome_title.update(&title);

        if self.permissions.is_some() {
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
