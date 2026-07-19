//! WS10 — user-configurable keybinding layer.
//!
//! Compiled defaults (matching OSA's historical hardcoded chords) overlaid by
//! `~/.osa/keybindings.json`, loaded once at startup. `app/update.rs` consults
//! the resolver (via `App::resolve_keymap` in `app/keymap_dispatch.rs`) before
//! its remaining hardcoded arms, so every action listed here is rebindable
//! without a rebuild.
//!
//! File format (Claude Code-compatible block list):
//!
//! ```json
//! [
//!   { "context": "global", "bindings": { "ctrl+x ctrl+k": "chat:killAgents" } },
//!   { "context": "idle",   "bindings": { "ctrl+n": "none", "alt+n": "app:newSession" } }
//! ]
//! ```
//!
//! * Chords are space-separated multi-step sequences of `mod+key` steps
//!   (`ctrl+x ctrl+k`).
//! * Modifier aliases: ctrl/control, alt/opt/option/meta, shift,
//!   cmd/command/super/win.
//! * `"none"` / `"unbound"` removes a default binding for that chord.
//! * A value starting with `/` runs that slash command (e.g. `"/compact"`).
//! * `ctrl+c`, `ctrl+d`, `ctrl+m` (Enter alias), `enter` and `esc` are
//!   non-rebindable — their semantics (interrupt/quit/submit/cancel with
//!   time-gated double-press) are hardwired, matching Claude Code.

// Some helpers (shortcut_display) are consumed by later workstreams (WS12
// footer hints); keep them compiled now so the API is stable.
#![allow(dead_code)]

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use std::path::Path;

/// Modifier bits considered for matching. The kitty keyboard protocol can
/// attach extra state bits (keypad, caps-lock); masking keeps chords portable.
fn mod_mask() -> KeyModifiers {
    KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SHIFT | KeyModifiers::SUPER
}

/// One step of a chord: a key plus its required modifiers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Keystroke {
    pub code: KeyCode,
    pub mods: KeyModifiers,
}

impl Keystroke {
    /// Whether `ev` is this keystroke, normalizing the cross-terminal quirks:
    /// Shift+Tab ↔ BackTab encodings, uppercase-char-vs-SHIFT-bit for letters,
    /// and stray protocol modifier bits outside the mask.
    pub fn matches(&self, ev: &KeyEvent) -> bool {
        let mask = mod_mask();
        let ev_mods = ev.modifiers.intersection(mask);
        let want = self.mods;
        // Shift+Tab: most terminals emit BackTab (with or without a stray
        // SHIFT), a few report Tab+SHIFT — accept both encodings.
        if self.code == KeyCode::Tab
            && want.contains(KeyModifiers::SHIFT)
            && ev.code == KeyCode::BackTab
        {
            return true;
        }
        match (self.code, ev.code) {
            (KeyCode::Char(a), KeyCode::Char(b)) => {
                if a.to_ascii_lowercase() != b.to_ascii_lowercase() {
                    return false;
                }
                let non_shift = mask.difference(KeyModifiers::SHIFT);
                if want.intersection(non_shift) != ev_mods.intersection(non_shift) {
                    return false;
                }
                if a.is_ascii_alphabetic() {
                    // Terminals disagree whether Ctrl+Shift+L reports 'l'+SHIFT
                    // or 'L': treat an uppercase char as an implicit SHIFT and
                    // require parity, so ctrl+l can never fire on ctrl+shift+l.
                    let ev_shift =
                        ev_mods.contains(KeyModifiers::SHIFT) || b.is_ascii_uppercase();
                    let want_shift =
                        want.contains(KeyModifiers::SHIFT) || a.is_ascii_uppercase();
                    ev_shift == want_shift
                } else {
                    // Punctuation: shift is baked into the character itself and
                    // terminals disagree on the bit — ignore it.
                    true
                }
            }
            (a, b) => a == b && want == ev_mods,
        }
    }
}

