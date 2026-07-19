use crossterm::event::{
    Event as CrosstermEvent, KeyCode, KeyEventKind, KeyModifiers,
};
use tracing::warn;

use super::App;
use crate::app::state::AppState;
use crate::components::{AppAction, Component, ComponentAction};
use crate::event::Event;

/// Max whitespace-separated tokens `paste_is_file_paths` will stat before
/// giving up and treating the paste as ordinary text. Bounds UI-thread disk I/O
/// on a large paste and stops a long prose line from being probed word by word.
const MAX_PATH_TOKENS: usize = 8;

/// Strip one matching pair of surrounding quotes (mirrors attachment.rs so the
/// path gate and attachment ingestion agree on what a path token is).
fn unquote_path(s: &str) -> &str {
    let s = s.trim();
    for q in ['\'', '"'] {
        if s.len() >= 2 && s.starts_with(q) && s.ends_with(q) {
            return &s[1..s.len() - 1];
        }
    }
    s
}

/// Undo the shell-style escaping a terminal applies to dropped paths
/// ("my\\ file" -> "my file"), mirroring attachment.rs.
fn unescape_path(s: &str) -> String {
    s.replace("\\ ", " ").replace("\\\\", "\\")
}

/// A token is worth stat'ing only when it *looks* like a filesystem path:
/// absolute (`/…`), explicitly relative (`./`, `../`), home (`~`), a Windows
/// drive path (`C:\…` / `C:/…`), or a UNC path (`\\…`). A bare word like
/// `Cargo.toml` or `src` never qualifies, so ordinary prose whose words happen
/// to name files on disk is inserted as text instead of being hijacked into
/// attachment chips — and, crucially, does NO filesystem I/O at all.
fn looks_like_path(tok: &str) -> bool {
    let t = tok.trim();
    if t.is_empty() {
        return false;
    }
    if t.starts_with('/')
        || t.starts_with("./")
        || t.starts_with("../")
        || t.starts_with('~')
        || t.starts_with("\\\\")
    {
        return true;
    }
    // Windows drive-letter path: `C:\` or `C:/`.
    let b = t.as_bytes();
    b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && (b[2] == b'\\' || b[2] == b'/')
}

/// Normalize a token the way attachment ingestion does (strip surrounding
/// quotes, undo `\\ ` escaping) and return it ONLY when it looks like a path.
/// Bare words return None so they never trigger a stat.
fn path_candidate(tok: &str) -> Option<String> {
    let unq = unquote_path(tok);
    if !looks_like_path(unq) {
        return None;
    }
    Some(unescape_path(unq))
}

/// True only when a pasted string is entirely one-or-more existing filesystem
/// paths (drag-drop of files or a copied path), as opposed to ordinary text.
/// Ordinary prose — even prose that happens to contain a word matching a
/// filename — returns false so it is inserted as text rather than hijacked into
/// an attachment chip. De-risked: a token must LOOK like a path (see
/// `looks_like_path`) before any `exists()` stat, and at most `MAX_PATH_TOKENS`
/// tokens are probed, so a large prose paste can never stall the UI thread on
/// disk I/O nor be silently turned into attachments.
pub(crate) fn paste_is_file_paths(text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return false;
    }
    // Whole paste is a single (optionally quoted) path — handles paths that
    // contain spaces. Only stat it when it looks like a path.
    if let Some(p) = path_candidate(trimmed) {
        if std::path::Path::new(&p).exists() {
            return true;
        }
    }
    // Otherwise every whitespace-separated token must look like a path AND
    // exist (multi-file drag-drop), bounded to MAX_PATH_TOKENS stats.
    let tokens: Vec<&str> = trimmed.split_whitespace().collect();
    if tokens.is_empty() || tokens.len() > MAX_PATH_TOKENS {
        return false;
    }
    for tok in tokens {
        match path_candidate(tok) {
            Some(p) if std::path::Path::new(&p).exists() => {}
            _ => return false,
        }
    }
    true
}

/// True only for the two keys that dismiss a read-only overlay: Esc, or an
/// unmodified `q`. Enter/Space/other keys (and Ctrl/Alt-chorded `q`) return
/// false so a stray keypress — or key-noise a terminal emits when a click is
/// delivered as a degraded mouse report — can never close a read-only surface.
fn is_overlay_dismiss(key: crossterm::event::KeyEvent) -> bool {
    matches!(
        (key.code, key.modifiers),
        (KeyCode::Esc, _) | (KeyCode::Char('q'), KeyModifiers::NONE)
    )
}

impl App {
    /// Main update function. Returns true if the app should quit.
    pub fn update(&mut self, event: Event) -> bool {
        match event {
            Event::Terminal(CrosstermEvent::Resize(w, h)) => {
                self.width = w;
                self.height = h;
                self.recompute_layout();
                false
            }
            Event::Terminal(CrosstermEvent::Key(key))
                if key.kind == KeyEventKind::Press =>
            {
                self.handle_key(key)
            }
            Event::Terminal(CrosstermEvent::Key(_)) => false, // ignore Release/Repeat
            // Mouse capture is intentionally NOT enabled (see main.rs): OSA leaves
            // the wheel to the terminal so scroll-up/down drives native scrollback,
            // matching Claude Code. crossterm's EnableMouseCapture is all-or-nothing
            // — it steals the wheel too, and the app cannot drive the terminal's
            // native scrollback, so there is no clean "click positions the caret
            // while the wheel still scrolls the terminal" with crossterm. We chose
            // native scroll; the caret is positioned with keys, voice with Alt+V,
            // and finalized history is re-read with the Ctrl+O transcript reader.
            // No mouse events are delivered here, but keep an explicit no-op arm so
            // a stray report (e.g. if a terminal sends one unsolicited) is dropped.
            Event::Terminal(CrosstermEvent::Mouse(_)) => false,
            Event::Terminal(CrosstermEvent::Paste(text)) => {
                // Route paste to onboarding wizard if active
                if self.state == AppState::Onboarding {
                    if let Some(ref mut wizard) = self.onboarding {
                        wizard.handle_paste(&text);
                    }
                } else if self.state == AppState::ModelPicker
                    && self
                        .model_picker
                        .as_ref()
                        .map(|p| p.is_key_entry())
                        .unwrap_or(false)
                {
                    // Paste-friendly API key entry on the picker's key screen.
                    if let Some(ref mut picker) = self.model_picker {
                        picker.handle_paste(&text);
                    }
                } else if self.state.allows_input() {
                    // Route through the single shared paste path so terminal
                    // bracketed paste and Ctrl+V clipboard paste behave
                    // identically (WS9 parity).
                    self.insert_paste_text(&text);
                }
                false
            }
            Event::Terminal(_) => false,
            Event::Backend(backend_event) => self.handle_backend_event(backend_event),
            Event::Voice(voice_event) => {
                self.handle_voice_event(voice_event);
                false
            }
            Event::Tick => {
                self.handle_tick();
                false
            }
            Event::HealthRetry => {
                self.check_health();
                false
            }
        }
    }

