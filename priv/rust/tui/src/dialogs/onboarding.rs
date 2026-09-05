/// 7-step onboarding wizard: Provider → Details → Model → Verify → Channels → Identity → Confirm
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};
use std::collections::HashMap;

use crate::client::types::OnboardingProvider;

/// Render a widget into `rect` but clipped to the frame's drawable area, so a
/// fixed-layout step draw on a very short/narrow terminal degrades gracefully
/// instead of writing out of bounds and panicking. Single choke point for the
/// whole wizard dialog.
fn put<W: ratatui::widgets::Widget>(frame: &mut Frame, widget: W, rect: Rect) {
    crate::app::event_loop::safe_render_widget(frame, widget, rect);
}

const DIALOG_W: u16 = 64;
const DIALOG_H: u16 = 28;

const STEP_LABELS: &[&str] = &[
    "1 Provider",
    "2 Details",
    "3 Model",
    "4 Verify",
    "5 Channels",
    "6 Identity",
    "7 Confirm",
];

const TOTAL_STEPS: usize = 7;

// Channel definitions: (id, display name, setup hint)
const CHANNELS: &[(&str, &str, &str)] = &[
    ("telegram", "Telegram", "get token from @BotFather"),
    ("discord", "Discord", "from the Developer Portal"),
    ("slack", "Slack", "from api.slack.com/apps"),
];

const CHANNEL_INSTRUCTIONS: &[&[&str]] = &[
    // Telegram
    &[
        "1. Open Telegram, search @BotFather",
        "2. Send /newbot, follow the prompts",
        "3. Copy the bot token",
    ],
    // Discord
    &[
        "1. Go to discord.com/developers/applications",
        "2. Create an application, add a Bot",
        "3. Copy the bot token from the Bot page",
    ],
    // Slack
    &[
        "1. Go to api.slack.com/apps and create an app",
        "2. Add Bot Token Scopes under OAuth & Permissions",
        "3. Install the app and copy the Bot User OAuth Token",
    ],
];

// ── Result ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct OnboardingResult {
    pub provider: String,
    pub model: String,
    pub api_key: Option<String>,
    pub base_url: Option<String>,
    pub channel_tokens: HashMap<String, String>,
    pub user_name: Option<String>,
    pub agent_name: Option<String>,
}

// ── Action ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub enum OnboardingAction {
    Complete(OnboardingResult),
    Cancel,
}

// ── Data ──────────────────────────────────────────────────────────────────────

pub struct OnboardingData {
    pub providers: Vec<OnboardingProvider>,
    pub system_info: std::collections::HashMap<String, serde_json::Value>,
}

// ── State ────────────────────────────────────────────────────────────────────

pub struct OnboardingWizard {
    step: usize,
    data: OnboardingData,

    // Step 0 — Provider
    selected_provider: usize,

    // Step 1 — Details
    api_key: String,
    api_key_masked: bool,
    base_url: String,
    // Which detail field the keyboard edits when the provider needs BOTH a key
    // and a base URL: 0 = API key, 1 = Base URL. Ignored when only one field is
    // present (that field is always the target). See `details_on_url`.
    details_focus: usize,
    // Inline validation message for the details step, e.g. a required base URL
    // left blank. Set on Enter, cleared on the next edit. Rendered under the
    // fields so the fix is visible in place instead of only failing at Verify.
    details_error: Option<String>,

    // Step 2 — Model
    model_input: String,
    selected_model: usize,
    model_list: Vec<(String, String)>, // (id, display label)

    // Step 3 — Verify (status display only)
    verify_status: VerifyStatus,

    // Step 4 — Channels
    selected_channels: Vec<bool>,          // [telegram, discord, slack]
    channel_tokens: HashMap<String, String>,
    current_channel_setup: Option<usize>,  // index into CHANNELS being configured
    channel_token_input: String,
    channel_token_masked: bool,

    // Step 5 — Identity
    user_name_input: String,
    agent_name_input: String,
    identity_focus: usize, // 0 = user_name, 1 = agent_name

    // Step 6 — Confirm
    confirm_selected: usize,
}

#[derive(Debug, Clone, PartialEq)]
enum VerifyStatus {
    Pending,
    Success { latency_ms: u64 },
    Failed { message: String },
}

impl OnboardingWizard {
    pub fn new(data: OnboardingData) -> Self {
        // Regression guard: the channel metadata and per-channel instructions
        // must stay the same length, or the channel-token screen would index
        // out of bounds. Draw code additionally uses .get() as a runtime guard.
        debug_assert_eq!(
            CHANNELS.len(),
            CHANNEL_INSTRUCTIONS.len(),
            "CHANNELS and CHANNEL_INSTRUCTIONS must stay in lockstep"
        );

        // Build initial model list from first provider
        let model_list = Self::extract_models(&data.providers, 0);

        Self {
            step: 0,
            data,
            selected_provider: 0,
            api_key: String::new(),
            api_key_masked: true,
            base_url: String::new(),
            details_focus: 0,
            details_error: None,
            model_input: String::new(),
            selected_model: 0,
            model_list,
            verify_status: VerifyStatus::Pending,
            selected_channels: vec![false; CHANNELS.len()],
            channel_tokens: HashMap::new(),
            current_channel_setup: None,
            channel_token_input: String::new(),
            channel_token_masked: true,
            user_name_input: String::new(),
            agent_name_input: String::new(),
            identity_focus: 0,
            confirm_selected: 0,
        }
    }

    fn extract_models(providers: &[OnboardingProvider], idx: usize) -> Vec<(String, String)> {
        if let Some(provider) = providers.get(idx) {
            if let Some(arr) = provider.models.as_array() {
                return arr
                    .iter()
                    .filter_map(|m| {
                        let id = m.get("id")?.as_str()?.to_string();
                        let name = m
                            .get("name")
                            .and_then(|n| n.as_str())
                            .unwrap_or(&id)
                            .to_string();
                        let ctx = m.get("ctx").and_then(|c| c.as_u64()).unwrap_or(0);
                        let tools = m.get("tools").and_then(|t| t.as_bool()).unwrap_or(false);
                        let note = m
                            .get("note")
                            .and_then(|n| n.as_str())
                            .map(|n| format!("  {}", n))
                            .unwrap_or_default();
                        let tools_label = if tools { "tools" } else { "" };
                        let ctx_label = if ctx >= 1_000_000 {
                            format!("{}M", ctx / 1_000_000)
                        } else if ctx > 0 {
                            format!("{}K", ctx / 1024)
                        } else {
                            String::new()
                        };
                        let label = format!("{:<32} {:>6}  {}{}", name, ctx_label, tools_label, note);
                        Some((id, label))
                    })
                    .collect();
            }
        }
        Vec::new()
    }

    fn current_provider(&self) -> Option<&OnboardingProvider> {
        self.data.providers.get(self.selected_provider)
    }

    fn provider_needs_key(&self) -> bool {
        self.current_provider()
            .map(|p| {
                p.requires_key.as_bool().unwrap_or(true) && p.id != "ollama_local"
            })
            .unwrap_or(false)
    }

    /// True when the selected provider declares a non-key auth mode alongside
    /// its key. Read from the catalog's `auth_modes`, which is the single
    /// source of truth every surface reads — never a second list here.
    fn provider_offers_account(&self) -> bool {
        self.current_provider()
            .and_then(|p| p.auth_modes.as_ref())
            .map(|modes| modes.iter().any(|m| m == "oauth"))
            .unwrap_or(false)
    }

    fn provider_needs_url(&self) -> bool {
        self.current_provider()
            .map(|p| p.id == "custom" || p.id == "ollama_local")
            .unwrap_or(false)
    }

    /// Number of focusable text fields on the details step (0, 1, or 2).
    /// Providers can need a key, a base URL, both, or neither.
    fn details_field_count(&self) -> usize {
        self.provider_needs_key() as usize + self.provider_needs_url() as usize
    }

    /// Whether the keyboard currently edits the Base URL (vs. the API key).
    /// A URL-only provider always edits the URL; a key-only provider never
    /// does; a provider needing both follows `details_focus`. This is the one
    /// place that decides where a keystroke lands, so the field the cursor is
    /// drawn on and the field that receives input can never drift apart.
    fn details_on_url(&self) -> bool {
        match (self.provider_needs_key(), self.provider_needs_url()) {
            (false, true) => true,
            (true, true) => self.details_focus == 1,
            _ => false,
        }
    }