/// Parse one `mod+key` step (`ctrl+shift+k`, `alt+enter`, `f9`, `opt+v`).
pub fn parse_keystroke(s: &str) -> Option<Keystroke> {
    let mut mods = KeyModifiers::NONE;
    let mut code: Option<KeyCode> = None;
    for part in s.split('+') {
        let p = part.trim().to_ascii_lowercase();
        match p.as_str() {
            "ctrl" | "control" => mods |= KeyModifiers::CONTROL,
            "alt" | "opt" | "option" | "meta" => mods |= KeyModifiers::ALT,
            "shift" => mods |= KeyModifiers::SHIFT,
            "cmd" | "command" | "super" | "win" => mods |= KeyModifiers::SUPER,
            "esc" | "escape" => code = Some(KeyCode::Esc),
            "enter" | "return" => code = Some(KeyCode::Enter),
            "space" => code = Some(KeyCode::Char(' ')),
            "tab" => code = Some(KeyCode::Tab),
            "backtab" => code = Some(KeyCode::BackTab),
            "backspace" => code = Some(KeyCode::Backspace),
            "delete" | "del" => code = Some(KeyCode::Delete),
            "insert" => code = Some(KeyCode::Insert),
            "home" => code = Some(KeyCode::Home),
            "end" => code = Some(KeyCode::End),
            "pageup" => code = Some(KeyCode::PageUp),
            "pagedown" => code = Some(KeyCode::PageDown),
            "up" | "\u{2191}" => code = Some(KeyCode::Up),
            "down" | "\u{2193}" => code = Some(KeyCode::Down),
            "left" | "\u{2190}" => code = Some(KeyCode::Left),
            "right" | "\u{2192}" => code = Some(KeyCode::Right),
            other => {
                if let Some(n) = other.strip_prefix('f').and_then(|n| n.parse::<u8>().ok())
                {
                    if (1..=12).contains(&n) {
                        code = Some(KeyCode::F(n));
                        continue;
                    }
                }
                let mut chars = other.chars();
                match (chars.next(), chars.next()) {
                    (Some(c), None) => code = Some(KeyCode::Char(c)),
                    _ => return None,
                }
            }
        }
    }
    code.map(|code| Keystroke { code, mods })
}

/// Parse a full (possibly multi-step) chord: `"ctrl+x ctrl+k"`.
pub fn parse_chord(s: &str) -> Option<Vec<Keystroke>> {
    // A lone space character IS the space key, not a step separator.
    if s == " " {
        return parse_keystroke("space").map(|k| vec![k]);
    }
    let steps = s
        .split_whitespace()
        .map(parse_keystroke)
        .collect::<Option<Vec<_>>>()?;
    if steps.is_empty() {
        None
    } else {
        Some(steps)
    }
}

/// Everything the keybinding layer can dispatch. `Command` runs an arbitrary
/// slash command, so users can bind chords to any `/command` without new code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    /// Explicit unbind marker (`"none"`); never stored in the map.
    Unbound,
    Help,
    Redraw,
    ToggleSidebar,
    NewSession,
    Suspend,
    Palette,
    CycleMode,
    Voice,
    HandsFree,
    Paste,
    ExpandTools,
    Background,
    KillAgents,
    ModelPicker,
    ThinkingToggle,
    TodosToggle,
    CopyLast,
    /// U-T7 — flip the chat between rendered markdown and its raw source view.
    RawToggle,
    /// WS5 — interrupt the running turn (chat:interrupt). Esc / Ctrl+C are
    /// hardwired to the same path in update.rs (non-rebindable); this action
    /// lets users bind ADDITIONAL keys to interrupt.
    Interrupt,
    Command(String),
}

impl Action {
    pub fn parse(s: &str) -> Option<Action> {
        Some(match s {
            "none" | "unbound" | "" => Action::Unbound,
            "app:help" => Action::Help,
            "app:redraw" => Action::Redraw,
            "app:toggleSidebar" => Action::ToggleSidebar,
            "app:newSession" => Action::NewSession,
            "app:suspend" => Action::Suspend,
            "app:palette" => Action::Palette,
            "chat:cycleMode" => Action::CycleMode,
            "chat:voice" => Action::Voice,
            "chat:handsFree" => Action::HandsFree,
            "chat:paste" => Action::Paste,
            "chat:expandTools" => Action::ExpandTools,
            "chat:background" => Action::Background,
            "chat:killAgents" => Action::KillAgents,
            "chat:modelPicker" => Action::ModelPicker,
            "chat:thinkingToggle" => Action::ThinkingToggle,
            "chat:todosToggle" => Action::TodosToggle,
            "chat:copyLast" => Action::CopyLast,
            "chat:rawToggle" => Action::RawToggle,
            "chat:interrupt" => Action::Interrupt,
            s if s.starts_with('/') => Action::Command(s.to_string()),
            _ => return None,
        })
    }