    /// The single shared paste path (WS9 parity): terminal bracketed paste and
    /// Ctrl+V clipboard paste both route here so they behave identically. A
    /// paste that is entirely existing file path(s) becomes attachment chips;
    /// otherwise the text is ANSI-stripped/CRLF-normalized, char-boundary
    /// capped, and inserted (large pastes collapse into a pill via insert_paste).
    pub(crate) fn insert_paste_text(&mut self, text: &str) {
        if paste_is_file_paths(text) && self.ingest_paste_as_attachments(text) {
            return;
        }
        let normalized = crate::components::input::normalize_paste(text);
        let capped = crate::util::truncate_str(&normalized, super::MAX_MESSAGE_SIZE);
        self.input.insert_paste(capped);
        self.recompute_layout();
    }

    fn handle_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        // Floating Option-overlays take key priority over the base state machine,
        // in the SAME order the draw layer paints them (see
        // `App::active_modal_overlay` / `event_loop::draw`). Routing here and
        // painting there both consume the one resolver, so the overlay drawn on
        // top is always the overlay that receives the keys — the previous hand-
        // maintained chains disagreed (config-editor drawn over file-picker while
        // file-picker ate the keys).
        if let Some(modal) = self.active_modal_overlay() {
            use crate::app::ModalOverlay;
            return match modal {
                ModalOverlay::Overdrive => self.handle_overdrive_confirm_key(key),
                ModalOverlay::ConfigEditor => self.handle_config_editor_key(key),
                ModalOverlay::FilePicker => self.handle_file_picker_key(key),
                ModalOverlay::Reasoning => self.handle_reasoning_key(key),
            };
        }