    /// Move focus between the API-key and Base-URL fields when the provider
    /// needs both; a no-op otherwise. Clears any stale validation message so
    /// the hint tracks the field the user is now on.
    fn details_cycle_focus(&mut self) {
        if self.details_field_count() == 2 {
            self.details_focus ^= 1;
            self.details_error = None;
        }
    }

    /// Enter-time validation for the details step. Returns an error message to
    /// show in place (and blocks advancing) when a required field is blank,
    /// steering focus to the offending field. `None` means the step is valid.
    fn validate_details(&mut self) -> Option<String> {
        if self.provider_needs_url() && self.base_url.trim().is_empty() {
            if self.provider_needs_key() {
                self.details_focus = 1;
            }
            return Some(
                "Base URL is required for this provider. Press Tab to focus the \
                 Base URL field, then enter your endpoint (e.g. https://api.example.com/v1)."
                    .to_string(),
            );
        }
        if self.provider_needs_key()
            && self.api_key.trim().is_empty()
            && !self.provider_offers_account()
        {
            if self.provider_needs_url() {
                self.details_focus = 0;
            }
            return Some(
                "API key is required. Enter the key for this provider to continue.".to_string(),
            );
        }
        None
    }

    fn provider_has_models(&self) -> bool {
        // dynamic or manual = no static list; custom = manual input
        if let Some(p) = self.current_provider() {
            if p.models.is_array() && !p.models.as_array().unwrap().is_empty() {
                return true;
            }
        }
        false
    }

    fn advance(&mut self) -> Option<OnboardingAction> {
        let mut next = self.step + 1;
        // Skip model step if provider has no static model list and models are dynamic
        if next == 2 && !self.provider_has_models() && self.model_list.is_empty() {
            next = 3;
        }
        if next >= TOTAL_STEPS {
            return self.build_result().map(OnboardingAction::Complete);
        }
        if next == 1 {
            // Entering details: start on the first field, no stale error.
            self.details_focus = 0;
            self.details_error = None;
        }
        if next == 2 {
            // Rebuild model list when entering model step
            self.model_list = Self::extract_models(&self.data.providers, self.selected_provider);
            self.selected_model = 0;
        }
        if next == 3 {
            // Reset verify status
            self.verify_status = VerifyStatus::Pending;
        }
        if next == 4 {
            // Reset channel cursor state when entering channels step
            self.current_channel_setup = None;
            self.confirm_selected = 0;
        }
        if next == 5 {
            // Reset identity fields focus when entering identity step
            self.identity_focus = 0;
        }
        if next == 6 {
            // Reset confirm button selection when entering confirm step
            self.confirm_selected = 0;
        }
        self.step = next;
        None
    }

    fn retreat(&mut self) -> Option<OnboardingAction> {
        if self.step == 0 {
            return Some(OnboardingAction::Cancel);
        }
        let mut prev = self.step - 1;
        // Skip model step backwards if no models
        if prev == 2 && !self.provider_has_models() && self.model_list.is_empty() {
            prev = 1;
        }
        if prev == 1 {
            // Returning to details: clear any stale validation message.
            self.details_error = None;
        }
        self.step = prev;
        None
    }

    /// Skip directly to identity from channels step (Esc on channel select screen).
    fn skip_to_identity(&mut self) {
        self.step = 5;
        self.identity_focus = 0;
    }

    fn build_result(&self) -> Option<OnboardingResult> {
        let provider = self.current_provider()?;

        let model = if !self.model_list.is_empty() {
            self.model_list
                .get(self.selected_model)
                .map(|(id, _)| id.clone())
                .unwrap_or_else(|| provider.default_model.clone().unwrap_or_default())
        } else if !self.model_input.is_empty() {
            self.model_input.trim().to_string()
        } else {
            provider.default_model.clone().unwrap_or_default()
        };

        let api_key = if self.api_key.is_empty() {
            None
        } else {
            Some(self.api_key.clone())
        };

        let base_url = if self.base_url.is_empty() {
            provider.base_url.clone()
        } else {
            Some(self.base_url.clone())
        };

        let user_name = if self.user_name_input.trim().is_empty() {
            None
        } else {
            Some(self.user_name_input.trim().to_string())
        };

        let agent_name = if self.agent_name_input.trim().is_empty() {
            None
        } else {
            Some(self.agent_name_input.trim().to_string())
        };

        Some(OnboardingResult {
            provider: provider.id.clone(),
            model,
            api_key,
            base_url,
            channel_tokens: self.channel_tokens.clone(),
            user_name,
            agent_name,
        })
    }

    // ── Public: Read-only accessors for the flow renderer ─────────────

    pub fn flow_step(&self) -> usize {
        self.step
    }

    pub fn flow_providers(&self) -> &[crate::client::types::OnboardingProvider] {
        &self.data.providers
    }

    pub fn flow_selected_provider(&self) -> usize {
        self.selected_provider
    }

    pub fn flow_provider_needs_key(&self) -> bool {
        self.provider_needs_key()
    }

    pub fn flow_provider_needs_url(&self) -> bool {
        self.provider_needs_url()
    }

    pub fn flow_api_key_masked(&self) -> bool {
        self.api_key_masked
    }

    pub fn flow_api_key_display(&self) -> String {
        if self.api_key_masked {
            // Cap the mask so a stray large paste can't allocate a giant string
            // on every frame; count chars (not bytes) so multi-byte input is safe.
            "\u{2022}".repeat(self.api_key.chars().count().min(64))
        } else {
            self.api_key.clone()
        }
    }

    pub fn flow_api_key_preview(&self) -> String {
        Self::masked_key_preview(&self.api_key)
    }

    /// Char-boundary-safe first-4/last-4 masked preview of a secret. Slicing by
    /// chars (never bytes) means a key holding multi-byte UTF-8 can never panic
    /// on a non-char-boundary index.
    fn masked_key_preview(key: &str) -> String {
        if key.is_empty() {
            return "not set".to_string();
        }
        let cs: Vec<char> = key.chars().collect();
        if cs.len() > 8 {
            let first: String = cs[..4].iter().collect();
            let last: String = cs[cs.len() - 4..].iter().collect();
            format!("{}...{}", first, last)
        } else {
            "set".to_string()
        }
    }

    pub fn flow_base_url(&self) -> &str {
        &self.base_url
    }

    /// True when the details cursor is on the Base URL field (vs. the API key),
    /// so the renderer draws the active cursor on the right field.
    pub fn flow_details_on_url(&self) -> bool {
        self.details_on_url()
    }

    /// Inline validation message for the details step, if any.
    pub fn flow_details_error(&self) -> Option<&str> {
        self.details_error.as_deref()
    }

    pub fn flow_model_list(&self) -> &[(String, String)] {
        &self.model_list
    }

    pub fn flow_selected_model(&self) -> usize {
        self.selected_model
    }

    pub fn flow_model_input(&self) -> &str {
        &self.model_input
    }

    /// Returns (is_pending, is_success, latency_ms, error_message)
    pub fn flow_verify_state(&self) -> (bool, bool, Option<u64>, Option<&str>) {
        match &self.verify_status {
            VerifyStatus::Pending => (true, false, None, None),
            VerifyStatus::Success { latency_ms } => (false, true, Some(*latency_ms), None),
            VerifyStatus::Failed { message } => (false, false, None, Some(message.as_str())),
        }
    }

    pub fn flow_selected_channels(&self) -> &[bool] {
        &self.selected_channels
    }

    pub fn flow_channel_tokens(&self) -> &std::collections::HashMap<String, String> {
        &self.channel_tokens
    }

    pub fn flow_current_channel_setup(&self) -> Option<usize> {
        self.current_channel_setup
    }

    pub fn flow_channel_token_display(&self) -> String {
        if self.channel_token_masked {
            "\u{2022}".repeat(self.channel_token_input.chars().count().min(64))
        } else {
            self.channel_token_input.clone()
        }
    }

    pub fn flow_channel_token_masked(&self) -> bool {
        self.channel_token_masked
    }

