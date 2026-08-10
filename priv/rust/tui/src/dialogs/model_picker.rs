/// Provider-first model picker — a 3-mode state machine living entirely in this
/// file: `Providers` (choose a provider, with ✓ ready / ⚠ needs-key status),
/// `Models` (drill into a configured provider's models), and `KeyEntry` (a
/// tight, paste-friendly, live-verifying API-key screen).
///
/// Reverse-engineered from Claude Code / OpenCode: status tags, configured
/// indicators ("Anthropic (api)"), a "Default (recommended)" top row, and a
/// dedicated key screen instead of the clunky 7-step onboarding wizard.
use std::cell::Cell;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

use crate::client::types::{DetectedProvidersResponse, OnboardingModel, OnboardingProvider};

/// Narrowest the dialog is allowed to get before it simply takes the whole
/// terminal. Also the width it used to be pinned at, unconditionally.
const MIN_W: u16 = 82;

/// Widest it may grow. Past roughly this, a centred box stops reading as a
/// dialog and the eye has too far to travel between a provider's name on the
/// left and its description on the right.
const MAX_W: u16 = 120;

const MAX_H: u16 = 30;

// ── Action ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub enum ModelPickerAction {
    /// A model was chosen for an already-configured provider.
    SelectModel {
        provider: String,
        runtime_provider: String,
        model: String,
        base_url: Option<String>,
    },
    Cancel,
    /// Fire a live health-check for a candidate key on the key screen.
    VerifyKey {
        provider: String,
        api_key: Option<String>,
        model: String,
        base_url: Option<String>,
    },
    /// Key verified — persist it (merging into .env) and switch to it.
    SaveKeyAndSwitch {
        provider: String,
        runtime_provider: String,
        api_key: Option<String>,
        model: String,
        base_url: Option<String>,
    },
    /// Load a provider's dynamic model list (miosa / ollama_local / custom).
    LoadProviderModels {
        provider: String,
        base_url: Option<String>,
        api_key: Option<String>,
    },
    /// Begin an account sign-in for a provider (no key involved).
    ///
    /// Non-terminal: the picker STAYS OPEN and switches to `AccountLogin`, so
    /// a device-code grant can render its user code and poll to completion
    /// inside the TUI. Closing the dialog here is what previously made every
    /// browser-based sign-in a "run this in another terminal" instruction.
    StartAccountLogin { provider: String, model: String },
    /// Ask the backend to abandon an in-flight sign-in (Esc on the wait screen).
    CancelAccountLogin { session_id: String },
    /// Retry the initial `/onboarding/status` catalog+detection fetch.
    /// Reachable from Providers mode any time (not just after a load
    /// failure) so a newcomer is never stuck on a stale/degraded list.
    Reload,
}

// ── Internal enums ───────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq)]
enum PickerMode {
    Providers,
    Models,
    KeyEntry,
    /// An account sign-in is in flight. Owns the screen while it runs so the
    /// code and URL stay on-screen for the whole grant, which for a
    /// device-code provider is the only place the user can read them.
    AccountLogin,
}

/// How the user proves who they are for a provider.
///
/// These are the catalog's `auth_modes` and nothing else. There used to be a
/// hardcoded per-provider match here deciding which methods a provider
/// offered — a second capability list, disagreeing with the backend's, which
/// is precisely the failure this codebase spent effort making unrepresentable
/// on the Elixir side. Every account provider except Ollama Cloud was
/// therefore invisible in this screen: the list said `PasteKey` only, for
/// providers that have no key to paste.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum AuthMethod {
    PasteKey,
    /// Connect an account rather than paste a credential. Covers a local CLI
    /// read, a signed-in daemon, an AWS credential chain and a browser device
    /// code alike — the backend knows which, and the difference shows up as
    /// whether a code appears to be typed.
    Account,
}

#[derive(Clone, PartialEq)]
enum VerifyState {
    Idle,
    Verifying,
    Valid { latency_ms: u64 },
    Invalid { reason: String },
    Error { reason: String },
}

struct KeyEntryState {
    provider_id: String,
    provider_name: String,
    signup_url: Option<String>,
    base_url: Option<String>,
    default_model: Option<String>,
    api_key: String,
    masked: bool,
    auth_method: AuthMethod,
    methods: Vec<AuthMethod>,
    verify: VerifyState,
}

/// What the sign-in screen is showing right now.
///
/// `provider_id` and `model` are carried through the whole wait so that a
/// success can save and switch without re-deriving them — the picker has
/// already been through provider selection at this point, and asking again
/// after a fifteen-minute grant would be absurd.
struct AccountLoginState {
    provider_id: String,
    provider_name: String,
    model: String,
    /// None until `POST /auth/login/start` answers. Cancel is unavailable for
    /// that window, which is well under a second.
    session_id: Option<String>,
    /// "starting" | "pending" | "connected" | "failed" | "cancelled".
    state: String,
    user_code: Option<String>,
    verification_uri: Option<String>,
    message: Option<String>,
    /// Advances once per poll so the wait is visibly alive. A spinner that
    /// does not move is indistinguishable from a hung process, which is the
    /// second-worst thing after a wait you cannot cancel.
    tick: usize,
    /// The browser is opened at most ONCE per sign-in. The poll fires every
    /// second for up to fifteen minutes; opening on every reading would spawn
    /// nine hundred browser tabs.
    browser_opened: bool,
}

impl KeyEntryState {
    fn method_idx(&self) -> usize {
        self.methods
            .iter()
            .position(|m| *m == self.auth_method)
            .unwrap_or(0)
    }

    fn cycle_method(&mut self) {
        if self.methods.len() <= 1 {
            return;
        }
        let next = (self.method_idx() + 1) % self.methods.len();
        self.auth_method = self.methods[next];
        // Changing method resets any prior verification result.
        self.verify = VerifyState::Idle;
    }
}

// ── State ────────────────────────────────────────────────────────────────────

pub struct ModelPicker {
    providers: Vec<OnboardingProvider>,
    detected: Option<DetectedProvidersResponse>,
    /// Sorted indices into `providers` (priority order).
    order: Vec<usize>,
    mode: PickerMode,
    current_provider: String,
    current_model: String,

    /// Providers-mode cursor: 0 = "Default (recommended)", 1.. = order[i-1].
    prov_cursor: usize,
    prov_scroll: usize,
    filter: String,

    /// Models mode.
    models: Vec<OnboardingModel>,
    models_cursor: usize,
    models_scroll: usize,
    /// The onboarding provider id whose models we're viewing.
    models_provider: String,
    models_base_url: Option<String>,

    key_entry: Option<KeyEntryState>,

    /// The in-flight account sign-in, when `mode == AccountLogin`.
    account_login: Option<AccountLoginState>,

    /// Rows the provider/model list can actually show — measured on every draw
    /// (via `Cell`, since `draw` takes `&self`) so handle_key scroll math
    /// matches the real dialog height instead of the MAX_H upper bound.
    list_viewport: Cell<usize>,

    /// True when this picker was built from `new_fallback` (the real
    /// `/onboarding/status` fetch failed). Drives a banner + retry hint so
    /// the user knows they're on a degraded static catalog and can ask for
    /// a fresh one instead of silently being stuck on stale data.
    load_failed: bool,
}

impl ModelPicker {
    pub fn new_provider_first(
        providers: Vec<OnboardingProvider>,
        detected: Option<DetectedProvidersResponse>,
        current_provider: String,
        current_model: String,
    ) -> Self {
        let order = Self::sorted_order(&providers);
        Self {
            providers,
            detected,
            order,
            mode: PickerMode::Providers,
            current_provider,
            current_model,
            prov_cursor: 0,
            prov_scroll: 0,
            filter: String::new(),
            models: Vec::new(),
            models_cursor: 0,
            models_scroll: 0,
            models_provider: String::new(),
            models_base_url: None,
            key_entry: None,
            account_login: None,
            list_viewport: Cell::new((MAX_H as usize).saturating_sub(6)),
            load_failed: false,
        }
    }