        match self.state {
            AppState::Quit => self.handle_quit_dialog_key(key),
            AppState::Palette => self.handle_palette_key(key),
            AppState::ModelPicker => self.handle_model_picker_key(key),
            AppState::Sessions => self.handle_session_browser_key(key),
            AppState::Rewind => self.handle_rewind_key(key),
            AppState::Onboarding => self.handle_onboarding_key(key),
            AppState::PlanReview => self.handle_plan_review_key(key),
            AppState::Permissions => self.handle_permissions_key(key),
            AppState::Survey => self.handle_survey_key(key),
            AppState::Idle => self.handle_idle_key(key),
            AppState::Processing => self.handle_processing_key(key),
            AppState::Recording => self.handle_recording_key(key),
            AppState::AgentsDashboard => self.handle_agents_dashboard_key(key),
            AppState::Status => self.handle_status_dashboard_key(key),
            AppState::ThemePicker => self.handle_theme_picker_key(key),
            AppState::Keybindings => self.handle_keybindings_key(key),
            AppState::Tools => self.handle_tools_browser_key(key),
            AppState::ContextBreakdown => self.handle_context_breakdown_key(key),
            AppState::Trust => self.handle_trust_key(key),
            AppState::PermissionsManager => {
                use crate::dialogs::permissions_manager::PermissionsAction;
                if matches!(
                    self.permissions_manager.as_mut().map(|d| d.handle_key(key)),
                    Some(PermissionsAction::Close)
                ) {
                    self.permissions_manager = None;
                    self.exit_overlay();
                }
                false
            }
            AppState::Hooks => {
                use crate::dialogs::hooks_viewer::HooksViewerAction;
                if matches!(
                    self.hooks_viewer.as_mut().map(|d| d.handle_key(key)),
                    Some(HooksViewerAction::Close)
                ) {
                    self.hooks_viewer = None;
                    self.exit_overlay();
                }
                false
            }
            AppState::Mcp => {
                use crate::dialogs::mcp_servers::McpServersAction;
                if matches!(
                    self.mcp_servers.as_mut().map(|d| d.handle_key(key)),
                    Some(McpServersAction::Close)
                ) {
                    self.mcp_servers = None;
                    self.exit_overlay();
                }
                false
            }
            AppState::Cost => {
                use crate::dialogs::cost_dashboard::CostDashboardAction;
                if matches!(
                    self.cost_dashboard.as_mut().map(|d| d.handle_key(key)),
                    Some(CostDashboardAction::Close)
                ) {
                    self.cost_dashboard = None;
                    self.exit_overlay();
                }
                false
            }
            AppState::Skills => {
                use crate::dialogs::skills_browser::SkillsBrowserAction;
                if matches!(
                    self.skills_browser.as_mut().map(|d| d.handle_key(key)),
                    Some(SkillsBrowserAction::Close)
                ) {
                    self.skills_browser = None;
                    self.exit_overlay();
                }
                false
            }
            AppState::Channels => {
                use crate::dialogs::channels_panel::ChannelsPanelAction;
                if matches!(
                    self.channels_panel.as_mut().map(|d| d.handle_key(key)),
                    Some(ChannelsPanelAction::Close)
                ) {
                    self.channels_panel = None;
                    self.exit_overlay();
                }
                false
            }
            AppState::Memory => {
                use crate::dialogs::memory_browser::MemoryBrowserAction;
                if matches!(
                    self.memory_browser.as_mut().map(|d| d.handle_key(key)),
                    Some(MemoryBrowserAction::Close)
                ) {
                    self.memory_browser = None;
                    self.exit_overlay();
                }
                false
            }
            AppState::Metrics => {
                use crate::dialogs::metrics_dashboard::MetricsAction;
                if matches!(
                    self.metrics_dashboard.as_mut().map(|d| d.handle_key(key)),
                    Some(MetricsAction::Close)
                ) {
                    self.metrics_dashboard = None;
                    self.exit_overlay();
                }
                false
            }
            AppState::Tasks => {
                use crate::dialogs::tasks_panel::TasksPanelAction;
                if matches!(
                    self.tasks_panel.as_mut().map(|d| d.handle_key(key)),
                    Some(TasksPanelAction::Close)
                ) {
                    self.tasks_panel = None;
                    self.exit_overlay();
                }
                false
            }
            AppState::Persona => {
                use crate::dialogs::persona_picker::PersonaPickerAction;
                match self.persona_picker.as_mut().map(|d| d.handle_key(key)) {
                    Some(PersonaPickerAction::Apply(name)) => {
                        self.persona_picker = None;
                        self.exit_overlay();
                        self.execute_backend_command("persona", &name);
                    }
                    Some(PersonaPickerAction::Close) => {
                        self.persona_picker = None;
                        self.exit_overlay();
                    }
                    _ => {}
                }
                false
            }
            AppState::Sandbox => {
                use crate::dialogs::sandbox_picker::SandboxAction;
                match self.sandbox_picker.as_mut().and_then(|d| d.handle_key(key)) {
                    Some(SandboxAction::Apply(name)) => {
                        self.sandbox_picker = None;
                        self.exit_overlay();
                        self.execute_backend_command("sandbox", &name);
                    }
                    Some(SandboxAction::Close) => {
                        self.sandbox_picker = None;
                        self.exit_overlay();
                    }
                    _ => {}
                }
                false
            }
            _ => false,
        }
    }

    /// `/trust` dialog: Accept persists trust for the workspace via the backend
    /// (POST /workspace/trust/accept) and closes; decline just closes (the
    /// on-demand command never force-quits the app, unlike a startup gate).
    fn handle_trust_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        use crate::dialogs::trust::TrustAction;
        let action = self.trust_dialog.as_mut().and_then(|d| d.handle_key(key));
        match action {
            Some(TrustAction::Accept) => {
                let path = self
                    .trust_dialog
                    .as_ref()
                    .map(|d| d.cwd.clone())
                    .unwrap_or_default();
                let client = self.client.clone();
                tokio::spawn(async move {
                    let _ = client.accept_trust(&path).await;
                });
                self.toasts.push(
                    "Workspace trusted".into(),
                    crate::components::toast::ToastLevel::Info,
                );
                self.trust_dialog = None;
                self.exit_overlay();
                false
            }
            Some(TrustAction::Exit) => {
                self.trust_dialog = None;
                self.exit_overlay();
                false
            }
            None => false,
        }
    }

    /// `/theme` picker: ↑/↓ move, Enter applies the highlighted theme (persists
    /// + repaints live), Esc closes without changing the theme.
    fn handle_theme_picker_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        use crate::dialogs::theme_picker::ThemeAction;
        let action = self.theme_picker.as_mut().and_then(|d| d.handle_key(key));
        match action {
            Some(ThemeAction::Apply(name)) => {
                if let Some(theme) = crate::style::themes::by_name(&name) {
                    self.config.theme = name.clone();
                    let _ = self.config.save();
                    crate::style::set_theme(theme);
                    self.toasts.push(
                        format!("Theme: {name}"),
                        crate::components::toast::ToastLevel::Info,
                    );
                }
                self.theme_picker = None;
                self.exit_overlay();
                false
            }
            Some(ThemeAction::Close) => {
                self.theme_picker = None;
                self.exit_overlay();
                false
            }
            None => false,
        }
    }

    /// `/keybindings` viewer: scroll keys handled inside; Esc/q close.
    fn handle_keybindings_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        use crate::dialogs::keybindings_viewer::ViewerAction;
        let action = self
            .keybindings_viewer
            .as_mut()
            .map(|d| d.handle_key(key))
            .unwrap_or(ViewerAction::Close);
        if matches!(action, ViewerAction::Close) {
            self.keybindings_viewer = None;
            self.exit_overlay();
        }
        false
    }

    /// `/tools` browser: type-to-filter + navigation handled inside; the
    /// browser signals Close (Esc on an empty filter).
    fn handle_tools_browser_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        use crate::dialogs::tools_browser::ToolsBrowserAction;
        let action = self
            .tools_browser
            .as_mut()
            .map(|d| d.handle_key(key))
            .unwrap_or(ToolsBrowserAction::Close);
        if matches!(action, ToolsBrowserAction::Close) {
            self.tools_browser = None;
            self.exit_overlay();
        }
        false
    }

    /// `/context` breakdown: read-only. Only Esc or an unmodified 'q' dismiss it
    /// — Enter, Space, and every other key are swallowed so a stray keypress (or
    /// key noise from a click when mouse capture is degraded) can never close it.
    fn handle_context_breakdown_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        if is_overlay_dismiss(key) {
            self.context_stats = None;
            self.exit_overlay();
        }
        false
    }

    /// Key handling for the `/status` dashboard. Read-only, no navigation: only
    /// Esc or an unmodified 'q' close it; Enter/Space/other keys are swallowed
    /// so a stray keypress (or click key-noise) can never dismiss it.
    fn handle_status_dashboard_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        if is_overlay_dismiss(key) {
            self.exit_overlay();
        }
        false
    }

    /// Key handling for the full-screen management dashboard.
    /// ↑/↓ (and j/k) move the selection across sub-agents then background
    /// terminals, Enter/v views the selected item, c/x stops it, Esc/q close.
    fn handle_agents_dashboard_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        let count = self.dashboard_item_count();
        match (key.code, key.modifiers) {
            (KeyCode::Esc, _) | (KeyCode::Char('q'), KeyModifiers::NONE) => {
                self.close_agents_dashboard();
            }
            (KeyCode::Up, _) | (KeyCode::Char('k'), KeyModifiers::NONE) => {
                if count > 0 && self.agents_dashboard_selected > 0 {
                    self.agents_dashboard_selected -= 1;
                }
            }
            (KeyCode::Down, _) | (KeyCode::Char('j'), KeyModifiers::NONE) => {
                if count > 0 && self.agents_dashboard_selected + 1 < count {
                    self.agents_dashboard_selected += 1;
                }
            }
            (KeyCode::Enter, _) | (KeyCode::Char('v'), KeyModifiers::NONE) => {
                if count > 0 {
                    self.view_selected_dashboard_item();
                }
            }
            (KeyCode::Char('c'), KeyModifiers::NONE)
            | (KeyCode::Char('x'), KeyModifiers::NONE) => {
                if count > 0 {
                    self.stop_selected_dashboard_item();
                }
            }
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => {
                self.close_agents_dashboard();
            }
            _ => {}
        }
        false
    }

    /// Advance the tool-permission mode one step (Shift+Tab). OSA's cycle is
    /// `ask → auto-edit → plan → overdrive (full auto) → ask`.
    ///
    /// Every transition notifies the backend (`permission_mode <token>`) so its
    /// enforcement tracks the displayed mode. Entering **overdrive** the first
    /// time on this install pops a red confirm dialog (reusing the QuitConfirm
    /// pattern); once acknowledged it enters directly. Overdrive keeps
    /// `config.skip_permissions`, the sidebar indicator, and the backend
    /// `dangerous_mode` toggle in lockstep so it converges with `/yolo`.
    pub(crate) fn cycle_permission_mode(&mut self) {
        let prev = self.status.permission_mode();
        let next = prev.next();

        // Entering overdrive: gate behind a one-time confirmation.
        if next.is_overdrive() {
            if self.overdrive_acked() {
                self.enter_overdrive();
            } else {
                // Park the request behind the confirm dialog; keep the current
                // mode on screen until the user decides.
                self.overdrive_prev_mode = prev;
                self.overdrive_confirm =
                    Some(crate::dialogs::overdrive_confirm::OverdriveConfirm::new());
            }
            return;
        }

        // Leaving overdrive: clear the bypass state + tell the backend.
        if prev.is_overdrive() {
            self.config.skip_permissions = false;
            self.sidebar.set_yolo_mode(false);
            self.spawn_backend_command("dangerous_mode", "off");
        }

        self.status.set_permission_mode(next);
        self.spawn_backend_command("permission_mode", next.backend_token());
        self.toasts.push(
            format!("Permission mode: {}", next.title()),
            crate::components::toast::ToastLevel::Info,
        );
        self.announce_a11y(&format!("permission mode: {}", next.short_title()));
    }

    /// Commit to overdrive (full auto): mode + bypass flag + sidebar + backend
    /// `dangerous_mode on`, with a loud red warning toast. Shared by the
    /// confirm-accept path and the already-acked fast path.
    pub(crate) fn enter_overdrive(&mut self) {
        use crate::components::status_bar::PermissionMode;
        self.status.set_permission_mode(PermissionMode::BypassPermissions);
        self.config.skip_permissions = true;
        self.sidebar.set_yolo_mode(true);
        self.spawn_backend_command("dangerous_mode", "on");
        self.spawn_backend_command("permission_mode", "overdrive");
        self.toasts.push(
            "Overdrive (full auto) ON — every tool runs without prompts".into(),
            crate::components::toast::ToastLevel::Warning,
        );
        self.announce_a11y("permission mode: overdrive full auto, no prompts");
    }

    /// Path to the one-shot overdrive acknowledgement marker (per install/profile).
    fn overdrive_ack_path(&self) -> std::path::PathBuf {
        self.config.profile_dir.join(".overdrive_ack")
    }

    /// Whether the user has already confirmed overdrive once on this install.
    pub(crate) fn overdrive_acked(&self) -> bool {
        self.overdrive_ack_path().exists()
    }

    /// Persist the overdrive acknowledgement so the confirm only shows once.
    fn set_overdrive_acked(&self) {
        let path = self.overdrive_ack_path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(path, b"acknowledged\n");
    }

    /// Handle a key while the overdrive confirmation overlay is open.
    fn handle_overdrive_confirm_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        if let Some(dialog) = self.overdrive_confirm.as_mut() {
            if let Some(decision) = dialog.handle_key(key) {
                self.overdrive_confirm = None;
                if decision {
                    self.set_overdrive_acked();
                    self.enter_overdrive();
                } else {
                    // Cancelled — revert to whatever mode was active before.
                    let prev = self.overdrive_prev_mode;
                    self.status.set_permission_mode(prev);
                    self.toasts.push(
                        "Overdrive cancelled".into(),
                        crate::components::toast::ToastLevel::Info,
                    );
                }
            }
        }
        false
    }

    /// Fire-and-forget backend command that must NOT disturb the UI state
    /// (unlike `execute_backend_command`, which flips into Processing). Used for
    /// lightweight mode toggles on every Shift+Tab.
    pub(crate) fn spawn_backend_command(&self, command: &str, arg: &str) {
        let client = self.client.clone();
        let session_id = self.session_id.clone();
        let req = crate::client::types::CommandExecuteRequest {
            command: command.to_string(),
            arg: arg.to_string(),
            session_id,
        };
        tokio::spawn(async move {
            let _ = client.execute_command(&req).await;
        });
    }

    /// Ctrl+Z — suspend the TUI to the shell (SIGTSTP). Terminal modes are
    /// restored to cooked first; when the user runs `fg` (SIGCONT) execution
    /// resumes on the next line, raw mode + protocols are re-enabled and a
    /// full repaint is forced. Mirrors the mode save/restore already proven in
    /// `InputComponent::open_in_editor`.
    #[cfg(unix)]
    pub(crate) fn suspend_to_shell(&mut self) {
        use crossterm::event::{
            DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste,
            KeyboardEnhancementFlags, PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
        };
        use crossterm::execute;
        use crossterm::terminal::{
            disable_raw_mode, enable_raw_mode, supports_keyboard_enhancement,
        };
        let mut out = std::io::stdout();
        let _ = execute!(
            out,
            PopKeyboardEnhancementFlags,
            DisableBracketedPaste,
            DisableMouseCapture
        );
        let _ = disable_raw_mode();
        // Stop this process; the parent shell shows its job-control prompt.
        // Execution continues below after `fg` delivers SIGCONT.
        let _ = unsafe { libc::raise(libc::SIGTSTP) };
        let _ = enable_raw_mode();
        // No mouse capture — keep the terminal's native scrollback (see main.rs).
        let _ = execute!(out, EnableBracketedPaste);
        // U-B3 — re-push the kitty keyboard protocol on resume. Trust the runtime
        // probe when it gives a definitive answer, else fall back to env detection
        // so a kitty-family terminal reached through tmux/SSH (which the runtime
        // probe misreports) keeps Shift+Enter working across suspend/resume.
        if crate::notification::kitty::should_repush_kitty_protocol(
            supports_keyboard_enhancement().ok(),
        ) {
            let _ = execute!(
                out,
                PushKeyboardEnhancementFlags(
                    KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES
                )
            );
        }
        self.force_redraw = true;
    }

    /// Non-unix fallback: no job control — say so instead of dying silently.
    #[cfg(not(unix))]
    pub(crate) fn suspend_to_shell(&mut self) {
        self.toasts.push(
            "Suspend (Ctrl+Z) is not supported on this platform".into(),
            crate::components::toast::ToastLevel::Info,
        );
    }

    /// `#` memory quick-add: a leading '#' in the composer captures the rest of
    /// the line straight to memory without consuming a turn (CC's `# note`
    /// quick-capture, mirroring the '!' shell branch). Fire-and-forget so it
    /// never changes app state — the same backend "memory" command the
    /// `/memory save` subcommand uses, plus an immediate confirmation toast.
    pub(crate) fn memory_quick_add(&mut self, note: &str) {
        let note = note.trim();
        if note.is_empty() {
            self.toasts.push(
                "Usage: # <note to remember>".into(),
                crate::components::toast::ToastLevel::Warning,
            );
            return;
        }
        let client = self.client.clone();
        let session_id = self.session_id.clone();
        let arg = format!("save {note}");
        tokio::spawn(async move {
            let req = crate::client::types::CommandExecuteRequest {
                command: "memory".to_string(),
                arg,
                session_id,
            };
            if let Err(e) = client.execute_command(&req).await {
                tracing::warn!("memory quick-add failed: {}", e);
            }
        });
        self.toasts.push(
            format!("Saved to memory: {note}"),
            crate::components::toast::ToastLevel::Success,
        );
    }

    /// Send a key straight to the composer, then apply the standard post-edit
    /// bookkeeping: layout recompute, submit / '#' memory routing, orphan prune.
    /// Shared by the vim first-refusal path (both Idle and Processing).
    fn route_composer_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        let action = self
            .input
            .handle_event(&Event::Terminal(CrosstermEvent::Key(key)));
        self.recompute_layout();
        match action {
            ComponentAction::Emit(AppAction::Submit(text)) => {
                if let Some(note) = text.strip_prefix('#') {
                    self.memory_quick_add(note);
                } else {
                    self.submit_input(&text);
                }
            }
            _ => self.prune_orphaned_attachments(),
        }
        false
    }

    fn handle_idle_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        // Vim modal layer gets first refusal on keys when enabled, so Esc and
        // Normal-mode motions aren't stolen by the app-level Esc chord. A no-op
        // when vim is disabled (never interferes with the default bindings).
        //
        // EXCEPTION: Shift+Tab (BackTab) is the permission-mode cycle, not a vim
        // motion. In Normal mode `vim_wants_key` claims every NONE/SHIFT key, so
        // it would swallow BackTab into `handle_vim_normal_key`'s `_ => {}` and
        // the mode cycle became unreachable in vim. Let it fall through to the
        // cycle check below.
        if self.input.vim_wants_key(&key) && !crate::app::keys::is_permission_cycle(&key) {
            return self.route_composer_key(key);
        }

        // Any non-Esc key breaks a pending double-Esc pair so a stale first Esc
        // can never combine with a much later one.
        if key.code != KeyCode::Esc {
            self.esc_tracker.reset();
        }

        // Shift+Tab cycles the tool-permission mode (Default → AcceptEdits →
        // Plan → BypassPermissions → Default), matching Claude Code.
        if crate::app::keys::is_permission_cycle(&key) {
            self.cycle_permission_mode();
            return false;
        }

        let input_empty = self.input.is_empty();

        // WS10 — consult the user-configurable keybinding map first. Esc never
        // enters the resolver: its double-press semantics are context-sensitive
        // and non-rebindable. A match consumes the key; a decline falls through
        // to the remaining hardcoded arms and the composer.
        if key.code != KeyCode::Esc {
            if let Some(quit) =
                self.resolve_keymap(crate::config::keybindings::Context::Idle, key)
            {
                return quit;
            }
        }

        match (key.code, key.modifiers) {
            // Esc — time-gated double-press chord (800ms). A single Esc never
            // destroys a draft: it only hints. Double Esc with text clears the
            // composer (with a toast) and pushes the cleared draft into input
            // history so ↑ restores it; double Esc on an empty composer opens
            // the rewind / jump-to-previous-message picker (Claude Code's
            // "press esc twice to go up a few messages"). The @-file dropdown,
            // when open, gets the Esc first (dismiss) and never starts a chord.
            (KeyCode::Esc, _) => {
                if self.input.file_search_active() {
                    self.input
                        .handle_event(&Event::Terminal(CrosstermEvent::Key(key)));
                    self.esc_tracker.reset();
                    return false;
                }
                // The `/`-command completions popup, like the @-dropdown, gets
                // the Esc first: dismiss it and never start the double-Esc chord
                // (which would otherwise clear the whole `/…` draft on a 2nd Esc).
                if self.input.completions_visible() {
                    self.input.dismiss_completions();
                    self.esc_tracker.reset();
                    return false;
                }
                // WS5 — queued messages pending at Idle (e.g. after an
                // interrupt): Esc pops them into the composer for editing (CC
                // CancelRequestHandler priority 2) instead of starting the
                // clear / rewind chord.
                if !self.message_queue.is_empty() {
                    self.pop_queue_to_composer();
                    self.esc_tracker.reset();
                    return false;
                }
                let now = std::time::Instant::now();
                if self.esc_tracker.press(now) {
                    if input_empty {
                        // Double-Esc on an empty composer → rewind picker.
                        self.load_rewind_checkpoints();
                    } else {
                        // Double-Esc with a draft → clear it, pushing it into
                        // input history first so ↑ (or Ctrl+R) restores it.
                        self.input.clear_to_history();
                        self.prune_orphaned_attachments();
                        self.recompute_layout();
                        self.toasts.push(
                            "Input cleared \u{2014} press \u{2191} to restore it".into(),
                            crate::components::toast::ToastLevel::Info,
                        );
                    }
                } else if !input_empty {
                    self.toasts.push(
                        "Press Esc again to clear".into(),
                        crate::components::toast::ToastLevel::Info,
                    );
                } else {
                    self.toasts.push(
                        "Press Esc again to edit a previous message".into(),
                        crate::components::toast::ToastLevel::Info,
                    );
                }
                false
            }
            // ? on empty input — open the keyboard-shortcut / help overlay
            // (Claude Code '?'). With text already present it inserts a literal
            // '?' via the composer (the fall-through arm), so typing a question
            // mark mid-message still works.
            (KeyCode::Char('?'), m)
                if input_empty
                    && (m == KeyModifiers::NONE || m == KeyModifiers::SHIFT) =>
            {
                self.show_help();
                false
            }
            (KeyCode::Char('c'), KeyModifiers::CONTROL) if input_empty => {
                self.enter_overlay(AppState::Quit);
                false
            }
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => {
                self.input.reset();
                false
            }
            (KeyCode::Char('d'), KeyModifiers::CONTROL) if input_empty => true,
            // F1 help, Alt+V voice, F9 hands-free, Ctrl+N new-session and
            // Ctrl+Z suspend moved to the keybinding map (resolve_keymap
            // above) so they are user-rebindable via ~/.osa/keybindings.json.
            // Ctrl+V clipboard paste, Ctrl+Shift+L sidebar, Ctrl+L redraw and
            // Ctrl+K palette moved to the keybinding map (resolve_keymap
            // above). Ctrl+K with a non-empty composer falls through to the
            // composer's kill-to-end-of-line; paste lives in
            // App::paste_from_clipboard (keymap_dispatch.rs).
            // / on empty input — type '/' into input to trigger inline completions
            (KeyCode::Char('/'), KeyModifiers::NONE) if input_empty => {
                self.input
                    .handle_event(&Event::Terminal(CrosstermEvent::Key(key)));
                false
            }
            // Ctrl+O expand/collapse moved to the keybinding map
            // (chat:expandTools via resolve_keymap above).
            // Chat scrolling is delegated to the host terminal's native
            // scrollback (mouse wheel / terminal keybindings). `j`/`k`/`u`/`d`,
            // Page/Home/End fall through to the input editor.
            (KeyCode::Char('y'), KeyModifiers::NONE) if input_empty => {
                self.copy_last_message();
                false
            }
            // Ctrl+R always reaches the composer's reverse-i-search — even from
            // an empty composer. (The old empty-composer steal expanded the last
            // tool result; that affordance stays on Ctrl+O.)
            // ↓ on an empty composer opens the agent/background dashboard —
            // Claude Code's "↓ to manage". Only intercepted when there are tracked
            // agents to manage and no @-file dropdown is open, so it never steals
            // the composer's history navigation while typing.
            (KeyCode::Down, KeyModifiers::NONE)
                if input_empty
                    && !self.input.file_search_active()
                    && self.has_dashboard_items() =>
            {
                self.open_agents_dashboard();
                false
            }
            // '@' is handled inline by the composer (fuzzy file/dir mention
            // dropdown) — let it fall through to the input rather than opening a
            // separate modal, so the path is inserted in place.
            _ => {
                let action =
                    self.input
                        .handle_event(&Event::Terminal(CrosstermEvent::Key(key)));
                // The input may have grown or shrunk (Shift+Enter newline, paste,
                // clear) — recompute so the box height tracks the content instead
                // of staying stuck at its previous size.
                self.recompute_layout();
                match action {
                    ComponentAction::Emit(AppAction::Submit(text)) => {
                        // '#' quick-adds to memory without a turn; everything
                        // else routes through the normal submit path.
                        if let Some(note) = text.strip_prefix('#') {
                            self.memory_quick_add(note);
                        } else {
                            self.submit_input(&text);
                        }
                        false
                    }
                    _ => {
                        // Content-changed hook: an edit may have deleted an
                        // [Image #N]/[File #N] chip — drop its attachment so it
                        // is never silently sent (CC PromptInput.tsx:1189).
                        self.prune_orphaned_attachments();
                        false
                    }
                }
            }
        }
    }

    fn handle_processing_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        // NOTE: vim does NOT get Esc first-refusal while Processing — Esc must
        // interrupt the running turn ("esc to interrupt"). Non-Esc Normal-mode
        // motions still reach the composer via the `_` fall-through arm below
        // (the input component applies its vim layer internally), so vim editing
        // of a queued message keeps working mid-turn.

        // U-T22 — any non-Esc key breaks a pending interrupt double-press so the
        // first Esc can't pair with a much-later one, and clears the armed
        // "esc again to interrupt" affordance (mirrors the Idle esc_tracker reset).
        if key.code != KeyCode::Esc {
            self.esc_tracker.reset();
            self.activity.arm_interrupt(false);
        }

        // Shift+Tab cycles the permission mode even mid-turn, matching Claude Code.
        if crate::app::keys::is_permission_cycle(&key) {
            self.cycle_permission_mode();
            return false;
        }

        // WS10 — user-configurable keybindings (Esc stays hardcoded: cancel is
        // non-rebindable). Decline falls through to the arms below.
        if key.code != KeyCode::Esc {
            if let Some(quit) =
                self.resolve_keymap(crate::config::keybindings::Context::Processing, key)
            {
                return quit;
            }
        }

        match (key.code, key.modifiers) {
            // U-T22 — double-press Esc to interrupt (distinct from the Idle
            // msg-nav "esc again to clear/edit" chord). The first Esc arms the
            // affordance + hints; a second Esc within the 800ms window actually
            // cancels. A single stray Esc can no longer kill a long turn. Ctrl+C
            // stays a single-press hard interrupt below.
            (KeyCode::Esc, _) => {
                let now = std::time::Instant::now();
                if self.esc_tracker.press(now) {
                    self.activity.arm_interrupt(false);
                    self.cancel_processing();
                } else {
                    self.activity.arm_interrupt(true);
                    self.toasts.push(
                        "Press Esc again to interrupt".into(),
                        crate::components::toast::ToastLevel::Info,
                    );
                }
                false
            }
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => {
                // WS5 — CC parity (useCancelRequest): a SINGLE Ctrl+C interrupts
                // the running turn, same as Esc. Double-press stays only at Idle
                // (quit confirm).
                self.cancel_processing();
                false
            }
            // WS5 — pop queued messages into the composer for editing (CC
            // messageQueueManager.popAllEditable): ↑ on an EMPTY composer while
            // items are queued recalls them instead of navigating input history.
            (KeyCode::Up, KeyModifiers::NONE)
                if self.input.is_empty() && !self.message_queue.is_empty() =>
            {
                self.pop_queue_to_composer();
                false
            }
            // Ctrl+B background and Ctrl+O expand moved to the keybinding map
            // (chat:background / chat:expandTools via resolve_keymap above).
            // Ctrl+R on an empty composer expands the last tool result (parity
            // with Ctrl+O / CC verbose-expand); with text it reaches reverse-search.
            (KeyCode::Char('r'), KeyModifiers::CONTROL) if self.input.is_empty() => {
                self.chat.toggle_last_tool_expand(self.width);
                false
            }
            // Ctrl+Z suspend, Ctrl+Shift+L sidebar and Ctrl+L redraw moved to
            // the keybinding map (Global context, resolve_keymap above).
            // Chat scrolling is delegated to the host terminal's native scrollback.
            _ => {
                let action =
                    self.input
                        .handle_event(&Event::Terminal(CrosstermEvent::Key(key)));
                // The input may have grown or shrunk (Shift+Enter newline, paste,
                // submit/clear) — recompute so the box height tracks the content
                // instead of staying stuck at its previous size.
                self.recompute_layout();
                match action {
                    ComponentAction::Emit(AppAction::Submit(text)) => {
                        // '#' quick-adds to memory without a turn; everything
                        // else routes through the normal submit path.
                        if let Some(note) = text.strip_prefix('#') {
                            self.memory_quick_add(note);
                        } else {
                            self.submit_input(&text);
                        }
                        false
                    }
                    _ => {
                        // Content-changed hook: deleted chip → drop attachment
                        // (CC PromptInput.tsx:1189 orphan prune).
                        self.prune_orphaned_attachments();
                        false
                    }
                }
            }
        }
    }

    fn handle_recording_key(&mut self, key: crossterm::event::KeyEvent) -> bool {
        match (key.code, key.modifiers) {
            (KeyCode::Enter, _) => {
                self.stop_recording();
                false
            }
            (KeyCode::Char('v'), KeyModifiers::ALT) => {
                self.stop_recording();
                false
            }
            (KeyCode::Esc, _) => {
                self.cancel_recording();
                false
            }
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => {
                self.cancel_recording();
                false
            }
            _ => false,
        }
    }

    fn handle_voice_event(&mut self, event: crate::event::VoiceEvent) {
        use crate::event::VoiceEvent;
        match event {
            VoiceEvent::TranscriptionReady(text) => {
                self.status.clear_download_progress();
                self.status.set_transcribing(false);
                let trimmed = text.trim();
                let is_hands_free = self.voice.hands_free;

                if trimmed.is_empty() {
                    self.toasts.push(
                        "No speech detected".into(),
                        crate::components::toast::ToastLevel::Warning,
                    );
                } else if is_hands_free {
                    // Hands-free: auto-submit the transcribed text
                    self.input.insert_str(trimmed);
                    self.submit_input(trimmed);
                    self.input.reset();
                } else if trimmed.starts_with('/') {
                    // Auto-submit slash commands without review
                    self.input.insert_str(trimmed);
                    self.submit_input(trimmed);
                    self.input.reset();
                } else {
                    self.input.insert_str(trimmed);
                    self.toasts.push(
                        "Voice transcribed \u{2014} review and press Enter".into(),
                        crate::components::toast::ToastLevel::Info,
                    );
                }
                if self.state == AppState::Recording {
                    self.transition(AppState::Idle);
                }

                // Hands-free: auto-restart recording after a brief delay
                if is_hands_free {
                    let tx = self.event_tx.clone();
                    tokio::spawn(async move {
                        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                        // Send a tick to trigger recording restart
                        let _ = tx.send(crate::event::Event::Voice(
                            crate::event::VoiceEvent::HandsFreeRestart,
                        ));
                    });
                }
            }
            VoiceEvent::TranscriptionError(err) => {
                self.status.clear_download_progress();
                self.status.set_transcribing(false);
                if err.contains("whisper-cli") || err.contains("whisper not found") {
                    let install_hint = if cfg!(target_os = "windows") {
                        "whisper-cli auto-downloads on Windows \u{2014} retry, or set VOICE_PROVIDER=cloud"
                    } else if cfg!(target_os = "macos") {
                        "install whisper.cpp (brew install whisper-cpp) or set OSA_WHISPER_URL; or use VOICE_PROVIDER=cloud"
                    } else {
                        "install whisper.cpp or set OSA_WHISPER_URL to a prebuilt zip; or use VOICE_PROVIDER=cloud"
                    };
                    self.toasts.push(
                        format!("Voice unavailable: {}", install_hint),
                        crate::components::toast::ToastLevel::Error,
                    );
                } else {
                    self.toasts.push(
                        format!("Voice error: {}", err),
                        crate::components::toast::ToastLevel::Error,
                    );
                }
                if self.state == AppState::Recording {
                    self.transition(AppState::Idle);
                }
            }
            VoiceEvent::RecordingStopped => {
                self.stop_recording();
            }
            VoiceEvent::DownloadProgress { label, downloaded, total } => {
                let pct = if total > 0 {
                    ((downloaded as f64 / total as f64) * 100.0).min(100.0) as u8
                } else {
                    0
                };
                self.status.set_download_progress(&label, pct);
                self.toasts.push(
                    format!("Downloading whisper model: {}%", pct),
                    crate::components::toast::ToastLevel::Info,
                );
            }
            VoiceEvent::AudioLevel(level) => {
                self.status.set_audio_level((level * 100.0).clamp(0.0, 100.0) as u8);
            }
            VoiceEvent::HandsFreeRestart => {
                if self.voice.hands_free && !self.voice.recording {
                    self.start_recording();
                }
            }
        }
    }

    fn handle_tick(&mut self) {
        self.toasts.tick();
        self.activity.tick();
        self.agents.tick();
        self.task_checklist.tick();

        // Poll audio level and elapsed time from active voice capture
        if self.voice.recording {
            self.status.set_recording_elapsed(self.voice.elapsed_secs());
            if let Some(ref capture) = self.voice.capture {
                let level = capture.level();
                self.status.set_audio_level(level);

                // Hands-free VAD: auto-stop on sustained silence
                if self.voice.hands_free {
                    if level < 5 {
                        // Silence detected — start or continue tracking
                        if self.voice.silence_start.is_none() {
                            self.voice.silence_start = Some(std::time::Instant::now());
                        }
                        if let Some(silence_start) = self.voice.silence_start {
                            let silence_dur = silence_start.elapsed();
                            let recorded_secs = self.voice.elapsed_secs();
                            if silence_dur >= std::time::Duration::from_millis(1500)
                                && recorded_secs >= 1
                            {
                                // Enough silence after meaningful audio — auto-stop
                                self.stop_recording();
                            }
                        }
                    } else {
                        // Sound detected — reset silence tracker
                        self.voice.silence_start = None;
                    }
                }
            }
        }

        if self.state.is_processing() {
            if let Some(start) = self.processing_start {
                let ms = start.elapsed().as_millis() as u64;
                self.sidebar.set_elapsed_ms(ms);
            }
        }

        if self.state.is_processing() {
            if let Some(start) = self.processing_start {
                let elapsed = start.elapsed();
                let timeout_secs = self.config.request_timeout_secs;
                let warning_secs = (timeout_secs * 4) / 5; // 80% threshold

                if elapsed >= std::time::Duration::from_secs(timeout_secs) {
                    warn!("Processing timed out after {}s", timeout_secs);
                    if let Some(cancel) = self.sse_cancel.take() {
                        cancel.cancel();
                    }
                    self.chat.clear_streaming();
                    self.stream_buf.clear();
                    self.thinking_buf.clear();
                    self.agent_header_sent = false;
                    self.activity.stop();
                    self.status.set_active(false);
                    self.transition(AppState::Idle);
                    self.toasts.push(
                        format!("Request timed out ({}m)", timeout_secs / 60),
                        crate::components::toast::ToastLevel::Error,
                    );
                    // If a /goal auto-continue loop was active, the stalled turn
                    // silently kills it. Clear the (now-stale) goal indicator and
                    // tell the user, rather than leaving a misleading "◎ goal N/max".
                    if self.goal.is_some() {
                        self.chat.add_system_message(
                            "Goal auto-continue stopped: the turn timed out before completing. Use /goal <text> to resume.",
                            "warning",
                        );
                        self.clear_goal(false);
                    }
                    self.start_sse();
                } else if elapsed >= std::time::Duration::from_secs(warning_secs) {
                    // Fire warning once when crossing the 80% threshold
                    let prev_elapsed =
                        elapsed.saturating_sub(std::time::Duration::from_millis(200));
                    if prev_elapsed < std::time::Duration::from_secs(warning_secs) {
                        let remaining = timeout_secs.saturating_sub(elapsed.as_secs());
                        let remaining_str = if remaining >= 60 {
                            format!("{}m", remaining / 60)
                        } else {
                            format!("{}s", remaining)
                        };
                        self.toasts.push(
                            format!(
                                "Processing for {}m, timing out in {}",
                                elapsed.as_secs() / 60,
                                remaining_str,
                            ),
                            crate::components::toast::ToastLevel::Warning,
                        );
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod paste_path_tests {
    use super::{looks_like_path, paste_is_file_paths, MAX_PATH_TOKENS};

    #[test]
    fn bare_words_are_never_paths() {
        assert!(!looks_like_path("Cargo.toml"));
        assert!(!looks_like_path("src"));
        assert!(!looks_like_path("README.md"));
    }

    #[test]
    fn path_prefixes_are_recognized() {
        assert!(looks_like_path("/etc/hosts"));
        assert!(looks_like_path("./foo"));
        assert!(looks_like_path("../bar"));
        assert!(looks_like_path("~/baz"));
        assert!(looks_like_path("C:\\Users\\x"));
        assert!(looks_like_path("C:/Users/x"));
        assert!(looks_like_path("\\\\host\\share"));
    }

    #[test]
    fn prose_of_real_filenames_is_not_hijacked() {
        // Even if these words name files in the CWD, without a path prefix they
        // are treated as text (the pre-fix hijack bug) and do zero disk I/O.
        assert!(!paste_is_file_paths("src Cargo.toml README.md"));
        assert!(!paste_is_file_paths("look at the readme file please"));
    }

    #[test]
    fn missing_prefixed_paths_are_text() {
        assert!(!paste_is_file_paths("/no/such/file/osa_xyz123"));
        assert!(!paste_is_file_paths("./nope-abc /also/missing-def"));
    }

    #[test]
    fn too_many_tokens_short_circuit() {
        let many = (0..(MAX_PATH_TOKENS + 1))
            .map(|i| format!("/p/{i}"))
            .collect::<Vec<_>>()
            .join(" ");
        assert!(!paste_is_file_paths(&many));
    }

    #[test]
    fn real_file_is_detected() {
        let dir = std::env::temp_dir();
        let path = dir.join(format!("osa_paste_test_{}.txt", std::process::id()));
        std::fs::write(&path, b"x").unwrap();
        let s = path.to_string_lossy().to_string();
        assert!(paste_is_file_paths(&s));
        let _ = std::fs::remove_file(&path);
    }
}