    /// The stable string id (what users write in keybindings.json).
    pub fn id(&self) -> String {
        match self {
            Action::Unbound => "none".into(),
            Action::Help => "app:help".into(),
            Action::Redraw => "app:redraw".into(),
            Action::ToggleSidebar => "app:toggleSidebar".into(),
            Action::NewSession => "app:newSession".into(),
            Action::Suspend => "app:suspend".into(),
            Action::Palette => "app:palette".into(),
            Action::CycleMode => "chat:cycleMode".into(),
            Action::Voice => "chat:voice".into(),
            Action::HandsFree => "chat:handsFree".into(),
            Action::Paste => "chat:paste".into(),
            Action::ExpandTools => "chat:expandTools".into(),
            Action::Background => "chat:background".into(),
            Action::KillAgents => "chat:killAgents".into(),
            Action::ModelPicker => "chat:modelPicker".into(),
            Action::ThinkingToggle => "chat:thinkingToggle".into(),
            Action::TodosToggle => "chat:todosToggle".into(),
            Action::CopyLast => "chat:copyLast".into(),
            Action::RawToggle => "chat:rawToggle".into(),
            Action::Interrupt => "chat:interrupt".into(),
            Action::Command(c) => c.clone(),
        }
    }
}

/// Where a binding applies. State-specific bindings win over `Global`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Context {
    Global,
    /// Composer idle (AppState::Idle).
    Idle,
    /// Mid-turn (AppState::Processing).
    Processing,
}

impl Context {
    fn parse(s: &str) -> Option<Context> {
        match s.to_ascii_lowercase().as_str() {
            "global" => Some(Context::Global),
            "idle" | "chat" => Some(Context::Idle),
            "processing" => Some(Context::Processing),
            _ => None,
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            Context::Global => "global",
            Context::Idle => "idle",
            Context::Processing => "processing",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Binding {
    pub context: Context,
    pub chord: Vec<Keystroke>,
    pub action: Action,
}

/// Outcome of resolving a key sequence against the map.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Resolution {
    /// The sequence exactly matches a binding.
    Action(Action),
    /// The sequence is a strict prefix of at least one multi-step chord —
    /// the caller should hold the keys pending and wait for the next press.
    Prefix,
    /// No binding involves this sequence.
    None,
}

/// Chords whose semantics are hardwired (interrupt / quit / submit / cancel
/// with double-press windows) and may not appear in user bindings.
fn non_rebindable_reason(chord: &[Keystroke]) -> Option<&'static str> {
    for ks in chord {
        let bad = match (ks.code, ks.mods) {
            (KeyCode::Char('c'), m) if m == KeyModifiers::CONTROL => {
                Some("ctrl+c is reserved (interrupt / quit, double-press)")
            }
            (KeyCode::Char('d'), m) if m == KeyModifiers::CONTROL => {
                Some("ctrl+d is reserved (quit)")
            }
            (KeyCode::Char('m'), m) if m == KeyModifiers::CONTROL => {
                Some("ctrl+m is identical to Enter in terminals")
            }
            (KeyCode::Esc, _) => {
                Some("esc is reserved (cancel / double-press chords)")
            }
            (KeyCode::Enter, m) if m == KeyModifiers::NONE => {
                Some("enter is reserved (submit)")
            }
            _ => None,
        };
        if bad.is_some() {
            return bad;
        }
    }
    None
}

/// The loaded keybinding map: compiled defaults overlaid by the user file.
#[derive(Debug, Clone)]
pub struct Keybindings {
    bindings: Vec<Binding>,
    warnings: Vec<String>,
}

impl Keybindings {
    /// The compiled defaults — exactly OSA's historical hardcoded chords, plus
    /// the WS10 additions (ctrl+x ctrl+k, alt+p, alt+t, ctrl+t).
    pub fn defaults() -> Self {
        let table: &[(Context, &str, Action)] = &[
            (Context::Global, "ctrl+l", Action::Redraw),
            (Context::Global, "ctrl+shift+l", Action::ToggleSidebar),
            (Context::Global, "ctrl+z", Action::Suspend),
            (Context::Global, "ctrl+o", Action::ExpandTools),
            (Context::Global, "ctrl+x ctrl+k", Action::KillAgents),
            (Context::Global, "alt+p", Action::ModelPicker),
            (Context::Global, "alt+t", Action::ThinkingToggle),
            (Context::Global, "ctrl+t", Action::TodosToggle),
            // U-T7 — raw-markdown view toggle (Ctrl+R is reverse-search, so alt+r).
            (Context::Global, "alt+r", Action::RawToggle),
            // Display/parity entry: the hardcoded is_permission_cycle check
            // runs first (Shift+Tab encodings are quirky), so this binding is
            // authoritative for shortcut_display but not for dispatch.
            (Context::Global, "shift+tab", Action::CycleMode),
            (Context::Idle, "f1", Action::Help),
            (Context::Idle, "alt+v", Action::Voice),
            (Context::Idle, "f9", Action::HandsFree),
            (Context::Idle, "ctrl+n", Action::NewSession),
            (Context::Idle, "ctrl+k", Action::Palette),
            (Context::Idle, "ctrl+v", Action::Paste),
            (Context::Processing, "ctrl+b", Action::Background),
        ];
        let bindings = table
            .iter()
            .map(|(ctx, chord, action)| Binding {
                context: *ctx,
                chord: parse_chord(chord).expect("default chord must parse"),
                action: action.clone(),
            })
            .collect();
        Keybindings {
            bindings,
            warnings: Vec::new(),
        }
    }