    /// Hotfix: hardcoded, offline fallback catalog used ONLY when the
    /// `/onboarding/status` fetch that would normally populate the picker
    /// fails (backend unreachable, transient error, etc.). Without this the
    /// picker simply never opens on a load failure — a hard dead-end for a
    /// newcomer with nothing left to retry against. Mirrors the shape of
    /// `Onboarding.providers_list/0`'s top entries closely enough that key
    /// entry / device-identity verify / save-and-switch all still work; the
    /// full dynamic catalog (extra providers, live model lists) reappears
    /// the moment a retry of the real fetch succeeds.
    pub fn new_fallback(current_provider: String, current_model: String) -> Self {
        let providers = vec![
            OnboardingProvider {
                id: "ollama_cloud".to_string(),
                name: "Ollama Cloud".to_string(),
                description: "No GPU needed — recommended".to_string(),
                group: "recommended".to_string(),
                requires_key: serde_json::Value::Bool(true),
                env_var: Some("OLLAMA_API_KEY".to_string()),
                default_model: Some("glm-5.2:cloud".to_string()),
                base_url: Some("https://ollama.com".to_string()),
                signup_url: Some("https://ollama.com/download".to_string()),
                auth_modes: None,
                models: serde_json::Value::String("dynamic".to_string()),
                ..Default::default()
            },
            OnboardingProvider {
                id: "anthropic".to_string(),
                name: "Anthropic".to_string(),
                description: "Claude models".to_string(),
                group: "popular".to_string(),
                requires_key: serde_json::Value::Bool(true),
                env_var: Some("ANTHROPIC_API_KEY".to_string()),
                default_model: Some("claude-sonnet-4-20250514".to_string()),
                base_url: None,
                signup_url: Some("https://console.anthropic.com/settings/keys".to_string()),
                auth_modes: None,
                models: serde_json::Value::String("dynamic".to_string()),
                ..Default::default()
            },
            OnboardingProvider {
                id: "openai".to_string(),
                name: "OpenAI".to_string(),
                description: "GPT models".to_string(),
                group: "popular".to_string(),
                requires_key: serde_json::Value::Bool(true),
                env_var: Some("OPENAI_API_KEY".to_string()),
                default_model: Some("gpt-4o".to_string()),
                base_url: Some("https://api.openai.com/v1".to_string()),
                signup_url: Some("https://platform.openai.com/api-keys".to_string()),
                auth_modes: None,
                models: serde_json::Value::String("dynamic".to_string()),
                ..Default::default()
            },
            OnboardingProvider {
                id: "ollama_local".to_string(),
                name: "Ollama (local)".to_string(),
                description: "Run models on this machine".to_string(),
                group: "local".to_string(),
                requires_key: serde_json::Value::String("optional".to_string()),
                env_var: None,
                default_model: Some("llama3.2".to_string()),
                base_url: Some("http://localhost:11434".to_string()),
                signup_url: None,
                auth_modes: None,
                models: serde_json::Value::String("dynamic".to_string()),
                ..Default::default()
            },
        ];
        let mut picker = Self::new_provider_first(providers, None, current_provider, current_model);
        picker.load_failed = true;
        picker
    }

    // ── Sorting / lookup ─────────────────────────────────────────────────────

    fn priority(id: &str) -> usize {
        const PINNED: [&str; 7] = [
            "ollama_cloud",
            "miosa",
            "anthropic",
            "openai",
            "openrouter",
            "ollama_local",
            "custom",
        ];
        PINNED.iter().position(|p| *p == id).unwrap_or(99)
    }

    /// Rank a provider's tab. Accounts first: a plan the user already pays for
    /// beats asking them for a new credential, and burying the free routes
    /// among 27 key providers is exactly why they were invisible.
    fn tab_rank(p: &OnboardingProvider) -> usize {
        match Self::tab_of(p) {
            "accounts" => 0,
            _ => 1,
        }
    }

    /// Ordering: tab, then the backend's curated `order`, then name.
    ///
    /// `order` is preferred over the local `priority()` table because the
    /// latter is a second, drifting copy of a decision the catalog already
    /// makes — the same duplication that let this screen's idea of which
    /// providers offer sign-in diverge from the backend's. `priority()`
    /// survives only as the tiebreak for a backend that sends no `order`.
    fn sorted_order(providers: &[OnboardingProvider]) -> Vec<usize> {
        let mut idx: Vec<usize> = (0..providers.len()).collect();
        idx.sort_by(|&a, &b| {
            let (pa, pb) = (&providers[a], &providers[b]);
            Self::tab_rank(pa)
                .cmp(&Self::tab_rank(pb))
                .then_with(|| match (pa.order, pb.order) {
                    (Some(x), Some(y)) => x.cmp(&y),
                    _ => Self::priority(&pa.id).cmp(&Self::priority(&pb.id)),
                })
                .then_with(|| pa.name.cmp(&pb.name))
        });
        idx
    }