    pub fn flow_confirm_selected(&self) -> usize {
        self.confirm_selected
    }

    pub fn flow_user_name_input(&self) -> &str {
        &self.user_name_input
    }

    pub fn flow_agent_name_input(&self) -> &str {
        &self.agent_name_input
    }

    pub fn flow_identity_focus(&self) -> usize {
        self.identity_focus
    }

    /// The provider id the user selected (e.g. "anthropic"). Used as a
    /// post-setup display fallback so the header/status never render a
    /// placeholder like "configured" when the backend echo is empty.
    pub fn selected_provider_id(&self) -> Option<String> {
        self.current_provider().map(|p| p.id.clone())
    }

    /// The model id the user chose (or the provider default), so the header
    /// never renders a placeholder like "default". Empty resolves to None.
    pub fn selected_model_id(&self) -> Option<String> {
        self.build_result()
            .map(|r| r.model)
            .filter(|m| !m.is_empty())
    }

    pub fn flow_channel_list() -> &'static [(&'static str, &'static str, &'static str)] {
        CHANNELS
    }

    pub fn flow_channel_instructions() -> &'static [&'static [&'static str]] {
        CHANNEL_INSTRUCTIONS
    }

    // ── Public: Set verify result from async health check ─────────────

    pub fn set_verify_success(&mut self, latency_ms: u64) {
        self.verify_status = VerifyStatus::Success { latency_ms };
    }

    pub fn set_verify_failed(&mut self, message: String) {
        self.verify_status = VerifyStatus::Failed { message };
    }

    pub fn get_health_check_params(&self) -> Option<serde_json::Value> {
        let provider = self.current_provider()?;
        Some(serde_json::json!({
            "provider": provider.id,
            "api_key": if self.api_key.is_empty() { serde_json::Value::Null } else { serde_json::Value::String(self.api_key.clone()) },
            "model": if !self.model_list.is_empty() {
                self.model_list.get(self.selected_model).map(|(id, _)| serde_json::Value::String(id.clone())).unwrap_or(serde_json::Value::Null)
            } else if !self.model_input.is_empty() {
                serde_json::Value::String(self.model_input.clone())
            } else {
                provider.default_model.as_ref().map(|m| serde_json::Value::String(m.clone())).unwrap_or(serde_json::Value::Null)
            },
            "base_url": if self.base_url.is_empty() { provider.base_url.as_ref().map(|u| serde_json::Value::String(u.clone())).unwrap_or(serde_json::Value::Null) } else { serde_json::Value::String(self.base_url.clone()) },
        }))
    }

    /// Clean pasted text: strip shell export prefix, quotes, whitespace, semicolons.
    /// Handles: "export KEY=value", "KEY=value", '"value"', "'value'", trailing ;
    fn clean_pasted_key(raw: &str) -> String {
        let trimmed = raw.trim();
        // Strip "export KEY=value" or "KEY=value" format
        let value = if let Some(idx) = trimmed.find('=') {
            let after_eq = &trimmed[idx + 1..];
            after_eq.trim()
        } else {
            trimmed
        };
        // Strip surrounding quotes — require at least two bytes so a lone quote
        // char (value.len()==1) can never produce a reversed &value[1..0] slice.
        let unquoted = if value.len() >= 2
            && ((value.starts_with('"') && value.ends_with('"'))
                || (value.starts_with('\'') && value.ends_with('\''))
                || (value.starts_with('`') && value.ends_with('`')))
        {
            &value[1..value.len() - 1]
        } else {
            value
        };
        // Strip trailing semicolon
        let cleaned = unquoted.strip_suffix(';').unwrap_or(unquoted);
        cleaned.trim().to_string()
    }

    /// Returns true if the wizard is on the verify step and needs a health check fired.
    /// Short-circuits to false when no health-check params can be built (e.g. no
    /// provider) so the flow never waits on a check that can't run.
    pub fn needs_health_check(&self) -> bool {
        self.step == 3
            && self.verify_status == VerifyStatus::Pending
            && self.get_health_check_params().is_some()
    }

    /// Handle a paste event (bracketed paste from terminal).
    pub fn handle_paste(&mut self, text: &str) -> Option<OnboardingAction> {
        match self.step {
            1 => {
                // Details step — paste into API key or URL. Cap to a sane
                // single-secret length so a stray multi-KB paste can't be stored
                // whole (keys/tokens/URLs are never multi-KB).
                let cleaned: String = Self::clean_pasted_key(text).chars().take(512).collect();
                if self.details_on_url() {
                    self.base_url.push_str(&cleaned);
                } else {
                    self.api_key.push_str(&cleaned);
                }
                self.details_error = None;
                None
            }
            2 => {
                // Model step — paste into manual model input
                if self.model_list.is_empty() {
                    self.model_input.push_str(text.trim());
                }
                None
            }
            4 => {
                // Channels token input
                if self.current_channel_setup.is_some() {
                    let cleaned: String =
                        Self::clean_pasted_key(text).chars().take(512).collect();
                    self.channel_token_input.push_str(&cleaned);
                }
                None
            }
            5 => {
                // Identity step — paste into focused field
                let trimmed = text.trim();
                if self.identity_focus == 0 {
                    self.user_name_input.push_str(trimmed);
                } else {
                    self.agent_name_input.push_str(trimmed);
                }
                None
            }
            _ => None,
        }
    }

    // ── Key handling ─────────────────────────────────────────────

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<OnboardingAction> {
        // Reveal / hide the API key on the details step. Handled before the
        // Ctrl/Alt guard below because that guard exists to stop control chords
        // being typed into a field, and this is the one chord the details step
        // deliberately wants. Kept off a plain key so it can never collide with
        // secret input, and off Tab so Tab is free to move between fields.
        if self.step == 1
            && key.modifiers.contains(KeyModifiers::CONTROL)
            && matches!(key.code, KeyCode::Char('r') | KeyCode::Char('R'))
            && self.provider_needs_key()
        {
            self.api_key_masked = !self.api_key_masked;
            return None;
        }

        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return None;
        }

        match self.step {
            0 => self.handle_step_provider(key),
            1 => self.handle_step_details(key),
            2 => self.handle_step_model(key),
            3 => self.handle_step_verify(key),
            4 => self.handle_step_channels(key),
            5 => self.handle_step_identity(key),
            6 => self.handle_step_confirm(key),
            _ => None,
        }
    }

    fn handle_step_provider(&mut self, key: KeyEvent) -> Option<OnboardingAction> {
        let count = self.data.providers.len();
        match key.code {
            KeyCode::Enter => {
                // Pre-fill base_url from provider
                if let Some(p) = self.current_provider() {
                    if let Some(ref url) = p.base_url {
                        self.base_url = url.clone();
                    }
                }
                self.advance()
            }
            KeyCode::Esc => Some(OnboardingAction::Cancel),
            KeyCode::Up | KeyCode::Char('k') => {
                if count > 0 {
                    self.selected_provider =
                        self.selected_provider.checked_sub(1).unwrap_or(count - 1);
                }
                None
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if count > 0 {
                    self.selected_provider = (self.selected_provider + 1) % count;
                }
                None
            }
            _ => None,
        }
    }

    fn handle_step_details(&mut self, key: KeyEvent) -> Option<OnboardingAction> {
        match key.code {
            KeyCode::Enter => {
                // Validate required fields in place; only advance when clean so
                // a blank base URL is caught here with a fix, not as an opaque
                // failure two steps later at Verify.
                match self.validate_details() {
                    Some(msg) => {
                        self.details_error = Some(msg);
                        None
                    }
                    None => self.advance(),
                }
            }
            KeyCode::Esc => self.retreat(),
            // Tab / arrows move between the API-key and Base-URL fields when the
            // provider needs both. Tab used to toggle key visibility, which left
            // the base URL unreachable and surprised users expecting field
            // navigation; visibility now lives on Ctrl+R (see handle_key).
            KeyCode::Tab | KeyCode::Down => {
                self.details_cycle_focus();
                None
            }
            KeyCode::BackTab | KeyCode::Up => {
                self.details_cycle_focus();
                None
            }
            KeyCode::Backspace => {
                if self.details_on_url() {
                    self.base_url.pop();
                } else {
                    self.api_key.pop();
                }
                self.details_error = None;
                None
            }
            KeyCode::Char(c) => {
                if self.details_on_url() {
                    self.base_url.push(c);
                } else {
                    self.api_key.push(c);
                }
                self.details_error = None;
                None
            }
            _ => None,
        }
    }

    fn handle_step_model(&mut self, key: KeyEvent) -> Option<OnboardingAction> {
        if self.model_list.is_empty() {
            // Manual text input for model name
            match key.code {
                KeyCode::Enter => self.advance(),
                KeyCode::Esc => self.retreat(),
                KeyCode::Backspace => {
                    self.model_input.pop();
                    None
                }
                KeyCode::Char(c) => {
                    self.model_input.push(c);
                    None
                }
                _ => None,
            }
        } else {
            // Selection from list
            let count = self.model_list.len();
            match key.code {
                KeyCode::Enter => self.advance(),
                KeyCode::Esc => self.retreat(),
                KeyCode::Up | KeyCode::Char('k') => {
                    self.selected_model =
                        self.selected_model.checked_sub(1).unwrap_or(count - 1);
                    None
                }
                KeyCode::Down | KeyCode::Char('j') => {
                    self.selected_model = (self.selected_model + 1) % count;
                    None
                }
                _ => None,
            }
        }
    }

    fn handle_step_verify(&mut self, key: KeyEvent) -> Option<OnboardingAction> {
        match key.code {
            KeyCode::Enter => {
                // Advance once verification resolves. Also advance immediately when
                // there is no provider / no buildable health check (e.g. zero
                // providers returned) so the wizard can never soft-lock waiting on
                // a check that can't run.
                if self.verify_status != VerifyStatus::Pending
                    || self.current_provider().is_none()
                    || self.get_health_check_params().is_none()
                {
                    self.advance()
                } else {
                    None
                }
            }
            KeyCode::Esc => self.retreat(),
            KeyCode::Char('r') => {
                // Retry
                self.verify_status = VerifyStatus::Pending;
                None
            }
            _ => None,
        }
    }

    fn handle_step_channels(&mut self, key: KeyEvent) -> Option<OnboardingAction> {
        // Sub-state: configuring a specific channel token
        if let Some(channel_idx) = self.current_channel_setup {
            return self.handle_step_channel_token(key, channel_idx);
        }

        // Main channel selection list
        match key.code {
            KeyCode::Enter => {
                // Find the first selected channel that does not yet have a token and
                // open its token input. If all selected channels are configured (or none
                // are selected), advance to confirm.
                let next_unconfigured = self.selected_channels
                    .iter()
                    .enumerate()
                    .find(|(i, &selected)| {
                        selected && !self.channel_tokens.contains_key(CHANNELS[*i].0)
                    })
                    .map(|(i, _)| i);

                if let Some(idx) = next_unconfigured {
                    self.current_channel_setup = Some(idx);
                    self.channel_token_input.clear();
                    self.channel_token_masked = true;
                    None
                } else {
                    self.advance()
                }
            }
            KeyCode::Esc => {
                // Skip channels — jump to identity
                self.skip_to_identity();
                None
            }
            KeyCode::Up | KeyCode::Char('k') => {
                // Move selection cursor (tracked via a temporary field isn't needed;
                // Space toggles the item under the cursor tracked by selected_channels).
                // Reuse confirm_selected as channel cursor since confirm is not active yet.
                if self.confirm_selected > 0 {
                    self.confirm_selected -= 1;
                }
                None
            }
            KeyCode::Down | KeyCode::Char('j') => {
                let max = CHANNELS.len().saturating_sub(1);
                if self.confirm_selected < max {
                    self.confirm_selected += 1;
                }
                None
            }
            KeyCode::Char(' ') => {
                let idx = self.confirm_selected.min(CHANNELS.len().saturating_sub(1));
                let mut now_selected = false;
                if let Some(v) = self.selected_channels.get_mut(idx) {
                    *v = !*v;
                    now_selected = *v;
                }
                // If we just deselected a channel, remove any saved token for it
                if !now_selected {
                    if let Some((channel_id, _, _)) = CHANNELS.get(idx) {
                        self.channel_tokens.remove(*channel_id);
                    }
                }
                None
            }
            _ => None,
        }
    }

    fn handle_step_channel_token(&mut self, key: KeyEvent, channel_idx: usize) -> Option<OnboardingAction> {
        match key.code {
            KeyCode::Enter => {
                // Save the token and look for the next unconfigured selected channel
                let channel_id = CHANNELS[channel_idx].0.to_string();
                let token = self.channel_token_input.trim().to_string();
                if !token.is_empty() {
                    self.channel_tokens.insert(channel_id, token);
                }
                self.channel_token_input.clear();
                self.current_channel_setup = None;

                // Find next selected but unconfigured channel
                let next = self.selected_channels
                    .iter()
                    .enumerate()
                    .find(|(i, &selected)| {
                        selected && !self.channel_tokens.contains_key(CHANNELS[*i].0)
                    })
                    .map(|(i, _)| i);

                if let Some(idx) = next {
                    self.current_channel_setup = Some(idx);
                    self.channel_token_masked = true;
                    None
                } else {
                    // All selected channels configured — proceed to confirm
                    self.advance()
                }
            }
            KeyCode::Esc => {
                // Go back to channel selection list without saving
                self.channel_token_input.clear();
                self.current_channel_setup = None;
                None
            }
            KeyCode::Tab => {
                self.channel_token_masked = !self.channel_token_masked;
                None
            }
            KeyCode::Backspace => {
                self.channel_token_input.pop();
                None
            }
            KeyCode::Char(c) => {
                self.channel_token_input.push(c);
                None
            }
            _ => None,
        }
    }

    fn handle_step_identity(&mut self, key: KeyEvent) -> Option<OnboardingAction> {
        match key.code {
            KeyCode::Enter => self.advance(),
            KeyCode::Esc => self.retreat(),
            KeyCode::Tab => {
                self.identity_focus = (self.identity_focus + 1) % 2;
                None
            }
            KeyCode::Backspace => {
                if self.identity_focus == 0 {
                    self.user_name_input.pop();
                } else {
                    self.agent_name_input.pop();
                }
                None
            }
            KeyCode::Char(c) => {
                if self.identity_focus == 0 {
                    self.user_name_input.push(c);
                } else {
                    self.agent_name_input.push(c);
                }
                None
            }
            _ => None,
        }
    }

    fn handle_step_confirm(&mut self, key: KeyEvent) -> Option<OnboardingAction> {
        match key.code {
            KeyCode::Left | KeyCode::Right | KeyCode::Tab => {
                self.confirm_selected = (self.confirm_selected + 1) % 2;
                None
            }
            KeyCode::Enter => {
                if self.confirm_selected == 0 {
                    self.build_result().map(OnboardingAction::Complete)
                } else {
                    self.retreat()
                }
            }
            KeyCode::Esc => self.retreat(),
            _ => None,
        }
    }

    // ── Drawing ───────────────────────────────────────────────────────

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();

        let w = DIALOG_W.min(area.width);
        let h = DIALOG_H.min(area.height);
        let x = area.x + area.width.saturating_sub(w) / 2;
        let y = area.y + area.height.saturating_sub(h) / 2;
        let dialog_rect = Rect::new(x, y, w, h);

        put(frame, Clear, dialog_rect);

        // Branded title on the top border: the OSA wordmark in the blue
        // grad_a -> grad_b gradient. Title lives on the border, so it adds no
        // layout rows and never disturbs the step flow below.
        let mut title_spans = vec![Span::raw(" ")];
        title_spans.extend(crate::style::gradient::theme_gradient("\u{25c6} OSA", true).spans);
        title_spans.push(Span::styled(
            " Setup ",
            Style::default()
                .fg(Color::White)
                .add_modifier(Modifier::BOLD),
        ));
        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.primary))
            .title(Line::from(title_spans).centered())
            .style(Style::default().bg(theme.colors.dialog_bg));
        put(frame, block, dialog_rect);

        let inner = Rect::new(
            dialog_rect.x + 1,
            dialog_rect.y + 1,
            dialog_rect.width.saturating_sub(2),
            dialog_rect.height.saturating_sub(2),
        );
        if inner.height < 5 {
            return;
        }

        let mut cy = inner.y;

        // Step indicator
        let step_line = self.render_step_indicator();
        put(frame, 
            Paragraph::new(step_line).alignment(Alignment::Center),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        // Separator
        let sep = "\u{2500}".repeat(inner.width as usize);
        put(frame, 
            Paragraph::new(sep.as_str()).style(Style::default().fg(theme.colors.dim)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        // Content area
        let content_area = Rect::new(inner.x, cy, inner.width, inner.height - (cy - inner.y) - 2);

        match self.step {
            0 => self.draw_step_provider(frame, content_area, &theme),
            1 => self.draw_step_details(frame, content_area, &theme),
            2 => self.draw_step_model(frame, content_area, &theme),
            3 => self.draw_step_verify(frame, content_area, &theme),
            4 => self.draw_step_channels(frame, content_area, &theme),
            5 => self.draw_step_identity(frame, content_area, &theme),
            6 => self.draw_step_confirm(frame, content_area, &theme),
            _ => {}
        }

        // Help bar
        let bottom_y = inner.y + inner.height.saturating_sub(1);
        let help = self.render_help_bar(&theme);
        put(frame, 
            Paragraph::new(help).alignment(Alignment::Center),
            Rect::new(inner.x, bottom_y, inner.width, 1),
        );
    }

    fn render_step_indicator(&self) -> Line<'static> {
        let mut spans = Vec::new();
        for (i, label) in STEP_LABELS.iter().enumerate() {
            if i > 0 {
                spans.push(Span::styled(
                    " \u{00b7} ",
                    Style::default().fg(Color::DarkGray),
                ));
            }
            let style = if i == self.step {
                Style::default()
                    .fg(Color::White)
                    .add_modifier(Modifier::BOLD)
            } else if i < self.step {
                Style::default().fg(Color::Green)
            } else {
                Style::default().fg(Color::DarkGray)
            };
            spans.push(Span::styled(label.to_string(), style));
        }
        Line::from(spans)
    }

    fn render_help_bar<'a>(&self, theme: &crate::style::Theme) -> Line<'a> {
        match self.step {
            0 => Line::from(vec![
                Span::styled("\u{2191}\u{2193}", theme.dialog_help_key()),
                Span::styled(" navigate  ", theme.dialog_help()),
                Span::styled("Enter", theme.dialog_help_key()),
                Span::styled(" select  ", theme.dialog_help()),
                Span::styled("Esc", theme.dialog_help_key()),
                Span::styled(" cancel", theme.dialog_help()),
            ]),
            1 => {
                let mut spans = Vec::new();
                if self.provider_needs_key() && self.provider_needs_url() {
                    spans.push(Span::styled("Tab", theme.dialog_help_key()));
                    spans.push(Span::styled(" switch field  ", theme.dialog_help()));
                }
                if self.provider_needs_key() {
                    spans.push(Span::styled("Ctrl+R", theme.dialog_help_key()));
                    spans.push(Span::styled(" show/hide  ", theme.dialog_help()));
                }
                spans.push(Span::styled("Enter", theme.dialog_help_key()));
                spans.push(Span::styled(" next  ", theme.dialog_help()));
                spans.push(Span::styled("Esc", theme.dialog_help_key()));
                spans.push(Span::styled(" back", theme.dialog_help()));
                Line::from(spans)
            }
            2 => Line::from(vec![
                Span::styled("\u{2191}\u{2193}", theme.dialog_help_key()),
                Span::styled(" navigate  ", theme.dialog_help()),
                Span::styled("Enter", theme.dialog_help_key()),
                Span::styled(" select  ", theme.dialog_help()),
                Span::styled("Esc", theme.dialog_help_key()),
                Span::styled(" back", theme.dialog_help()),
            ]),
            3 => Line::from(vec![
                Span::styled("r", theme.dialog_help_key()),
                Span::styled(" retry  ", theme.dialog_help()),
                Span::styled("Enter", theme.dialog_help_key()),
                Span::styled(" next  ", theme.dialog_help()),
                Span::styled("Esc", theme.dialog_help_key()),
                Span::styled(" back", theme.dialog_help()),
            ]),
            4 => {
                if self.current_channel_setup.is_some() {
                    Line::from(vec![
                        Span::styled("Tab", theme.dialog_help_key()),
                        Span::styled(" show/hide  ", theme.dialog_help()),
                        Span::styled("Enter", theme.dialog_help_key()),
                        Span::styled(" next  ", theme.dialog_help()),
                        Span::styled("Esc", theme.dialog_help_key()),
                        Span::styled(" back", theme.dialog_help()),
                    ])
                } else {
                    Line::from(vec![
                        Span::styled("Space", theme.dialog_help_key()),
                        Span::styled(" toggle  ", theme.dialog_help()),
                        Span::styled("Enter", theme.dialog_help_key()),
                        Span::styled(" next  ", theme.dialog_help()),
                        Span::styled("Esc", theme.dialog_help_key()),
                        Span::styled(" skip", theme.dialog_help()),
                    ])
                }
            }
            5 => Line::from(vec![
                Span::styled("Tab", theme.dialog_help_key()),
                Span::styled(" switch field  ", theme.dialog_help()),
                Span::styled("Enter", theme.dialog_help_key()),
                Span::styled(" next  ", theme.dialog_help()),
                Span::styled("Esc", theme.dialog_help_key()),
                Span::styled(" back", theme.dialog_help()),
            ]),
            6 => Line::from(vec![
                Span::styled("\u{2190}\u{2192}/Tab", theme.dialog_help_key()),
                Span::styled(" focus  ", theme.dialog_help()),
                Span::styled("Enter", theme.dialog_help_key()),
                Span::styled(" confirm", theme.dialog_help()),
            ]),
            _ => Line::default(),
        }
    }

    // ── Per-step draw methods ─────────────────────────────────────────────

    fn draw_step_provider(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &crate::style::Theme,
    ) {
        let mut cy = area.y + 1;

        put(frame, 
            Paragraph::new("How do you want to connect?")
                .style(theme.banner_title())
                .alignment(Alignment::Center),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        let mut last_group: Option<&str> = None;
        for (i, p) in self.data.providers.iter().enumerate() {
            if cy >= area.y + area.height {
                break;
            }
            let group = p.group.as_str();
            if last_group != Some(group) {
                let label = match group {
                    "recommended" => "  \u{2500}\u{2500} Recommended \u{2500}\u{2500}",
                    _ => "  \u{2500}\u{2500} Bring Your Own \u{2500}\u{2500}",
                };
                put(frame, 
                    Paragraph::new(label).style(Style::default().fg(theme.colors.dim)),
                    Rect::new(area.x, cy, area.width, 1),
                );
                cy += 1;
                last_group = Some(group);
            }

            let is_selected = self.selected_provider == i;
            let style = if is_selected {
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(theme.colors.muted)
            };
            let dot = if is_selected { "\u{25cf}" } else { "\u{25cb}" };
            let label = format!("    {} {}  ({})", dot, p.name, p.description);
            put(frame, 
                Paragraph::new(label).style(style),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 1;
        }
    }

    fn draw_step_details(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &crate::style::Theme,
    ) {
        let mut cy = area.y + 1;

        let provider_name = self
            .current_provider()
            .map(|p| p.name.as_str())
            .unwrap_or("Provider");

        put(frame, 
            Paragraph::new(format!("{} Setup", provider_name))
                .style(theme.banner_title())
                .alignment(Alignment::Center),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        // Signup URL hint
        if let Some(ref url) = self.current_provider().and_then(|p| p.signup_url.clone()) {
            put(frame, 
                Paragraph::new(format!("  Grab a key at {}", url))
                    .style(Style::default().fg(theme.colors.dim)),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 2;
        }

        if self.provider_needs_key() {
            let env_label = self
                .current_provider()
                .and_then(|p| p.env_var.clone())
                .unwrap_or_else(|| "API_KEY".to_string());

            put(frame, 
                Paragraph::new(format!("  {} :", env_label))
                    .style(Style::default().fg(theme.colors.muted)),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 1;

            let key_caret = if self.details_on_url() { "" } else { "_" };
            let display = if self.api_key_masked {
                format!("  {}{}", "\u{2022}".repeat(self.api_key.chars().count().min(64)), key_caret)
            } else {
                format!("  {}{}", self.api_key, key_caret)
            };
            put(frame, 
                Paragraph::new(display).style(
                    Style::default()
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD),
                ),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 2;

            // A provider that also offers account sign-in accepts an empty key
            // here: the backend then connects the signed-in local client
            // instead. Without this line the field looks mandatory and the
            // free route is invisible in this surface, which is how it stayed
            // unreachable from the TUI for so long.
            if self.provider_offers_account() {
                put(frame,
                    Paragraph::new("  Leave blank to use your signed-in account instead")
                        .style(Style::default().fg(theme.colors.dim)),
                    Rect::new(area.x, cy - 1, area.width, 1),
                );
            }
        }

        if self.provider_needs_url() {
            put(frame, 
                Paragraph::new("  Base URL:")
                    .style(Style::default().fg(theme.colors.muted)),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 1;

            let url_caret = if self.details_on_url() { "_" } else { "" };
            let url_display = format!("  {}{}", self.base_url, url_caret);
            put(frame, 
                Paragraph::new(url_display).style(
                    Style::default()
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD),
                ),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 2;
        }

        // Inline validation message (safe_render clips if it overflows).
        if let Some(ref err) = self.details_error {
            put(frame,
                Paragraph::new(format!("  {}", err))
                    .style(Style::default().fg(theme.colors.error).add_modifier(Modifier::BOLD)),
                Rect::new(area.x, cy, area.width, area.height.saturating_sub(cy - area.y)),
            );
        }
    }

    fn draw_step_model(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &crate::style::Theme,
    ) {
        let mut cy = area.y + 1;

        put(frame, 
            Paragraph::new("Choose a model")
                .style(theme.banner_title())
                .alignment(Alignment::Center),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        if self.model_list.is_empty() {
            // Manual input
            put(frame, 
                Paragraph::new("  Model name:")
                    .style(Style::default().fg(theme.colors.muted)),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 1;

            let display = format!("  {}_", self.model_input);
            put(frame, 
                Paragraph::new(display).style(
                    Style::default()
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD),
                ),
                Rect::new(area.x, cy, area.width, 1),
            );
        } else {
            // Selection list
            for (i, (_id, label)) in self.model_list.iter().enumerate() {
                if cy >= area.y + area.height {
                    break;
                }
                let is_selected = self.selected_model == i;
                let style = if is_selected {
                    Style::default()
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD)
                } else {
                    Style::default().fg(theme.colors.muted)
                };
                let dot = if is_selected { "\u{25cf}" } else { "\u{25cb}" };
                let line = format!("  {} {}", dot, label);
                // Fit by DISPLAY COLUMNS, not bytes and not chars: bytes would cut
                // mid-char on the 3-byte dot glyph, and a char count would let a
                // wide label overflow the row.
                let truncated = crate::util::fit_cols(&line, area.width as usize);
                put(frame, 
                    Paragraph::new(truncated).style(style),
                    Rect::new(area.x, cy, area.width, 1),
                );
                cy += 1;
            }
        }
    }

    fn draw_step_verify(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &crate::style::Theme,
    ) {
        let mut cy = area.y + 1;

        put(frame, 
            Paragraph::new("Verifying connection")
                .style(theme.banner_title())
                .alignment(Alignment::Center),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        let provider_name = self
            .current_provider()
            .map(|p| p.name.as_str())
            .unwrap_or("?");

        put(frame, 
            Paragraph::new(format!("  Provider: {}", provider_name))
                .style(Style::default().fg(theme.colors.muted)),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        match &self.verify_status {
            VerifyStatus::Pending => {
                put(frame, 
                    Paragraph::new("  \u{25d0} Testing connection...")
                        .style(Style::default().fg(theme.colors.secondary)),
                    Rect::new(area.x, cy, area.width, 1),
                );
            }
            VerifyStatus::Success { latency_ms } => {
                put(frame, 
                    Paragraph::new(format!("  \u{2713} Connection verified ({}ms)", latency_ms))
                        .style(Style::default().fg(Color::Green)),
                    Rect::new(area.x, cy, area.width, 1),
                );
            }
            VerifyStatus::Failed { message } => {
                put(frame, 
                    Paragraph::new(format!("  \u{2717} {}", message))
                        .style(Style::default().fg(Color::Red)),
                    Rect::new(area.x, cy, area.width, 1),
                );
                cy += 2;
                put(frame, 
                    Paragraph::new("  Couldn't connect \u{2014} press r to retry.")
                        .style(Style::default().fg(theme.colors.dim)),
                    Rect::new(area.x, cy, area.width, 1),
                );
            }
        }
    }

    fn draw_step_channels(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &crate::style::Theme,
    ) {
        if let Some(channel_idx) = self.current_channel_setup {
            self.draw_step_channel_token(frame, area, theme, channel_idx);
            return;
        }

        let mut cy = area.y + 1;

        put(frame, 
            Paragraph::new("Connect channels (optional)")
                .style(theme.banner_title())
                .alignment(Alignment::Center),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        put(frame, 
            Paragraph::new("  Reach OSA from Telegram, Discord, or Slack.")
                .style(Style::default().fg(theme.colors.muted)),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 1;
        put(frame, 
            Paragraph::new("  Skip to stay terminal-only.")
                .style(Style::default().fg(theme.colors.dim)),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        // Use confirm_selected as the channel list cursor when on this step
        let cursor = self.confirm_selected.min(CHANNELS.len().saturating_sub(1));

        for (i, (id, name, hint)) in CHANNELS.iter().enumerate() {
            if cy >= area.y + area.height {
                break;
            }
            let is_checked = self.selected_channels.get(i).copied().unwrap_or(false);
            let is_cursor = cursor == i;
            let has_token = self.channel_tokens.contains_key(*id);

            let check = if is_checked { "\u{25a0}" } else { "\u{25a1}" };
            let cursor_marker = if is_cursor { ">" } else { " " };
            let token_note = if is_checked && has_token { " \u{2713}" } else { "" };

            let style = if is_cursor {
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD)
            } else if is_checked {
                Style::default().fg(theme.colors.secondary)
            } else {
                Style::default().fg(theme.colors.muted)
            };

            let line = format!(
                "  {} [{}] {:<10}  \u{2014} {}{}",
                cursor_marker, check, name, hint, token_note
            );
            put(frame, 
                Paragraph::new(line).style(style),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 1;
        }
    }

    fn draw_step_channel_token(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &crate::style::Theme,
        channel_idx: usize,
    ) {
        // Defensive: fall back gracefully if the two const arrays ever drift
        // out of lockstep instead of indexing out of bounds.
        let name = CHANNELS.get(channel_idx).map(|(_, n, _)| *n).unwrap_or("Channel");
        let instructions: &[&str] = CHANNEL_INSTRUCTIONS.get(channel_idx).copied().unwrap_or(&[]);

        let mut cy = area.y + 1;

        put(frame, 
            Paragraph::new(format!("{} Setup", name))
                .style(theme.banner_title())
                .alignment(Alignment::Center),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        for line in instructions.iter() {
            if cy >= area.y + area.height {
                break;
            }
            put(frame, 
                Paragraph::new(format!("  {}", line))
                    .style(Style::default().fg(theme.colors.muted)),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 1;
        }
        cy += 1;

        put(frame, 
            Paragraph::new("  Bot Token:")
                .style(Style::default().fg(theme.colors.muted)),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 1;

        let display = if self.channel_token_masked {
            format!("  {}_", "\u{2022}".repeat(self.channel_token_input.chars().count().min(64)))
        } else {
            format!("  {}_", self.channel_token_input)
        };
        put(frame, 
            Paragraph::new(display).style(
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD),
            ),
            Rect::new(area.x, cy, area.width, 1),
        );
    }

    fn draw_step_identity(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &crate::style::Theme,
    ) {
        let mut cy = area.y + 1;

        put(frame, 
            Paragraph::new("What should I call you?")
                .style(theme.banner_title())
                .alignment(Alignment::Center),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        // User name field
        let user_label_style = if self.identity_focus == 0 {
            Style::default().fg(theme.colors.primary).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(theme.colors.muted)
        };
        put(frame, 
            Paragraph::new("  Your name:").style(user_label_style),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 1;

        let user_cursor = if self.identity_focus == 0 { "_" } else { "" };
        let user_display = format!("  {}{}", self.user_name_input, user_cursor);
        put(frame, 
            Paragraph::new(user_display).style(
                Style::default()
                    .fg(if self.identity_focus == 0 { theme.colors.primary } else { theme.colors.secondary })
                    .add_modifier(Modifier::BOLD),
            ),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        // Agent name field
        let agent_label_style = if self.identity_focus == 1 {
            Style::default().fg(theme.colors.primary).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(theme.colors.muted)
        };
        put(frame, 
            Paragraph::new("  Name your agent (or keep OSA):").style(agent_label_style),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 1;

        let agent_cursor = if self.identity_focus == 1 { "_" } else { "" };
        let agent_display = format!("  {}{}", self.agent_name_input, agent_cursor);
        put(frame, 
            Paragraph::new(agent_display).style(
                Style::default()
                    .fg(if self.identity_focus == 1 { theme.colors.primary } else { theme.colors.secondary })
                    .add_modifier(Modifier::BOLD),
            ),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        put(frame, 
            Paragraph::new("  Both optional \u{2014} press Enter to continue.")
                .style(Style::default().fg(theme.colors.dim)),
            Rect::new(area.x, cy, area.width, 1),
        );
    }

    fn draw_step_confirm(
        &self,
        frame: &mut Frame,
        area: Rect,
        theme: &crate::style::Theme,
    ) {
        let mut cy = area.y + 1;

        put(frame, 
            Paragraph::new("Ready to go")
                .style(theme.banner_title())
                .alignment(Alignment::Center),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 2;

        let provider_name = self
            .current_provider()
            .map(|p| p.name.as_str())
            .unwrap_or("\u{2014}");
        let model_name = if !self.model_list.is_empty() {
            self.model_list
                .get(self.selected_model)
                .map(|(id, _)| id.as_str())
                .unwrap_or("\u{2014}")
        } else if !self.model_input.is_empty() {
            &self.model_input
        } else {
            self.current_provider()
                .and_then(|p| p.default_model.as_deref())
                .unwrap_or("\u{2014}")
        };
        // Char-boundary-safe preview (reuses the shared helper) so a key with
        // multi-byte chars can never panic on a byte slice here.
        let key_display = Self::masked_key_preview(&self.api_key);

        // Build channels display string
        let channels_display: String = {
            let active: Vec<&str> = CHANNELS
                .iter()
                .enumerate()
                .filter(|(i, _)| self.selected_channels.get(*i).copied().unwrap_or(false))
                .map(|(_, (_, name, _))| *name)
                .collect();
            if active.is_empty() {
                "terminal only".to_string()
            } else {
                active.join(", ")
            }
        };

        let user_name_display = if self.user_name_input.trim().is_empty() {
            "not set".to_string()
        } else {
            self.user_name_input.trim().to_string()
        };
        let agent_name_display = if self.agent_name_input.trim().is_empty() {
            "OSA (default)".to_string()
        } else {
            self.agent_name_input.trim().to_string()
        };

        let summary = vec![
            ("Provider", provider_name.to_string()),
            ("Model", model_name.to_string()),
            ("API Key", key_display),
            ("Channels", channels_display),
            ("Your Name", user_name_display),
            ("Agent Name", agent_name_display),
        ];

        for (label, value) in &summary {
            if cy >= area.y + area.height.saturating_sub(3) {
                break;
            }
            let line = Line::from(vec![
                Span::styled(
                    format!("  {:10} ", label),
                    Style::default().fg(theme.colors.muted),
                ),
                Span::styled(value.clone(), Style::default().fg(theme.colors.secondary)),
            ]);
            put(frame, 
                Paragraph::new(line),
                Rect::new(area.x, cy, area.width, 1),
            );
            cy += 1;
        }

        cy += 1;
        put(frame, 
            Paragraph::new("  Change any of this later with /setup")
                .style(Style::default().fg(theme.colors.dim)),
            Rect::new(area.x, cy, area.width, 1),
        );
        cy += 1;
        // First-run security note (CC parity: onboarding securityStep).
        put(
            frame,
            Paragraph::new("  Review what I run \u{2014} only use OSA with code you trust.")
                .style(Style::default().fg(theme.colors.dim)),
            Rect::new(area.x, cy, area.width, 1),
        );

        // Buttons
        let btn_y = area.y + area.height.saturating_sub(2);
        let confirm_style = if self.confirm_selected == 0 {
            theme.button_active()
        } else {
            theme.button_inactive()
        };
        let back_style = if self.confirm_selected == 1 {
            theme.button_active()
        } else {
            theme.button_inactive()
        };

        let buttons = Line::from(vec![
            Span::styled("[ Let's go ]", confirm_style),
            Span::raw("   "),
            Span::styled("[ Back ]", back_style),
        ]);
        put(frame, 
            Paragraph::new(buttons).alignment(Alignment::Center),
            Rect::new(area.x, btn_y, area.width, 1),
        );
    }
}

#[cfg(test)]
mod onboarding_tests {
    use super::*;
    use crossterm::event::KeyCode;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    const SIZES: &[(u16, u16)] = &[(1, 1), (10, 3), (40, 12), (64, 28), (200, 60)];

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    /// A provider carrying a long, multi-byte model name so the model-row
    /// shortening path (leading ● + label) is exercised with mid-char cuts.
    fn provider_with_multibyte_model() -> OnboardingProvider {
        serde_json::from_value(serde_json::json!({
            "id": "custom",
            "name": "Provider \u{00e9}\u{00e9}\u{00e9}",
            "description": "multi-byte \u{20ac}\u{20ac}\u{20ac} description",
            "group": "recommended",
            "requires_key": false,
            "models": [
                { "id": "m1", "name": "\u{20ac}".repeat(60), "ctx": 1000000, "tools": true },
                { "id": "m2", "name": "gpt\u{2011}4o\u{2011}\u{4e2d}\u{6587}", "ctx": 128000 }
            ]
        }))
        .unwrap()
    }

    fn wizard_with(providers: Vec<OnboardingProvider>) -> OnboardingWizard {
        OnboardingWizard::new(OnboardingData {
            providers,
            system_info: std::collections::HashMap::new(),
        })
    }

    fn draw_at_all_sizes(wizard: &OnboardingWizard) {
        for &(w, h) in SIZES {
            let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
            term.draw(|f| {
                let area = f.area();
                wizard.draw(f, area);
            })
            .unwrap();
        }
    }

    #[test]
    fn draws_every_step_with_multibyte_model_without_panic() {
        let mut wizard = wizard_with(vec![provider_with_multibyte_model()]);
        // Walk the whole flow, drawing at every size at every step. Enter
        // advances; the model step lists the multi-byte labels. The custom
        // provider needs a base URL, so fill it before advancing.
        let _ = wizard.handle_key(key(KeyCode::Enter)); // -> details
        for c in "https://api.example.com/v1".chars() {
            let _ = wizard.handle_key(key(KeyCode::Char(c)));
        }
        for _ in 0..8 {
            draw_at_all_sizes(&wizard);
            let _ = wizard.handle_key(key(KeyCode::Enter));
        }
    }

    #[test]
    fn model_step_lists_multibyte_labels_without_panic() {
        let mut wizard = wizard_with(vec![provider_with_multibyte_model()]);
        // step0 -> step1 (details) -> step2 (model list). Custom provider needs
        // a base URL before it will advance out of details.
        let _ = wizard.handle_key(key(KeyCode::Enter));
        for c in "https://api.example.com/v1".chars() {
            let _ = wizard.handle_key(key(KeyCode::Char(c)));
        }
        let _ = wizard.handle_key(key(KeyCode::Enter));
        assert_eq!(wizard.flow_step(), 2);
        draw_at_all_sizes(&wizard);
        // Navigate the list too.
        let _ = wizard.handle_key(key(KeyCode::Down));
        draw_at_all_sizes(&wizard);
    }

    #[test]
    fn selected_provider_and_model_are_real_values_not_placeholders() {
        // Post-setup display must resolve to the user's actual choices, never a
        // "configured" / "default" placeholder. With a static model list, the
        // model id resolves even before the model step is reached (via the
        // provider default), and the provider id is always the selected one.
        let mut wizard = wizard_with(vec![serde_json::from_value(serde_json::json!({
            "id": "anthropic", "name": "Anthropic", "requires_key": true,
            "default_model": "claude-sonnet-4-6",
            "models": [
                { "id": "claude-sonnet-4-6", "name": "Claude Sonnet 4.6", "ctx": 1000000, "tools": true }
            ]
        }))
        .unwrap()]);

        assert_eq!(
            wizard.selected_provider_id().as_deref(),
            Some("anthropic"),
            "provider id must be the real selection, not a placeholder"
        );

        // Walk to the model step and select the listed model.
        let _ = wizard.handle_key(key(KeyCode::Enter)); // -> details
        let _ = wizard.handle_key(key(KeyCode::Enter)); // -> model
        let model = wizard.selected_model_id();
        assert_eq!(model.as_deref(), Some("claude-sonnet-4-6"));
        assert_ne!(model.as_deref(), Some("default"));
        assert_ne!(model.as_deref(), Some(""));
    }

    #[test]
    fn empty_providers_never_soft_locks_or_panics() {
        let mut wizard = wizard_with(vec![]);
        // No provider: needs_health_check must be false so the flow can't wait
        // on an un-buildable check, and drawing every step must not panic.
        assert!(!wizard.needs_health_check());
        for _ in 0..10 {
            draw_at_all_sizes(&wizard);
            let _ = wizard.handle_key(key(KeyCode::Enter));
        }
    }

    #[test]
    fn lone_quote_paste_does_not_panic() {
        // clean_pasted_key on a single quote char must not slice &value[1..0].
        for q in ["\"", "'", "`"] {
            assert_eq!(OnboardingWizard::clean_pasted_key(q), q);
        }
        // And through the live paste path on the key field.
        let mut wizard = wizard_with(vec![serde_json::from_value(serde_json::json!({
            "id": "openai", "name": "OpenAI", "requires_key": true,
        }))
        .unwrap()]);
        let _ = wizard.handle_key(key(KeyCode::Enter)); // -> details
        for q in ["\"", "'", "`"] {
            let _ = wizard.handle_paste(q);
        }
    }

    #[test]
    fn masked_key_preview_multibyte_never_panics() {
        for k in [
            "",
            "short",
            "\u{20ac}\u{20ac}\u{20ac}",                        // 9 bytes, 3 chars (<=8 chars)
            &"\u{20ac}".repeat(12),                            // long multi-byte
            "sk-aaaa\u{20ac}\u{20ac}\u{20ac}\u{20ac}bbbbcccc", // multi-byte head/tail region
        ] {
            let _ = OnboardingWizard::masked_key_preview(k);
        }
    }

    #[test]
    fn large_paste_into_key_is_capped() {
        let mut wizard = wizard_with(vec![serde_json::from_value(serde_json::json!({
            "id": "openai", "name": "OpenAI", "requires_key": true,
        }))
        .unwrap()]);
        let _ = wizard.handle_key(key(KeyCode::Enter)); // -> details
        let huge = "\u{20ac}".repeat(50_000);
        let _ = wizard.handle_paste(&huge);
        // Rendering the masked field must not allocate/burn on the whole blob.
        draw_at_all_sizes(&wizard);
        assert!(wizard.flow_api_key_display().chars().count() <= 64);
    }

    /// A custom / OpenAI-compatible provider that needs BOTH an API key and a
    /// base URL. This is the configuration issue #205 was reported against.
    fn provider_needs_key_and_url() -> OnboardingProvider {
        serde_json::from_value(serde_json::json!({
            "id": "custom",
            "name": "Custom",
            "requires_key": true,
            "env_var": "OPENAI_API_KEY",
        }))
        .unwrap()
    }

    fn ctrl(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::CONTROL)
    }

    fn type_str(wizard: &mut OnboardingWizard, s: &str) {
        for c in s.chars() {
            let _ = wizard.handle_key(key(KeyCode::Char(c)));
        }
    }

    #[test]
    fn base_url_field_is_reachable_and_captured_for_custom_provider() {
        // Regression for #205: a provider needing a key AND a base URL let the
        // user type only the key; the base URL field was unreachable, so
        // submission failed with an empty base URL.
        let mut wizard = wizard_with(vec![provider_needs_key_and_url()]);
        let _ = wizard.handle_key(key(KeyCode::Enter)); // -> details
        assert_eq!(wizard.flow_step(), 1);

        // Typing lands in the API key field first.
        type_str(&mut wizard, "sk-secret");
        assert!(!wizard.flow_details_on_url());

        // Tab moves focus to the Base URL field; now typing lands there.
        let _ = wizard.handle_key(key(KeyCode::Tab));
        assert!(wizard.flow_details_on_url());
        type_str(&mut wizard, "https://api.example.com/v1");

        // Enter now validates clean and advances (single provider skips the
        // model list -> lands on verify step 3).
        let _ = wizard.handle_key(key(KeyCode::Enter));
        assert!(wizard.flow_step() > 1, "should advance past details");

        let result = wizard.build_result().expect("result");
        assert_eq!(result.api_key.as_deref(), Some("sk-secret"));
        assert_eq!(result.base_url.as_deref(), Some("https://api.example.com/v1"));
    }

    #[test]
    fn empty_base_url_blocks_advance_with_guidance() {
        let mut wizard = wizard_with(vec![provider_needs_key_and_url()]);
        let _ = wizard.handle_key(key(KeyCode::Enter)); // -> details
        type_str(&mut wizard, "sk-secret"); // key only, no URL

        let _ = wizard.handle_key(key(KeyCode::Enter));
        // Blocked on details with an actionable message, focus steered to URL.
        assert_eq!(wizard.flow_step(), 1);
        let err = wizard.flow_details_error().expect("validation message");
        assert!(err.to_lowercase().contains("base url"));
        assert!(wizard.flow_details_on_url(), "focus moves to the URL field");

        // Editing clears the message and lets the user recover.
        type_str(&mut wizard, "https://api.example.com/v1");
        assert!(wizard.flow_details_error().is_none());
        let _ = wizard.handle_key(key(KeyCode::Enter));
        assert!(wizard.flow_step() > 1);
    }

    #[test]
    fn tab_navigates_fields_and_ctrl_r_toggles_visibility() {
        let mut wizard = wizard_with(vec![provider_needs_key_and_url()]);
        let _ = wizard.handle_key(key(KeyCode::Enter)); // -> details

        // Tab now navigates between fields instead of toggling the mask.
        assert!(wizard.flow_api_key_masked());
        let _ = wizard.handle_key(key(KeyCode::Tab));
        assert!(wizard.flow_api_key_masked(), "Tab must not toggle masking");
        assert!(wizard.flow_details_on_url());
        let _ = wizard.handle_key(key(KeyCode::BackTab));
        assert!(!wizard.flow_details_on_url());

        // Ctrl+R reveals / hides the key.
        let _ = wizard.handle_key(ctrl(KeyCode::Char('r')));
        assert!(!wizard.flow_api_key_masked());
        let _ = wizard.handle_key(ctrl(KeyCode::Char('r')));
        assert!(wizard.flow_api_key_masked());
    }

    #[test]
    fn channel_token_step_renders_without_panic() {
        let mut wizard = wizard_with(vec![provider_with_multibyte_model()]);
        // Advance to channels (step 4): provider(0)->details(1)->model(2)->verify(3)->channels(4)
        let _ = wizard.handle_key(key(KeyCode::Enter)); // -> details
        for c in "https://api.example.com/v1".chars() {
            let _ = wizard.handle_key(key(KeyCode::Char(c)));
        }
        for _ in 0..3 {
            let _ = wizard.handle_key(key(KeyCode::Enter));
        }
        // Toggle a channel on and open its token screen.
        let _ = wizard.handle_key(key(KeyCode::Char(' ')));
        let _ = wizard.handle_key(key(KeyCode::Enter));
        draw_at_all_sizes(&wizard);
    }
}