    /// Defaults overlaid by the user's keybindings file (missing file is fine).
    pub fn load(path: &Path) -> Self {
        let mut kb = Self::defaults();
        if let Ok(text) = std::fs::read_to_string(path) {
            kb.apply_user(&text);
        }
        kb
    }

    /// Apply user JSON over the current map. Invalid entries are skipped and
    /// recorded in `load_warnings()` — one bad line never disables the rest.
    pub fn apply_user(&mut self, text: &str) {
        let val: serde_json::Value = match serde_json::from_str(text) {
            Ok(v) => v,
            Err(e) => {
                self.warnings
                    .push(format!("keybindings.json parse error: {e}"));
                return;
            }
        };
        let Some(blocks) = val.as_array() else {
            self.warnings.push(
                "keybindings.json must be an array of {context, bindings} blocks".into(),
            );
            return;
        };
        for block in blocks {
            let ctx_str = block
                .get("context")
                .and_then(|v| v.as_str())
                .unwrap_or("global");
            let Some(ctx) = Context::parse(ctx_str) else {
                self.warnings.push(format!(
                    "unknown context '{ctx_str}' (use global|idle|processing)"
                ));
                continue;
            };
            let Some(map) = block.get("bindings").and_then(|v| v.as_object()) else {
                continue;
            };
            for (chord_str, action_val) in map {
                let Some(chord) = parse_chord(chord_str) else {
                    self.warnings
                        .push(format!("unparseable chord '{chord_str}'"));
                    continue;
                };
                if let Some(reason) = non_rebindable_reason(&chord) {
                    self.warnings.push(format!("'{chord_str}': {reason}"));
                    continue;
                }
                let action_str = action_val.as_str().unwrap_or("");
                let Some(action) = Action::parse(action_str) else {
                    self.warnings.push(format!(
                        "'{chord_str}': unknown action '{action_str}'"
                    ));
                    continue;
                };
                self.set_binding(ctx, chord, action);
            }
        }
    }

    /// Replace any binding for `chord` in `ctx` (Unbound just removes).
    pub fn set_binding(&mut self, ctx: Context, chord: Vec<Keystroke>, action: Action) {
        self.bindings
            .retain(|b| !(b.context == ctx && b.chord == chord));
        if action != Action::Unbound {
            self.bindings.push(Binding {
                context: ctx,
                chord,
                action,
            });
        }
    }

    /// Resolve a pressed key sequence in `ctx`. State-specific bindings are
    /// checked before `Global` so a state can shadow a global chord.
    pub fn resolve(&self, ctx: Context, seq: &[KeyEvent]) -> Resolution {
        if seq.is_empty() {
            return Resolution::None;
        }
        let passes: &[Context] = if ctx == Context::Global {
            &[Context::Global]
        } else {
            &[ctx, Context::Global]
        };
        let mut prefix = false;
        for pass in passes {
            for b in &self.bindings {
                if b.context != *pass || b.chord.len() < seq.len() {
                    continue;
                }
                if !seq.iter().zip(b.chord.iter()).all(|(e, k)| k.matches(e)) {
                    continue;
                }
                if b.chord.len() == seq.len() {
                    return Resolution::Action(b.action.clone());
                }
                prefix = true;
            }
        }
        if prefix {
            Resolution::Prefix
        } else {
            Resolution::None
        }
    }