    /// The section heading a row opens, if it is the first of its tab in the
    /// current (filtered) view. `None` for every other row.
    ///
    /// Returned rather than pre-baked into the list so filtering cannot strand
    /// a heading above zero rows — a "Connect an account" header with nothing
    /// under it reads as a broken fetch.
    pub(crate) fn section_heading(&self, idx: usize) -> Option<&'static str> {
        let vis = self.visible_providers();
        let pos = vis.iter().position(|&i| i == idx)?;
        let this = Self::tab_of(&self.providers[idx]);
        let prev = pos
            .checked_sub(1)
            .map(|p| Self::tab_of(&self.providers[vis[p]]));
        if prev == Some(this) {
            return None;
        }
        Some(match this {
            "accounts" => "Connect an account",
            _ => "Paste an API key",
        })
    }

    fn runtime_provider(id: &str) -> String {
        match id {
            "ollama_cloud" | "ollama_local" | "ollama" => "ollama",
            "miosa" => "miosa",
            "anthropic" => "anthropic",
            "openai" | "custom" => "openai",
            "openrouter" => "openrouter",
            other => other,
        }
        .to_string()
    }

    fn requires_key(p: &OnboardingProvider) -> bool {
        match &p.requires_key {
            serde_json::Value::Bool(b) => *b,
            // "optional" → not required (custom); "true" → required.
            serde_json::Value::String(s) => s != "optional",
            _ => false,
        }
    }

    fn detected_ids(&self) -> Vec<String> {
        self.detected
            .as_ref()
            .map(|d| d.detected.iter().map(|x| x.provider.clone()).collect())
            .unwrap_or_default()
    }

    fn ollama_local_reachable(&self) -> bool {
        self.detected
            .as_ref()
            .and_then(|d| d.ollama_local.as_ref())
            .map(|o| o.reachable)
            .unwrap_or(false)
    }

    /// True when a provider is ready to use without further key entry.
    ///
    /// The backend's `auth.state` wins wherever it is present, because
    /// `requires_key` cannot answer this question and pretending it could is
    /// what produced the shipped defect: `openai_codex` is `requires_key:
    /// false` (there is no key — it is sign-in only), so this returned `true`
    /// for a provider nobody had signed into. The picker then drilled straight
    /// into its `:dynamic` model list, and the user saw `Failed to load
    /// models: HTTP 401` where a "connect your account" prompt belonged.
    ///
    /// Keyless is not the same as configured. `auth.state` is the field that
    /// knows the difference.
    fn is_ready(&self, p: &OnboardingProvider) -> bool {
        if let Some(auth) = p.auth.as_ref() {
            match auth.state.as_str() {
                "connected" | "connected_unverified" => return true,
                // Sign-in required and not done — or done and lapsed. Either
                // way the answer is the sign-in screen, never a model list.
                "needs_sign_in" | "expired" => return false,
                // "needs_key" and "unknown" fall through to key detection
                // below, which is the pre-`auth` behaviour and still correct
                // for the 27 key-only providers.
                _ => {}
            }
        }

        let detected = self.detected_ids();
        match p.id.as_str() {
            // REQUIREMENT 1: Ollama Cloud is ready either with a stored key OR
            // via a signed-in local Ollama daemon (device identity, key-free).
            "ollama_cloud" => detected.contains(&p.id) || self.ollama_local_reachable(),
            "ollama_local" => self.ollama_local_reachable(),
            _ => {
                if !Self::requires_key(p) {
                    true
                } else {
                    detected.contains(&p.id)
                }
            }
        }
    }

    /// The tab a provider belongs to: `"accounts"` (connect a plan) or
    /// `"keys"` (paste a credential).
    ///
    /// Read from the backend's field, falling back to the derivation an older
    /// backend implies. Grouping is the reason an account-capable provider can
    /// no longer render as key-only: it is not in that group.
    fn tab_of(p: &OnboardingProvider) -> &str {
        if let Some(t) = p.tab.as_deref() {
            return t;
        }
        let offers_account = p
            .usable_auth_modes
            .as_ref()
            .or(p.auth_modes.as_ref())
            .map(|m| m.iter().any(|x| x == "oauth"))
            .unwrap_or(false);
        if offers_account {
            "accounts"
        } else {
            "keys"
        }
    }

    /// OpenCode-style configured suffix, e.g. " (api)".
    ///
    /// A connected subscription is badged differently from a pasted key on
    /// purpose: they are the same "configured" state but very different
    /// billing, and "(api)" against an account sign-in reads as "you are
    /// paying per token" to a user who chose the provider precisely to avoid
    /// that. The backend already reports which it is in `source`.
    fn configured_suffix(&self, p: &OnboardingProvider) -> &'static str {
        match self
            .detected
            .as_ref()
            .and_then(|d| d.detected.iter().find(|x| x.provider == p.id))
        {
            Some(d) if d.source == "subscription" => " (account)",
            Some(_) => " (api)",
            None => "",
        }
    }

    fn static_models(p: &OnboardingProvider) -> Option<Vec<OnboardingModel>> {
        p.models
            .as_array()
            .map(|_| serde_json::from_value::<Vec<OnboardingModel>>(p.models.clone()).unwrap_or_default())
    }

    fn provider_matches_filter(&self, p: &OnboardingProvider) -> bool {
        if self.filter.is_empty() {
            return true;
        }
        let f = self.filter.to_lowercase();
        p.name.to_lowercase().contains(&f) || p.id.to_lowercase().contains(&f)
    }

    /// Visible provider indices (filtered), in sorted order.
    fn visible_providers(&self) -> Vec<usize> {
        self.order
            .iter()
            .copied()
            .filter(|&i| self.provider_matches_filter(&self.providers[i]))
            .collect()
    }

    // ── Key handling ─────────────────────────────────────────────────────────

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<ModelPickerAction> {
        match self.mode {
            PickerMode::Providers => self.handle_providers_key(key),
            PickerMode::Models => self.handle_models_key(key),
            PickerMode::KeyEntry => self.handle_key_entry_key(key),
            PickerMode::AccountLogin => self.handle_account_login_key(key),
        }
    }

    fn handle_providers_key(&mut self, key: KeyEvent) -> Option<ModelPickerAction> {
        if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('r') {
            // Hotfix: retry the catalog/detection fetch on demand — covers
            // both the fallback-catalog-after-failure case and a normal
            // "detection changed since I opened this" refresh (e.g. the
            // user just signed in to a local Ollama daemon in another pane).
            return Some(ModelPickerAction::Reload);
        }
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return None;
        }
        let vis = self.visible_providers();
        let total = vis.len() + 1; // +1 for the "Default" row
        match key.code {
            KeyCode::Esc => return Some(ModelPickerAction::Cancel),
            KeyCode::Up | KeyCode::Char('k') if self.filter.is_empty() => {
                if self.prov_cursor > 0 {
                    self.prov_cursor -= 1;
                }
                self.adjust_prov_scroll();
            }
            KeyCode::Up => {
                if self.prov_cursor > 0 {
                    self.prov_cursor -= 1;
                }
                self.adjust_prov_scroll();
            }
            KeyCode::Down | KeyCode::Char('j') if self.filter.is_empty() => {
                if self.prov_cursor + 1 < total {
                    self.prov_cursor += 1;
                }
                self.adjust_prov_scroll();
            }
            KeyCode::Down => {
                if self.prov_cursor + 1 < total {
                    self.prov_cursor += 1;
                }
                self.adjust_prov_scroll();
            }
            KeyCode::Enter => {
                if self.prov_cursor == 0 {
                    // "Default (recommended)" resolves to the CURRENT model —
                    // selecting it keeps the current setup, so just close.
                    return Some(ModelPickerAction::Cancel);
                }
                let sel = vis.get(self.prov_cursor - 1).copied()?;
                return self.activate_provider(sel);
            }
            KeyCode::Backspace => {
                self.filter.pop();
                self.prov_cursor = 0;
                self.prov_scroll = 0;
            }
            KeyCode::Char(c) => {
                self.filter.push(c);
                self.prov_cursor = 0;
                self.prov_scroll = 0;
            }
            _ => {}
        }
        None
    }

    /// Enter pressed on a provider row: drill into models (ready) or open the
    /// key screen (needs a key).
    fn activate_provider(&mut self, idx: usize) -> Option<ModelPickerAction> {
        let p = self.providers[idx].clone();
        if self.is_ready(&p) {
            // Ready → show its models.
            self.models_provider = p.id.clone();
            // CRITICAL: Ollama Cloud that's ready ONLY via the local device
            // identity (no stored OLLAMA_API_KEY) must run its :cloud models
            // through the LOCAL daemon (localhost), NOT ollama.com — otherwise
            // saving the selection would write OLLAMA_URL=https://ollama.com with
            // no key and every request 401s. Use the cloud base_url only when an
            // actual key is present.
            let key_free_ollama =
                p.id == "ollama_cloud" && !self.detected_ids().contains(&p.id);
            self.models_base_url = if key_free_ollama {
                Some("http://localhost:11434".to_string())
            } else {
                p.base_url.clone()
            };
            if let Some(models) = Self::static_models(&p) {
                self.models = models;
                self.models_cursor = 0;
                self.models_scroll = 0;
                self.mode = PickerMode::Models;
                None
            } else {
                // Dynamic catalog — fetch from backend (which falls back to the
                // provider's configured key), stay open.
                return Some(ModelPickerAction::LoadProviderModels {
                    provider: p.id.clone(),
                    base_url: self.models_base_url.clone(),
                    api_key: None,
                });
            }
        } else {
            // Needs a key → open the dedicated key screen.
            self.open_key_entry(&p);
            None
        }
    }

    /// The auth methods a provider offers, straight from its catalog entry.
    ///
    /// Falls back to `PasteKey` when the backend sent no `auth_modes` at all,
    /// which is what an older backend does. Degrading to the key prompt is
    /// the safe direction: it is the behaviour every provider had before
    /// account modes existed, and it can never offer a route that cannot
    /// complete.
    fn auth_methods(p: &OnboardingProvider) -> Vec<AuthMethod> {
        // Three sources, most-decided first. All three are the backend's
        // answer, never this file's — the point is that there is no second
        // capability list here to drift.
        //
        //   1. `auth.can_sign_in` / `can_paste_key`: the collapsed answer the
        //      backend has already worked out for THIS machine and THIS
        //      credential state. Preferred, because re-deriving it here is how
        //      the two surfaces come to disagree.
        //   2. `usable_auth_modes`: `auth_modes` minus anything this build
        //      cannot actually run (no compiled client id, no installed CLI).
        //   3. `auth_modes`: what the provider offers in principle.
        //
        // An older backend sends none of them, and the fallback is `PasteKey`
        // — the behaviour every provider had before account modes existed, and
        // one that can never offer a route that cannot complete.
        if let Some(auth) = p.auth.as_ref() {
            let mut out = Vec::new();
            if auth.can_sign_in {
                out.push(AuthMethod::Account);
            }
            if auth.can_paste_key {
                out.push(AuthMethod::PasteKey);
            }
            if !out.is_empty() {
                return out;
            }
        }

        let modes = p
            .usable_auth_modes
            .as_ref()
            .filter(|m| !m.is_empty())
            .or(p.auth_modes.as_ref().filter(|m| !m.is_empty()));

        let modes = match modes {
            Some(m) => m,
            None => return vec![AuthMethod::PasteKey],
        };

        let mut out = Vec::new();
        if modes.iter().any(|m| m == "oauth") {
            out.push(AuthMethod::Account);
        }
        if modes.iter().any(|m| m == "api_key") {
            out.push(AuthMethod::PasteKey);
        }
        if out.is_empty() {
            out.push(AuthMethod::PasteKey);
        }
        out
    }

    fn open_key_entry(&mut self, p: &OnboardingProvider) {
        // Derived from the catalog's `auth_modes` — the single capability
        // source of truth every other surface reads — and from nothing else.
        // A hardcoded list here is a second source that WILL drift; it already
        // had, which is why an account provider could be selected in this
        // screen and then only be offered a key field it has no key for.
        //
        // Account first, matching the order the CLI surfaces render (sign-in
        // above paste-a-key), so the two do not disagree about which is the
        // primary route.
        let methods = Self::auth_methods(p);
        let initial = *methods.first().unwrap_or(&AuthMethod::PasteKey);
        self.key_entry = Some(KeyEntryState {
            provider_id: p.id.clone(),
            provider_name: p.name.clone(),
            signup_url: p.signup_url.clone(),
            base_url: p.base_url.clone(),
            default_model: p.default_model.clone(),
            api_key: String::new(),
            masked: true,
            auth_method: initial,
            methods,
            verify: VerifyState::Idle,
        });
        self.mode = PickerMode::KeyEntry;
    }

    fn handle_models_key(&mut self, key: KeyEvent) -> Option<ModelPickerAction> {
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return None;
        }
        let vis = self.visible_models();
        match key.code {
            KeyCode::Esc => {
                self.mode = PickerMode::Providers;
                self.filter.clear();
            }
            KeyCode::Up | KeyCode::Char('k') if self.filter.is_empty() => {
                self.models_cursor = self.models_cursor.saturating_sub(1);
                self.adjust_models_scroll();
            }
            KeyCode::Up => {
                self.models_cursor = self.models_cursor.saturating_sub(1);
                self.adjust_models_scroll();
            }
            KeyCode::Down | KeyCode::Char('j') if self.filter.is_empty() => {
                if self.models_cursor + 1 < vis.len() {
                    self.models_cursor += 1;
                }
                self.adjust_models_scroll();
            }
            KeyCode::Down => {
                if self.models_cursor + 1 < vis.len() {
                    self.models_cursor += 1;
                }
                self.adjust_models_scroll();
            }
            KeyCode::Enter => {
                let midx = vis.get(self.models_cursor).copied()?;
                let model = self.models[midx].id.clone();
                return Some(ModelPickerAction::SelectModel {
                    provider: self.models_provider.clone(),
                    runtime_provider: Self::runtime_provider(&self.models_provider),
                    model,
                    base_url: self.models_base_url.clone(),
                });
            }
            KeyCode::Backspace => {
                self.filter.pop();
                self.models_cursor = 0;
                self.models_scroll = 0;
            }
            KeyCode::Char(c) => {
                self.filter.push(c);
                self.models_cursor = 0;
                self.models_scroll = 0;
            }
            _ => {}
        }
        None
    }

    fn visible_models(&self) -> Vec<usize> {
        let f = self.filter.to_lowercase();
        self.models
            .iter()
            .enumerate()
            .filter(|(_, m)| {
                self.filter.is_empty()
                    || m.name.to_lowercase().contains(&f)
                    || m.id.to_lowercase().contains(&f)
            })
            .map(|(i, _)| i)
            .collect()
    }

    fn handle_key_entry_key(&mut self, key: KeyEvent) -> Option<ModelPickerAction> {
        // Match the mask/reveal chord BEFORE the Ctrl/Alt guard.
        if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('r') {
            if let Some(ke) = self.key_entry.as_mut() {
                ke.masked = !ke.masked;
            }
            return None;
        }
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return None;
        }

        match key.code {
            KeyCode::Esc => {
                self.mode = PickerMode::Providers;
                self.key_entry = None;
            }
            KeyCode::Tab => {
                if let Some(ke) = self.key_entry.as_mut() {
                    ke.cycle_method();
                }
            }
            KeyCode::Backspace => {
                if let Some(ke) = self.key_entry.as_mut() {
                    ke.api_key.pop();
                    ke.verify = VerifyState::Idle;
                }
            }
            KeyCode::Char(c) => {
                if let Some(ke) = self.key_entry.as_mut() {
                    ke.api_key.push(c);
                    ke.verify = VerifyState::Idle;
                }
            }
            KeyCode::Enter => return self.key_entry_submit(),
            _ => {}
        }
        None
    }

    fn key_entry_submit(&mut self) -> Option<ModelPickerAction> {
        let ke = self.key_entry.as_mut()?;
        let model = ke
            .default_model
            .clone()
            .unwrap_or_else(|| "default".to_string());

        match ke.auth_method {
            AuthMethod::Account => {
                // Hand off to the backend's out-of-band sign-in and stay on
                // screen. Whether this finishes in 50ms (a local CLI read, an
                // AWS credential chain, a signed-in daemon) or needs a browser
                // and a typed code is the backend's business — the picker
                // renders whatever state comes back, so a new provider needs
                // no new case here.
                let provider = ke.provider_id.clone();
                Some(ModelPickerAction::StartAccountLogin { provider, model })
            }
            AuthMethod::PasteKey => {
                if ke.api_key.trim().is_empty() {
                    return None;
                }
                match &ke.verify {
                    VerifyState::Valid { .. } => {
                        // Second Enter → save + switch.
                        let provider = ke.provider_id.clone();
                        let api_key = ke.api_key.clone();
                        let base_url = ke.base_url.clone();
                        ke.verify = VerifyState::Idle;
                        Some(ModelPickerAction::SaveKeyAndSwitch {
                            runtime_provider: Self::runtime_provider(&provider),
                            provider,
                            api_key: Some(api_key),
                            model,
                            base_url,
                        })
                    }
                    VerifyState::Verifying => None,
                    // Hotfix: this used to fall into the catch-all "re-verify"
                    // branch below, which meant a rejected key OR a transport
                    // error (ollama_cloud's Bearer-vs-device-identity mismatch,
                    // a flaky network, etc.) could NEVER be saved — the user
                    // was stuck re-verifying forever with no way to finish
                    // onboarding. A second, unmodified Enter after seeing the
                    // failure now saves the key and moves on: an explicitly
                    // rejected key (401/403) is still saved so the user can
                    // fix it later with `osa setup` / the in-app key screen,
                    // and an unverified/network error is by definition not
                    // proof the key is bad, so it must never block completion.
                    VerifyState::Invalid { .. } | VerifyState::Error { .. } => {
                        let provider = ke.provider_id.clone();
                        let api_key = ke.api_key.clone();
                        let base_url = ke.base_url.clone();
                        ke.verify = VerifyState::Idle;
                        Some(ModelPickerAction::SaveKeyAndSwitch {
                            runtime_provider: Self::runtime_provider(&provider),
                            provider,
                            api_key: Some(api_key),
                            model,
                            base_url,
                        })
                    }
                    VerifyState::Idle => {
                        // First Enter → verify.
                        ke.verify = VerifyState::Verifying;
                        Some(ModelPickerAction::VerifyKey {
                            provider: ke.provider_id.clone(),
                            api_key: Some(ke.api_key.clone()),
                            model,
                            base_url: ke.base_url.clone(),
                        })
                    }
                }
            }
        }
    }

    // ── Paste + verify-result setters (called from the app layer) ────────────

    pub fn is_key_entry(&self) -> bool {
        self.mode == PickerMode::KeyEntry
    }

    pub fn handle_paste(&mut self, text: &str) {
        if let Some(ke) = self.key_entry.as_mut() {
            let cleaned = clean_pasted_key(text);
            ke.api_key.push_str(&cleaned);
            ke.verify = VerifyState::Idle;
        }
    }

    pub fn set_verify_success(&mut self, latency_ms: u64) {
        if let Some(ke) = self.key_entry.as_mut() {
            ke.verify = VerifyState::Valid { latency_ms };
        }
    }

    pub fn set_verify_failed(&mut self, reason: String) {
        if let Some(ke) = self.key_entry.as_mut() {
            ke.verify = VerifyState::Invalid { reason };
        }
    }

    pub fn set_verify_error(&mut self, reason: String) {
        if let Some(ke) = self.key_entry.as_mut() {
            ke.verify = VerifyState::Error { reason };
        }
    }

    /// Push a freshly-loaded dynamic model list and switch to Models mode.
    pub fn set_provider_models(&mut self, models: Vec<OnboardingModel>) {
        self.models = models;
        self.models_cursor = 0;
        self.models_scroll = 0;
        self.filter.clear();
        self.mode = PickerMode::Models;
    }

    // ── Scroll helpers ───────────────────────────────────────────────────────

    fn list_height(&self) -> usize {
        // Measured from the last draw; the MAX_H-derived estimate only applies
        // before the first frame. Fixes the short-terminal bug where scroll
        // math assumed the full-height dialog and let the cursor walk off the
        // visible list.
        self.list_viewport.get().max(1)
    }

    fn adjust_prov_scroll(&mut self) {
        let visible = self.list_height();
        if self.prov_cursor < self.prov_scroll {
            self.prov_scroll = self.prov_cursor;
        } else if self.prov_cursor >= self.prov_scroll + visible {
            self.prov_scroll = self.prov_cursor - visible + 1;
        }
    }

    fn adjust_models_scroll(&mut self) {
        let visible = self.list_height();
        if self.models_cursor < self.models_scroll {
            self.models_scroll = self.models_cursor;
        } else if self.models_cursor >= self.models_scroll + visible {
            self.models_scroll = self.models_cursor - visible + 1;
        }
    }

    // ── Drawing ──────────────────────────────────────────────────────────────

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();

        // Grow with the terminal instead of sitting at a fixed 82 columns.
        //
        // The rows here are two-column — name + status on the left, the
        // provider's description right-aligned — and the description is
        // dropped entirely when what remains is too narrow to read. Pinning
        // the dialog at 82 meant a wide terminal changed nothing: a long row
        // ("Claude subscription (via Claude Code)  ✓ signed in as
        // someone@example.com") consumed the line, its description silently
        // vanished, and the user was looking at 60 columns of unused screen
        // beside a box that had run out of room. The drop is by design — a
        // truncated status is worse than a missing description — but it should
        // be a last resort on a genuinely narrow terminal, not the normal case
        // on a wide one.
        let w = area
            .width
            .saturating_sub(8)
            .max(MIN_W)
            .min(MAX_W)
            .min(area.width);
        let h = MAX_H.min(area.height);
        let x = area.x + area.width.saturating_sub(w) / 2;
        let y = area.y + area.height.saturating_sub(h) / 2;
        let dialog_rect = Rect::new(x, y, w, h);

        frame.render_widget(Clear, dialog_rect);

        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.primary))
            .style(Style::default().bg(theme.colors.dialog_bg));
        frame.render_widget(block, dialog_rect);

        let inner = Rect::new(
            dialog_rect.x + 1,
            dialog_rect.y + 1,
            dialog_rect.width.saturating_sub(2),
            dialog_rect.height.saturating_sub(2),
        );
        if inner.height < 4 {
            return;
        }

        match self.mode {
            PickerMode::Providers => self.draw_providers(frame, inner, &theme),
            PickerMode::Models => self.draw_models(frame, inner, &theme),
            PickerMode::KeyEntry => self.draw_key_entry(frame, inner, &theme),
            PickerMode::AccountLogin => self.draw_account_login(frame, inner, &theme),
        }
    }

    /// The badge on a provider row, and what it is allowed to claim.
    ///
    /// The shipped version had exactly two outcomes — "✓ ready" or "⚠ needs
    /// key" — and that second string is a bug for any provider with no key to
    /// need. `ChatGPT (Codex)` is sign-in only; telling a user it "needs key"
    /// sends them looking for an OpenAI API key, which is the one credential
    /// that endpoint will not accept. It was the literal text of one of the
    /// reported symptoms.
    ///
    /// Reads the backend's `auth.state`, so a row can never advertise a route
    /// the backend does not have.
    fn status_tag(
        &self,
        p: &OnboardingProvider,
        theme: &crate::style::Theme,
    ) -> (String, Style) {
        let success = Style::default().fg(theme.colors.success);
        let warning = Style::default().fg(theme.colors.warning);

        if let Some(auth) = p.auth.as_ref() {
            match auth.state.as_str() {
                // Name the account when the backend knows it. "signed in" with
                // no whom is the state a user re-checks; "signed in as x@y" is
                // the one they trust.
                "connected" | "connected_unverified" => {
                    let who = auth
                        .account
                        .as_deref()
                        .filter(|a| !a.is_empty())
                        .map(|a| format!("✓ signed in as {}", a))
                        .unwrap_or_else(|| "✓ signed in".to_string());
                    return (who, success);
                }
                "expired" => return ("⚠ sign-in expired".to_string(), warning),
                "needs_sign_in" => {
                    // A provider that ALSO takes a key says so, so the free
                    // route is visible without hiding the paid one.
                    let label = if auth.can_paste_key {
                        "→ connect account or key"
                    } else {
                        "→ connect account"
                    };
                    return (label.to_string(), Style::default().fg(theme.colors.primary));
                }
                _ => {}
            }
        }

        if self.is_ready(p) {
            ("✓ ready".to_string(), success)
        } else {
            ("⚠ needs key".to_string(), warning)
        }
    }

    fn draw_providers(&self, frame: &mut Frame, inner: Rect, theme: &crate::style::Theme) {
        let mut cy = inner.y;

        let title = Paragraph::new("Select Provider")
            .style(theme.dialog_title())
            .alignment(Alignment::Center);
        frame.render_widget(title, Rect::new(inner.x, cy, inner.width, 1));
        cy += 1;

        let vis = self.visible_providers();
        let filter_line = if self.filter.is_empty() {
            format!("  Filter: _  ({} providers)", vis.len())
        } else {
            format!("  Filter: {}_  ({} providers)", self.filter, vis.len())
        };
        frame.render_widget(
            Paragraph::new(filter_line).style(Style::default().fg(theme.colors.secondary)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        // Hotfix: on the offline fallback catalog, say so and offer a retry
        // instead of silently showing a shorter list with no explanation.
        if self.load_failed {
            frame.render_widget(
                Paragraph::new(
                    "  ⚠ Couldn't reach the server — showing a basic list. Ctrl+R to retry.",
                )
                .style(Style::default().fg(theme.colors.warning)),
                Rect::new(inner.x, cy, inner.width, 1),
            );
            cy += 1;
        }

        let sep = "─".repeat(inner.width as usize);
        frame.render_widget(
            Paragraph::new(sep.as_str()).style(Style::default().fg(theme.colors.dim)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        let list_h = inner.height.saturating_sub(cy - inner.y + 1);
        self.list_viewport.set((list_h as usize).max(1));
        // Render-time clamp: the cursor row stays inside the window even when
        // the stored offset predates a terminal resize.
        let scroll = super::clamp_scroll_to_cursor(
            self.prov_scroll,
            self.prov_cursor,
            (list_h as usize).max(1),
        );

        // The renderable list interleaves non-selectable section headings with
        // the selectable rows (Default + visible providers). Navigation still
        // indexes the SELECTABLE rows only — `prov_cursor` is untouched — so
        // headings can never be landed on, and arrow keys do not stutter over
        // them. `None` marks a heading; `Some(i)` is selectable index `i`.
        let mut render_rows: Vec<(Option<usize>, &'static str)> = vec![(Some(0), "")];
        for (n, &pi) in vis.iter().enumerate() {
            if let Some(h) = self.section_heading(pi) {
                render_rows.push((None, h));
            }
            render_rows.push((Some(n + 1), ""));
        }

        // `prov_scroll` is stored in selectable space; translate it into render
        // space, then let the shared clamp guarantee the cursor is on screen.
        let cursor_render = render_rows
            .iter()
            .position(|(s, _)| *s == Some(self.prov_cursor))
            .unwrap_or(0);
        let scroll_render = render_rows
            .iter()
            .position(|(s, _)| *s == Some(scroll))
            .unwrap_or(0);
        let scroll = super::clamp_scroll_to_cursor(
            scroll_render,
            cursor_render,
            (list_h as usize).max(1),
        );

        let total_rows = render_rows.len();
        for rel in 0..(list_h as usize) {
            let abs_render = rel + scroll;
            if abs_render >= total_rows {
                break;
            }
            let ry = cy + rel as u16;

            let abs = match render_rows[abs_render] {
                (None, heading) => {
                    frame.render_widget(
                        Paragraph::new(Span::styled(
                            format!("  {}", heading),
                            Style::default()
                                .fg(theme.colors.secondary)
                                .add_modifier(Modifier::BOLD),
                        )),
                        Rect::new(inner.x, ry, inner.width, 1),
                    );
                    continue;
                }
                (Some(i), _) => i,
            };

            let is_selected = abs == self.prov_cursor;
            let cursor_char = if is_selected { "▸" } else { " " };
            let row_style = if is_selected {
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(theme.colors.muted)
            };

            if abs == 0 {
                // Default (recommended)
                let spans = vec![
                    Span::styled(format!("{} ", cursor_char), row_style),
                    Span::styled("Default (recommended)", row_style),
                    Span::styled(
                        format!("  · current: {}", self.current_model),
                        Style::default().fg(theme.colors.dim),
                    ),
                ];
                frame.render_widget(
                    Paragraph::new(Line::from(spans)),
                    Rect::new(inner.x, ry, inner.width, 1),
                );
                continue;
            }

            let p = &self.providers[vis[abs - 1]];
            let (tag, tag_style) = self.status_tag(p, theme);
            let suffix = self.configured_suffix(p);

            let mut spans = vec![
                Span::styled(format!("{} ", cursor_char), row_style),
                Span::styled(p.name.clone(), row_style),
            ];
            if !suffix.is_empty() {
                spans.push(Span::styled(
                    suffix,
                    Style::default().fg(theme.colors.success),
                ));
            }
            spans.push(Span::raw("  "));
            spans.push(Span::styled(tag, tag_style));

            // The name+status column is sized to what it actually needs, and
            // the description takes whatever is genuinely left over.
            //
            // It was a hard 46 columns, sized back when the tag was only
            // "✓ ready" or "⚠ needs key". The tag now carries the answer to
            // the question this screen exists to answer — "✓ signed in as
            // someone@example.com" — and beside a long provider name that
            // truncated to "✓ sig". A status the user cannot read is the same
            // as no status, whereas a clipped description costs nothing: it
            // repeats the provider's marketing line.
            //
            // So the priority is explicit — name and status first, description
            // last — rather than implied by a fixed split that happened to fit
            // the strings of the day.
            use unicode_width::UnicodeWidthStr;
            let needed: usize = spans.iter().map(|s| s.content.width()).sum();
            let name_w = (needed as u16 + 2).min(inner.width);
            frame.render_widget(
                Paragraph::new(Line::from(spans)),
                Rect::new(inner.x, ry, name_w, 1),
            );

            // Dim capability hint on the right side of the row — only when
            // there is a readable amount of room after the columns that matter.
            let hint_w = inner.width.saturating_sub(name_w);
            if !p.description.is_empty() && hint_w >= 14 {
                let hint = format!("{}  ", p.description);
                let para = Paragraph::new(Span::styled(
                    hint,
                    Style::default().fg(theme.colors.dim),
                ))
                .alignment(Alignment::Right);
                frame.render_widget(para, Rect::new(inner.x + name_w, ry, hint_w, 1));
            }
        }

        self.draw_help(
            frame,
            inner,
            theme,
            &[
                ("↑↓/jk", "nav"),
                ("Enter", "open"),
                ("type", "filter"),
                ("Ctrl+R", "reload"),
                ("Esc", "cancel"),
            ],
        );
    }

    fn draw_models(&self, frame: &mut Frame, inner: Rect, theme: &crate::style::Theme) {
        let mut cy = inner.y;

        let title = Paragraph::new(format!("Models · {}", self.models_provider))
            .style(theme.dialog_title())
            .alignment(Alignment::Center);
        frame.render_widget(title, Rect::new(inner.x, cy, inner.width, 1));
        cy += 1;

        let vis = self.visible_models();
        let filter_line = if self.filter.is_empty() {
            format!("  Filter: _  ({} models)", vis.len())
        } else {
            format!("  Filter: {}_  ({} models)", self.filter, vis.len())
        };
        frame.render_widget(
            Paragraph::new(filter_line).style(Style::default().fg(theme.colors.secondary)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        let sep = "─".repeat(inner.width as usize);
        frame.render_widget(
            Paragraph::new(sep.as_str()).style(Style::default().fg(theme.colors.dim)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        let list_h = inner.height.saturating_sub(cy - inner.y + 1);
        self.list_viewport.set((list_h as usize).max(1));
        let scroll = super::clamp_scroll_to_cursor(
            self.models_scroll,
            self.models_cursor,
            (list_h as usize).max(1),
        );

        if vis.is_empty() {
            frame.render_widget(
                Paragraph::new(Span::styled(
                    "No models",
                    Style::default().fg(theme.colors.muted),
                ))
                .alignment(Alignment::Center),
                Rect::new(inner.x, cy + list_h / 2, inner.width, 1),
            );
        }

        for rel in 0..(list_h as usize) {
            let abs = rel + scroll;
            if abs >= vis.len() {
                break;
            }
            let ry = cy + rel as u16;
            let m = &self.models[vis[abs]];
            let is_selected = abs == self.models_cursor;
            let cursor_char = if is_selected { "▸" } else { " " };
            let row_style = if is_selected {
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(theme.colors.muted)
            };

            let mut spans = vec![
                Span::styled(format!("{} ", cursor_char), row_style),
                Span::styled(
                    if m.name.is_empty() { m.id.clone() } else { m.name.clone() },
                    row_style,
                ),
            ];
            if m.recommended {
                spans.push(Span::styled(
                    " ★",
                    Style::default().fg(theme.colors.success),
                ));
            }
            if m.ctx > 0 {
                let ctx = if m.ctx >= 1_000_000 {
                    format!(" {}M ctx", m.ctx / 1_000_000)
                } else if m.ctx >= 1_000 {
                    format!(" {}K ctx", m.ctx / 1_000)
                } else {
                    format!(" {} ctx", m.ctx)
                };
                spans.push(Span::styled(ctx, Style::default().fg(theme.colors.dim)));
            }
            if m.tools {
                spans.push(Span::styled(
                    " ⚒tools",
                    Style::default().fg(theme.colors.dim),
                ));
            }
            frame.render_widget(
                Paragraph::new(Line::from(spans)),
                Rect::new(inner.x, ry, inner.width, 1),
            );

            // Second-line tagline (note), rendered dim on the same row's right.
            if let Some(note) = &m.note {
                if !note.is_empty() && inner.width > 44 {
                    let hint_w = inner.width.saturating_sub(44);
                    let para = Paragraph::new(Span::styled(
                        format!("{}  ", note),
                        Style::default().fg(theme.colors.dim),
                    ))
                    .alignment(Alignment::Right);
                    frame.render_widget(para, Rect::new(inner.x + 44, ry, hint_w, 1));
                }
            }
        }

        self.draw_help(
            frame,
            inner,
            theme,
            &[
                ("↑↓/jk", "nav"),
                ("Enter", "select"),
                ("Esc", "back"),
            ],
        );
    }

    // ── Account sign-in ──────────────────────────────────────────────────

    /// Enter the wait screen. Called by the app the moment it dispatches the
    /// start request, so there is never a frame where the user pressed Enter
    /// and nothing changed.
    pub fn begin_account_login(&mut self, provider_id: String, model: String) {
        let provider_name = self
            .providers
            .iter()
            .find(|p| p.id == provider_id)
            .map(|p| p.name.clone())
            .unwrap_or_else(|| provider_id.clone());

        self.account_login = Some(AccountLoginState {
            provider_id,
            provider_name,
            model,
            session_id: None,
            state: "starting".to_string(),
            user_code: None,
            verification_uri: None,
            message: None,
            tick: 0,
            browser_opened: false,
        });
        self.mode = PickerMode::AccountLogin;
    }

    /// Fold one poll result into the wait screen.
    ///
    /// Returns the action to take when the sign-in has reached a terminal
    /// state, so the caller does not have to re-derive it: `Some(...)` means
    /// "we are done, do this". A still-running sign-in returns `None` and the
    /// screen keeps waiting.
    pub fn apply_account_login(
        &mut self,
        session: &crate::client::types::LoginSessionResponse,
    ) -> Option<ModelPickerAction> {
        let al = self.account_login.as_mut()?;
        al.tick = al.tick.wrapping_add(1);
        al.state = session.state.clone();
        if !session.id.is_empty() {
            al.session_id = Some(session.id.clone());
        }
        if session.user_code.is_some() {
            al.user_code = session.user_code.clone();
        }
        // Prefer the URL that already embeds the code: it is one fewer thing
        // for the user to type, and providers that offer it do so precisely
        // because typing a code in a browser is the step people get wrong.
        if session.verification_uri_complete.is_some() || session.verification_uri.is_some() {
            al.verification_uri = session
                .verification_uri_complete
                .clone()
                .or_else(|| session.verification_uri.clone());
        }
        al.message = session.message.clone();

        if session.state == "connected" {
            let provider = al.provider_id.clone();
            let model = al.model.clone();
            return Some(ModelPickerAction::SaveKeyAndSwitch {
                runtime_provider: Self::runtime_provider(&provider),
                provider,
                // No key: the credential lives in the backend's own store (or
                // in the vendor client that owns it). Sending an empty string
                // here would write a blank entry into `.env` and shadow the
                // real credential on the next turn.
                api_key: None,
                model,
                base_url: None,
            });
        }
        None
    }

    /// The verification URL, the first time there is one to open.
    ///
    /// Opening the browser is the CLIENT's job, not the backend's: a gateway
    /// serving a remote TUI that opened a browser would open it on the wrong
    /// machine. It is also the one departure from "everything happens in the
    /// TUI" that is unavoidable — the consent screen belongs to the provider.
    ///
    /// Returns `Some` exactly once, and the URL stays on screen either way, so
    /// a machine with no browser (a bare SSH session) loses nothing.
    pub fn take_url_to_open(&mut self) -> Option<String> {
        let al = self.account_login.as_mut()?;
        if al.browser_opened {
            return None;
        }
        let uri = al.verification_uri.clone()?;
        al.browser_opened = true;
        Some(uri)
    }

    /// The session id to cancel, if the wait screen owns one.
    pub fn account_login_session_id(&self) -> Option<String> {
        self.account_login.as_ref().and_then(|al| al.session_id.clone())
    }

    fn handle_account_login_key(&mut self, key: KeyEvent) -> Option<ModelPickerAction> {
        match key.code {
            KeyCode::Esc => {
                // Esc always leaves, whether or not the backend can be told.
                // A wait screen that traps the user because a cancel request
                // failed is worse than an orphaned grant, which the backend
                // abandons on its own deadline anyway.
                let id = self.account_login_session_id();
                self.account_login = None;
                self.mode = PickerMode::Providers;
                id.map(|session_id| ModelPickerAction::CancelAccountLogin { session_id })
            }
            KeyCode::Enter => {
                // On a terminal failure Enter goes back to the provider list
                // rather than retrying blindly — the message on screen usually
                // names something the user has to fix elsewhere first.
                let terminal = self
                    .account_login
                    .as_ref()
                    .map(|al| al.state == "failed" || al.state == "cancelled")
                    .unwrap_or(false);
                if terminal {
                    self.account_login = None;
                    self.mode = PickerMode::Providers;
                }
                None
            }
            _ => None,
        }
    }

    fn draw_account_login(&self, frame: &mut Frame, inner: Rect, theme: &crate::style::Theme) {
        let al = match &self.account_login {
            Some(a) => a,
            None => return,
        };
        let mut cy = inner.y + 1;

        frame.render_widget(
            Paragraph::new(format!("Connect {}", al.provider_name))
                .style(theme.dialog_title())
                .alignment(Alignment::Center),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 2;

        match al.state.as_str() {
            "failed" | "cancelled" => {
                let text = al
                    .message
                    .clone()
                    .unwrap_or_else(|| "Sign-in did not complete.".to_string());
                for line in wrap_text(&text, inner.width.saturating_sub(4) as usize) {
                    frame.render_widget(
                        Paragraph::new(Span::styled(
                            format!("  {}", line),
                            Style::default().fg(theme.colors.warning),
                        )),
                        Rect::new(inner.x, cy, inner.width, 1),
                    );
                    cy += 1;
                }
                cy += 1;
                frame.render_widget(
                    Paragraph::new(Span::styled(
                        "  Enter or Esc to go back — you can pick another provider.",
                        Style::default().fg(theme.colors.dim),
                    )),
                    Rect::new(inner.x, cy, inner.width, 1),
                );
            }
            _ => {
                // The code, big and alone on its line. This is the single most
                // important string on the screen: the user is about to
                // transcribe it into a browser, and burying it in a sentence
                // is how it gets mistyped.
                if let Some(code) = &al.user_code {
                    frame.render_widget(
                        Paragraph::new(Span::styled(
                            "  1. Open this page in your browser:",
                            Style::default().fg(theme.colors.secondary),
                        )),
                        Rect::new(inner.x, cy, inner.width, 1),
                    );
                    cy += 1;

                    if let Some(uri) = &al.verification_uri {
                        frame.render_widget(
                            Paragraph::new(Span::styled(
                                format!("     {}", uri),
                                Style::default()
                                    .fg(theme.colors.primary)
                                    .add_modifier(Modifier::UNDERLINED),
                            )),
                            Rect::new(inner.x, cy, inner.width, 1),
                        );
                        cy += 2;
                    }

                    frame.render_widget(
                        Paragraph::new(Span::styled(
                            "  2. Enter this code:",
                            Style::default().fg(theme.colors.secondary),
                        )),
                        Rect::new(inner.x, cy, inner.width, 1),
                    );
                    cy += 1;
                    frame.render_widget(
                        Paragraph::new(Span::styled(
                            format!("     {}", code),
                            Style::default()
                                .fg(theme.colors.primary)
                                .add_modifier(Modifier::BOLD),
                        )),
                        Rect::new(inner.x, cy, inner.width, 1),
                    );
                    cy += 2;

                    // Codex's anti-phishing line, verbatim in intent: a device
                    // code is exactly the shape of a credential-theft lure, and
                    // the only defence is telling the user who should have
                    // started this.
                    frame.render_widget(
                        Paragraph::new(Span::styled(
                            "  Continue only if you started this sign-in. If someone sent you",
                            Style::default().fg(theme.colors.dim),
                        )),
                        Rect::new(inner.x, cy, inner.width, 1),
                    );
                    cy += 1;
                    frame.render_widget(
                        Paragraph::new(Span::styled(
                            "  this code, press Esc.",
                            Style::default().fg(theme.colors.dim),
                        )),
                        Rect::new(inner.x, cy, inner.width, 1),
                    );
                    cy += 2;
                } else {
                    frame.render_widget(
                        Paragraph::new(Span::styled(
                            "  Connecting…",
                            Style::default().fg(theme.colors.secondary),
                        )),
                        Rect::new(inner.x, cy, inner.width, 1),
                    );
                    cy += 2;
                }

                const FRAMES: [&str; 4] = ["|", "/", "-", "\\"];
                frame.render_widget(
                    Paragraph::new(Span::styled(
                        format!("  {} Waiting for approval…", FRAMES[al.tick % FRAMES.len()]),
                        Style::default().fg(theme.colors.dim),
                    )),
                    Rect::new(inner.x, cy, inner.width, 1),
                );
            }
        }

        self.draw_help(frame, inner, theme, &[("Esc", "cancel")]);
    }

    fn draw_key_entry(&self, frame: &mut Frame, inner: Rect, theme: &crate::style::Theme) {
        let ke = match &self.key_entry {
            Some(k) => k,
            None => return,
        };
        let mut cy = inner.y + 1;

        let title = Paragraph::new(format!("Connect {}", ke.provider_name))
            .style(theme.dialog_title())
            .alignment(Alignment::Center);
        frame.render_widget(title, Rect::new(inner.x, cy, inner.width, 1));
        cy += 2;

        // Auth-method toggle (only shown when more than one method exists).
        if ke.methods.len() > 1 {
            let mut spans = vec![Span::styled(
                "  Method: ",
                Style::default().fg(theme.colors.secondary),
            )];
            for (i, m) in ke.methods.iter().enumerate() {
                let label = match m {
                    AuthMethod::PasteKey => "Paste API key",
                    AuthMethod::Account => "Connect account",
                };
                let selected = *m == ke.auth_method;
                let style = if selected {
                    Style::default()
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD)
                } else {
                    Style::default().fg(theme.colors.dim)
                };
                if i > 0 {
                    spans.push(Span::styled(" · ", Style::default().fg(theme.colors.dim)));
                }
                spans.push(Span::styled(label, style));
            }
            frame.render_widget(
                Paragraph::new(Line::from(spans)),
                Rect::new(inner.x, cy, inner.width, 1),
            );
            cy += 2;
        }

        // Contextual help line with the create-key URL.
        if let Some(url) = &ke.signup_url {
            frame.render_widget(
                Paragraph::new(Span::styled(
                    format!("  Get a key: {}", url),
                    Style::default().fg(theme.colors.dim),
                )),
                Rect::new(inner.x, cy, inner.width, 1),
            );
            cy += 2;
        }

        match ke.auth_method {
            AuthMethod::Account => {
                frame.render_widget(
                    Paragraph::new(Span::styled(
                        "  Uses your existing account — no API key needed. Enter to connect.",
                        Style::default().fg(theme.colors.secondary),
                    )),
                    Rect::new(inner.x, cy, inner.width, 1),
                );
                cy += 2;
            }
            AuthMethod::PasteKey => {
                // Masked field.
                let shown = if ke.api_key.is_empty() {
                    "Enter your API key".to_string()
                } else if ke.masked {
                    "•".repeat(ke.api_key.chars().count().min(48))
                } else {
                    ke.api_key.clone()
                };
                let field_style = if ke.api_key.is_empty() {
                    Style::default().fg(theme.colors.dim)
                } else {
                    Style::default().fg(theme.colors.muted)
                };
                let spans = vec![
                    Span::styled("  ▏", Style::default().fg(theme.colors.primary)),
                    Span::styled(shown, field_style),
                    Span::styled("_", Style::default().fg(theme.colors.primary)),
                ];
                frame.render_widget(
                    Paragraph::new(Line::from(spans)),
                    Rect::new(inner.x, cy, inner.width, 1),
                );
                cy += 2;
            }
        }

        // Live verification status line.
        let (status_text, status_style) = match &ke.verify {
            VerifyState::Idle => (String::new(), Style::default()),
            VerifyState::Verifying => (
                "  Verifying…".to_string(),
                Style::default().fg(theme.colors.secondary),
            ),
            VerifyState::Valid { latency_ms } => (
                format!("  ✓ Key valid ({} ms) — press Enter to save", latency_ms),
                Style::default().fg(theme.colors.success),
            ),
            VerifyState::Invalid { reason } => (
                format!(
                    "  ✗ Invalid key: {} — edit key to retry, or Enter again to save anyway",
                    reason
                ),
                Style::default().fg(theme.colors.error),
            ),
            VerifyState::Error { reason } => (
                format!(
                    "  ⚠ Could not verify (network/API): {} — press Enter to save and continue",
                    reason
                ),
                Style::default().fg(theme.colors.warning),
            ),
        };
        if !status_text.is_empty() {
            frame.render_widget(
                Paragraph::new(Span::styled(status_text, status_style)),
                Rect::new(inner.x, cy, inner.width, 1),
            );
        }

        let help: &[(&str, &str)] = match ke.auth_method {
            AuthMethod::PasteKey => &[
                ("Enter", "verify/save"),
                ("Ctrl+R", "reveal"),
                ("Tab", "method"),
                ("Esc", "back"),
            ],
            _ => &[("Enter", "continue"), ("Tab", "method"), ("Esc", "back")],
        };
        self.draw_help(frame, inner, theme, help);
    }

    fn draw_help(
        &self,
        frame: &mut Frame,
        inner: Rect,
        theme: &crate::style::Theme,
        entries: &[(&str, &str)],
    ) {
        let bottom_y = inner.y + inner.height.saturating_sub(1);
        let mut spans: Vec<Span> = Vec::new();
        for (k, label) in entries {
            spans.push(Span::styled(*k, theme.dialog_help_key()));
            spans.push(Span::styled(format!(" {}  ", label), theme.dialog_help()));
        }
        frame.render_widget(
            Paragraph::new(Line::from(spans)).alignment(Alignment::Center),
            Rect::new(inner.x, bottom_y, inner.width, 1),
        );
    }
}

/// Clean pasted text: strip shell export prefix, quotes, whitespace, semicolons.
/// Mirrors the onboarding wizard's paste handling.
fn clean_pasted_key(raw: &str) -> String {
    let trimmed = raw.trim();
    let value = if let Some(idx) = trimmed.find('=') {
        trimmed[idx + 1..].trim()
    } else {
        trimmed
    };
    let unquoted = if value.len() >= 2
        && ((value.starts_with('"') && value.ends_with('"'))
            || (value.starts_with('\'') && value.ends_with('\''))
            || (value.starts_with('`') && value.ends_with('`')))
    {
        &value[1..value.len().saturating_sub(1)]
    } else {
        value
    };
    unquoted.strip_suffix(';').unwrap_or(unquoted).trim().to_string()
}

#[cfg(test)]
mod hotfix_tests {
    //! Regression coverage for the onboarding-TUI hotfix: a verify failure
    //! (rejected key OR network/unverified error) must never dead-end the
    //! key-entry screen, and a failed initial catalog fetch must never leave
    //! the picker unopenable.
    use super::*;
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn ctrl(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::CONTROL)
    }

    fn ollama_cloud_provider() -> OnboardingProvider {
        OnboardingProvider {
            id: "ollama_cloud".to_string(),
            name: "Ollama Cloud".to_string(),
            description: "No GPU needed".to_string(),
            group: "recommended".to_string(),
            requires_key: serde_json::Value::Bool(true),
            env_var: Some("OLLAMA_API_KEY".to_string()),
            default_model: Some("glm-5.2:cloud".to_string()),
            base_url: Some("https://ollama.com".to_string()),
            signup_url: None,
            auth_modes: None,
            usable_auth_modes: None,
            tab: None,
            order: None,
            auth: None,
            models: serde_json::Value::String("dynamic".to_string()),
        }
    }

    fn picker_with_key_entry() -> ModelPicker {
        let mut picker = ModelPicker::new_provider_first(
            vec![ollama_cloud_provider()],
            None,
            "anthropic".to_string(),
            "claude".to_string(),
        );
        picker.open_key_entry(&ollama_cloud_provider());
        picker.mode = PickerMode::KeyEntry;
        picker
    }

    // ── PasteKey: rejected key or network error must both be save-able ──────

    #[test]
    fn paste_key_verify_error_second_enter_saves_and_continues() {
        let mut picker = picker_with_key_entry();
        picker.key_entry.as_mut().unwrap().api_key = "sk-something".to_string();

        // First Enter → fires VerifyKey, not a terminal action.
        let first = picker.key_entry_submit();
        assert!(matches!(first, Some(ModelPickerAction::VerifyKey { .. })));

        // Backend comes back with a network/unverified error (the exact bug:
        // ollama_cloud's Bearer-vs-device-identity mismatch, or any transport
        // failure) — this must NOT be reported as an invalid key, and must
        // NOT dead-end the screen.
        picker.set_verify_error("Connection failed: timeout".to_string());

        // Second Enter (unmodified key) → save-and-continue, not re-verify.
        let second = picker.key_entry_submit();
        match second {
            Some(ModelPickerAction::SaveKeyAndSwitch { api_key, .. }) => {
                assert_eq!(api_key.as_deref(), Some("sk-something"));
            }
            other => panic!("expected SaveKeyAndSwitch, got {:?}", other),
        }
    }

    #[test]
    fn paste_key_verify_rejected_second_enter_still_allows_save_anyway() {
        let mut picker = picker_with_key_entry();
        picker.key_entry.as_mut().unwrap().api_key = "bad-key".to_string();
        let _ = picker.key_entry_submit();

        // Explicit 401/403 rejection this time.
        picker.set_verify_failed("API key is invalid or expired.".to_string());

        let second = picker.key_entry_submit();
        assert!(
            matches!(second, Some(ModelPickerAction::SaveKeyAndSwitch { .. })),
            "a rejected key must still be save-able so the user can fix it later, got {:?}",
            second
        );
    }

    #[test]
    fn paste_key_editing_after_failure_resets_to_reverify_not_save() {
        let mut picker = picker_with_key_entry();
        picker.key_entry.as_mut().unwrap().api_key = "sk-something".to_string();
        let _ = picker.key_entry_submit();
        picker.set_verify_error("timeout".to_string());

        // Typing a correction resets verify state — Enter should re-verify,
        // not silently save the edited-but-unverified key.
        picker.handle_key(key(KeyCode::Char('x')));
        let after_edit = picker.key_entry_submit();
        assert!(matches!(
            after_edit,
            Some(ModelPickerAction::VerifyKey { .. })
        ));
    }

    // ── Account sign-in: reachable, non-terminal, cancellable ───────────────

    #[test]
    fn account_method_starts_a_sign_in_instead_of_asking_for_a_key() {
        // The whole point of the mode. Previously this branch printed
        // "OAuth sign-in coming soon" and every account provider was a dead
        // end in this screen.
        let mut picker = picker_with_key_entry();
        picker.key_entry.as_mut().unwrap().auth_method = AuthMethod::Account;

        assert!(matches!(
            picker.key_entry_submit(),
            Some(ModelPickerAction::StartAccountLogin { .. })
        ));
    }

    #[test]
    fn beginning_a_sign_in_keeps_the_picker_open() {
        // A device-code grant has to render its code SOMEWHERE. Closing the
        // dialog on start is exactly what forced "run this in another
        // terminal" as the only way in.
        let mut picker = picker_with_key_entry();
        picker.begin_account_login("ollama_cloud".to_string(), "m".to_string());

        assert!(matches!(picker.mode, PickerMode::AccountLogin));
    }

    #[test]
    fn a_pending_session_shows_the_code_and_url_and_does_not_finish() {
        let mut picker = picker_with_key_entry();
        picker.begin_account_login("ollama_cloud".to_string(), "m".to_string());

        let action = picker.apply_account_login(&session("pending", Some("ABCD-1234")));

        assert!(action.is_none(), "a pending sign-in must not save anything");
        let al = picker.account_login.as_ref().unwrap();
        assert_eq!(al.user_code.as_deref(), Some("ABCD-1234"));
        assert_eq!(al.verification_uri.as_deref(), Some("https://example.test/device"));
        assert_eq!(picker.account_login_session_id().as_deref(), Some("sess-1"));
    }

    #[test]
    fn a_connected_session_saves_and_switches_with_no_key() {
        // `api_key: None` is load-bearing: an empty string would write a blank
        // entry into .env and shadow the real credential on the next turn.
        let mut picker = picker_with_key_entry();
        picker.begin_account_login("ollama_cloud".to_string(), "glm".to_string());

        let action = picker.apply_account_login(&session("connected", None));

        match action {
            Some(ModelPickerAction::SaveKeyAndSwitch {
                provider,
                api_key,
                model,
                ..
            }) => {
                assert_eq!(provider, "ollama_cloud");
                assert_eq!(model, "glm");
                assert!(api_key.is_none());
            }
            other => panic!("expected a save, got {:?}", other),
        }
    }

    #[test]
    fn esc_cancels_the_sign_in_and_returns_to_the_provider_list() {
        let mut picker = picker_with_key_entry();
        picker.begin_account_login("ollama_cloud".to_string(), "m".to_string());
        let _ = picker.apply_account_login(&session("pending", Some("CODE")));

        let action = picker.handle_key(key(KeyCode::Esc));

        assert!(matches!(
            action,
            Some(ModelPickerAction::CancelAccountLogin { .. })
        ));
        assert!(matches!(picker.mode, PickerMode::Providers));
    }

    #[test]
    fn esc_before_the_session_id_arrives_still_leaves_the_screen() {
        // The window between "Enter pressed" and "backend answered" is short
        // but real, and a wait screen the user cannot leave is worse than an
        // orphaned grant — which the backend abandons on its own deadline.
        let mut picker = picker_with_key_entry();
        picker.begin_account_login("ollama_cloud".to_string(), "m".to_string());

        assert!(picker.handle_key(key(KeyCode::Esc)).is_none());
        assert!(matches!(picker.mode, PickerMode::Providers));
    }

    #[test]
    fn a_failed_sign_in_shows_its_message_and_is_not_a_dead_end() {
        let mut picker = picker_with_key_entry();
        picker.begin_account_login("ollama_cloud".to_string(), "m".to_string());

        let mut failed = session("failed", None);
        failed.message = Some("Ollama is not signed in. Run `ollama signin`.".to_string());
        assert!(picker.apply_account_login(&failed).is_none());

        // Enter on a terminal failure goes back rather than retrying blindly:
        // the message names something to fix elsewhere first.
        assert!(picker.handle_key(key(KeyCode::Enter)).is_none());
        assert!(matches!(picker.mode, PickerMode::Providers));
    }

    #[test]
    fn auth_methods_come_from_the_catalog_and_never_from_a_list_here() {
        let mut p = ollama_cloud_provider();

        p.auth_modes = None;
        assert_eq!(ModelPicker::auth_methods(&p).len(), 1, "older backend → key only");

        p.auth_modes = Some(vec!["api_key".into(), "oauth".into()]);
        let methods = ModelPicker::auth_methods(&p);
        assert_eq!(methods.len(), 2);
        assert_eq!(methods[0], AuthMethod::Account, "sign-in is offered first");

        // A provider with no key path must not be offered a key field.
        p.auth_modes = Some(vec!["oauth".into()]);
        assert_eq!(ModelPicker::auth_methods(&p), vec![AuthMethod::Account]);

        // `usable_auth_modes` wins: a sign-in this build cannot run is dropped
        // upstream, and offering it anyway is a route that cannot complete.
        p.auth_modes = Some(vec!["api_key".into(), "oauth".into()]);
        p.usable_auth_modes = Some(vec!["api_key".into()]);
        assert_eq!(ModelPicker::auth_methods(&p), vec![AuthMethod::PasteKey]);
    }

    fn session(state: &str, user_code: Option<&str>) -> crate::client::types::LoginSessionResponse {
        crate::client::types::LoginSessionResponse {
            id: "sess-1".to_string(),
            provider: "ollama_cloud".to_string(),
            state: state.to_string(),
            user_code: user_code.map(|c| c.to_string()),
            verification_uri: Some("https://example.test/device".to_string()),
            verification_uri_complete: None,
            message: None,
            error: None,
        }
    }

    // ── Load-path hardening: failed initial fetch is never a dead end ───────

    #[test]
    fn fallback_picker_always_has_a_usable_provider_list() {
        let picker =
            ModelPicker::new_fallback("anthropic".to_string(), "claude".to_string());
        assert!(picker.load_failed);
        assert!(!picker.providers.is_empty());
        // The zero-config local option must always be present so a newcomer
        // has at least one path that needs no key at all.
        assert!(picker.providers.iter().any(|p| p.id == "ollama_local"));
    }

    #[test]
    fn ctrl_r_in_providers_mode_requests_a_reload() {
        let mut picker =
            ModelPicker::new_fallback("anthropic".to_string(), "claude".to_string());
        let action = picker.handle_key(ctrl(KeyCode::Char('r')));
        assert!(matches!(action, Some(ModelPickerAction::Reload)));
    }
}

#[cfg(test)]
mod clean_key_tests {
    use super::clean_pasted_key;

    #[test]
    fn lone_quote_char_does_not_panic() {
        // A single quote char must not slice &value[1..0] (start > end).
        for q in ["\"", "'", "`"] {
            assert_eq!(clean_pasted_key(q), q);
        }
    }

    #[test]
    fn strips_paired_quotes_and_export_prefix() {
        assert_eq!(clean_pasted_key("\"abc\""), "abc");
        assert_eq!(clean_pasted_key("export KEY=\"secret\""), "secret");
        assert_eq!(clean_pasted_key("KEY=value"), "value");
    }

    #[test]
    fn multibyte_value_does_not_panic() {
        let _ = clean_pasted_key(&"\u{20ac}".repeat(30));
        let _ = clean_pasted_key("\"\u{4e2d}\u{6587}\"");
    }
}

/// Greedy word wrap for the sign-in screen's message line.
///
/// Failure messages here are full sentences that name a command or a URL, and
/// truncating one at the dialog edge removes exactly the part the user needs.
fn wrap_text(text: &str, width: usize) -> Vec<String> {
    if width == 0 {
        return vec![text.to_string()];
    }
    let mut lines = Vec::new();
    let mut current = String::new();
    for word in text.split_whitespace() {
        if current.is_empty() {
            current.push_str(word);
        } else if current.chars().count() + 1 + word.chars().count() <= width {
            current.push(' ');
            current.push_str(word);
        } else {
            lines.push(std::mem::take(&mut current));
            current.push_str(word);
        }
    }
    if !current.is_empty() {
        lines.push(current);
    }
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}
