pub mod attachment;
pub mod commands;
pub mod event_loop;
pub mod focus;
mod handle_actions;
mod handle_backend;
mod handle_dialogs;
pub mod keys;
pub mod layout;
pub mod state;
pub mod update;

use anyhow::Result;
use std::collections::HashMap;
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
use crate::dialogs::file_picker::FilePicker;
use crate::dialogs::model_picker::ModelPicker;
use crate::dialogs::onboarding::OnboardingWizard;
use crate::dialogs::permissions::Permissions;
use crate::dialogs::plan_review::PlanReview;
use crate::dialogs::quit_confirm::QuitConfirm;
use crate::dialogs::reasoning::ReasoningSelector;
use crate::dialogs::sessions::SessionBrowser;
use crate::event::Event;

use self::focus::FocusStack;
use self::keys::KeyMap;
use self::layout::Layout;
use self::state::AppState;
use crate::voice::VoiceState;

/// Constants
pub const HEALTH_RETRY_DELAY: Duration = Duration::from_secs(5);
pub const MAX_MESSAGE_SIZE: usize = 100_000;

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
    pub file_picker: Option<FilePicker>,
    pub survey: Option<crate::dialogs::survey::SurveyDialog>,

    // State
    pub state: AppState,
    pub prev_state: Option<AppState>,
    pub focus: FocusStack,
    pub keys: KeyMap,
    pub layout: Layout,

    // Network
    pub client: Arc<ApiClient>,
    pub sse_cancel: Option<CancellationToken>,

    // Session
    pub session_id: String,
    pub working_dir: String,

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
    pub last_cancel_attempt: Option<Instant>,
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

    // Background tasks
    pub bg_tasks: Vec<String>,

    // Backend auto-start
    pub backend_spawn_attempted: bool,
    pub health_retry_count: u32,

    // Commands from backend
    pub command_entries: Vec<crate::client::types::CommandEntry>,

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

    // Completion notification: bell / OSC 9 when a turn ends while the user is
    // likely away. `notify_on_complete` toggles it (off via OSA_NO_NOTIFY);
    // `last_user_input` tracks the last keypress for the idle heuristic.
    pub notify_on_complete: bool,
    pub last_user_input: Option<Instant>,

    // Background-agent dashboard (AppState::AgentsDashboard): index of the
    // currently-selected agent row, for cancel targeting.
    pub agents_dashboard_selected: usize,
}

impl App {
    pub async fn new(config: Config, _cli: Cli) -> Result<Self> {
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

        // Seed the status-line permission mode from --dangerously-skip-permissions.
        let mut status = StatusBar::new();
        if config.skip_permissions {
            status.set_permission_mode(
                crate::components::status_bar::PermissionMode::BypassPermissions,
            );
        }

        Ok(Self {
            header: Header::new(),
            chat: Chat::new(),
            input: InputComponent::new(),
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
            file_picker: None,
            survey: None,

            state: AppState::Connecting,
            prev_state: None,
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
            last_cancel_attempt: None,
            cancelled: false,
            sse_reconnecting: false,

            pending_tool_args: HashMap::new(),
            collapse: crate::tools::collapse::Accumulator::default(),
            agent_header_sent: false,

            bg_tasks: Vec::new(),
            backend_spawn_attempted: false,
            health_retry_count: 0,
            command_entries: Vec::new(),

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
            notify_on_complete: std::env::var("OSA_NO_NOTIFY").is_err(),
            last_user_input: None,
            agents_dashboard_selected: 0,
        })
    }

    /// True when the app wants a full-height alternate-screen viewport (dialogs,
    /// connecting, onboarding, file picker) instead of the inline live region.
    pub fn wants_full_viewport(&self) -> bool {
        self.state.is_overlay()
            || self.state.is_fullscreen()
            || self.file_picker.is_some()
            || self.transcript.is_some()
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
            self.last_cancel_attempt = None;
        }
        // Dismiss the file picker on any state transition — prevents the invisible
        // overlay from silently intercepting keystrokes when the app changes context.
        if self.file_picker.is_some() {
            self.file_picker = None;
        }
        self.prev_state = Some(self.state);
        self.state = target;
        // Reset quit dialog focus to Cancel (safe default) each time the dialog opens.
        if target == AppState::Quit {
            self.quit_dialog.reset();
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