    /// The display chord for `action` (first binding wins) — the single source
    /// for footer hints / help text, replacing hardcoded hint strings.
    pub fn shortcut_display(&self, action: &Action) -> Option<String> {
        self.bindings
            .iter()
            .find(|b| &b.action == action)
            .map(|b| format_chord(&b.chord))
    }

    /// Human-readable listing of every active binding (used by /keybindings).
    pub fn describe(&self) -> String {
        let mut lines: Vec<String> = self
            .bindings
            .iter()
            .map(|b| {
                format!(
                    "  {:<18} {:<11} {}",
                    format_chord(&b.chord),
                    b.context.name(),
                    b.action.id()
                )
            })
            .collect();
        lines.sort();
        lines.join("\n")
    }

    /// Problems found while loading the user file (bad chords, reserved keys).
    pub fn load_warnings(&self) -> &[String] {
        &self.warnings
    }
}

/// Canonical display form of one keystroke: `ctrl+shift+l`, `alt+v`, `f9`.
pub fn format_keystroke(ks: &Keystroke) -> String {
    let mut parts: Vec<String> = Vec::new();
    if ks.mods.contains(KeyModifiers::CONTROL) {
        parts.push("ctrl".into());
    }
    if ks.mods.contains(KeyModifiers::ALT) {
        parts.push("alt".into());
    }
    if ks.mods.contains(KeyModifiers::SHIFT) {
        parts.push("shift".into());
    }
    if ks.mods.contains(KeyModifiers::SUPER) {
        parts.push("cmd".into());
    }
    let key = match ks.code {
        KeyCode::Esc => "esc".into(),
        KeyCode::Enter => "enter".into(),
        KeyCode::Char(' ') => "space".into(),
        KeyCode::Char(c) => c.to_string(),
        KeyCode::Tab => "tab".into(),
        KeyCode::BackTab => "backtab".into(),
        KeyCode::Backspace => "backspace".into(),
        KeyCode::Delete => "delete".into(),
        KeyCode::Insert => "insert".into(),
        KeyCode::Home => "home".into(),
        KeyCode::End => "end".into(),
        KeyCode::PageUp => "pageup".into(),
        KeyCode::PageDown => "pagedown".into(),
        KeyCode::Up => "up".into(),
        KeyCode::Down => "down".into(),
        KeyCode::Left => "left".into(),
        KeyCode::Right => "right".into(),
        KeyCode::F(n) => format!("f{n}"),
        other => format!("{other:?}").to_ascii_lowercase(),
    };
    parts.push(key);
    parts.join("+")
}

/// Display form of a full chord (`ctrl+x ctrl+k`).
pub fn format_chord(chord: &[Keystroke]) -> String {
    chord
        .iter()
        .map(format_keystroke)
        .collect::<Vec<_>>()
        .join(" ")
}

/// Display form of a raw key event (for pending-chord hints).
pub fn format_key_event(ev: &KeyEvent) -> String {
    format_keystroke(&Keystroke {
        code: ev.code,
        mods: ev.modifiers.intersection(mod_mask()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(code: KeyCode, mods: KeyModifiers) -> KeyEvent {
        KeyEvent::new(code, mods)
    }

    #[test]
    fn parses_aliases_and_chords() {
        assert_eq!(
            parse_keystroke("opt+v").unwrap(),
            Keystroke {
                code: KeyCode::Char('v'),
                mods: KeyModifiers::ALT
            }
        );
        assert_eq!(parse_keystroke("f9").unwrap().code, KeyCode::F(9));
        assert_eq!(parse_chord("ctrl+x ctrl+k").unwrap().len(), 2);
        assert_eq!(
            format_chord(&parse_chord("ctrl+x ctrl+k").unwrap()),
            "ctrl+x ctrl+k"
        );
        assert!(parse_keystroke("ctrl+notakey").is_none());
    }

    #[test]
    fn matching_normalizes_shift_and_backtab() {
        let st = parse_keystroke("shift+tab").unwrap();
        assert!(st.matches(&ev(KeyCode::BackTab, KeyModifiers::NONE)));
        assert!(st.matches(&ev(KeyCode::Tab, KeyModifiers::SHIFT)));
        let ctrl_l = parse_keystroke("ctrl+l").unwrap();
        assert!(ctrl_l.matches(&ev(KeyCode::Char('l'), KeyModifiers::CONTROL)));
        assert!(!ctrl_l.matches(&ev(
            KeyCode::Char('l'),
            KeyModifiers::CONTROL | KeyModifiers::SHIFT
        )));
        assert!(!ctrl_l.matches(&ev(KeyCode::Char('L'), KeyModifiers::CONTROL)));
        let csl = parse_keystroke("ctrl+shift+l").unwrap();
        assert!(csl.matches(&ev(KeyCode::Char('L'), KeyModifiers::CONTROL)));
        assert!(csl.matches(&ev(
            KeyCode::Char('l'),
            KeyModifiers::CONTROL | KeyModifiers::SHIFT
        )));
    }

    #[test]
    fn defaults_resolve_with_context_precedence() {
        let kb = Keybindings::defaults();
        assert_eq!(
            kb.resolve(
                Context::Idle,
                &[ev(KeyCode::Char('n'), KeyModifiers::CONTROL)]
            ),
            Resolution::Action(Action::NewSession)
        );
        // Global binding reachable from Processing.
        assert_eq!(
            kb.resolve(
                Context::Processing,
                &[ev(KeyCode::Char('l'), KeyModifiers::CONTROL)]
            ),
            Resolution::Action(Action::Redraw)
        );
        // Idle-only binding must NOT fire in Processing.
        assert_eq!(
            kb.resolve(
                Context::Processing,
                &[ev(KeyCode::Char('n'), KeyModifiers::CONTROL)]
            ),
            Resolution::None
        );
    }

    #[test]
    fn chord_prefix_then_action() {
        let kb = Keybindings::defaults();
        let x = ev(KeyCode::Char('x'), KeyModifiers::CONTROL);
        let k = ev(KeyCode::Char('k'), KeyModifiers::CONTROL);
        assert_eq!(kb.resolve(Context::Idle, &[x]), Resolution::Prefix);
        assert_eq!(
            kb.resolve(Context::Idle, &[x, k]),
            Resolution::Action(Action::KillAgents)
        );
        // Plain ctrl+k (no prefix) still resolves to the palette in Idle.
        assert_eq!(
            kb.resolve(Context::Idle, &[k]),
            Resolution::Action(Action::Palette)
        );
    }

    #[test]
    fn user_overrides_unbind_and_rebind() {
        let mut kb = Keybindings::defaults();
        kb.apply_user(
            r#"[
              {"context":"idle","bindings":{"ctrl+n":"none","alt+n":"app:newSession","ctrl+g":"/compact"}},
              {"context":"global","bindings":{"ctrl+c":"app:help","bogus++":"app:help","ctrl+q":"nosuch:action"}}
            ]"#,
        );
        assert_eq!(
            kb.resolve(
                Context::Idle,
                &[ev(KeyCode::Char('n'), KeyModifiers::CONTROL)]
            ),
            Resolution::None
        );
        assert_eq!(
            kb.resolve(Context::Idle, &[ev(KeyCode::Char('n'), KeyModifiers::ALT)]),
            Resolution::Action(Action::NewSession)
        );
        assert_eq!(
            kb.resolve(
                Context::Idle,
                &[ev(KeyCode::Char('g'), KeyModifiers::CONTROL)]
            ),
            Resolution::Action(Action::Command("/compact".into()))
        );
        // ctrl+c is non-rebindable; bad chord + unknown action warn too.
        assert_eq!(
            kb.resolve(
                Context::Global,
                &[ev(KeyCode::Char('c'), KeyModifiers::CONTROL)]
            ),
            Resolution::None
        );
        assert_eq!(kb.load_warnings().len(), 3);
    }

    #[test]
    fn shortcut_display_finds_first_chord() {
        let kb = Keybindings::defaults();
        assert_eq!(
            kb.shortcut_display(&Action::KillAgents).unwrap(),
            "ctrl+x ctrl+k"
        );
        assert_eq!(kb.shortcut_display(&Action::TodosToggle).unwrap(), "ctrl+t");
    }
}
