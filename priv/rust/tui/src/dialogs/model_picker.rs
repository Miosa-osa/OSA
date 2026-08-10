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

const MAX_W: u16 = 82;
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
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum AuthMethod {
    PasteKey,
    OAuth,
    DeviceFree,
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
                models: serde_json::Value::String("dynamic".to_string()),
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
                models: serde_json::Value::String("dynamic".to_string()),
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
                models: serde_json::Value::String("dynamic".to_string()),
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
                models: serde_json::Value::String("dynamic".to_string()),
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

    fn sorted_order(providers: &[OnboardingProvider]) -> Vec<usize> {
        let mut idx: Vec<usize> = (0..providers.len()).collect();
        idx.sort_by(|&a, &b| {
            let pa = Self::priority(&providers[a].id);
            let pb = Self::priority(&providers[b].id);
            pa.cmp(&pb).then_with(|| providers[a].name.cmp(&providers[b].name))
        });
        idx
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
    fn is_ready(&self, p: &OnboardingProvider) -> bool {
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

    /// OpenCode-style configured suffix, e.g. " (api)".
    fn configured_suffix(&self, p: &OnboardingProvider) -> &'static str {
        if self.detected_ids().contains(&p.id) {
            " (api)"
        } else {
            ""
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

    fn open_key_entry(&mut self, p: &OnboardingProvider) {
        // Auth methods available per provider. PasteKey is always first and the
        // default focus. OAuth is a "coming soon" stub for providers that will
        // support sign-in. Ollama Cloud offers a key-free device-identity path.
        //
        // Anthropic is deliberately NOT in the OAuth list: OSA's Anthropic
        // subscription sign-in was removed (Anthropic does not permit
        // subscription credentials in third-party tools), so advertising
        // "Sign in (OAuth) — coming soon" for it would promise something that
        // is never coming. Anthropic is API-key only.
        let methods: Vec<AuthMethod> = match p.id.as_str() {
            "ollama_cloud" => vec![AuthMethod::PasteKey, AuthMethod::DeviceFree],
            "miosa" => vec![AuthMethod::PasteKey, AuthMethod::OAuth],
            _ => vec![AuthMethod::PasteKey],
        };
        self.key_entry = Some(KeyEntryState {
            provider_id: p.id.clone(),
            provider_name: p.name.clone(),
            signup_url: p.signup_url.clone(),
            base_url: p.base_url.clone(),
            default_model: p.default_model.clone(),
            api_key: String::new(),
            masked: true,
            auth_method: AuthMethod::PasteKey,
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
            AuthMethod::OAuth => {
                // Stub — must not trap. PasteKey remains reachable via Tab.
                ke.verify = VerifyState::Error {
                    reason: "OAuth sign-in coming soon — use Tab for Paste API key".into(),
                };
                None
            }
            AuthMethod::DeviceFree => {
                // Ollama Cloud key-free: verify against the LOCAL daemon (device
                // identity), no key. Uses provider="ollama_local" + localhost.
                match &ke.verify {
                    VerifyState::Valid { .. } => {
                        let provider = ke.provider_id.clone();
                        ke.verify = VerifyState::Idle;
                        Some(ModelPickerAction::SaveKeyAndSwitch {
                            runtime_provider: Self::runtime_provider(&provider),
                            provider,
                            api_key: None,
                            model,
                            base_url: Some("http://localhost:11434".to_string()),
                        })
                    }
                    VerifyState::Verifying => None,
                    // Hotfix: a failed/errored verify must never dead-end the
                    // screen. A second, unmodified Enter (the user already saw
                    // the failure reason and pressed Enter again deliberately)
                    // saves and continues anyway — mirrors the CLI wizard's
                    // "Continue anyway" choice for the TUI's keyboard-only flow.
                    VerifyState::Invalid { .. } | VerifyState::Error { .. } => {
                        let provider = ke.provider_id.clone();
                        ke.verify = VerifyState::Idle;
                        Some(ModelPickerAction::SaveKeyAndSwitch {
                            runtime_provider: Self::runtime_provider(&provider),
                            provider,
                            api_key: None,
                            model,
                            base_url: Some("http://localhost:11434".to_string()),
                        })
                    }
                    VerifyState::Idle => {
                        ke.verify = VerifyState::Verifying;
                        Some(ModelPickerAction::VerifyKey {
                            provider: "ollama_local".to_string(),
                            api_key: None,
                            model,
                            base_url: Some("http://localhost:11434".to_string()),
                        })
                    }
                }
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

        let w = MAX_W.min(area.width);
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

        // Build the flat renderable row list: Default + visible providers.
        // Row 0 is the Default (recommended) entry.
        let total_rows = vis.len() + 1;
        for rel in 0..(list_h as usize) {
            let abs = rel + scroll;
            if abs >= total_rows {
                break;
            }
            let ry = cy + rel as u16;
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
            let ready = self.is_ready(p);
            let (tag, tag_style) = if ready {
                ("✓ ready", Style::default().fg(theme.colors.success))
            } else {
                ("⚠ needs key", Style::default().fg(theme.colors.warning))
            };
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

            frame.render_widget(
                Paragraph::new(Line::from(spans)),
                Rect::new(inner.x, ry, inner.width.min(46), 1),
            );

            // Dim capability hint on the right side of the row.
            if !p.description.is_empty() && inner.width > 48 {
                let hint = format!("{}  ", p.description);
                let hint_w = inner.width.saturating_sub(48);
                let para = Paragraph::new(Span::styled(
                    hint,
                    Style::default().fg(theme.colors.dim),
                ))
                .alignment(Alignment::Right);
                frame.render_widget(para, Rect::new(inner.x + 48, ry, hint_w, 1));
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
                    AuthMethod::OAuth => "Sign in (OAuth)",
                    AuthMethod::DeviceFree => "Use key-free (device identity)",
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
            AuthMethod::DeviceFree => {
                frame.render_widget(
                    Paragraph::new(Span::styled(
                        "  Uses your signed-in local Ollama (no API key needed).",
                        Style::default().fg(theme.colors.secondary),
                    )),
                    Rect::new(inner.x, cy, inner.width, 1),
                );
                cy += 2;
            }
            AuthMethod::OAuth => {
                frame.render_widget(
                    Paragraph::new(Span::styled(
                        "  OAuth sign-in is coming soon — press Tab to paste a key.",
                        Style::default().fg(theme.colors.warning),
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

    // ── DeviceFree (keyless ollama_cloud): same guarantee ────────────────────

    #[test]
    fn device_free_verify_error_second_enter_saves_anyway() {
        let mut picker = picker_with_key_entry();
        picker.key_entry.as_mut().unwrap().auth_method = AuthMethod::DeviceFree;

        let first = picker.key_entry_submit();
        assert!(matches!(first, Some(ModelPickerAction::VerifyKey { .. })));

        picker.set_verify_error("no local daemon reachable".to_string());
        let second = picker.key_entry_submit();
        assert!(matches!(
            second,
            Some(ModelPickerAction::SaveKeyAndSwitch { api_key: None, .. })
        ));
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
